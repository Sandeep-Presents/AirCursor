import AppKit
import ApplicationServices

/// Answers "is the thing under the pointer clickable?" for smart hover click.
///
/// Uses the Accessibility tree AirCursor already has permission to read: an element
/// (or one of its close ancestors) that is a button, link, tab, menu item, text field,
/// Dock icon… or that supports the "press" action. Falls back to the system
/// pointer: when it turns into the pointing hand, it's over a link.
enum ClickableProbe {
    private static let queue = DispatchQueue(label: "AirCursor.ClickableProbe", qos: .userInitiated)

    private static let clickableRoles: Set<String> = [
        "AXButton", "AXLink", "AXMenuItem", "AXMenuBarItem", "AXMenuButton",
        "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXDisclosureTriangle",
        "AXTextField", "AXTextArea", "AXComboBox", "AXDockItem", "AXSegment",
    ]

    /// Container roles where the search stops (anything above is too broad to count).
    private static let boundaryRoles: Set<String> = [
        "AXWindow", "AXApplication", "AXWebArea", "AXScrollArea", "AXSheet", "AXDrawer",
    ]

    /// Asynchronously checks the point (global CG coordinates); completes on main.
    @MainActor static func check(_ point: CGPoint, completion: @escaping @MainActor (Bool) -> Void) {
        // Do not AX-hit-test our own SwiftUI windows from the worker queue. The
        // query itself can enter SwiftUI/AppKit off-main and hang the UI before
        // accessibilityVerdict's PID check ever runs.
        if let window = ownWindow(at: point) {
            let clickable = isInteractive(window) || cursorLooksClickable()
            DispatchQueue.main.async { completion(clickable) }
            return
        }
        queue.async {
            let verdict = accessibilityVerdict(at: point)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let verdict {
                        completion(verdict)
                    } else {
                        completion(cursorLooksClickable())
                    }
                }
            }
        }
    }

    /// true/false when Accessibility knows; nil when it can't tell (or it's our own app).
    private static func accessibilityVerdict(at point: CGPoint) -> Bool? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.15)

        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              let hit, case var element = hit else { return nil }

        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        if pid == getpid() { return nil }

        for depth in 0..<4 {
            let role = string(element, kAXRoleAttribute) ?? ""
            if boundaryRoles.contains(role) { break }
            if clickableRoles.contains(role) { return true }
            // Generic "pressable" elements only count when they're near the hit point
            // and button-sized: web/Electron apps often make whole panels pressable,
            // and resting on text in those must not click.
            if depth <= 2, supportsPress(element), isCompact(element) { return true }
            guard let parent = parent(of: element) else { break }
            element = parent
        }
        return controlBeneath(hit, point: point)
    }

    /// Some apps answer a hit test with a container lying over the real control: Chrome's
    /// full-screen tab strip reports a plain group where the tab is. So look through the
    /// window that was hit (only that one, so a control in another window behind it can't
    /// count) for an actual control (tab, button, link…) under the point.
    /// Skips web pages (hit-tested fine, and resting on text must never click) and stops
    /// after a few hundred elements or a few dozen milliseconds.
    private static func controlBeneath(_ hit: AXUIElement, point: CGPoint) -> Bool {
        // The hit element's top-level ancestor (its window). Chrome's full-screen tab
        // strip hangs off it even though it isn't in the app's window list.
        var root = hit
        for _ in 0..<40 {
            guard let up = parent(of: root), string(up, kAXRoleAttribute) != "AXApplication" else { break }
            root = up
        }
        let rootRole = string(root, kAXRoleAttribute) ?? ""
        guard rootRole != "AXApplication", rootRole != "AXMenuBar" else { return false }
        var queue = [root]
        var visited = 0
        let deadline = Date().addingTimeInterval(0.15)
        while !queue.isEmpty, visited < 800, Date() < deadline {
            let element = queue.removeFirst()
            visited += 1
            let role = string(element, kAXRoleAttribute) ?? ""
            if role == "AXWebArea" { continue }
            // No pruning by frame: Chrome draws its full-screen tabs above the frame it
            // reports for their window, so a parent's frame can't rule children out.
            if clickableRoles.contains(role), let f = frame(of: element), f.contains(point) { return true }
            var kids: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &kids) == .success,
               let children = kids as? [AXUIElement] {
                queue.append(contentsOf: children)
            }
        }
        return false
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    /// Roughly button/link/card sized, not a panel or a list.
    private static func isCompact(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return false }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return false }
        return size.width <= 600 && size.height <= 240 && size.width * size.height <= 90_000
    }

    /// Debug description of the element chain at a point, e.g. "AXButton[press] < AXGroup".
    @MainActor static func describe(_ point: CGPoint) -> String {
        if let window = ownWindow(at: point) {
            return "AirCursor: own window (\(window.title)); AX query skipped"
        }
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.15)
        var hit: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit)
        guard err == .success, var element = hit else { return "no element (\(err.rawValue))" }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let app = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
        var parts: [String] = []
        for _ in 0..<5 {
            let role = string(element, kAXRoleAttribute) ?? "?"
            parts.append(role + (supportsPress(element) ? (isCompact(element) ? "[press]" : "[press,large]") : ""))
            guard let parent = parent(of: element) else { break }
            element = parent
        }
        return app + ": " + parts.joined(separator: " < ")
    }

    private static func supportsPress(_ element: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let actions = names as? [String] else { return false }
        return actions.contains("AXPress")
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// Resolve the actual mouse target, not just a rectangle: another app may
    /// cover our window. Mouse-transparent overlays are skipped by AppKit.
    @MainActor private static func ownWindow(at point: CGPoint) -> NSWindow? {
        let cocoa = ScreenGeometry.cocoaPoint(from: point)
        let number = NSWindow.windowNumber(at: cocoa, belowWindowWithWindowNumber: 0)
        return NSApp.window(withWindowNumber: number)
    }

    /// Preserve the tour/Settings fallback without querying our own AX tree.
    @MainActor private static func isInteractive(_ window: NSWindow) -> Bool {
        let titles: Set<String> = ["AirCursor", "Welcome to AirCursor"]
        return window.isVisible && titles.contains(window.title)
    }

    /// The system pointer turns into a pointing hand over links and many custom buttons
    /// (web pages, Electron apps) even when they're invisible to Accessibility.
    @MainActor private static func cursorLooksClickable() -> Bool {
        guard let current = NSCursor.currentSystem else { return false }
        let hand = NSCursor.pointingHand
        return current.hotSpot == hand.hotSpot && current.image.size == hand.image.size
    }
}
