// 회의 목록 · 폴더 · 회의 문서 · 파이프라인(minutes.py) 호출.
// 회의 하나 = meetings/<날짜_시각>/ 폴더. 명령줄 도구(minutes)와 같은 파일을 쓴다.
//   title.txt 제목 · notes.md 메모 · context.md 맥락 · minutes.md 회의록 · transcript.json 전사
//   speakers.json 화자 이름 · folder.txt 들어 있는 목록 폴더 이름
// 목록 폴더 차례는 meetings/folders.json.
import AppKit
import Foundation
import SwiftUI

/// 엔진(minutes.py · speakers.py · whisper · llama · Python). 배포본은 앱 안 Resources/engine,
/// 개발 중에는 ~/local-minutes(Homebrew · .venv).
let engineRoot: URL = {
    if let r = Bundle.main.resourceURL?.appendingPathComponent("engine"),
       FileManager.default.fileExists(atPath: r.appendingPathComponent("minutes.py").path) {
        return r
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("local-minutes")
}()
let isBundledEngine = engineRoot.path.hasSuffix("Resources/engine")

/// 데이터(회의 · 모델 · 기록). iCloud 로 동기화되는 문서 폴더가 아닌 Application Support.
let dataRoot: URL = {
    let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LocalMinutes")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}()
let meetingsRoot = dataRoot.appendingPathComponent("meetings")
let modelsRoot = dataRoot.appendingPathComponent("models")

let pythonURL: URL = {
    let candidates = [engineRoot.appendingPathComponent("python/bin/python3"),
                      engineRoot.appendingPathComponent(".venv/bin/python"),
                      URL(fileURLWithPath: "/opt/homebrew/bin/python3")]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) } ?? candidates[2]
}()

struct Segment: Codable, Identifiable, Equatable {
    var start: Double
    var end: Double
    var text: String
    var speaker: String?
    var id: String { "\(start)-\(text.hashValue)" }
}

struct MeetingSummary: Identifiable, Hashable {
    let id: String      // 폴더 이름
    let title: String
    let date: Date?
    let folder: String?
}

enum Language: String, CaseIterable, Identifiable {
    case auto, ko, en, ja
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "언어 자동"
        case .ko: return "한국어"
        case .en: return "English"
        case .ja: return "日本語"
        }
    }
}

/// 이름 바꾸기 창이 무엇을 바꾸는지
enum RenameTarget: Equatable {
    case meeting(String)
    case folder(String)
    case speaker(String)
}

func timeLabel(_ s: Double) -> String {
    let t = Int(s)
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
                     : String(format: "%02d:%02d", t / 60, t % 60)
}

func readText(_ url: URL) -> String {
    (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

func copyToClipboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

// MARK: - 파이프라인

enum Pipeline {
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = isBundledEngine
            ? engineRoot.appendingPathComponent("bin").path + ":/usr/bin:/bin:/usr/sbin:/sbin"
            : "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["LOCAL_MINUTES_HOME"] = dataRoot.path
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        return env
    }

    static func openLog(_ log: URL) -> FileHandle? {
        if !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil)
        }
        let h = try? FileHandle(forWritingTo: log)
        h?.seekToEndOfFile()
        return h
    }

    /// minutes.py 를 부른다. minutes.py 가 스스로 네트워크가 막힌 샌드박스로 다시 뜬다.
    static func run(_ args: [String], log: URL) -> (Int32, Data) {
        let p = Process()
        p.executableURL = pythonURL
        p.arguments = ["-I", "-B", engineRoot.appendingPathComponent("minutes.py").path] + args
        p.environment = environment
        let out = Pipe()
        p.standardOutput = out
        let logHandle = openLog(log)
        p.standardError = logHandle ?? FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return (-1, Data())
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        try? logHandle?.close()
        return (p.terminationStatus, data)
    }

    static func lastLogLines(_ log: URL, _ n: Int = 3) -> String {
        readText(log).split(separator: "\n").suffix(n).joined(separator: "\n")
    }

    static func appendLog(_ log: URL, _ line: String) {
        let h = openLog(log)
        h?.write(Data("[\(ISO8601DateFormatter().string(from: Date()))] \(line)\n".utf8))
        try? h?.close()
    }
}

