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
    @AppStorage("autoUpdateCheck") var autoCheck = true
    @AppStorage("lastUpdateCheck") private var lastCheck = 0.0

    func checkOnLaunch() {
        guard autoCheck, isBundledEngine, Date().timeIntervalSince1970 - lastCheck > 6 * 3600 else { return }
        Task { await check(manual: false) }
    }

    func check(manual: Bool) async {
        lastCheck = Date().timeIntervalSince1970
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(updateRepo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                if manual { state = "업데이트 정보를 받지 못했습니다." }
                return
            }
            let r = try JSONDecoder().decode(Release.self, from: data)
            if isNewer(r.version, than: currentVersion) {
                available = r
            } else if manual {
                state = "최신 버전입니다 (\(currentVersion))."
            }
        } catch {
            if manual { state = "업데이트 확인 실패: \(error.localizedDescription)" }
        }
    }

    /// 받기 → SHA-256 확인 → 풀기 → 서명 요건이 지금 앱과 같은지 확인 → 앱을 닫고 바꿔 끼운 뒤 다시 연다.
    func install(_ r: Release, canQuit: () -> Bool) {
        guard canQuit() else {
            state = "녹음 · 회의록 작업이 끝난 뒤 업데이트하세요."
            return
        }
        guard let zip = r.assets.first(where: { $0.name.hasSuffix(".zip") }),
              let sum = r.assets.first(where: { $0.name.hasSuffix(".sha256") }) else {
            state = "릴리스에 업데이트 파일이 없습니다."
            return
        }
        busy = true
        state = "내려받는 중…"
        Task.detached {
            let result = Self.prepare(zipURL: zip.browser_download_url, sumURL: sum.browser_download_url)
            await MainActor.run {
                switch result {
                case .failure(let e):
                    self.busy = false
                    self.state = e.message
                case .success(let newApp):
                    self.state = "다시 여는 중…"
                    Self.swapAndRelaunch(newApp)
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

    nonisolated private static func prepare(zipURL: String, sumURL: String) -> Result<URL, Fail> {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("LocalMinutesUpdate-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let zip = tmp.appendingPathComponent("update.zip"), sum = tmp.appendingPathComponent("update.sha256")
        for (u, f) in [(zipURL, zip), (sumURL, sum)] {
            let (c, o) = sh("/usr/bin/curl", ["-L", "--fail", "--silent", "--show-error", "--retry", "3", "-o", f.path, u])
            if c != 0 { return .failure(Fail(message: "업데이트 내려받기 실패: \(o)")) }
        }
        let expected = readText(sum).split(separator: " ").first.map(String.init) ?? ""
        guard let got = try? sha256(of: zip), !expected.isEmpty, got == expected else {
            return .failure(Fail(message: "업데이트 파일 해시가 맞지 않습니다. 설치하지 않았습니다."))
        }
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

    private static func swapAndRelaunch(_ newApp: URL) {
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
        NSApp.terminate(nil)
    }
}

struct UpdateSheet: View {
    @ObservedObject var updater: Updater
    let release: Release
    let canQuit: () -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("새 버전 \(release.version)").font(.title2.weight(.semibold))
            Text("지금 버전 \(currentVersion)").foregroundStyle(.secondary)
            ScrollView {
                Text(release.body ?? "")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 180)
            if let s = updater.state { Text(s).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("나중에") { updater.available = nil }.disabled(updater.busy)
                Button("지금 업데이트") { updater.install(release, canQuit: canQuit) }
                    .buttonStyle(.borderedProminent)
                    .disabled(updater.busy)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
