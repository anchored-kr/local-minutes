// 녹음 엔진: ScreenCaptureKit 으로 마이크(나)와 시스템 오디오(상대)를 받아
// 16 kHz 로 바꾸고 시각을 맞춰 audio.raw(스테레오 s16le, 왼쪽 나 · 오른쪽 상대)에 계속 쓴다.
// 말이 끊긴 곳(4초 이상 쌓인 뒤)이나 15초마다 조각을 잘라 onChunk 로 넘긴다. 네트워크 코드는 없다.
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

struct AudioChunk {
    let index: Int
    let startSample: Int
    let mic: [Float]
    let system: [Float]
}

private final class Track {
    var converter: AVAudioConverter?
    var inFormat: AVAudioFormat?
    var outFormat: AVAudioFormat?
    var started = false
    var start = 0          // pending[0] 의 절대 표본 위치
    var pending: [Float] = []
    var peak: Float = 0
    var end: Int { start + pending.count }
}

final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    static let rate = 16000
    // 상주 whisper-server 로 조각 하나가 2~3초면 끝나서, 짧게 잘라 화면에 빨리 띄운다.
    private static let minChunk = 4 * rate
    private static let maxChunk = 15 * rate
    private static let maxLag = 2 * rate

    var onChunk: ((AudioChunk) -> Void)?
    var onError: ((String) -> Void)?

    private let rawURL: URL
    private var raw: FileHandle?
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "capture")
    private var origin: Double?
    private let tracks = [Track(), Track()]   // 0 = 마이크, 1 = 시스템
    private var written = 0
    private var chunkStart = 0
    private var chunkIndex = 0
    private var chunkMic: [Float] = []
    private var chunkSys: [Float] = []
    private(set) var startedAt = Date()

    init(rawURL: URL) {
        self.rawURL = rawURL
    }

    func start() async throws {
        if !(await AVCaptureDevice.requestAccess(for: .audio)) {
            throw NSError(domain: "capture", code: 1, userInfo: [NSLocalizedDescriptionKey: "마이크 권한이 없습니다. 시스템 설정 → 개인정보 보호 및 보안 → 마이크에서 켜 주세요."])
        }
        FileManager.default.createFile(atPath: rawURL.path, contents: nil)
        raw = try FileHandle(forWritingTo: rawURL)
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw NSError(domain: "capture", code: 2, userInfo: [NSLocalizedDescriptionKey: "화면 및 시스템 오디오 녹음 권한이 없습니다. 시스템 설정 → 개인정보 보호 및 보안에서 'LocalMinutes'를 켜고 앱을 다시 여세요. 켜져 있는데도 이 안내가 뜨면, 목록에서 LocalMinutes 를 − 로 지운 뒤 다시 추가하세요."])
        }
        guard let display = content.displays.first else {
            throw NSError(domain: "capture", code: 3, userInfo: [NSLocalizedDescriptionKey: "디스플레이를 찾지 못했습니다."])
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
        }
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.showsCursor = false
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "screen"))
        startedAt = Date()
        try await s.startCapture()
        stream = s
    }

    /// 녹음을 멈추고 남은 소리를 마지막 조각으로 넘긴다. 녹음된 길이(초)를 돌려준다.
    func stop() async -> Double {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        return queue.sync {
            let maxEnd = tracks.filter(\.started).map(\.end).max() ?? written
            for t in tracks { pad(t, to: maxEnd) }
            flush()
            emitChunk(force: true)
            try? raw?.close()
            raw = nil
            return Double(written) / Double(Self.rate)
        }
    }

    /// 지난 호출 뒤 가장 큰 소리(나, 상대)와 녹음 길이(초).
    func poll() -> (Float, Float, Double) {
        queue.sync {
            let r = (tracks[0].peak, tracks[1].peak, Double(written) / Double(Self.rate))
            tracks[0].peak = 0
            tracks[1].peak = 0
            return r
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .microphone: append(sb, to: tracks[0])
        case .audio: append(sb, to: tracks[1])
        default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.onError?("녹음이 멈췄습니다: \(error.localizedDescription)") }
    }

    // MARK: - 표본 처리 (모두 queue 위에서)

    private func append(_ sb: CMSampleBuffer, to t: Track) {
        guard CMSampleBufferDataIsReady(sb), let fd = sb.formatDescription,
              var asbd = fd.audioStreamBasicDescription else { return }
        if t.converter == nil {
            guard let inF = AVAudioFormat(streamDescription: &asbd),
                  let outF = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Self.rate),
                                           channels: inF.channelCount, interleaved: false),
                  let conv = AVAudioConverter(from: inF, to: outF) else { return }
            t.inFormat = inF
            t.outFormat = outF
            t.converter = conv
        }
        guard let inF = t.inFormat, let outF = t.outFormat, let conv = t.converter else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
        if origin == nil { origin = pts }
        var samples: [Float] = []
        try? sb.withAudioBufferList { abl, _ in
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: inF, bufferListNoCopy: abl.unsafePointer) else { return }
            let cap = AVAudioFrameCount(Double(inBuf.frameLength) * outF.sampleRate / inF.sampleRate) + 64
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outF, frameCapacity: cap) else { return }
            var fed = false
            var err: NSError?
            conv.convert(to: outBuf, error: &err) { _, status in
                if fed {
                    status.pointee = .noDataNow
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return inBuf
            }
            guard let ch = outBuf.floatChannelData else { return }
            let n = Int(outBuf.frameLength)
            let nch = Int(outF.channelCount)
            samples = [Float](repeating: 0, count: n)
            for c in 0..<nch {
                for i in 0..<n { samples[i] += ch[c][i] / Float(nch) }
            }
        }
        if samples.isEmpty { return }
        for v in samples { t.peak = max(t.peak, abs(v)) }
        var at = Int(((pts - origin!) * Double(Self.rate)).rounded())
        if !t.started {
            t.started = true
            if at < written {
                samples.removeFirst(min(samples.count, written - at))
                at = written
            }
            t.start = at
        } else if at > t.end + Self.rate / 100 {
            // 버퍼가 비었던 만큼 무음을 넣어 시간을 맞춘다.
            t.pending.append(contentsOf: [Float](repeating: 0, count: at - t.end))
        }
        t.pending.append(contentsOf: samples)
        let maxEnd = tracks.filter(\.started).map(\.end).max() ?? 0
        for other in tracks where other.end < maxEnd - Self.maxLag {
            // 한쪽이 오래 조용하면(예: 상대 소리 없음) 무음으로 채워 다른 쪽이 기다리지 않게 한다.
            pad(other, to: maxEnd - Self.maxLag)
        }
        flush()
        emitChunk(force: false)
    }

    private func pad(_ t: Track, to end: Int) {
        if !t.started {
            t.started = true
            t.start = written
        }
        if t.end < end {
            t.pending.append(contentsOf: [Float](repeating: 0, count: end - t.end))
        }
    }

    /// 두 트랙 모두 가진 구간까지 파일과 조각 버퍼에 옮긴다.
    private func flush() {
        guard tracks.allSatisfy(\.started) else { return }
        for t in tracks where t.start > written {
            t.pending.insert(contentsOf: [Float](repeating: 0, count: t.start - written), at: 0)
            t.start = written
        }
        let target = tracks.map(\.end).min()!
        let n = target - written
        if n <= 0 { return }
        let mic = Array(tracks[0].pending.prefix(n))
        let sys = Array(tracks[1].pending.prefix(n))
        for t in tracks {
            t.pending.removeFirst(n)
            t.start += n
        }
        var pcm = [Int16](repeating: 0, count: n * 2)
        for i in 0..<n {
            pcm[2 * i] = Int16(max(-1, min(1, mic[i])) * 32767)
            pcm[2 * i + 1] = Int16(max(-1, min(1, sys[i])) * 32767)
        }
        pcm.withUnsafeBufferPointer { raw?.write(Data(buffer: $0)) }
        chunkMic.append(contentsOf: mic)
        chunkSys.append(contentsOf: sys)
        written = target
    }

    private func emitChunk(force: Bool) {
        let len = chunkMic.count
        if len == 0 { return }
        if !force {
            if len < Self.minChunk { return }
            if len < Self.maxChunk {
                // 마지막 0.3초가 조용할 때만 자른다.
                let tail = Self.rate * 3 / 10
                var sum: Float = 0
                for i in (len - tail)..<len {
                    let v = (chunkMic[i] + chunkSys[i]) / 2
                    sum += v * v
                }
                if (sum / Float(tail)).squareRoot() > 0.01 { return }
            }
        } else if len < Self.rate / 2 {
            return
        }
        chunkIndex += 1
        let c = AudioChunk(index: chunkIndex, startSample: chunkStart, mic: chunkMic, system: chunkSys)
        chunkStart = written
        chunkMic.removeAll(keepingCapacity: true)
        chunkSys.removeAll(keepingCapacity: true)
        onChunk?(c)
    }
}

/// 조각을 스테레오 16-bit WAV 로 쓴다(왼쪽 나 · 오른쪽 상대).
func writeWav(_ c: AudioChunk, to url: URL) throws {
    let n = c.mic.count
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    let rate = UInt32(CaptureEngine.rate)
    d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + n * 4))
    d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(2); u32(rate); u32(rate * 4); u16(4); u16(16)
    d.append(contentsOf: Array("data".utf8)); u32(UInt32(n * 4))
    var pcm = [Int16](repeating: 0, count: n * 2)
    for i in 0..<n {
        pcm[2 * i] = Int16(max(-1, min(1, c.mic[i])) * 32767)
        pcm[2 * i + 1] = Int16(max(-1, min(1, c.system[i])) * 32767)
    }
    pcm.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
    try d.write(to: url)
}
