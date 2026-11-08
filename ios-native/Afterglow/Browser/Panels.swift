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
        var icon: String? = nil      // an SF Symbol name, or an emoji
        var style: Style = .key
        var value: String? = nil     // a row's value, on the right
        var accent: Bool = false     // stands out: the current choice, the primary action
        var light: Int = 0           // a window's traffic light: 1 red (close), 2 yellow (minimize), 3 green (size)
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

/// The look shared by every panel: Afterglow glass. Dark, slightly violet glass with a soft
/// top highlight and a hairline rim, large rounded corners, bright rounded type, one accent for
/// what the gaze is on. Type is sized for a phone behind cardboard lenses: nothing a panel shows
/// is under about 1.5 degrees tall at its usual distance (the first phone round, 2026-11-07,
/// found the earlier sizes unreadable), so each panel shows few things, large.
enum PanelStyle {
    static let background = Color(red: 0.08, green: 0.05, blue: 0.16).opacity(0.78)
    static let glassTop = Color(red: 0.16, green: 0.12, blue: 0.30).opacity(0.80)
    static let glassBottom = Color(red: 0.05, green: 0.03, blue: 0.12).opacity(0.88)
    static let rim = Color.white.opacity(0.22)
    static let key = Color.white.opacity(0.10)
    static let keyHover = Color(red: 1.0, green: 0.25, blue: 0.75).opacity(0.85)
    static let text = Color.white
    static let dim = Color.white.opacity(0.62)
    static let accent = Color(red: 0.2, green: 0.9, blue: 1.0)
    static let pink = Color(red: 1.0, green: 0.3, blue: 0.75)
    static let font: Font.Design = .rounded

    /// The panel's own backdrop.
    static func glass(radius: CGFloat = 56) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(LinearGradient(colors: [glassTop, glassBottom], startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.35), Color.white.opacity(0.08)], startPoint: .top, endPoint: .bottom), lineWidth: 3))
    }

    /// A control's fill and ring: raised glass, lit pink when hovered.
    static func control(hovered: Bool, radius: CGFloat, accent: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(hovered ? keyHover : (accent ? Color.white.opacity(0.22) : key))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(hovered ? Color.white.opacity(0.7) : Color.white.opacity(0.16), lineWidth: hovered ? 4 : 2))
            .shadow(color: hovered ? pink.opacity(0.6) : .clear, radius: 24)
    }
}

extension ScenePanel.Button {
    /// How a button draws: a key (text filling it), a tile (an icon over a name), a pill (a wide
    /// label), a round icon, a settings row (name left, value right), or a plain label with no
    /// fill. The icon is an SF Symbol name, or an emoji when it is not one.
    enum Style { case key, tile, pill, round, row, label }
}

/// Draws buttons at their rectangles over the glass; the same rectangles the gaze is tested
/// against, so what is seen is what is pressed. Type sizes follow the button's height, with a
/// floor, so every panel reads at its distance.
struct ButtonsView: View {
    let size: CGSize
    let buttons: [ScenePanel.Button]
    let hovered: String?
    let title: String?
    let titleHighlight: Bool
    var subtitle: String? = nil
    var transparent = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if !transparent { PanelStyle.glass() }
            if let title {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 84, weight: .semibold, design: PanelStyle.font))
                        .foregroundStyle(titleHighlight ? PanelStyle.accent : PanelStyle.text)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle).font(.system(size: 54, weight: .regular, design: PanelStyle.font)).foregroundStyle(PanelStyle.dim).lineLimit(1)
                    }
                }
                .padding(.horizontal, 48)
                .padding(.top, 24)
            }
            ForEach(buttons, id: \.id) { button in
                let r = CGRect(x: button.rect.minX * size.width, y: button.rect.minY * size.height,
                               width: button.rect.width * size.width, height: button.rect.height * size.height).insetBy(dx: 6, dy: 6)
                ButtonBody(button: button, rect: r, hovered: hovered == button.id)
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
            }
        }
    }
}

/// One control, by its style.
struct ButtonBody: View {
    let button: ScenePanel.Button
    let rect: CGRect
    let hovered: Bool

    private var isSymbol: Bool {
        guard let icon = button.icon, let first = icon.unicodeScalars.first else { return false }
        return first.isASCII
    }

    @ViewBuilder private func icon(size: CGFloat) -> some View {
        if let icon = button.icon {
            if isSymbol {
                Image(systemName: icon).font(.system(size: size, weight: .medium)).foregroundStyle(PanelStyle.text)
            } else {
                Text(icon).font(.system(size: size * 1.05))
            }
        }
    }

