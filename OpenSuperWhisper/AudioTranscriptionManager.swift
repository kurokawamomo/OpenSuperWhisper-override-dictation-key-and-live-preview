import AVFoundation
import Combine
import Foundation
import Speech

/// Drives ONE live-preview transcription session. Implementations receive raw
/// microphone buffers as they arrive during recording and report partial text as
/// it becomes available. Completely independent of the final batch transcription
/// path (`TranscriptionService`): a live engine's failure never affects it, and
/// vice versa.
protocol LivePreviewEngine: AnyObject {
    func start(onPartialText: @escaping (String) -> Void)
    func appendAudio(_ buffer: AVAudioPCMBuffer)
    func stop()
}

/// Orchestrates the live-preview engine for the current recording. Owns no audio
/// capture itself: `AudioRecorder` fans out the same buffers it already taps for
/// the final recording into `appendLiveAudio`, keyed by the recording's session ID
/// (the same one `RecordingSessionController`/`IndicatorViewModel` already use), so
/// a stale/cancelled session's buffers are dropped rather than leaking into the
/// next recording's preview.
@MainActor
final class AudioTranscriptionManager: ObservableObject {
    static let shared = AudioTranscriptionManager()

    @Published private(set) var partialText: String?

    // `appendLiveAudio` is called directly from the AVAudioEngine tap thread (not
    // the main actor) so a live-preview chunk is handed off with no main-thread
    // round trip. These two are the only state it touches, so they're guarded by
    // a lock instead of actor isolation (same pattern as `AbortFlag` elsewhere).
    private let stateLock = NSLock()
    private nonisolated(unsafe) var activeSessionID: UUID?
    private nonisolated(unsafe) var engine: LivePreviewEngine?

    private var batchBusyCancellable: AnyCancellable?

    private init() {}

    func startLivePreview(sessionID: UUID) {
        partialText = nil

        guard AppPreferences.shared.livePreviewEnabled else {
            print("[LivePreview][diag] startLivePreview(\(sessionID)): livePreviewEnabled=false, skipping")
            return
        }

        print("[LivePreview][diag] startLivePreview(\(sessionID)): enabled, engine=\(AppPreferences.shared.livePreviewEngine)")

        let newEngine: LivePreviewEngine?
        switch AppPreferences.shared.livePreviewEngine {
        case "whisper":
            if let whisperEngine = TranscriptionService.shared.whisperEngineForLivePreview,
               let whisperLiveEngine = WhisperLivePreviewEngine(whisperEngine: whisperEngine) {
                // The final batch pass must never wait on (or be slowed down by) a
                // live-preview decode sharing the same model weights, so the live
                // loop skips its tick whenever a batch transcription is in flight.
                batchBusyCancellable = TranscriptionService.shared.$isTranscribing
                    .sink { [weak whisperLiveEngine] busy in
                        whisperLiveEngine?.setBatchBusy(busy)
                    }
                newEngine = whisperLiveEngine
            } else {
                print("[LivePreview] whisper selected, but the active batch engine isn't Whisper (likely Parakeet) — skipping live preview for this recording rather than loading a second model")
                newEngine = nil
            }
        default:
            newEngine = AppleLivePreviewEngine()
        }

        guard let newEngine else {
            print("[LivePreview][diag] startLivePreview(\(sessionID)): no engine constructed, live preview inactive for this recording")
            return
        }

        stateLock.lock()
        activeSessionID = sessionID
        engine = newEngine
        stateLock.unlock()

        print("[LivePreview][diag] startLivePreview(\(sessionID)): engine=\(type(of: newEngine)) armed")

        newEngine.start { [weak self] text in
            guard let self else { return }
            Task { @MainActor in
                self.stateLock.lock()
                let isActive = self.activeSessionID == sessionID
                self.stateLock.unlock()
                print("[LivePreview][diag] partial text for \(sessionID) (isActive=\(isActive)): \"\(text)\"")
                guard isActive else { return }
                self.partialText = text
            }
        }
    }

    private nonisolated(unsafe) var didLogFirstBuffer = false

    nonisolated func appendLiveAudio(_ buffer: AVAudioPCMBuffer, sessionID: UUID) {
        stateLock.lock()
        let isActive = activeSessionID == sessionID
        let currentEngine = engine
        stateLock.unlock()
        if !didLogFirstBuffer {
            didLogFirstBuffer = true
            print("[LivePreview][diag] appendLiveAudio(\(sessionID)): isActive=\(isActive), format=\(buffer.format)")
        }
        guard isActive else { return }
        currentEngine?.appendAudio(buffer)
    }

    func stopLivePreview(sessionID: UUID) {
        stateLock.lock()
        guard activeSessionID == sessionID else {
            stateLock.unlock()
            return
        }
        let stoppingEngine = engine
        activeSessionID = nil
        engine = nil
        stateLock.unlock()

        batchBusyCancellable = nil
        stoppingEngine?.stop()
        partialText = nil
        didLogFirstBuffer = false
    }
}

/// Apple's on-device speech recognizer. Partial results are a native feature here,
/// so this engine is little more than wiring — and a completely separate path from
/// Whisper, its output never touches the final batch pass.
final class AppleLivePreviewEngine: LivePreviewEngine {
    private let recognizer = SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var onPartialText: ((String) -> Void)?

