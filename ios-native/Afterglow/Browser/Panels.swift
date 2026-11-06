import SwiftUI
import Metal
import simd

/// A panel in the scene: a pane with a texture rendered from SwiftUI, and buttons with known
/// rectangles (0-1 across and down the pane) that the gaze lands on and a pinch or tap presses.
/// Rendering happens only when the content changes, through `ImageRenderer`.
@MainActor
final class ScenePanel {
    struct Button {
        var id: String
        var rect: CGRect       // 0-1 across and down
        var label: String
        var wide: Bool = false
    }

    var pane = BrowserWindow()
    private(set) var texture: MTLTexture?
    private(set) var buttons: [Button] = []
    private(set) var hovered: String?
    private let device: MTLDevice
    private let pixelSize: CGSize
    private var version = ""
    private var rendered = ""
    var visible = true

    init(device: MTLDevice, pixelWidth: Int, pixelHeight: Int) {
        self.device = device
        pixelSize = CGSize(width: pixelWidth, height: pixelHeight)
        pane.aspect = Float(pixelWidth) / Float(pixelHeight)
    }

    func set(buttons: [Button], version: String) {
        self.buttons = buttons
        self.version = version
    }

    func hover(_ uv: SIMD2<Float>?) -> Bool {
        let id = uv.flatMap { p in buttons.first { $0.rect.contains(CGPoint(x: Double(p.x), y: Double(p.y))) }?.id }
        let changed = id != hovered
        hovered = id
        return changed
    }

    /// Renders `content` into the texture when it (or the hover) changed since the last render.
    func render<V: View>(_ content: V) {
        let key = version + "|" + (hovered ?? "")
        if key == rendered && texture != nil { return }
        let renderer = ImageRenderer(content: content.frame(width: pixelSize.width, height: pixelSize.height))
        renderer.scale = 1
        renderer.isOpaque = false
        guard let image = renderer.cgImage else { return }
        upload(image)
        rendered = key
    }

    private func upload(_ image: CGImage) {
        let width = image.width, height = image.height
        if texture == nil || texture!.width != width || texture!.height != height {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            d.usage = .shaderRead
            d.storageMode = .shared
            texture = device.makeTexture(descriptor: d)
            texture?.label = "panel"
        }
        guard let texture else { return }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: buffer.baseAddress!, bytesPerRow: width * 4)
        }
    }
}

/// The look shared by the panels: dark glass, rounded, bright text, a glow on the hovered key.
enum PanelStyle {
    static let background = Color(red: 0.08, green: 0.05, blue: 0.16).opacity(0.78)
    static let key = Color.white.opacity(0.10)
    static let keyHover = Color(red: 1.0, green: 0.25, blue: 0.75).opacity(0.85)
    static let text = Color.white
    static let accent = Color(red: 0.2, green: 0.9, blue: 1.0)
}

/// Draws buttons at their rectangles over a panel background; the same rectangles the gaze is
/// tested against, so what is seen is what is pressed.
struct ButtonsView: View {
    let size: CGSize
    let buttons: [ScenePanel.Button]
    let hovered: String?
    let title: String?
    let titleHighlight: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 36).fill(PanelStyle.background)
            if let title {
                Text(title)
                    .font(.system(size: 34, weight: .medium, design: .rounded))
                    .foregroundStyle(titleHighlight ? PanelStyle.accent : PanelStyle.text)
                    .lineLimit(1)
                    .padding(.horizontal, 30)
                    .padding(.top, 18)
            }
            ForEach(buttons, id: \.id) { button in
                let r = CGRect(x: button.rect.minX * size.width, y: button.rect.minY * size.height,
                               width: button.rect.width * size.width, height: button.rect.height * size.height).insetBy(dx: 5, dy: 5)
                RoundedRectangle(cornerRadius: 18)
                    .fill(hovered == button.id ? PanelStyle.keyHover : PanelStyle.key)
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.18), lineWidth: 2))
                    .overlay(Text(button.label)
                        .font(.system(size: button.label.count > 2 ? 26 : 38, weight: .medium, design: .rounded))
                        .foregroundStyle(PanelStyle.text)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .padding(6))
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
            }
        }
    }
}

/// The keyboard: letters, a symbols layer, shift, space, backspace, clear, mic, hide and go.
/// Gazed at and pinched (or tapped), key by key, as the Unity app's WebKeyboard.
@MainActor
final class KeyboardPanel {
    let panel: ScenePanel
    private(set) var shifted = false
    private(set) var symbols = false
    private static let letterRows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    private static let symbolRows = ["1234567890", "-/:;()$&@\"", ".,?!'[]{}#"]

    init(device: MTLDevice) {
        panel = ScenePanel(device: device, pixelWidth: 1600, pixelHeight: 620)
        panel.pane.widthMeters = 1.25
        layout()
    }

