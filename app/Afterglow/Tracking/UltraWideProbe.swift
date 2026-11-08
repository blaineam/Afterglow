import AVFoundation

/// An experiment, `--ei ultraTest N`: opens the ultra-wide camera through AVFoundation N seconds
/// after ARKit starts and logs what happens to both, to settle whether a second camera can run
/// beside ARKit's world tracking on this phone (the ultra-wide has no ARKit world-tracking
/// format here). Nothing is drawn from it.
final class UltraWideProbe: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "afterglow.ultraprobe")
    private var frames = 0
    private var lastLog: Double = 0

    func start() {
        queue.async { [self] in
            guard let device = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) else {
                log("[Camera] Ultra-wide probe: no ultra-wide capture device")
                return
            }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                session.beginConfiguration()
                session.sessionPreset = .hd1280x720
                guard session.canAddInput(input) else { log("[Camera] Ultra-wide probe: cannot add the input"); return }
                session.addInput(input)
                let output = AVCaptureVideoDataOutput()
                output.setSampleBufferDelegate(self, queue: queue)
                guard session.canAddOutput(output) else { log("[Camera] Ultra-wide probe: cannot add the output"); return }
                session.addOutput(output)
                session.commitConfiguration()
                let fov = device.activeFormat.videoFieldOfView
                log(String(format: "[Camera] Ultra-wide probe: starting %@, field of view %.0f deg, multi-cam supported %@",
                           device.localizedName, fov, AVCaptureMultiCamSession.isMultiCamSupported ? "yes" : "no"))
                NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { note in
                    log("[Camera] Ultra-wide probe: runtime error \(note.userInfo?[AVCaptureSessionErrorKey] ?? "?")")
                }
                NotificationCenter.default.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { note in
                    log("[Camera] Ultra-wide probe: interrupted, reason \(note.userInfo?[AVCaptureSessionInterruptionReasonKey] ?? "?")")
                }
                session.startRunning()
                log("[Camera] Ultra-wide probe: running \(session.isRunning)")
            } catch {
                log("[Camera] Ultra-wide probe failed: \(error.localizedDescription)")
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frames += 1
        let now = CACurrentMediaTime()
        if now - lastLog >= 5 {
            log("[Camera] Ultra-wide probe: \(frames) frames in the last 5 s")
            frames = 0
            lastLog = now
        }
    }
}