    func start(onPartialText: @escaping (String) -> Void) {
        self.onPartialText = onPartialText
        print("[LivePreview][apple][diag] requesting speech recognition authorization")
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            print("[LivePreview][apple][diag] authorization status=\(status.rawValue)")
            guard status == .authorized else {
                print("[LivePreview][apple] speech recognition authorization not granted (\(status.rawValue))")
                return
            }
            DispatchQueue.main.async { self?.beginRecognitionIfNeeded() }
        }
    }

    private func beginRecognitionIfNeeded() {
        guard task == nil, let recognizer, recognizer.isAvailable else {
            print("[LivePreview][apple] recognizer unavailable for this locale/session (recognizer=\(String(describing: recognizer)), isAvailable=\(recognizer?.isAvailable ?? false))")
            return
        }
        print("[LivePreview][apple][diag] recognition task starting, onDeviceSupported=\(recognizer.supportsOnDeviceRecognition)")
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            if let result {
                self?.onPartialText?(result.bestTranscription.formattedString)
            }
            if let error {
                print("[LivePreview][apple] recognition error: \(error.localizedDescription)")
            }
        }
    }

    func appendAudio(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
    }

    func stop() {
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        onPartialText = nil
    }
}

/// A hand-rolled equivalent of whisper.cpp's classic `examples/stream`: repeatedly
/// re-decodes the trailing few seconds of audio against the SAME already-loaded
/// model — a second, independent `whisper_state` (see
/// `MyWhisperContext.makeSecondaryState()`) — so this needs no additional
/// native/bridge work and no second model load. `noContext` stays true so each
/// window decodes independently: a hallucination on one window's audio cannot
/// poison the next, at the cost of the sentence-level continuity the final batch
/// pass gets via `prompt_past` — live preview does not need that.
final class WhisperLivePreviewEngine: LivePreviewEngine {
    private static let windowDuration: TimeInterval = 4.0
    private static let stepDuration: TimeInterval = 1.2
    private static let sampleRate: Double = 16000

    private let context: MyWhisperContext
    private var state: OpaquePointer?
    private var converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat

    private let queue = DispatchQueue(label: "com.opensuperwhisper.livepreview.whisper", qos: .userInitiated)
    private var pendingSamples: [Float] = []
    private var samplesSinceLastDecode = 0
    private var isDecoding = false
    private var onPartialText: ((String) -> Void)?
    private var lastEmittedText = ""

    private let busyLock = NSLock()
    private var isBatchBusy = false

    init?(whisperEngine: WhisperEngine) {
        guard let sharedContext = whisperEngine.contextForLivePreview,
              let secondaryState = sharedContext.makeSecondaryState(),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false)
        else {
            print("[LivePreview][whisper][diag] init failed (contextForLivePreview or makeSecondaryState returned nil)")
            return nil
        }
        context = sharedContext
        state = secondaryState
        targetFormat = format
        print("[LivePreview][whisper][diag] secondary state created on shared context")
    }

    func setBatchBusy(_ busy: Bool) {
        busyLock.lock()
        isBatchBusy = busy
        busyLock.unlock()
    }

    func start(onPartialText: @escaping (String) -> Void) {
        queue.async { [weak self] in
            self?.onPartialText = onPartialText
        }
    }

    func appendAudio(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            self?.handle(buffer: buffer)
        }
    }

    private func handle(buffer: AVAudioPCMBuffer) {
        guard state != nil else { return }

        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            converter?.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        }
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return }

        var consumed = false
        var convError: NSError?
        converter.convert(to: outBuffer, error: &convError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard convError == nil, outBuffer.frameLength > 0, let channelData = outBuffer.floatChannelData else { return }

        let newSamples = UnsafeBufferPointer(start: channelData[0], count: Int(outBuffer.frameLength))
        pendingSamples.append(contentsOf: newSamples)
        samplesSinceLastDecode += newSamples.count

        let stepSamples = Int(Self.stepDuration * Self.sampleRate)
        guard samplesSinceLastDecode >= stepSamples, !isDecoding else { return }
        samplesSinceLastDecode = 0
        decodeCurrentWindow()
    }

    private func decodeCurrentWindow() {
        guard let state else { return }

        let windowSamples = Int(Self.windowDuration * Self.sampleRate)
        if pendingSamples.count > windowSamples {
            pendingSamples.removeFirst(pendingSamples.count - windowSamples)
        }
        let chunk = pendingSamples
        guard !chunk.isEmpty else { return }

        busyLock.lock()
        let busy = isBatchBusy
        busyLock.unlock()
        guard !busy else {
            print("[LivePreview][whisper][diag] skipping tick: batch transcription in flight")
            return
        }

        isDecoding = true
        defer { isDecoding = false }

        var params = WhisperFullParams()
        params.strategy = .greedy
        params.nThreads = Int32(max(2, min(ProcessInfo.processInfo.activeProcessorCount / 2, 4)))
        params.noContext = true
        params.noTimestamps = true
        params.suppressBlank = true
        params.greedyBestOf = 1
        params.temperature = 0
        let language = AppPreferences.shared.whisperLanguage
        params.language = language == "auto" ? nil : language
        var cParams = params.toC()

        guard context.full(samples: chunk, params: &cParams, state: state) else {
            print("[LivePreview][whisper][diag] decode of \(chunk.count) samples failed")
            return
        }

        var text = ""
        let nSegments = context.fullNSegments(state: state)
        for i in 0..<nSegments {
            text += context.fullGetSegmentText(state: state, iSegment: i) ?? ""
        }
        text = text
            .replacingOccurrences(of: "[MUSIC]", with: "")
            .replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty, text != lastEmittedText else { return }
        lastEmittedText = text
        onPartialText?(text)
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            if let state = self.state {
                self.context.freeSecondaryState(state)
            }
            self.state = nil
            self.pendingSamples.removeAll()
            self.onPartialText = nil
        }
    }
}