/// 회의 동안 켜 두는 전사 작업자(minutes.py worker). whisper 모델을 한 번만 읽는다.
/// 요청 한 줄 → 결과 한 줄(JSON). 앱이 끝나면 stdin 이 닫혀 작업자도 끝난다.
final class TranscribeWorker {
    private var proc: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()

    var isRunning: Bool { proc?.isRunning == true }

    /// 작업자를 띄우고 준비될 때까지 기다린다. 호출은 transcribeQueue 위에서.
    func start(log: URL) -> Bool {
        if isRunning { return true }
        let p = Process()
        p.executableURL = pythonURL
        p.arguments = ["-I", "-B", engineRoot.appendingPathComponent("minutes.py").path, "worker"]
        p.environment = Pipeline.environment
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = Pipeline.openLog(log) ?? FileHandle.nullDevice
        do { try p.run() } catch { return false }
        proc = p
        input = inPipe.fileHandleForWriting
        output = outPipe.fileHandleForReading
        buffer = Data()
        guard let line = readLine(), line.contains("ready") else {
            stop()
            return false
        }
        return true
    }

    func request(_ obj: [String: Any]) -> Data? {
        guard isRunning, let input, let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        input.write(data + Data([0x0A]))
        return readLine().map { Data($0.utf8) }
    }

    private func readLine() -> String? {
        guard let output else { return nil }
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                return String(decoding: line, as: UTF8.self)
            }
            let more = output.availableData
            if more.isEmpty { return nil }
            buffer.append(more)
        }
    }

    /// stdin 을 닫으면 작업자가 whisper-server 를 끄고 스스로 끝난다. 3초 안에 안 끝나면 종료 신호.
    func stop() {
        try? input?.close()
        if let p = proc {
            let deadline = Date().addingTimeInterval(3)
            while p.isRunning && Date() < deadline { usleep(100_000) }
            if p.isRunning { p.terminate() }
        }
        proc = nil
        input = nil
        output = nil
    }
}

// MARK: - 회의 문서

@MainActor
final class MeetingDoc: ObservableObject {
    nonisolated let dir: URL
    @Published var title: String { didSet { scheduleSave("title.txt", title) } }
    @Published var notes: String { didSet { scheduleSave("notes.md", notes) } }
    @Published var context: String { didSet { scheduleSave("context.md", context) } }
    @Published var minutes: String { didSet { scheduleSave("minutes.md", minutes) } }
    @Published var segments: [Segment] = []
    @Published var speakerNames: [String: String] = [:]
    @Published var language: Language = .auto
    /// 상대 인원(0 = 자동). others.txt. 회의 끝 · 화자 다시 나누기에 쓴다.
    @Published var otherCount: Int = 0 { didSet { scheduleSave("others.txt", otherCount == 0 ? "" : String(otherCount)) } }
    @Published var respeaking = false
    @Published var hasRecording: Bool
    @Published var pendingChunks = 0
    @Published var writingMinutes = false
    @Published var status: String?

    private var saveWork: [String: DispatchWorkItem] = [:]
    private var detectedLanguages: [String] = []

    nonisolated var log: URL { dir.appendingPathComponent("app.log") }
    var id: String { dir.lastPathComponent }

