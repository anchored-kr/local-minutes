// 업데이트: GitHub 공개 저장소의 최신 릴리스를 확인하고, 받은 앱이 같은 인증서로 서명됐는지 확인한 뒤 바꿔 끼운다.
// 보내는 것은 GitHub API 요청(버전 확인)뿐이다. 회의 데이터 · 기기 정보는 보내지 않는다.
// 같은 인증서("LocalMinutes Signing")로 서명하므로 마이크 · 화면 녹음 권한이 업데이트 뒤에도 유지된다.
import AppKit
import Foundation
import SwiftUI

let updateRepo = "anchored-kr/local-minutes"

struct Release: Decodable, Identifiable {
    var id: String { tag_name }
    struct Asset: Decodable {
        let name: String
        let browser_download_url: String
        let size: Int64?
    }
    let tag_name: String
    let name: String?
    let body: String?
    let assets: [Asset]
    var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
}

let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

func isNewer(_ a: String, than b: String) -> Bool {
    let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(x.count, y.count) {
        let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
        if p != q { return p > q }
    }
    return false
}

@MainActor
final class Updater: ObservableObject {
    @Published var available: Release?
    @Published var state: String?
    @Published var busy = false
    /// 받기 진행률(0~1). nil 이면 막대를 그리지 않는다.
    @Published var progress: Double?
    @AppStorage("autoUpdateCheck") var autoCheck = true
    @AppStorage("lastUpdateCheck") private var lastCheck = 0.0

    private var timer: Timer?

