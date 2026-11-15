import AppKit
import CoreGraphics

/// Posts synthetic mouse, scroll and keyboard events. Requires Accessibility permission.
final class EventSynthesizer {
    private let source = CGEventSource(stateID: .hidSystemState)
    private(set) var isLeftButtonDown = false

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system "allow Accessibility" prompt (once per app identity).
    static func requestTrust() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Current pointer position in global CG coordinates (top-left origin).
    func currentLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    func move(to point: CGPoint) {
        let type: CGEventType = isLeftButtonDown ? .leftMouseDragged : .mouseMoved
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    func click(_ button: CGMouseButton, at point: CGPoint, count: Int = 1) {
        let (downType, upType) = Self.types(for: button)
        for n in 1...max(1, count) {
            for type in [downType, upType] {
                guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { continue }
                e.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                e.post(tap: .cghidEventTap)
            }
        }
    }

    func leftDown(at point: CGPoint) {
        guard !isLeftButtonDown else { return }
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        isLeftButtonDown = true
    }

    func leftUp(at point: CGPoint) {
        guard isLeftButtonDown else { return }
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        isLeftButtonDown = false
    }

    /// Pixel-precise scroll. Positive `vertical` scrolls up, positive `horizontal` scrolls left.
    func scroll(vertical: Int32, horizontal: Int32) {
        CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0)?
            .post(tap: .cghidEventTap)
    }

    // MARK: Pinch (trackpad magnify) gesture

    enum PinchPhase: Int64 { case began = 1, changed = 2, ended = 4 }

    /// Posts one step of a two-finger pinch, as a trackpad would. EXPERIMENTAL: macOS has
    /// no public API for this; it uses the undocumented CGEvent gesture fields the
    /// WindowServer uses (event type 29, gesture kind 110 = 8 zoom, phase 132, amount 113),
    /// so a future macOS could stop delivering it. Apps receive a normal magnify event.
    /// Always end a pinch you began (`.ended`) so no app is left mid-gesture.
    func pinch(_ phase: PinchPhase, magnification: Double = 0, at point: CGPoint) {
        guard let e = CGEvent(source: source),
              let gestureType = CGEventType(rawValue: 29),
              let kindField = CGEventField(rawValue: 110),
              let phaseField = CGEventField(rawValue: 132),
              let amountField = CGEventField(rawValue: 113) else { return }
        e.type = gestureType
        e.setIntegerValueField(kindField, value: 8)   // zoom
        e.setIntegerValueField(phaseField, value: phase.rawValue)
        if magnification != 0 { e.setDoubleValueField(amountField, value: magnification) }
        e.location = point
        e.post(tap: .cghidEventTap)
    }

    /// Taps Control twice, the macOS Dictation shortcut "Press Control Key Twice".
    /// Toggles Dictation: it listens through the current mic (the AirPods) and types
    /// into the focused text field. AirCursor itself never touches the audio.
    func doubleTapControl() {
        let tap = { [source] in
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0x3B, keyDown: down) else { continue }
                e.type = .flagsChanged
                e.flags = down ? .maskControl : []
                e.post(tap: .cghidEventTap)
            }
        }
        tap()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: tap)
    }

    func keyStroke(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
    }

    private static func types(for button: CGMouseButton) -> (CGEventType, CGEventType) {
        switch button {
        case .left: (.leftMouseDown, .leftMouseUp)
        case .right: (.rightMouseDown, .rightMouseUp)
        default: (.otherMouseDown, .otherMouseUp)
        }
    }
}