    init(dir: URL) {
        self.dir = dir
        title = readText(dir.appendingPathComponent("title.txt")).trimmingCharacters(in: .whitespacesAndNewlines)
        notes = readText(dir.appendingPathComponent("notes.md"))
        context = readText(dir.appendingPathComponent("context.md"))
        minutes = readText(dir.appendingPathComponent("minutes.md"))
        let fm = FileManager.default
        hasRecording = ["audio.m4a", "audio.raw", "recording.json"].contains {
            fm.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
        if let data = try? Data(contentsOf: dir.appendingPathComponent("transcript.json")),
           let segs = try? JSONDecoder().decode([Segment].self, from: data) {
            segments = segs
        }
        if let data = try? Data(contentsOf: dir.appendingPathComponent("speakers.json")),
           let names = try? JSONDecoder().decode([String: String].self, from: data) {
            speakerNames = names
        }
        if let l = Language(rawValue: readText(dir.appendingPathComponent("language.txt")).trimmingCharacters(in: .whitespacesAndNewlines)) {
            language = l
        }
        otherCount = Int(readText(dir.appendingPathComponent("others.txt")).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    func reloadTranscript() {
        if let data = try? Data(contentsOf: dir.appendingPathComponent("transcript.json")),
           let segs = try? JSONDecoder().decode([Segment].self, from: data) {
            segments = segs
        }
        saveTranscript()
    }

    private func scheduleSave(_ name: String, _ text: String) {
        saveWork[name]?.cancel()
        let url = dir.appendingPathComponent(name)
        let w = DispatchWorkItem { try? text.write(to: url, atomically: true, encoding: .utf8) }
        saveWork[name] = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    func flushSaves() {
        for (_, w) in saveWork { w.perform(); w.cancel() }
        saveWork.removeAll()
    }

    func append(_ segs: [Segment], language: String?) {
        segments.append(contentsOf: segs)
        if let language { detectedLanguages.append(language) }
        saveTranscript()
    }

    /// 회의가 끝난 뒤 화자 정리 결과(시작 시각 → 화자)를 반영한다.
    func applySpeakers(_ labels: [Double: String]) {
        for i in segments.indices {
            if let s = labels[segments[i].start] { segments[i].speaker = s }
        }
        saveTranscript()
    }

    /// 회의록 언어: 고른 언어, 자동이면 조각에서 가장 많이 나온 언어.
    var minutesLanguage: String {
        if language != .auto { return language.rawValue }
        let counts = Dictionary(detectedLanguages.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max { $0.value < $1.value }?.key ?? "ko"
    }

    // MARK: 화자

    /// 전사에 나온 화자, 처음 나온 차례대로
    var speakers: [String] {
        var seen: [String] = []
        for s in segments { if let k = s.speaker, !seen.contains(k) { seen.append(k) } }
        return seen
    }

    func displayName(_ raw: String?) -> String {
        guard let raw else { return "?" }
        if let n = speakerNames[raw], !n.isEmpty { return n }
        return raw
    }

    func rename(speaker raw: String, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty || n == raw { speakerNames[raw] = nil } else { speakerNames[raw] = n }
        if let data = try? JSONEncoder().encode(speakerNames) {
            try? data.write(to: dir.appendingPathComponent("speakers.json"))
        }
        saveTranscript()
    }

    // MARK: 글로 내기

    /// 말 차례마다 "[시각] 이름: 문장" — 클립보드 · transcript.md 에 같이 쓴다.
    func transcriptText(header: Bool) -> String {
        var lines: [String] = []
        if header {
            lines.append("# \(title.isEmpty ? "회의" : title) — 전사")
            if !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines += ["", "## 맥락", context.trimmingCharacters(in: .whitespacesAndNewlines)]
            }
            lines += ["", "## 전사"]
        }
        var prev: String?
        var turn = ""
        func flush() { if !turn.isEmpty { lines.append(turn); turn = "" } }
        for s in segments {
            let who = displayName(s.speaker)
            if who != prev || turn.isEmpty {
                flush()
                turn = "[\(timeLabel(s.start))] \(who): \(s.text)"
                prev = who
            } else {
                turn += " " + s.text
            }
        }
        flush()
        return lines.joined(separator: "\n")
    }

    func saveTranscript() {
        if let data = try? JSONEncoder().encode(segments) {
            try? data.write(to: dir.appendingPathComponent("transcript.json"))
        }
        try? transcriptText(header: true).write(to: dir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
    }
}

// MARK: - 앱 상태

@MainActor
final class AppModel: ObservableObject {
    @Published var meetings: [MeetingSummary] = []
    @Published var folders: [String] = []
    @Published var selectedID: String? { didSet { if selectedID != oldValue { openSelected() } } }
    @Published var doc: MeetingDoc?
    @Published var recordingID: String?
    @Published var micLevel: Float = 0
    @Published var systemLevel: Float = 0
    @Published var elapsed: Double = 0
    @Published var alert: String?
    @Published var renaming: RenameTarget?
    @Published var toast: String?

    private var engine: CaptureEngine?
    private var docs: [String: MeetingDoc] = [:]
    private var pollTimer: Timer?
    private let transcribeQueue = DispatchQueue(label: "transcribe")   // 조각 · 화자 정리 · 회의록을 차례로
    nonisolated private let worker = TranscribeWorker()   // transcribeQueue 위에서만 쓴다

    private var foldersFile: URL { meetingsRoot.appendingPathComponent("folders.json") }

    /// 앱이 비정상으로 끝나 주인(launchd)만 남은 whisper-server · llama-server 를 치운다.
    nonisolated static func cleanOrphans() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-P", "1", "-f", "LocalMinutes/models/"]
        try? p.run()
        p.waitUntilExit()
    }

    func stopWorker() {
        let w = worker
        transcribeQueue.sync { w.stop() }
    }

    init() {
        Self.cleanOrphans()
        try? FileManager.default.createDirectory(at: meetingsRoot, withIntermediateDirectories: true)
        reload()
        selectedID = meetings.first?.id
    }

    func reload() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: meetingsRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd_HHmm"
        meetings = dirs.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { d in
                let name = d.lastPathComponent
                let t = readText(d.appendingPathComponent("title.txt")).trimmingCharacters(in: .whitespacesAndNewlines)
                let f = readText(d.appendingPathComponent("folder.txt")).trimmingCharacters(in: .whitespacesAndNewlines)
                return MeetingSummary(id: name, title: t.isEmpty ? name : t,
                                      date: parser.date(from: String(name.prefix(15))),
                                      folder: f.isEmpty ? nil : f)
            }
            .sorted { $0.id > $1.id }
        var list = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: foldersFile))) ?? []
        for m in meetings { if let f = m.folder, !list.contains(f) { list.append(f) } }
        folders = list
    }

