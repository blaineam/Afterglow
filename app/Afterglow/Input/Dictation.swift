import Speech
import AVFoundation

/// Speech to text for the browser's address bar and forms: the Speech framework, on-device where
/// the phone supports it, with partial results as they come. Needs the microphone and speech
/// recognition usage strings in Info.plist. Logs [Speech].
@MainActor
final class Dictation: ObservableObject {
    @Published private(set) var text = ""
    @Published private(set) var listening = false
    @Published private(set) var available = false
    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var onFinal: ((String) -> Void)?
    /// Off for a spoken passcode: what was heard never reaches the log.
    private var logsText = true
    private var tapInstalled = false
    private var categoryBefore: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?

    init() {
        available = recognizer?.isAvailable ?? false
    }

    func requestPermission() async -> Bool {
        let speech = await Self.askSpeechPermission()
        let microphone = await AVAudioApplication.requestRecordPermission()
        let ok = speech == .authorized && microphone
        log("[Speech] Dictation \(ok ? "allowed" : "not allowed") (speech \(speech.rawValue), microphone \(microphone))")
        return ok
    }

    // The Speech and audio frameworks call back on their own threads. A closure written inside
    // this main-actor class is main-actor isolated, and Swift 6 stops the app the moment one
    // runs off the main thread: the permission callback crashed the whole app when the voice
    // unlock was pressed (owner, 2026-11-08). So these closures are made outside its isolation.
    nonisolated static func askSpeechPermission(
        using ask: @Sendable (@escaping (SFSpeechRecognizerAuthorizationStatus) -> Void) -> Void = { SFSpeechRecognizer.requestAuthorization($0) }
    ) async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            ask { continuation.resume(returning: $0) }
        }
    }

    nonisolated static func tap(into request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        nonisolated(unsafe) let request = request
        return { buffer, _ in request.append(buffer) }
    }

    nonisolated static func resultHandler(_ deliver: @escaping @MainActor @Sendable (String?, Bool) -> Void) -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in
            let text = result?.bestTranscription.formattedString
            let done = error != nil || result?.isFinal == true
            Task { @MainActor in deliver(text, done) }
        }
    }

    /// Why a private entry cannot start, or nil when it can.
    var privateEntryProblem: String? {
        guard let recognizer else { return "No speech recognition for this language" }
        if !recognizer.isAvailable { return "Speech recognition isn't available now" }
        if !recognizer.supportsOnDeviceRecognition { return "On-device speech isn't installed: turn on Dictation in Settings" }
        return nil
    }

    /// Starts listening; `onFinal` gets the text when listening stops. `private` keeps the speech
    /// on the phone (it refuses to start where only server recognition exists) and out of the log.
    func start(private isPrivate: Bool = false, onFinal: @escaping (String) -> Void) {
        guard let recognizer, recognizer.isAvailable, !listening else { return }
        if isPrivate && !recognizer.supportsOnDeviceRecognition {
            log("[Speech] Not listening: this phone has no on-device recognition for a private entry")
            return
        }
        logsText = !isPrivate
        self.onFinal = onFinal
        text = ""
        do {
            let session = AVAudioSession.sharedInstance()
            categoryBefore = (session.category, session.mode, session.categoryOptions)
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            self.request = request
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            // A tap on a format with no rate raises an exception no Swift code can catch.
            guard format.sampleRate > 0, format.channelCount > 0 else {
                log("[Speech] Could not start: the microphone has no input format")
                finish()
                return
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(into: request))
            tapInstalled = true
            engine.prepare()
            try engine.start()
            task = recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler { [weak self] heard, done in
                guard let self else { return }
                if let heard { self.text = heard }
                if done { self.finish() }
            })
            listening = true
            log("[Speech] Listening\(request.requiresOnDeviceRecognition ? " (on device)" : "")")
        } catch {
            log("[Speech] Could not start: \(error.localizedDescription)")
            finish()
        }
    }

    func stop() {
        request?.endAudio()
        finish()
    }

    private func finish() {
        guard listening || task != nil || categoryBefore != nil else { return }
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        task?.cancel()
        task = nil
        request = nil
        listening = false
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        // Back to how the app's audio was: left on record, the app's own sounds stay silent.
        if let before = categoryBefore { try? session.setCategory(before.0, mode: before.1, options: before.2); categoryBefore = nil }
        let final = text
        onFinal?(final)
        onFinal = nil
        log(logsText ? "[Speech] Heard: \(final.isEmpty ? "(nothing)" : final)" : "[Speech] Heard a private entry (\(final.isEmpty ? "nothing" : "not logged"))")
    }
}
