@preconcurrency import AVFoundation
import Metal
import CoreVideo
import Photos

/// Records one eye's picture, undistorted, as a flat H.264 movie: each frame the eye texture's
/// slice is copied into a pixel buffer from a Metal-compatible pool and appended through an
/// AVAssetWriter at the display's rate; the file lands in Documents/Recordings and is offered to
/// the Photos library. The owner's ask: a 2D recording of what the left or right eye sees. Logs
/// [Capture].
final class EyeRecorder: @unchecked Sendable {
    private let device: MTLDevice
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var cache: CVMetalTextureCache?
    private var startTime: Double = 0
    private var frames = 0
    private var dropped = 0
    private(set) var url: URL?
    private(set) var eye: Int = 0
    private var size = (0, 0)
    private var finishing = false

    var isRecording: Bool { writer != nil && !finishing }

    init(device: MTLDevice) {
        self.device = device
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    }

    func start(eye: Int, width: Int, height: Int, frameRate: Int) {
        guard writer == nil else { return }
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Recordings")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = folder.appendingPathComponent("afterglow-\(eye == 0 ? "left" : "right")-\(stamp).mp4")
        // Even dimensions for the encoder.
        let w = width & ~1, h = height & ~1
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
                                           AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000, AVVideoExpectedSourceFrameRateKey: frameRate]]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferMetalCompatibilityKey as String: true])
            guard writer.canAdd(input) else { log("[Capture] Cannot add the video input"); return }
            writer.add(input)
            guard writer.startWriting() else { log("[Capture] Cannot start writing: \(writer.error?.localizedDescription ?? "?")"); return }
            writer.startSession(atSourceTime: .zero)
            self.writer = writer
            self.input = input
            self.adaptor = adaptor
            self.url = url
            self.eye = eye
            size = (w, h)
            startTime = 0
            frames = 0
            dropped = 0
            log("[Capture] Recording the \(eye == 0 ? "left" : "right") eye, \(w)x\(h) at \(frameRate) fps, to \(url.lastPathComponent)")
        } catch {
            log("[Capture] Recording failed to start: \(error.localizedDescription)")
        }
    }

    /// Encodes a copy of the eye's slice: a blit into a pool buffer's texture, then the append once
    /// the GPU has copied it.
    func capture(eyeTexture: MTLTexture, commandBuffer: MTLCommandBuffer, time: Double) {
        guard let input, let adaptor, let pool = adaptor.pixelBufferPool, let cache, input.isReadyForMoreMediaData else {
            if writer != nil { dropped += 1 }
            return
        }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess, let pixelBuffer else { dropped += 1; return }
        var cvTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, nil, .bgra8Unorm, size.0, size.1, 0, &cvTexture) == kCVReturnSuccess,
              let cvTexture, let target = CVMetalTextureGetTexture(cvTexture), let blit = commandBuffer.makeBlitCommandEncoder() else { dropped += 1; return }
        blit.copy(from: eyeTexture, sourceSlice: eye, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: size.0, height: size.1, depth: 1),
                  to: target, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        if startTime == 0 { startTime = time }
        let presentation = CMTime(seconds: time - startTime, preferredTimescale: 600)
        let keep = Unchecked((pixelBuffer, cvTexture))
        commandBuffer.addCompletedHandler { [weak self] _ in
            guard let self, let adaptor = self.adaptor, let input = self.input, input.isReadyForMoreMediaData else { return }
            if adaptor.append(keep.value.0, withPresentationTime: presentation) { self.frames += 1 } else { self.dropped += 1 }
        }
    }

    func stop(saveToPhotos: Bool) {
        guard let writer, let input, !finishing else { return }
        finishing = true
        input.markAsFinished()
        let url = self.url
        let frames = self.frames, dropped = self.dropped
        writer.finishWriting { [weak self] in
            log("[Capture] Recording finished: \(frames) frames, \(dropped) dropped, \(url?.lastPathComponent ?? "?") (\(writer.status == .completed ? "ok" : writer.error?.localizedDescription ?? "failed"))")
            if saveToPhotos, writer.status == .completed, let url {
                PHPhotoLibrary.shared().performChanges({ PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url) }) { ok, error in
                    log("[Capture] \(ok ? "Saved to Photos" : "Not saved to Photos: \(error?.localizedDescription ?? "?")")")
                }
            }
            self?.writer = nil
            self?.input = nil
            self?.adaptor = nil
            self?.finishing = false
        }
    }
}