    var body: some View {
        let h = rect.height
        switch button.style {
        case .key:
            PanelStyle.control(hovered: hovered, radius: min(28, h * 0.22))
                .overlay(Text(button.label)
                    .font(.system(size: max(60, min(h * 0.55, 96)), weight: .medium, design: PanelStyle.font))
                    .foregroundStyle(PanelStyle.text).minimumScaleFactor(0.5).lineLimit(1).padding(6))
        case .tile:
            PanelStyle.control(hovered: hovered, radius: min(44, h * 0.16), accent: button.accent)
                .overlay(VStack(spacing: h * 0.06) {
                    icon(size: h * 0.36)
                    Text(button.label)
                        .font(.system(size: max(56, min(h * 0.17, 72)), weight: .medium, design: PanelStyle.font))
                        .foregroundStyle(PanelStyle.text).minimumScaleFactor(0.6).lineLimit(1)
                }.padding(10))
        case .pill:
            PanelStyle.control(hovered: hovered, radius: h / 2, accent: button.accent)
                .overlay(HStack(spacing: 18) {
                    icon(size: h * 0.42)
                    Text(button.label)
                        .font(.system(size: max(60, min(h * 0.46, 84)), weight: .medium, design: PanelStyle.font))
                        .foregroundStyle(PanelStyle.text).minimumScaleFactor(0.5).lineLimit(1)
                }.padding(.horizontal, 24))
        case .round where button.light > 0:
            let d = min(rect.width, h)
            let color: Color = button.light == 1 ? Color(red: 1, green: 0.37, blue: 0.34) : button.light == 2 ? Color(red: 1, green: 0.75, blue: 0.18) : Color(red: 0.3, green: 0.8, blue: 0.35)
            Circle().fill(color)
                .overlay(Circle().strokeBorder(Color.white.opacity(hovered ? 0.9 : 0.25), lineWidth: hovered ? 5 : 2))
                .overlay(icon(size: d * 0.42).opacity(hovered ? 1 : 0.55))
                .shadow(color: hovered ? color.opacity(0.8) : .clear, radius: 20)
                .frame(width: d, height: d)
        case .round:
            PanelStyle.control(hovered: hovered, radius: min(rect.width, h) / 2, accent: button.accent)
                .frame(width: min(rect.width, h), height: min(rect.width, h))
                .overlay(Group {
                    if button.icon != nil { icon(size: min(rect.width, h) * 0.42) }
                    else { Text(button.label).font(.system(size: max(60, min(h * 0.48, 90)), weight: .medium, design: PanelStyle.font)).foregroundStyle(PanelStyle.text).minimumScaleFactor(0.5).lineLimit(1) }
                })
        case .row:
            PanelStyle.control(hovered: hovered, radius: min(30, h * 0.3))
                .overlay(HStack {
                    icon(size: h * 0.42)
                    Text(button.label).font(.system(size: max(60, min(h * 0.46, 78)), weight: .medium, design: PanelStyle.font)).foregroundStyle(PanelStyle.text).lineLimit(1)
                    Spacer(minLength: 12)
                    if let value = button.value {
                        Text(value).font(.system(size: max(60, min(h * 0.46, 78)), weight: .regular, design: PanelStyle.font)).foregroundStyle(button.accent ? PanelStyle.accent : PanelStyle.dim).lineLimit(1)
                    }
                }.padding(.horizontal, 32))
        case .label:
            Text(button.label)
                .font(.system(size: max(60, min(h * 0.55, 84)), weight: .regular, design: PanelStyle.font))
                .foregroundStyle(button.accent ? PanelStyle.accent : PanelStyle.text).minimumScaleFactor(0.5).lineLimit(2)
                .frame(width: rect.width, height: rect.height, alignment: .leading)
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
        panel.pane.widthMeters = 1.8
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
        let bar: [(String, String, String?, CGFloat)] = [("shift", shifted ? "ABC" : "abc", "shift", 0.12), ("symbols", symbols ? "abc" : "#+=", nil, 0.12), ("space", "space", nil, 0.30),
                                                         ("backspace", "", "delete.left", 0.12), ("clear", "clear", nil, 0.11), ("mic", "", "mic.fill", 0.09), ("go", "Go", nil, 0.12)]
        var x: CGFloat = 0.01
        for (id, label, icon, width) in bar {
            buttons.append(.init(id: id, rect: CGRect(x: x, y: bottom, width: width, height: rowHeight), label: label, wide: true, icon: icon, style: icon != nil && label.isEmpty ? .round : .key, accent: id == "go"))
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
        let row1: CGFloat = 0.06, row2: CGFloat = 0.53, h: CGFloat = 0.42
        let address = browser.typed.isEmpty ? WebBridge.shorten(browser.current?.url?.absoluteString ?? "") : browser.typed + "▏"
        // The first row: back, forward, reload, the address, the keyboard, the mic, a star, close.
        var x: CGFloat = 0.01
        func round(_ id: String, _ icon: String, _ label: String, accent: Bool = false) {
            buttons.append(.init(id: id, rect: CGRect(x: x, y: row1, width: 0.075, height: h), label: label, icon: icon, style: .round, accent: accent))
            x += 0.08
        }
        round("back", "chevron.left", "Back")
        round("forward", "chevron.right", "Forward")
        round("reload", "arrow.clockwise", "Reload")
        // Text size on the bar itself, where it is needed (owner, 2026-11-08: pages too small).
        round("text:-", "textformat.size.smaller", "Smaller text")
        round("text:+", "textformat.size.larger", "Larger text")
        let progress = browser.current?.progress ?? 1
        let loading = progress < 1 && browser.typed.isEmpty
        buttons.append(.init(id: "address", rect: CGRect(x: x, y: row1, width: 0.18, height: h), label: loading ? "Loading \(Int(progress * 100))%  ·  " + (address.isEmpty ? "" : address) : (address.isEmpty ? "Search or address" : address), wide: true,
                             icon: loading ? "arrow.triangle.2.circlepath" : (browser.current?.isPrivate == true ? "eyeglasses" : "globe"), style: .pill, accent: !browser.typed.isEmpty || loading))
        x += 0.19
        round("keys", "keyboard", "Keyboard")
        round("mic", "mic.fill", "Dictate")
        let handAccess = browser.handAccessHere
        round("handsite", handAccess == .always ? "hand.raised.fill" : (handAccess == .never ? "hand.raised.slash" : "hand.raised"),
              handAccess == .always ? "This site always gets your hands" : (handAccess == .never ? "This site never gets your hands" : "This site asks for your hands"), accent: handAccess == .always)
        round("star", browser.isBookmarked() ? "star.fill" : "star", "Bookmark", accent: browser.isBookmarked())
        round("home", "house.fill", "Start")
        // The second row: the tabs as pills, a new tab, a private tab; or a prompt.
        if case .hands(let host, _)? = browser.prompt {
            buttons.append(.init(id: "prompt", rect: CGRect(x: 0.01, y: row2, width: 0.46, height: h), label: "Hands for \(WebBridge.shorten(host))?", wide: true, icon: "hand.raised.fill", style: .pill))
            buttons.append(.init(id: "no", rect: CGRect(x: 0.48, y: row2, width: 0.15, height: h), label: "Not now", wide: true, style: .pill))
            buttons.append(.init(id: "yes", rect: CGRect(x: 0.64, y: row2, width: 0.2, height: h), label: "Just this time", wide: true, style: .pill))
            buttons.append(.init(id: "handsAlways", rect: CGRect(x: 0.85, y: row2, width: 0.14, height: h), label: "Always", wide: true, style: .pill, accent: true))
        } else if let prompt = browser.prompt {
            let text: String
            switch prompt {
            case .save(let c): text = "Save the password for \(c.host)\(c.username.isEmpty ? "" : " (\(c.username))")?"
            case .fill(let host, let cs): text = "Fill the login for \(host)\(cs.first.map { $0.username.isEmpty ? "" : " (\($0.username))" } ?? "")?"
            case .hands: text = ""
            }
            buttons.append(.init(id: "prompt", rect: CGRect(x: 0.01, y: row2, width: 0.66, height: h), label: text, wide: true, icon: "key.fill", style: .pill))
            buttons.append(.init(id: "yes", rect: CGRect(x: 0.68, y: row2, width: 0.15, height: h), label: "Yes", wide: true, style: .pill, accent: true))
            buttons.append(.init(id: "no", rect: CGRect(x: 0.84, y: row2, width: 0.15, height: h), label: "No", wide: true, style: .pill))
        } else {
            var tx: CGFloat = 0.01
            for (i, tab) in browser.tabs.prefix(4).enumerated() {
                let label = String(WebBridge.shorten(tab.url?.absoluteString ?? "Start").prefix(12))
                buttons.append(.init(id: "tab:\(i)", rect: CGRect(x: tx, y: row2, width: 0.19, height: h), label: label, wide: true,
                                     icon: tab.isPrivate ? "eyeglasses" : nil, style: .pill, accent: i == browser.currentIndex))
                tx += 0.195
            }
            buttons.append(.init(id: "new", rect: CGRect(x: 0.80, y: row2, width: 0.095, height: h), label: "New tab", icon: "plus", style: .round))
            buttons.append(.init(id: "private", rect: CGRect(x: 0.90, y: row2, width: 0.095, height: h), label: "Private tab", icon: "eyeglasses", style: .round))
            if browser.tabs.count > 1 {
                buttons.append(.init(id: "close", rect: CGRect(x: 0.80 - 0.1, y: row2, width: 0.095, height: h), label: "Close tab", icon: "xmark", style: .round))
            }
        }
        panel.set(buttons: buttons, version: "chrome|\(address)|\(browser.tabs.count)|\(browser.currentIndex)|\(browser.prompt.map { "\($0)" } ?? "")|\(browser.handAccessHere.rawValue)|\(browser.placing)|\(browser.isBookmarked())|\(Int(progress * 20))")
        lastAddress = address
    }

    private var lastAddress = ""

    func render(typing: Bool) {
        panel.render(ButtonsView(size: CGSize(width: 1600, height: 300), buttons: panel.buttons, hovered: panel.hovered, title: nil, titleHighlight: typing))
    }
}