    private func saveFolders() {
        if let data = try? JSONEncoder().encode(folders) { try? data.write(to: foldersFile) }
    }

    private func openSelected() {
        doc?.flushSaves()
        guard let id = selectedID else { doc = nil; return }
        if let d = docs[id] { doc = d; return }
        let d = MeetingDoc(dir: meetingsRoot.appendingPathComponent(id))
        docs[id] = d
        doc = d
    }

    func meetings(in folder: String?) -> [MeetingSummary] {
        meetings.filter { $0.folder == folder }
    }

    /// 녹음 · 전사 · 회의록 작업이 없을 때만 앱을 닫고 업데이트한다.
    var isIdle: Bool {
        recordingID == nil && !docs.values.contains { $0.writingMinutes || $0.pendingChunks > 0 || $0.respeaking }
    }

    // MARK: 회의 · 폴더 관리

    func newMeeting(in folder: String? = nil) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        let name = f.string(from: Date())
        let dir = meetingsRoot.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let t = DateFormatter()
        t.dateFormat = "M월 d일 a h:mm 회의"
        t.locale = Locale(identifier: "ko_KR")
        try? t.string(from: Date()).write(to: dir.appendingPathComponent("title.txt"), atomically: true, encoding: .utf8)
        if let folder { try? folder.write(to: dir.appendingPathComponent("folder.txt"), atomically: true, encoding: .utf8) }
        reload()
        selectedID = name
    }

    func delete(_ id: String) {
        guard id != recordingID else { return }
        try? FileManager.default.trashItem(at: meetingsRoot.appendingPathComponent(id), resultingItemURL: nil)
        docs[id] = nil
        if selectedID == id { selectedID = nil }
        reload()
        if selectedID == nil { selectedID = meetings.first?.id }
    }

    func revealInFinder(_ id: String) {
        NSWorkspace.shared.activateFileViewerSelecting([meetingsRoot.appendingPathComponent(id)])
    }

    func renameMeeting(_ id: String, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if let d = docs[id] {
            d.title = t
            d.flushSaves()
        } else {
            try? t.write(to: meetingsRoot.appendingPathComponent(id).appendingPathComponent("title.txt"), atomically: true, encoding: .utf8)
        }
        reload()
    }

    func move(_ ids: [String], to folder: String?) {
        for id in ids {
            let url = meetingsRoot.appendingPathComponent(id).appendingPathComponent("folder.txt")
            if let folder {
                try? folder.write(to: url, atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        reload()
    }

    @discardableResult
    func newFolder() -> String {
        var name = "새 폴더"
        var n = 2
        while folders.contains(name) { name = "새 폴더 \(n)"; n += 1 }
        folders.append(name)
        saveFolders()
        renaming = .folder(name)
        return name
    }

    func renameFolder(_ old: String, to new: String) {
        let n = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n != old, !folders.contains(n), let i = folders.firstIndex(of: old) else { return }
        folders[i] = n
        saveFolders()
        move(meetings(in: old).map(\.id), to: n)
    }

    /// 폴더만 지운다. 안의 회의는 폴더 밖으로 나온다.
    func deleteFolder(_ name: String) {
        move(meetings(in: name).map(\.id), to: nil)
        folders.removeAll { $0 == name }
        saveFolders()
    }

    func commitRename(_ text: String) {
        switch renaming {
        case .meeting(let id): renameMeeting(id, to: text)
        case .folder(let name): renameFolder(name, to: text)
        case .speaker(let raw): doc?.rename(speaker: raw, to: text)
        case nil: break
        }
        renaming = nil
    }

    func currentName(of target: RenameTarget) -> String {
        switch target {
        case .meeting(let id): return meetings.first { $0.id == id }?.title ?? ""
        case .folder(let name): return name
        case .speaker(let raw): return doc?.displayName(raw) ?? raw
        }
    }

    func copy(_ text: String, what: String) {
        copyToClipboard(text)
        toast = "\(what) 복사됨 · \(text.count.formatted())자"
        let shown = toast
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { if self.toast == shown { self.toast = nil } }
    }

    // MARK: 녹음

    func startRecording() {
        guard recordingID == nil, let doc, !doc.hasRecording else { return }
        doc.flushSaves()
        let engine = CaptureEngine(rawURL: doc.dir.appendingPathComponent("audio.raw"))
        let chunksDir = doc.dir.appendingPathComponent(".chunks")
        try? FileManager.default.createDirectory(at: chunksDir, withIntermediateDirectories: true)
        try? doc.language.rawValue.write(to: doc.dir.appendingPathComponent("language.txt"), atomically: true, encoding: .utf8)
        let lang = doc.language.rawValue
        let meeting = doc.dir.path
        engine.onChunk = { [weak self, weak doc] chunk in
            guard let self, let doc else { return }
            let wav = chunksDir.appendingPathComponent(String(format: "chunk-%04d.wav", chunk.index))
            try? writeWav(chunk, to: wav)
            let offset = Double(chunk.startSample) / Double(CaptureEngine.rate)
            DispatchQueue.main.async { doc.pendingChunks += 1 }
            self.transcribeQueue.async {
                // 앞 문장과 맥락(회의 중에 고쳐도 다음 조각부터 반영)
                let (previous, terms) = DispatchQueue.main.sync {
                    (doc.segments.suffix(3).map(\.text).joined(separator: " "), doc.context)
                }
                // 작업자가 죽었으면 다시 띄운다.
                let data = self.worker.start(log: doc.log)
                    ? self.worker.request(["wav": wav.path, "offset": offset, "lang": lang, "context": previous,
                                           "terms": terms, "meeting": meeting]) : nil
                try? FileManager.default.removeItem(at: wav)
                struct Result: Decodable { let language: String?; let segments: [Segment]; let error: String? }
                let result = data.flatMap { try? JSONDecoder().decode(Result.self, from: $0) }.flatMap { $0.error == nil ? $0 : nil }
                DispatchQueue.main.async {
                    doc.pendingChunks -= 1
                    if let result {
                        doc.append(result.segments, language: result.language)
                    } else {
                        doc.status = "전사 실패(조각 \(chunk.index)): \(Pipeline.lastLogLines(doc.log, 2))"
                    }
                }
            }
        }
        engine.onError = { [weak self] msg in self?.alert = msg }
        let worker = self.worker
        transcribeQueue.async { _ = worker.start(log: doc.log) }   // 첫 조각 전에 모델을 읽어 둔다
        self.engine = engine
        recordingID = doc.id
        doc.hasRecording = true
        doc.status = nil
        Task {
            do {
                try await engine.start()
                self.pollTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.poll() }
                }
            } catch {
                self.alert = error.localizedDescription
                Pipeline.appendLog(doc.log, "녹음 시작 실패: \(error.localizedDescription) (\(error))")
                self.engine = nil
                self.recordingID = nil
                doc.hasRecording = false
                try? FileManager.default.removeItem(at: doc.dir.appendingPathComponent("audio.raw"))
            }
        }
    }

    private func poll() {
        guard let engine else { return }
        let (m, s, e) = engine.poll()
        micLevel = max(m, micLevel * 0.7)
        systemLevel = max(s, systemLevel * 0.7)
        elapsed = e
    }

    func stopRecording() {
        guard let engine, let id = recordingID, let doc = docs[id] else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        Task {
            let duration = await engine.stop()
            self.engine = nil
            self.recordingID = nil
            self.micLevel = 0
            self.systemLevel = 0
            let meta: [String: Any] = ["started_at": ISO8601DateFormatter().string(from: engine.startedAt), "duration": duration]
            if let data = try? JSONSerialization.data(withJSONObject: meta) {
                try? data.write(to: doc.dir.appendingPathComponent("recording.json"))
            }
            doc.status = "화자 정리 중…"
            let raw = doc.dir.appendingPathComponent("audio.raw").path
            transcribeQueue.async {
                // 남은 조각이 다 끝난 뒤(같은 줄): 전체 녹음으로 상대 화자를 다시 묶고, 녹음을 m4a 로 바꾼다.
                let (segs, count) = DispatchQueue.main.sync {
                    (doc.segments.map { ["start": $0.start, "end": $0.end, "speaker": $0.speaker ?? ""] as [String: Any] },
                     doc.otherCount)
                }
                struct Labels: Decodable { struct L: Decodable { let start: Double; let speaker: String }; let labels: [L] }
                if self.worker.start(log: doc.log),
                   let data = self.worker.request(["cmd": "speakers", "meeting": doc.dir.path, "raw": raw, "segments": segs,
                                                      "n_speakers": count > 0 ? count : NSNull()]),
                   let result = try? JSONDecoder().decode(Labels.self, from: data) {
                    let map = Dictionary(result.labels.map { ($0.start, $0.speaker) }, uniquingKeysWith: { a, _ in a })
                    DispatchQueue.main.sync { doc.applySpeakers(map) }
                }
                DispatchQueue.main.async { doc.status = "녹음 저장 중…" }
                _ = Pipeline.run(["finalize", doc.dir.path], log: doc.log)
                DispatchQueue.main.async { doc.status = nil }
            }
            writeMinutes(doc)
        }
    }

    /// 끝난 회의의 상대 화자를 전체 녹음으로 다시 나눈다(minutes.py respeak).
    func respeak(_ doc: MeetingDoc) {
        guard !doc.respeaking, recordingID != doc.id else { return }
        doc.flushSaves()
        doc.respeaking = true
        doc.status = "화자 다시 나누는 중…"
        let count = doc.otherCount
        transcribeQueue.async {
            let (code, _) = Pipeline.run(["respeak", doc.dir.path, "-n", String(count)], log: doc.log)
            DispatchQueue.main.async {
                doc.respeaking = false
                if code == 0 {
                    doc.reloadTranscript()
                    doc.status = "화자 다시 나눔 · \(doc.speakers.filter { $0.hasPrefix("상대") }.count)명"
                } else {
                    doc.status = "화자 나누기 실패: \(Pipeline.lastLogLines(doc.log, 2))"
                }
            }
        }
    }

    // MARK: 회의록

    func writeMinutes(_ doc: MeetingDoc) {
        guard !doc.writingMinutes else { return }
        doc.flushSaves()
        doc.writingMinutes = true
        transcribeQueue.async {
            // 남은 조각 전사 · 화자 정리가 모두 끝난 뒤(같은 줄) 회의록을 쓴다. 녹음 중이 아니면 전사 작업자를 내려
            // 메모리를 회의록 모델에 넘긴다.
            if DispatchQueue.main.sync(execute: { self.recordingID == nil }) { self.worker.stop() }
            let lang = DispatchQueue.main.sync { () -> String in
                doc.flushSaves()
                doc.saveTranscript()
                let chosen = UserDefaults.standard.string(forKey: "minutesLang") ?? "ko"
                return chosen == "auto" ? doc.minutesLanguage : chosen
            }
            let style = UserDefaults.standard.string(forKey: "minutesStyle") ?? "detailed"
            let (code, _) = Pipeline.run(["notes", doc.dir.path, "-o", lang, "-s", style], log: doc.log)
            let text = readText(doc.dir.appendingPathComponent("minutes.md"))
            DispatchQueue.main.async {
                doc.writingMinutes = false
                if code == 0 {
                    doc.minutes = text
                    doc.status = nil
                } else {
                    doc.status = "회의록 실패: \(Pipeline.lastLogLines(doc.log, 2))"
                }
                self.reload()
            }
        }
    }
}
