@preconcurrency import AVFoundation
import CoreMedia
import Photos
import Metal
import CoreVideo

/// Plays a video from the Photos library or a file and hands each frame over as a Metal texture,
/// without copying: AVPlayerItemVideoOutput gives BGRA pixel buffers, wrapped through a texture
/// cache. Spatial (MV-HEVC) videos come through AVPlayerVideoOutput with both stereo views as a
/// tagged buffer group, each eye a texture, as the Unity plugin does. Logs [Video].
final class VideoPlayer: @unchecked Sendable {
    let player = AVPlayer()
    private let device: MTLDevice
    private var cache: CVMetalTextureCache?
    private var output: AVPlayerItemVideoOutput?
    private var stereoOutput: AVPlayerVideoOutput?
    private var stereoAskedAt: Double = 0
    private var stereoFellBack = false
    private var playerItem: AVPlayerItem?
    /// True until the first picture of the current item is on screen: the viewer shows a spinner.
    private(set) var isLoading = false
    private let lock = NSLock()
    private var current: (texture: MTLTexture, ref: CVMetalTexture, buffer: CVPixelBuffer)?
    private var eyes: (left: MTLTexture, right: MTLTexture, refs: [CVMetalTexture], buffers: [CVPixelBuffer])?
    private var eyeArray: MTLTexture?
    private var lastFrameTime: Double = 0
    private var frames = 0
    private var lastLog: Double = 0
    private(set) var isStereo = false
    private(set) var naturalSize = CGSize.zero
    private var loggedFirst = false