    /// 앱을 켤 때마다 확인하고(새 버전이 있으면 업데이트 창), 켜 둔 동안에는 6시간마다 확인한다.
    func checkOnLaunch() {
        guard autoCheck, isBundledEngine else { return }
        Task { await check(manual: false) }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.autoCheck, self.available == nil else { return }
                await self.check(manual: false)
            }
        }
    }

    /// GitHub API 는 쓰지 않는다 — 비로그인 요청은 같은 인터넷 주소(IP)를 쓰는 사람 모두가 시간당 60번을 나눠 써서,
    /// 회사 네트워크에서 한도가 바닥나 "업데이트 정보를 받지 못했습니다"가 떴다(2026-10-29, 403).
    /// 대신 /releases/latest 가 /releases/tag/vX.Y.Z 로 넘겨 주는 것으로 최신 버전을 알고, 파일 · 노트는 공개 다운로드 주소로 받는다.
    func check(manual: Bool) async {
        lastCheck = Date().timeIntervalSince1970
        do {
            var latest = URLRequest(url: URL(string: "https://github.com/\(updateRepo)/releases/latest")!)
            latest.httpMethod = "HEAD"
            latest.timeoutInterval = 15
            let (_, resp) = try await URLSession.shared.data(for: latest)
            guard let url = resp.url, url.path.contains("/releases/tag/") else {
                if manual { state = "릴리스를 찾지 못했습니다." }
                return
            }
            let tag = url.lastPathComponent
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard isNewer(version, than: currentVersion) else {
                if manual { state = "최신 버전입니다 (\(currentVersion))." }
                return
            }
            let base = "https://github.com/\(updateRepo)/releases/download/\(tag)/"
            let zipName = "LocalMinutes-\(version).zip"
            var notes = ""
            if let (d, r) = try? await URLSession.shared.data(from: URL(string: base + "RELEASE_NOTES.md")!),
               (r as? HTTPURLResponse)?.statusCode == 200 {
                notes = String(decoding: d, as: UTF8.self)
            }
            var size: Int64?
            var head = URLRequest(url: URL(string: base + zipName)!)
            head.httpMethod = "HEAD"
            if let (_, r) = try? await URLSession.shared.data(for: head), r.expectedContentLength > 0 {
                size = r.expectedContentLength
            }
            available = Release(tag_name: tag, name: nil, body: notes.isEmpty ? nil : notes, assets: [
                .init(name: zipName, browser_download_url: base + zipName, size: size),
                .init(name: zipName + ".sha256", browser_download_url: base + zipName + ".sha256", size: nil),
            ])
        } catch {
            if manual { state = "업데이트 확인 실패: \(error.localizedDescription)" }
        }
    }

    /// 받기 → SHA-256 확인 → 풀기 → 서명 요건이 지금 앱과 같은지 확인 → 앱을 닫고 바꿔 끼운 뒤 다시 연다.
    /// beforeQuit: 전사 작업자 같은 자식 프로세스를 먼저 내린다.
    func install(_ r: Release, canQuit: () -> Bool, beforeQuit: @escaping () -> Void) {
        guard canQuit() else {
            state = "녹음 · 회의록 작업이 끝난 뒤 업데이트하세요."
            return
        }
        guard !Bundle.main.bundlePath.contains("/AppTranslocation/") else {
            state = "LocalMinutes 를 '응용 프로그램' 폴더로 옮긴 뒤 다시 열고 업데이트하세요."
            return
        }
        guard let zip = r.assets.first(where: { $0.name.hasSuffix(".zip") }),
              let sum = r.assets.first(where: { $0.name.hasSuffix(".sha256") }) else {
            state = "릴리스에 업데이트 파일이 없습니다."
            return
        }
        busy = true
        progress = 0
        state = "내려받는 중…"
        let total = zip.size ?? 0
        Task.detached {
            let result = Self.prepare(zipURL: zip.browser_download_url, sumURL: sum.browser_download_url, total: total) { phase, value in
                Task { @MainActor in
                    self.state = phase
                    self.progress = value
                }
            }
            await MainActor.run {
                switch result {
                case .failure(let e):
                    self.busy = false
                    self.progress = nil
                    self.state = e.message
                case .success(let newApp):
                    self.progress = 1
                    self.state = "다시 여는 중…"
                    Self.swapAndRelaunch(newApp, beforeQuit: beforeQuit, dismiss: { self.available = nil })
                }
            }
        }
    }

    struct Fail: Error { let message: String }

    nonisolated private static func sh(_ path: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    nonisolated private static func prepare(zipURL: String, sumURL: String, total: Int64,
                                            report: @escaping (String, Double?) -> Void) -> Result<URL, Fail> {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("LocalMinutesUpdate-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let zip = tmp.appendingPathComponent("update.zip"), sum = tmp.appendingPathComponent("update.sha256")
        let (sc, so) = sh("/usr/bin/curl", ["-L", "--fail", "--silent", "--show-error", "--retry", "3", "-o", sum.path, sumURL])
        if sc != 0 { return .failure(Fail(message: "업데이트 내려받기 실패: \(so)")) }
        // zip 은 받는 동안 파일 크기를 보며 진행률을 알린다.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = ["-L", "--fail", "--silent", "--show-error", "--retry", "3", "-o", zip.path, zipURL]
        let err = Pipe()
        p.standardError = err
        do { try p.run() } catch { return .failure(Fail(message: "curl 을 실행하지 못했습니다.")) }
        while p.isRunning {
            let got = (try? FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int64) ?? 0
            let mb = { (b: Int64) in String(format: "%.0f", Double(b) / 1_000_000) }
            report(total > 0 ? "내려받는 중… \(mb(got)) / \(mb(total)) MB" : "내려받는 중… \(mb(got)) MB",
                   total > 0 ? min(0.9, 0.9 * Double(got) / Double(total)) : nil)
            usleep(200_000)
        }
        if p.terminationStatus != 0 {
            let o = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return .failure(Fail(message: "업데이트 내려받기 실패: \(o)"))
        }
        report("파일 확인 중(SHA-256 · 서명)…", 0.92)
        let expected = readText(sum).split(separator: " ").first.map(String.init) ?? ""
        guard let got = try? sha256(of: zip), !expected.isEmpty, got == expected else {
            return .failure(Fail(message: "업데이트 파일 해시가 맞지 않습니다. 설치하지 않았습니다."))
        }
        report("압축 푸는 중…", 0.95)
        let (c, o) = sh("/usr/bin/ditto", ["-x", "-k", zip.path, tmp.path])
        guard c == 0 else { return .failure(Fail(message: "압축 풀기 실패: \(o)")) }
        let newApp = tmp.appendingPathComponent("LocalMinutes.app")
        guard FileManager.default.fileExists(atPath: newApp.path) else {
            return .failure(Fail(message: "업데이트에 LocalMinutes.app 이 없습니다."))
        }
        let (v, vo) = sh("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])
        guard v == 0 else { return .failure(Fail(message: "업데이트 서명 확인 실패: \(vo)")) }
        // 지금 앱과 같은 인증서로 서명됐는지(서명 요건 비교) — 다른 사람이 만든 앱으로 바뀌지 않게.
        let (_, mine) = sh("/usr/bin/codesign", ["-d", "-r-", Bundle.main.bundlePath])
        let (_, theirs) = sh("/usr/bin/codesign", ["-d", "-r-", newApp.path])
        func req(_ s: String) -> String { s.split(separator: "\n").first { $0.contains("designated =>") }.map(String.init) ?? "" }
        guard !req(mine).isEmpty, req(mine) == req(theirs) else {
            return .failure(Fail(message: "업데이트가 같은 인증서로 서명되지 않았습니다. 설치하지 않았습니다."))
        }
        return .success(newApp)
    }

    /// 교체 스크립트를 띄우고 앱을 끝낸다. 스크립트는 앱이 끝나기를 기다렸다가 바꿔 끼우고 다시 연다.
    /// 1.0.0 에서는 업데이트 창(시트)이 열린 채 NSApp.terminate 를 불러 앱이 꺼지지 않고 "다시 여는 중…"에 멈췄다
    /// (2026-10-29). 창을 먼저 닫고, 그래도 2초 안에 안 끝나면 exit 로 끝낸다.
    private static func swapAndRelaunch(_ newApp: URL, beforeQuit: @escaping () -> Void, dismiss: @escaping () -> Void) {
        let old = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
        rm -rf "\(old).old"
        mv "\(old)" "\(old).old" && mv "\(newApp.path)" "\(old)" && rm -rf "\(old).old"
        xattr -dr com.apple.quarantine "\(old)" 2>/dev/null
        open "\(old)"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try? p.run()
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            beforeQuit()
            NSApp.terminate(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
        }
    }
}

struct UpdateSheet: View {
    @ObservedObject var updater: Updater
    let release: Release
    let canQuit: () -> Bool
    let beforeQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("새 버전 \(release.version)이 나왔습니다").font(.title2.weight(.semibold))
            Text("지금 버전 \(currentVersion) · 지금 업데이트할까요? 회의 기록은 그대로 남습니다.").foregroundStyle(.secondary)
            ScrollView {
                Text(release.body ?? "")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 180)
            if let v = updater.progress {
                ProgressView(value: v)
            }
            if let s = updater.state { Text(s).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            HStack {
                Spacer()
                Button("나중에") { updater.available = nil }.disabled(updater.busy)
                Button("지금 업데이트") { updater.install(release, canQuit: canQuit, beforeQuit: beforeQuit) }
                    .buttonStyle(.borderedProminent)
                    .disabled(updater.busy)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
