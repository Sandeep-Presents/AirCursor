import Foundation

/// Something the user does with their AirPods.
public enum Trigger: String, Codable, CaseIterable, Identifiable, Sendable {
    case stemSingle, stemDouble, stemTriple
    case nod, nodUp, shake, tiltLeft, tiltRight
    case swipeLeft, swipeRight
    case dwell

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .stemSingle: "Press stem once"
        case .stemDouble: "Press stem twice"
        case .stemTriple: "Press stem three times"
        case .nod: "Nod"
        case .nodUp: "Nod up (chin up and back)"
        case .shake: "Shake head"
        case .tiltLeft: "Tilt head left"
        case .tiltRight: "Tilt head right"
        case .swipeLeft: "Flick head left"
        case .swipeRight: "Flick head right"
        case .dwell: "Hover (rest the pointer)"
        }
    }

    public var isStem: Bool { self == .stemSingle || self == .stemDouble || self == .stemTriple }

    public var headGesture: HeadGesture? {
        switch self {
        case .nod: .nod
        case .nodUp: .nodUp
        case .shake: .shake
        case .tiltLeft: .tiltLeft
        case .tiltRight: .tiltRight
        case .swipeLeft: .swipeLeft
        case .swipeRight: .swipeRight
        default: nil
        }
    }

    public init(_ gesture: HeadGesture) {
        switch gesture {
        case .nod: self = .nod
        case .nodUp: self = .nodUp
        case .shake: self = .shake
        case .tiltLeft: self = .tiltLeft
        case .tiltRight: self = .tiltRight
        case .swipeLeft: self = .swipeLeft
        case .swipeRight: self = .swipeRight
        }
    }
}

/// What AirCursor does in response to a trigger.
public enum PointerAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case leftClick, rightClick, doubleClick, middleClick
    case toggleDrag
    case toggleScrollMode
    case toggleZoomMode
    case toggleTracking
    case recenter
    case missionControl, appWindows, previousSpace, nextSpace
    case back, forward
    case screenshot
    case dictate, pressReturn

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: "Do nothing"
        case .leftClick: "Left click"
        case .rightClick: "Right click"
        case .doubleClick: "Double click"
        case .middleClick: "Middle click"
        case .toggleDrag: "Start / drop drag"
        case .toggleScrollMode: "Toggle scroll mode"
        case .toggleZoomMode: "Toggle zoom mode"
        case .toggleTracking: "Pause / resume tracking"
        case .recenter: "Recenter cursor"
        case .missionControl: "Mission Control"
        case .appWindows: "App windows"
        case .previousSpace: "Previous Space"
        case .nextSpace: "Next Space"
        case .back: "Back (⌘[)"
        case .forward: "Forward (⌘])"
        case .screenshot: "Screenshot tool"
        case .dictate: "Dictate (talk to type)"
        case .pressReturn: "Press Return (send)"
        }
    }

    /// Actions that put a mouse button event on screen.
    public var isClick: Bool {
        switch self {
        case .leftClick, .rightClick, .doubleClick, .middleClick, .toggleDrag: true
        default: false
        }
    }

    /// Grouping for menus.
    public static let groups: [(title: String, actions: [PointerAction])] = [
        ("", [.none]),
        ("Mouse", [.leftClick, .rightClick, .doubleClick, .middleClick, .toggleDrag]),
        ("AirCursor", [.toggleScrollMode, .toggleZoomMode, .toggleTracking, .recenter]),
        ("System", [.missionControl, .appWindows, .previousSpace, .nextSpace, .back, .forward, .screenshot]),
        ("Voice", [.dictate, .pressReturn]),
    ]
}

/// Trigger → action bindings. Unknown or missing entries fall back to defaults.
public struct ActionMap: Codable, Equatable, Sendable {
    public static let defaults: [Trigger: PointerAction] = [
        .stemSingle: .leftClick,
        .stemDouble: .rightClick,
        // Talk through the AirPods: macOS Dictation types into the focused text box.
        .stemTriple: .dictate,
        .nod: .leftClick,
        // A quick chin-up nod enters and leaves scroll mode; a normal (downward) nod clicks.
        .nodUp: .toggleScrollMode,
        // Pausing is one calm tilt-and-hold; shaking is tiring and too close to a flick.
        .shake: .none,
        // Tilt left and hold: zoom mode (hold head up to pinch-zoom in, down to zoom out).
        .tiltLeft: .toggleZoomMode,
        .tiltRight: .toggleTracking,
        // Like a three-finger swipe: flick right to go to the Space / full-screen app on the right.
        .swipeLeft: .previousSpace,
        .swipeRight: .nextSpace,
        .dwell: .leftClick,
    ]

    private var bindings: [Trigger: PointerAction]

    public init() { bindings = Self.defaults }

    public subscript(trigger: Trigger) -> PointerAction {
        get { bindings[trigger] ?? Self.defaults[trigger] ?? .none }
        set { bindings[trigger] = newValue }
    }

    /// Head gestures that should be detected at all (bound to something).
    public var enabledHeadGestures: Set<HeadGesture> {
        Set(Trigger.allCases.compactMap { t in
            guard let g = t.headGesture, self[t] != .none else { return nil }
            return g
        })
    }

    public func triggers(for action: PointerAction) -> [Trigger] {
        Trigger.allCases.filter { self[$0] == action }
    }

    /// True if some head gesture can resume tracking while paused.
    public var headGestureCanToggleTracking: Bool {
        triggers(for: .toggleTracking).contains { $0.headGesture != nil }
    }

    /// True if a trigger switches between pointer, scroll and zoom mode or pauses, so it
    /// stays live while the head is busy scrolling or zooming.
    public static func isModeSwitch(_ action: PointerAction) -> Bool {
        action == .toggleScrollMode || action == .toggleZoomMode || action == .toggleTracking
    }

    /// True if some stem press can resume tracking while paused.
    public var stemCanToggleTracking: Bool {
        triggers(for: .toggleTracking).contains { $0.isStem }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: String].self)
        var result = Self.defaults
        for (k, v) in raw {
            if let t = Trigger(rawValue: k), let a = PointerAction(rawValue: v) { result[t] = a }
        }
        bindings = result
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value.rawValue) }))
    }
}