    init(device: MTLDevice) {
        self.device = device
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        player.actionAtItemEnd = .none
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: nil) { [weak self] note in
            guard let self, let item = note.object as? AVPlayerItem, item === self.player.currentItem else { return }
            item.seek(to: .zero, completionHandler: nil)
        }
    }

    /// Seconds, 0 while nothing is loaded (an indefinite time is NaN, which no integer takes).
    var duration: Double { let d = player.currentItem?.duration.seconds ?? 0; return d.isFinite ? d : 0 }
    var time: Double { let t = player.currentTime().seconds; return t.isFinite ? t : 0 }
    var isPlaying: Bool { player.rate > 0 }

    /// Opens an item: a Photos asset (the library hands over the AVAsset) or a file.
    @MainActor
    func open(item: MediaItem, stereo: Bool) async {
        var avAsset: AVAsset?
        if let asset = item.asset {
            let boxed: Unchecked<AVAsset?> = await withCheckedContinuation { continuation in
                let options = PHVideoRequestOptions()
                options.isNetworkAccessAllowed = true
                options.deliveryMode = .highQualityFormat
                // The original, so a spatial video's second layer survives any edit.
                options.version = stereo ? .original : .current
                // Photos may call back more than once (a progress call, then the asset): the first
                // answer with an asset, or the first at all after that, is the one taken.
                let once = LockedValue<Bool>(false)
                PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { @Sendable av, _, info in
                    let inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false
                    if av == nil && inCloud { return }
                    if once.value { return }
                    once.value = true
                    continuation.resume(returning: Unchecked(av))
                }
            }
            avAsset = boxed.value
        } else if let url = item.fileURL {
            avAsset = AVURLAsset(url: url)
        }
        guard let avAsset else { log("[Video] Nothing to play"); return }
        let playerItem = AVPlayerItem(asset: avAsset)
        lock.withLock {
            current = nil
            eyes = nil
            eyeArray = nil
            isStereo = false
            loggedFirst = false
        }
        if let track = try? await avAsset.loadTracks(withMediaType: .video).first {
            naturalSize = (try? await track.load(.naturalSize)) ?? .zero
        }
        if stereo {
            // Both stereo views, as the Unity plugin asks: the stereoscopic preset first, the
            // monoscopic as the fallback, BGRA and Metal-compatible, the output set before the item.
            // In Swift a tag collection is an array of tags: the stereoscopic preset (both eyes)
            // first, a monoscopic one (the left eye alone) as the fallback.
            let collections: [[CMTag]] = [[.stereoView(.leftEye), .stereoView(.rightEye)], [.stereoView(.leftEye)]]
            let specification = AVVideoOutputSpecification(tagCollections: collections)
            specification.defaultPixelBufferAttributes = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                                          kCVPixelBufferMetalCompatibilityKey as String: true]
            let stereoOutput = AVPlayerVideoOutput(specification: specification)
            player.videoOutput = stereoOutput
            self.stereoOutput = stereoOutput
            self.output = nil
            stereoAskedAt = CACurrentMediaTime()
            stereoFellBack = false
        } else {
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                                                          kCVPixelBufferMetalCompatibilityKey as String: true])
            playerItem.add(output)
            self.output = output
            player.videoOutput = nil
            self.stereoOutput = nil
        }
        self.playerItem = playerItem
        isLoading = true
        player.replaceCurrentItem(with: playerItem)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        log("[Video] Playing \(item.kind.rawValue) \(Int(naturalSize.width))x\(Int(naturalSize.height)), \(Int(item.duration)) s\(stereo ? ", asking for both eyes" : "")")
    }

    func pause() { player.pause() }

    func togglePlay() {
        if isPlaying { player.pause() } else { player.play() }
    }

    func skip(_ seconds: Double) {
        let target = max(0, min(duration, time + seconds))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seek(fraction: Double) {
        guard duration > 0 else { return }
        player.seek(to: CMTime(seconds: duration * fraction, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func close() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        player.videoOutput = nil
        lock.withLock {
            current = nil
            eyes = nil
            eyeArray = nil
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// The frame for the display time: a flat texture, or a two-slice array for a spatial video.
    func frame(at hostTime: Double) -> (texture: MTLTexture?, eyes: MTLTexture?) {
        guard let cache else { return (nil, nil) }
        if let stereoOutput {
            // No tagged buffers two seconds into playback: the player gave the sound and not the
            // picture (owner, 2026-11-07); the flat output shows the file's base view instead.
            if !stereoFellBack, frames == 0, loggedFirst == false, time > 0.3, CACurrentMediaTime() - stereoAskedAt > 2, let playerItem {
                stereoFellBack = true
                log("[Video] No stereo frames from the spatial output in 2 s (status \(player.status.rawValue), item \(playerItem.status.rawValue)): showing the base view flat")
                let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                                                              kCVPixelBufferMetalCompatibilityKey as String: true])
                playerItem.add(output)
                player.videoOutput = nil
                self.stereoOutput = nil
                self.output = output
                return (nil, nil)
            }
            if let result = stereoOutput.taggedBuffers(forHostTime: CMClockGetTime(CMClockGetHostTimeClock())),
               result.presentationTime.seconds != lastFrameTime {
                lastFrameTime = result.presentationTime.seconds
                var left: CVPixelBuffer?, right: CVPixelBuffer?, any: CVPixelBuffer?
                for item in result.taggedBufferGroup {
                    guard case .pixelBuffer(let buffer) = item.buffer else { continue }
                    if any == nil { any = buffer }
                    if item.tags.contains(.stereoView(.leftEye)) { left = buffer }
                    else if item.tags.contains(.stereoView(.rightEye)) { right = buffer }
                }
                if let left, let right, let l = texture(from: left, cache: cache), let r = texture(from: right, cache: cache) {
                    lock.withLock {
                        eyes = (l.texture, r.texture, [l.ref, r.ref], [left, right])
                        isStereo = true
                    }
                    if !loggedFirst { loggedFirst = true; isLoading = false; log("[Video] Spatial video playing: \(l.texture.width)x\(l.texture.height) per eye, both eyes") }
                    frames += 1
                } else if let any, let t = texture(from: any, cache: cache) {
                    lock.withLock {
                        current = (t.texture, t.ref, any)
                        eyes = nil
                        isStereo = false
                    }
                    if !loggedFirst { loggedFirst = true; isLoading = false; log("[Video] Spatial video playing: one eye shown to both") }
                    frames += 1
                }
            }
        } else if let output {
            let itemTime = output.itemTime(forHostTime: hostTime)
            if output.hasNewPixelBuffer(forItemTime: itemTime), let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil),
               let t = texture(from: buffer, cache: cache) {
                lock.withLock { current = (t.texture, t.ref, buffer) }
                frames += 1
                if !loggedFirst { loggedFirst = true; isLoading = false; log("[Video] Playing \(t.texture.width)x\(t.texture.height)") }
            }
        }
        CVMetalTextureCacheFlush(cache, 0)
        let now = CACurrentMediaTime()
        if now - lastLog >= 5 {
            if lastLog > 0 { log(String(format: "[Video] %.1f frames/s, at %.0f of %.0f s", Double(frames) / (now - lastLog), time, duration)) }
            lastLog = now
            frames = 0
        }
        return lock.withLock {
            if let eyes {
                // The two eyes as one array for the shader: blitted when either changes.
                return (nil, eyeArrayFor(eyes.left, eyes.right))
            }
            return (current?.texture, nil)
        }
    }

    private func eyeArrayFor(_ left: MTLTexture, _ right: MTLTexture) -> MTLTexture? {
        if eyeArray == nil || eyeArray!.width != left.width || eyeArray!.height != left.height {
            let d = MTLTextureDescriptor()
            d.textureType = .type2DArray
            d.arrayLength = 2
            d.pixelFormat = left.pixelFormat
            d.width = left.width
            d.height = left.height
            d.usage = .shaderRead
            d.storageMode = .private
            eyeArray = device.makeTexture(descriptor: d)
        }
        guard let eyeArray, let queue = blitQueue ?? device.makeCommandQueue() else { return nil }
        blitQueue = queue
        guard let buffer = queue.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder() else { return eyeArray }
        let size = MTLSize(width: left.width, height: left.height, depth: 1)
        blit.copy(from: left, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: size, to: eyeArray, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.copy(from: right, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: size, to: eyeArray, destinationSlice: 1, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        buffer.commit()
        return eyeArray
    }
    private var blitQueue: MTLCommandQueue?

    private func texture(from buffer: CVPixelBuffer, cache: CVMetalTextureCache) -> (texture: MTLTexture, ref: CVMetalTexture)? {
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        var cvTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm, width, height, 0, &cvTexture) == kCVReturnSuccess,
              let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        return (texture, cvTexture)
    }
}