    private func layout() {
        var buttons: [ScenePanel.Button] = []
        let rows = symbols ? Self.symbolRows : Self.letterRows
        let rowHeight: CGFloat = 0.2
        let top: CGFloat = 0.03
        for (r, row) in rows.enumerated() {
            let n = CGFloat(row.count)
            let keyWidth = 0.094
            let rowWidth = n * keyWidth
            let x0 = (1 - rowWidth) / 2
            for (i, ch) in row.enumerated() {
                let label = shifted && !symbols ? String(ch).uppercased() : String(ch)
                buttons.append(.init(id: "k:" + label, rect: CGRect(x: x0 + CGFloat(i) * keyWidth, y: top + CGFloat(r) * rowHeight, width: keyWidth, height: rowHeight), label: label))
            }
        }
        let bottom = top + 3 * rowHeight
        let bar: [(String, String, CGFloat)] = [("shift", shifted ? "ABC" : "abc", 0.12), ("symbols", symbols ? "abc" : "#+=", 0.12), ("space", "space", 0.30),
                                                ("backspace", "⌫", 0.12), ("clear", "clear", 0.11), ("mic", "🎤", 0.09), ("go", "go", 0.12)]
        var x: CGFloat = 0.01
        for (id, label, width) in bar {
            buttons.append(.init(id: id, rect: CGRect(x: x, y: bottom, width: width, height: rowHeight), label: label, wide: true))
            x += width
        }
        panel.set(buttons: buttons, version: "kb\(shifted)\(symbols)")
    }

    /// What a press of a button means for the browser: text, a key, or a toggle handled here.
    enum Press { case text(String), key(String), mic, none }

    func press(_ id: String) -> Press {
        switch id {
        case "shift": shifted.toggle(); layout(); return .none
        case "symbols": symbols.toggle(); layout(); return .none
        case "space": return .text(" ")
        case "backspace": return .key("Backspace")
        case "clear": return .key("Clear")
        case "go": return .key("Enter")
        case "mic": return .mic
        default:
            if id.hasPrefix("k:") {
                let text = String(id.dropFirst(2))
                if shifted { shifted = false; layout() }
                return .text(text)
            }
            return .none
        }
    }

    func render() {
        panel.render(ButtonsView(size: CGSize(width: 1600, height: 620), buttons: panel.buttons, hovered: panel.hovered, title: nil, titleHighlight: false))
    }
}

/// The address bar and tab strip above the window: the page's address (or what is being typed),
/// the tabs as chips, and the buttons; a login prompt takes the strip's bottom row when there is one.
@MainActor
final class ChromePanel {
    let panel: ScenePanel

    init(device: MTLDevice) {
        panel = ScenePanel(device: device, pixelWidth: 1600, pixelHeight: 300)
        panel.pane.widthMeters = 1.25
    }

    func update(browser: Browser) {
        var buttons: [ScenePanel.Button] = []
        let row1: CGFloat = 0.30, row2: CGFloat = 0.64, h: CGFloat = 0.33
        // Tabs along the first row, then the actions.
        var x: CGFloat = 0.01
        for (i, tab) in browser.tabs.enumerated() {
            let label = (i == browser.currentIndex ? "● " : "") + (tab.isPrivate ? "🕶 " : "") + String(WebBridge.shorten(tab.url?.absoluteString ?? "Start").prefix(10))
            buttons.append(.init(id: "tab:\(i)", rect: CGRect(x: x, y: row1, width: 0.14, height: h), label: label, wide: true))
            x += 0.145
        }
        buttons.append(.init(id: "new", rect: CGRect(x: x, y: row1, width: 0.06, height: h), label: "+"))
        buttons.append(.init(id: "private", rect: CGRect(x: x + 0.065, y: row1, width: 0.06, height: h), label: "🕶"))
        let actions: [(String, String)]
        if let prompt = browser.prompt {
            let text: String
            switch prompt {
            case .save(let c): text = "Save the password for \(c.host)\(c.username.isEmpty ? "" : " (\(c.username))")?"
            case .fill(let host, let cs): text = "Fill the saved login for \(host)\(cs.first.map { $0.username.isEmpty ? "" : " (\($0.username))" } ?? "")?"
            }
            buttons.append(.init(id: "prompt", rect: CGRect(x: 0.01, y: row2, width: 0.74, height: h), label: text, wide: true))
            actions = [("yes", "Yes"), ("no", "No")]
        } else {
            actions = [("back", "‹"), ("forward", "›"), ("reload", "↻"), ("home", "⌂"), ("star", browser.isBookmarked() ? "★" : "☆"),
                       ("size", "⤢"), ("place", browser.placing ? "📍" : "📌"), ("keys", "⌨"), ("mic", "🎤"), ("close", "✕")]
        }
        var ax: CGFloat = browser.prompt == nil ? 0.01 : 0.76
        for (id, label) in actions {
            buttons.append(.init(id: id, rect: CGRect(x: ax, y: row2, width: browser.prompt == nil ? 0.098 : 0.115, height: h), label: label))
            ax += browser.prompt == nil ? 0.099 : 0.12
        }
        let address = browser.typed.isEmpty ? WebBridge.shorten(browser.current?.url?.absoluteString ?? "") : browser.typed + "▏"
        panel.set(buttons: buttons, version: "chrome|\(address)|\(browser.tabs.count)|\(browser.currentIndex)|\(browser.prompt.map { "\($0)" } ?? "")|\(browser.placing)|\(browser.isBookmarked())")
        lastAddress = address
    }

    private var lastAddress = ""

    func render(typing: Bool) {
        panel.render(ButtonsView(size: CGSize(width: 1600, height: 300), buttons: panel.buttons, hovered: panel.hovered, title: lastAddress, titleHighlight: typing))
    }
}
