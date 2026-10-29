// 첫 실행 설정: 이 맥이 쓸 수 있는지 보고, 모델을 원본에서 내려받아 해시로 확인한다.
// 네트워크를 쓰는 곳은 여기(모델)와 Updater.swift(업데이트 확인) 둘뿐이다. 회의 데이터는 보내지 않는다.
import CryptoKit
import Foundation
import SwiftUI

struct ModelFile: Identifiable {
    let name: String
    let label: String
    let url: String
    let sha256: String
    let size: Int64
    var id: String { name }
    var path: URL { modelsRoot.appendingPathComponent(name) }
    var isReady: Bool {
        ((try? FileManager.default.attributesOfItem(atPath: path.path)[.size] as? Int64) ?? -1) == size
    }
}

let requiredModels: [ModelFile] = [
    ModelFile(name: "ggml-large-v3-turbo-q5_0.bin", label: "전사 (whisper large-v3-turbo, MIT)",
              url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin",
              sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2", size: 574_041_195),
    ModelFile(name: "3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx", label: "화자 분리 (3D-Speaker CAM++, Apache 2.0)",
              url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx",
              sha256: "aa3cfc16963a10586a9393f5035d6d6b57e98d358b347f80c2a30bf4f00ceba2", size: 28_281_164),
    ModelFile(name: "gemma-4-26B-A4B-it-UD-Q4_K_M.gguf", label: "회의록 (Gemma 4 26B-A4B, Apache 2.0)",
              url: "https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF/resolve/main/gemma-4-26B-A4B-it-UD-Q4_K_M.gguf",
              sha256: "f2c28b3dc4776931ac6f879e11f203dec637ea0f14267a86ec8f6165f63f293f", size: 16_947_541_728),
]

func formatBytes(_ b: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
}

@MainActor
final class SetupModel: ObservableObject {
    @Published var ready = requiredModels.allSatisfy(\.isReady)
    @Published var downloading = false
    @Published var current: String?
    @Published var received: Int64 = 0
    @Published var error: String?
    private var proc: Process?
    private var cancelled = false

    let memoryGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    var freeDisk: Int64 {
        (try? dataRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
    }
    var missing: [ModelFile] { requiredModels.filter { !$0.isReady } }
    var totalMissing: Int64 { missing.map(\.size).reduce(0, +) }
    var alreadyHave: Int64 {
        missing.map { m in
            (try? FileManager.default.attributesOfItem(atPath: m.path.path + ".part")[.size] as? Int64) ?? 0
        }.reduce(0, +)
    }

    func start() {
        guard !downloading else { return }
        try? FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
        downloading = true
        cancelled = false
        error = nil
        Task.detached { [weak self] in
            for m in requiredModels where !m.isReady {
                guard let self else { return }
                if await self.cancelled { break }
                await MainActor.run { self.current = m.label }
                if let e = await self.download(m) {
                    await MainActor.run { self.error = e }
                    break
                }
            }
            await MainActor.run {
                guard let self else { return }
                self.downloading = false
                self.current = nil
                self.ready = requiredModels.allSatisfy(\.isReady)
            }
        }
    }

    func cancel() {
        cancelled = true
        proc?.terminate()
    }

    /// curl 로 이어받기(-C -) 하고, 다 받으면 SHA-256 을 확인한 뒤 이름을 바꾼다.
    nonisolated private func download(_ m: ModelFile) async -> String? {
        let part = URL(fileURLWithPath: m.path.path + ".part")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = ["-L", "--fail", "--silent", "--show-error", "--retry", "5", "-C", "-", "-o", part.path, m.url]
        let err = Pipe()
        p.standardError = err
        do { try p.run() } catch { return "curl 을 실행하지 못했습니다: \(error.localizedDescription)" }
        await MainActor.run { self.proc = p }
        while p.isRunning {
            let got = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int64) ?? 0
            await MainActor.run { self.received = got }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        if await MainActor.run(body: { self.cancelled }) { return nil }
        if p.terminationStatus != 0 {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return "\(m.label) 내려받기 실패(이어받기 가능): \(msg.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        await MainActor.run { self.current = "\(m.label) — 확인 중(SHA-256)" }
        guard let h = try? sha256(of: part), h == m.sha256 else {
            try? FileManager.default.removeItem(at: part)
            return "\(m.label) 파일이 원본과 다릅니다(해시 불일치). 다시 받으세요."
        }
        try? FileManager.default.removeItem(at: m.path)
        do { try FileManager.default.moveItem(at: part, to: m.path) } catch { return error.localizedDescription }
        return nil
    }
}

func sha256(of url: URL) throws -> String {
    let h = try FileHandle(forReadingFrom: url)
    defer { try? h.close() }
    var hasher = SHA256()
    while let chunk = try h.read(upToCount: 8 << 20), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

struct SetupView: View {
    @ObservedObject var setup: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("LocalMinutes 처음 설정").font(.title.weight(.semibold))
            Text("회의 녹음 · 전사 · 회의록을 이 맥 안에서만 처리하는 앱입니다. 처음 한 번 AI 모델을 원본(Hugging Face · GitHub)에서 내려받습니다. 받은 뒤에는 회의 내용이 이 맥 밖으로 나가지 않습니다.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    check(ok: setup.memoryGB >= 31, "메모리 \(Int(setup.memoryGB.rounded())) GB",
                          bad: "32 GB 이상이 필요합니다. 이 맥에서는 회의록 단계가 매우 느리거나 멈출 수 있습니다.")
                    check(ok: setup.freeDisk > setup.totalMissing + 2_000_000_000,
                          "남은 디스크 \(formatBytes(setup.freeDisk))",
                          bad: "모델에 \(formatBytes(setup.totalMissing)) 이상이 필요합니다.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("내려받을 모델") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(requiredModels) { m in
                        HStack {
                            Image(systemName: m.isReady ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(m.isReady ? .green : .secondary)
                            Text(m.label)
                            Spacer()
                            Text(formatBytes(m.size)).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if setup.downloading {
                VStack(alignment: .leading, spacing: 6) {
                    Text(setup.current ?? "준비 중…")
                    ProgressView(value: Double(setup.received),
                                 total: Double(requiredModels.first { $0.label == setup.current }?.size ?? max(setup.received, 1)))
                    Text("\(formatBytes(setup.received)) 받음 · 창을 닫아도 다음에 이어받습니다").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let e = setup.error {
                Text(e).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if setup.downloading {
                    Button("멈추기") { setup.cancel() }
                } else {
                    Button(setup.alreadyHave > 0 ? "이어받기 (\(formatBytes(setup.totalMissing - setup.alreadyHave)) 남음)"
                                                 : "모델 내려받기 (\(formatBytes(setup.totalMissing)))") { setup.start() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(28)
        .frame(width: 620)
    }

    private func check(ok: Bool, _ text: String, bad: String) -> some View {
        HStack(alignment: .top) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading) {
                Text(text)
                if !ok { Text(bad).font(.caption).foregroundStyle(.orange) }
            }
        }
    }
}
