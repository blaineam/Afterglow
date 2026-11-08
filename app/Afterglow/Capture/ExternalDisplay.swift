import UIKit
import Metal
import QuartzCore

/// What the user sees, flat, on an Apple TV or any screen the phone mirrors to: iOS hands the
/// app a scene for the external display, and this window on it shows the left eye's picture
/// undistorted (the lens-warped screen would be unwatchable). The renderer blits the eye texture
/// into this layer's drawable each frame while a display is connected. Logs [Cast].
@MainActor
final class ExternalDisplay {
    static let shared = ExternalDisplay()
    private(set) var window: UIWindow?
    private(set) var layer: CAMetalLayer?
    private var view: UIView?

    var isConnected: Bool { layer != nil }

    func connect(to scene: UIWindowScene, device: MTLDevice) {
        let window = UIWindow(windowScene: scene)
        let bounds = scene.effectiveGeometry.coordinateSpace.bounds
        let view = CastView(frame: bounds)
        view.metalLayer.device = device
        view.metalLayer.pixelFormat = .bgra8Unorm
        view.metalLayer.framebufferOnly = false
        view.metalLayer.contentsScale = scene.screen.scale
        view.metalLayer.drawableSize = CGSize(width: bounds.width * scene.screen.scale, height: bounds.height * scene.screen.scale)
        window.rootViewController = UIViewController()
        window.rootViewController?.view = view
        window.isHidden = false
        self.window = window
        self.view = view
        self.layer = view.metalLayer
        log("[Cast] External display connected: \(Int(view.metalLayer.drawableSize.width))x\(Int(view.metalLayer.drawableSize.height))")
    }

    func disconnect() {
        window?.isHidden = true
        window = nil
        view = nil
        layer = nil
        log("[Cast] External display disconnected")
    }

    /// Blits one eye's slice into the display's drawable, letterboxed by scaling into the centre.
    func present(eyeTexture: MTLTexture, eye: Int, commandBuffer: MTLCommandBuffer, device: MTLDevice, pipeline: MTLRenderPipelineState) {
        guard let layer, let drawable = layer.nextDrawable() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        // The eye's picture is taller than a TV: fit it by height, centred.
        let targetAspect = Double(drawable.texture.width) / Double(drawable.texture.height)
        let eyeAspect = Double(eyeTexture.width) / Double(eyeTexture.height)
        var viewport = MTLViewport(originX: 0, originY: 0, width: Double(drawable.texture.width), height: Double(drawable.texture.height), znear: 0, zfar: 1)
        if eyeAspect < targetAspect {
            viewport.width = Double(drawable.texture.height) * eyeAspect
            viewport.originX = (Double(drawable.texture.width) - viewport.width) / 2
        } else {
            viewport.height = Double(drawable.texture.width) / eyeAspect
            viewport.originY = (Double(drawable.texture.height) - viewport.height) / 2
        }
        encoder.setViewport(viewport)
        encoder.setRenderPipelineState(pipeline)
        var slice = UInt32(eye)
        encoder.setFragmentBytes(&slice, length: MemoryLayout<UInt32>.stride, index: 0)
        encoder.setFragmentTexture(eyeTexture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
    }
}

final class CastView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
}
