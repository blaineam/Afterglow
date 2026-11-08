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

    init() {
        available = recognizer?.isAvailable ?? false
    }

    func requestPermission() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        let microphone = await AVAudioApplication.requestRecordPermission()
        let ok = speech == .authorized && microphone
        log("[Speech] Dictation \(ok ? "allowed" : "not allowed") (speech \(speech.rawValue), microphone \(microphone))")
        return ok
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
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            self.request = request
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            engine.prepare()
            try engine.start()
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result { self.text = result.bestTranscription.formattedString }
                    if error != nil || result?.isFinal == true { self.finish() }
                }
            }
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
        guard listening || task != nil else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        task?.cancel()
        task = nil
        request = nil
        listening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let final = text
        onFinal?(final)
        onFinal = nil
        log(logsText ? "[Speech] Heard: \(final.isEmpty ? "(nothing)" : final)" : "[Speech] Heard a private entry (\(final.isEmpty ? "nothing" : "not logged"))")
    }
}
