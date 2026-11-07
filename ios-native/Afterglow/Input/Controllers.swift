import GameController
import simd

/// Bluetooth controllers paired to the phone (Joy-Cons, DualSense, DualShock, any MFi pad):
/// the A button is a select, B a back, the left stick scrolls a page or looks in desk mode, and
/// where the pad reports motion (DualSense, DualShock; Joy-Cons where iOS passes it through)
/// its rotation gives a 3DoF pointer whose origin is estimated beside the head, so a controller
/// can point at things. Logs [Pad].
final class Controllers: @unchecked Sendable {
    struct State {
        var connected = 0
        var names: [String] = []
        var stick = SIMD2<Float>.zero
        var rightStick = SIMD2<Float>.zero
        var select = false          // A pressed this frame
        var back = false            // B pressed this frame
        var menu = false
        var trigger = false         // a shoulder or trigger held
        var attitude: simd_quatf?   // the pad's rotation, when it has motion
    }

    private let lock = NSLock()
    private var state = State()
    private var pressedA = false, pressedB = false, pressedMenu = false
    private var observers: [NSObjectProtocol] = []

    func start() {
        observers.append(NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            if let pad = note.object as? GCController { self?.attach(pad) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            self.lock.lock()
            self.state.connected = max(0, self.state.connected - 1)
            self.state.names.removeAll { $0 == (note.object as? GCController)?.vendorName }
            self.state.attitude = nil
            self.lock.unlock()
            log("[Pad] Controller disconnected")
        })
        for pad in GCController.controllers() { attach(pad) }
        GCController.startWirelessControllerDiscovery {}
        log("[Pad] Listening for controllers (\(GCController.controllers().count) connected)")
    }

    private func attach(_ pad: GCController) {
        lock.lock()
        state.connected += 1
        state.names.append(pad.vendorName ?? "controller")
        lock.unlock()
        let motion = pad.motion != nil ? (pad.motion!.hasAttitude ? "attitude" : "rates only") : "no motion"
        log("[Pad] \(pad.vendorName ?? "controller") connected: \(pad.extendedGamepad != nil ? "extended" : "basic") pad, \(motion)")
        if let motion = pad.motion, motion.hasAttitude {
            motion.sensorsActive = true
            motion.valueChangedHandler = { [weak self] m in
                let q = m.attitude
                self?.lock.lock()
                self?.state.attitude = simd_quatf(ix: Float(q.x), iy: Float(q.y), iz: Float(q.z), r: Float(q.w))
                self?.lock.unlock()
            }
        }
        guard let gamepad = pad.extendedGamepad else { return }
        gamepad.valueChangedHandler = { [weak self] g, _ in
            guard let self else { return }
            self.lock.lock()
            self.state.stick = SIMD2(g.leftThumbstick.xAxis.value, g.leftThumbstick.yAxis.value)
            self.state.rightStick = SIMD2(g.rightThumbstick.xAxis.value, g.rightThumbstick.yAxis.value)
            self.state.trigger = g.rightTrigger.isPressed || g.leftTrigger.isPressed || g.rightShoulder.isPressed || g.leftShoulder.isPressed
            if g.buttonA.isPressed && !self.pressedA { self.state.select = true }
            if g.buttonB.isPressed && !self.pressedB { self.state.back = true }
            if g.buttonMenu.isPressed && !self.pressedMenu { self.state.menu = true }
            self.pressedA = g.buttonA.isPressed
            self.pressedB = g.buttonB.isPressed
            self.pressedMenu = g.buttonMenu.isPressed
            self.lock.unlock()
        }
    }

    /// The state since the last call; the one-shot presses are cleared on reading.
    func take() -> State {
        lock.lock()
        defer { lock.unlock() }
        let s = state
        state.select = false
        state.back = false
        state.menu = false
        return s
    }
}
