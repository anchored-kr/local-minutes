// LocalMinutes Recorder — 마이크와 시스템 오디오를 같은 시계로 따로 저장한다.
// 네트워크 코드는 없다. 사용: LocalMinutesRecorder <출력 폴더>
// SIGINT / SIGTERM 을 받으면 파일을 닫고 끝낸다.
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

final class TrackWriter {
    let url: URL
    private var file: AVAudioFile?
    private var format: AVAudioFormat?
    private(set) var firstPTS: Double?
    private var nextPTS: Double?
    private(set) var frames: Int64 = 0
    private(set) var gapFrames: Int64 = 0
    private var peak: Float = 0
    private let lock = NSLock()

    init(url: URL) { self.url = url }

    var sampleRate: Double { format?.sampleRate ?? 0 }

    /// 마지막 호출 뒤 가장 큰 소리(0~1)를 돌려주고 초기화한다.
    func takePeak() -> Float {
        lock.lock(); defer { lock.unlock() }
        let p = peak
        peak = 0
        return p
    }

    func append(_ sb: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sb), let fd = sb.formatDescription,
              var asbd = fd.audioStreamBasicDescription else { return }
        lock.lock(); defer { lock.unlock() }
        if file == nil {
            guard let fmt = AVAudioFormat(streamDescription: &asbd), fmt.commonFormat == .pcmFormatFloat32 else {
                log("지원하지 않는 형식: \(asbd)")
                return
            }
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: fmt.sampleRate,
                AVNumberOfChannelsKey: fmt.channelCount,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
            ]
            do {
                file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: fmt.isInterleaved)
                format = fmt
                log("\(url.lastPathComponent): \(Int(fmt.sampleRate)) Hz, \(fmt.channelCount) ch")
            } catch {
                log("파일을 열지 못함 \(url.path): \(error)")
                return
            }
        }
        guard let file, let format else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
        let n = CMSampleBufferGetNumSamples(sb)
        if firstPTS == nil { firstPTS = pts }
        // 소리가 끊겨 버퍼가 비면 그만큼 무음을 넣어 두 트랙의 시간을 맞춘다.
        if let expected = nextPTS, pts - expected > 0.05 {
            let missing = AVAudioFrameCount((pts - expected) * format.sampleRate)
            if let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: missing) {
                silence.frameLength = missing
                let abl = UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList)
                for buf in abl { memset(buf.mData, 0, Int(buf.mDataByteSize)) }
                try? file.write(from: silence)
                frames += Int64(missing)
                gapFrames += Int64(missing)
            }
        }
        do {
            try sb.withAudioBufferList { abl, _ in
                guard let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: abl.unsafePointer) else { return }
                if let ch = pcm.floatChannelData {
                    for c in 0..<Int(format.channelCount) {
                        for i in stride(from: 0, to: Int(pcm.frameLength), by: 16) {
                            peak = max(peak, abs(ch[c][i]))
                        }
                    }
                }
                try file.write(from: pcm)
                frames += Int64(pcm.frameLength)
            }
        } catch {
            log("쓰기 실패: \(error)")
        }
        nextPTS = pts + Double(n) / format.sampleRate
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        file = nil
    }
}

func log(_ s: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(s)\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
}

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    let outDir: URL
    let mic: TrackWriter
    let system: TrackWriter
    var stream: SCStream?
    let startedAt = Date()
    private let audioQueue = DispatchQueue(label: "audio")
    private let micQueue = DispatchQueue(label: "mic")
    private let screenQueue = DispatchQueue(label: "screen")

    init(outDir: URL) {
        self.outDir = outDir
        mic = TrackWriter(url: outDir.appendingPathComponent("mic.caf"))
        system = TrackWriter(url: outDir.appendingPathComponent("system.caf"))
    }

    func start() async throws {
        if !(await AVCaptureDevice.requestAccess(for: .audio)) {
            throw NSError(domain: "rec", code: 1, userInfo: [NSLocalizedDescriptionKey: "마이크 권한이 없습니다"])
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "rec", code: 2, userInfo: [NSLocalizedDescriptionKey: "디스플레이를 찾지 못함"])
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 2
        cfg.captureMicrophone = true
        if let dev = AVCaptureDevice.default(for: .audio) {
            cfg.microphoneCaptureDeviceID = dev.uniqueID
            log("마이크: \(dev.localizedName)")
        }
        // 화면은 쓰지 않는다. 가장 작게, 가장 드물게.
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.showsCursor = false
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: micQueue)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenQueue)
        try await s.startCapture()
        stream = s
        log("녹음 시작")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .audio: system.append(sb)
        case .microphone: mic.append(sb)
        default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("캡처가 멈춤: \(error)")
        finish(code: 3)
    }

    func writeStatus(final: Bool = false) {
        let status: [String: Any] = [
            "state": final ? "stopped" : "recording",
            "seconds": Date().timeIntervalSince(startedAt),
            "mic_peak": mic.takePeak(),
            "system_peak": system.takePeak(),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: status) {
            try? data.write(to: outDir.appendingPathComponent("status.json"), options: .atomic)
        }
    }

    private var finished = false
    func finish(code: Int32) {
        if finished { return }
        finished = true
        let sem = DispatchSemaphore(value: 0)
        if let stream {
            stream.stopCapture { _ in sem.signal() }
            _ = sem.wait(timeout: .now() + 3)
        }
        // 두 트랙이 받은 첫 버퍼 시각의 차이를 남긴다. 합칠 때 이만큼 밀어 맞춘다.
        let starts = [mic.firstPTS, system.firstPTS].compactMap { $0 }
        let origin = starts.min() ?? 0
        audioQueue.sync {}
        micQueue.sync {}
        mic.close()
        system.close()
        var meta: [String: Any] = ["started_at": ISO8601DateFormatter().string(from: startedAt),
                                   "duration": Date().timeIntervalSince(startedAt)]
        for (name, t) in [("mic", mic), ("system", system)] {
            meta[name] = [
                "file": t.url.lastPathComponent,
                "offset": t.firstPTS.map { $0 - origin } as Any,
                "seconds": t.sampleRate > 0 ? Double(t.frames) / t.sampleRate : 0,
                "gap_seconds": t.sampleRate > 0 ? Double(t.gapFrames) / t.sampleRate : 0,
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: outDir.appendingPathComponent("recording.json"))
        }
        writeStatus(final: true)
        log("녹음 끝")
        exit(code)
    }
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    log("사용: LocalMinutesRecorder <출력 폴더>")
    exit(64)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let recorder = Recorder(outDir: outDir)

for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { recorder.finish(code: 0) }
    src.resume()
    // 소스를 살려 둔다.
    objc_setAssociatedObject(recorder, "sig\(sig)", src, .OBJC_ASSOCIATION_RETAIN)
}

Task {
    do {
        try await recorder.start()
    } catch {
        log("시작 실패: \(error.localizedDescription)")
        try? "\(error.localizedDescription)".write(to: outDir.appendingPathComponent("error.txt"), atomically: true, encoding: .utf8)
        exit(2)
    }
}
Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in recorder.writeStatus() }
RunLoop.main.run()
