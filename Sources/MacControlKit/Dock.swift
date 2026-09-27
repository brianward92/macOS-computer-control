import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Finding things in the Dock.
///
/// The Dock is not inside any application's window, and its icons carry no
/// on-screen text, so neither window geometry nor OCR can locate them. The
/// accessibility tree is the only way to ask "where is the icon for this app",
/// and it is a small, stable tree — unlike the empty one a canvas-rendered app
/// exposes.
///
/// Every screen measurement here is against the main display, the one with
/// the menu bar, in the same top-left-origin points as the rest of the
/// library. `NSScreen` is deliberately not used: its frames have a bottom-left
/// origin and `NSScreen.main` is whichever screen has keyboard focus, and
/// mixing either of those in is a coordinate bug waiting for a second monitor.
public enum Dock {

    public enum DockError: Error, CustomStringConvertible {
        case accessibilityDenied
        case dockNotRunning
        case itemNotFound(String)
        case menuItemNotFound(item: String, app: String, detail: String)

        public var description: String {
            switch self {
            case .accessibilityDenied:
                return "Accessibility permission is required to read the Dock"
            case .dockNotRunning:
                return "the Dock is not running"
            case .itemNotFound(let n):
                return "no Dock item named \(n)"
            case .menuItemNotFound(let item, let app, let detail):
                return "\(item) was not found in the Dock menu for \(app) \(detail)"
            }
        }
    }

    public struct Item: Sendable {
        public let title: String
        /// Screen points, top-left origin — the same space as everything else.
        public let frame: CGRect
        public var center: CGPoint {
            CGPoint(x: frame.midX.rounded(), y: frame.midY.rounded())
        }
    }

    private static var screen: CGRect { CGDisplayBounds(CGMainDisplayID()) }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    /// Every item in the Dock, with where it is on screen.
    public static func items() throws -> [Item] {
        guard AXIsProcessTrusted() else { throw DockError.accessibilityDenied }
        guard let dock = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == "com.apple.dock" })
        else { throw DockError.dockNotRunning }

        let app = AXUIElementCreateApplication(dock.processIdentifier)
        guard let children = attribute(app, kAXChildrenAttribute as String) as? [AXUIElement] else {
            return []
        }
        // The Dock's tree is app -> AXList -> the icons.
        let lists = children.filter {
            (attribute($0, kAXRoleAttribute as String) as? String) == kAXListRole as String
        }
        var found: [Item] = []
        for list in lists {
            guard let icons = attribute(list, kAXChildrenAttribute as String) as? [AXUIElement] else { continue }
            for icon in icons {
                guard let title = attribute(icon, kAXTitleAttribute as String) as? String else { continue }
                var origin = CGPoint.zero
                var size = CGSize.zero
                if let p = attribute(icon, kAXPositionAttribute as String) {
                    AXValueGetValue(p as! AXValue, .cgPoint, &origin)
                }
                if let s = attribute(icon, kAXSizeAttribute as String) {
                    AXValueGetValue(s as! AXValue, .cgSize, &size)
                }
                guard size.width > 0, size.height > 0 else { continue }
                found.append(Item(title: title, frame: CGRect(origin: origin, size: size)))
            }
        }
        return found
    }

    /// Is the Dock actually on screen right now?
    ///
    /// Asked by looking at where its icons are, not by asking whether auto-hide
    /// is configured. A hidden Dock still reports icon positions — below the
    /// bottom of the screen.
    public static var isOnScreen: Bool {
        guard let first = (try? items())?.first else { return false }
        return first.frame.maxY <= screen.maxY + 1
    }

    /// Slide an auto-hidden Dock into view, and wait until it is really there.
    ///
    /// A single warp to the bottom edge does **not** reveal the Dock. The
    /// reveal is driven by sustained pointer presence at the edge, so the
    /// pointer has to keep producing motion there — one synthetic jump looks
    /// like nothing happened. Starting from the middle of the screen this
    /// failed every single time, while starting with the pointer already near
    /// the Dock succeeded; that alternation is what gave it away.
    ///
    /// Waits on the observable effect — icons actually being on screen — rather
    /// than on a fixed sleep.
    @discardableResult
    public static func reveal(timeout: TimeInterval = 4) -> Bool {
        if isOnScreen { waitForStableLayout(); return true }

        let edgeY = screen.maxY - 1
        let deadline = Date().addingTimeInterval(timeout)
        var nudge = 0
        while Date() < deadline {
            // Keep the pointer moving along the very bottom row. Motion is what
            // the reveal watches for; position alone is not enough.
            let x = screen.midX + CGFloat((nudge % 2 == 0) ? 0 : 2)
            Input.move(to: CGPoint(x: x, y: edgeY), steps: 1)
            nudge += 1
            usleep(90_000)
            if isOnScreen {
                waitForStableLayout()
                return true
            }
        }
        return false
    }

    /// Wait until two consecutive reads of the Dock agree.
    ///
    /// The Dock slides up over a couple of hundred milliseconds, and positions
    /// read during that slide are real but instantly stale. Worse, the
    /// convergence in `item` will happily chase them and settle on a fixed
    /// point that is not the icon at all: on one run it landed on the Trash,
    /// 250 points from the target, and reported success.
    static func waitForStableLayout(tries: Int = 25, needed: Int = 3) {
        var previous: [String: CGPoint] = [:]
        var agreements = 0
        for _ in 0..<tries {
            let snapshot = Dictionary(
                (try? items())?.map { ($0.title, $0.center) } ?? [],
                uniquingKeysWith: { a, _ in a }
            )
            if !snapshot.isEmpty, snapshot == previous {
                agreements += 1
                if agreements >= needed { return }
            } else {
                agreements = 0
            }
            previous = snapshot
            usleep(120_000)
        }
    }

    /// Where the Dock icon for an app is, once the pointer is on it.
    ///
    /// Two things move the answer, and both are the same failure as reading a
    /// stale window rect: you read a coordinate, act on it, and the world has
    /// moved underneath you.
    ///
    /// - **Auto-hide.** A position read while the Dock is hidden points off the
    ///   bottom of the screen. Revealing is a hover gesture, so the pointer has
    ///   to go to the edge and stay there.
    /// - **Magnification.** Icons near the pointer grow and push their
    ///   neighbours aside, so an icon's position depends on where the pointer
    ///   is — including where the pointer is *because you just moved it toward
    ///   that icon*. Reading once and moving there lands somewhere else
    ///   entirely: on this machine it opened the Trash menu instead of the
    ///   app's, because the read said x=1115 and the icon was really at x=990.
    ///
    /// So the pointer is moved onto the icon and the position re-read until it
    /// stops moving. It converges in two or three passes, or it refuses.
    public static func item(named name: String) throws -> Item {
        guard reveal() else { throw DockError.itemNotFound("the Dock did not come out of hiding") }

        // Walk to the icon by IDENTITY, not by position.
        //
        // Chasing the position does not work and fails in a way that looks like
        // success: magnification grows whatever is under the pointer and pushes
        // its neighbours aside, so moving toward an icon moves the icon. A loop
        // that reads a position, moves there, and re-reads will walk sideways
        // across the whole Dock and settle on a completely different icon —
        // this one ended up on the Trash at x=1239 while the target sat at 992,
        // reported a stable position, and right-clicked the wrong app.
        //
        // So the question asked each step is "what is under the pointer now?",
        // and the answer is a name. That is stable under magnification, because
        // magnification cannot change which icon you are pointing at.
        //
        // The step budget is generous on purpose. Magnification pushes the
        // target away as the pointer approaches, so the walk can take twice as
        // many steps as the plain distance suggests; measured here, a target
        // 480 points away took five steps one run and did not settle in
        // twelve on another.
        for _ in 0..<30 {
            let all = try items()
            guard let target = match(name, in: all) else { throw DockError.itemNotFound(name) }
            let cursor = Input.cursorPosition

            if target.frame.insetBy(dx: -2, dy: -2).contains(cursor) {
                return target
            }

            // Step a bounded distance toward it rather than jumping, so the
            // layout shifts a little at a time and stays readable.
            let dx = target.center.x - cursor.x
            let step = max(-90, min(90, dx))
            Input.move(to: CGPoint(x: cursor.x + step, y: target.center.y), steps: 3)
            usleep(140_000)
        }
        throw DockError.itemNotFound("\(name): could not settle the pointer on its Dock icon")
    }

    private static func match(_ name: String, in all: [Item]) -> Item? {
        all.first { $0.title.caseInsensitiveCompare(name) == .orderedSame }
            ?? all.first { $0.title.range(of: name, options: .caseInsensitive) != nil }
    }

    /// Right-click a Dock icon and choose an item from the menu that opens.
    ///
    /// Opened with a full click rather than a press-and-hold. Both gestures open
    /// the menu, but holding the button keeps the pointer in a drag and makes
    /// every subsequent step harder for no benefit — and an early version that
    /// held the button hung for five minutes with it still down, which freezes
    /// the desktop for whoever is sitting there.
    ///
    /// The menu is read with `screencapture`, never ScreenCaptureKit: with a
    /// menu open, SCK never returns. Accessibility is no help either — the menu
    /// is not exposed under the application element or the dock item, and
    /// `AXShowMenu` reports success while yielding nothing readable. So the menu
    /// is found the way a person finds it, by looking at the screen.
    @discardableResult
    public static func chooseFromMenu(
        app name: String,
        item menuItem: String,
        menuSettleMs: UInt32 = 1200
    ) async throws -> CGPoint {
        let bounds = screen

        // The whole gesture is retried, not just the look at the screen.
        // Opening a Dock menu is itself unreliable — the reveal animation, the
        // magnification shuffle and the click all have to line up, and roughly
        // one attempt in three does not produce a menu at all. Retrying only the
        // capture cannot fix a menu that never opened.
        var lastIcon: Item?
        for attempt in 0..<3 {
            let icon = try item(named: name)
            lastIcon = icon
            // Approach with a real hover. Posting a click at coordinates the
            // pointer is not actually on does not register as a click on that
            // icon — the Dock targets what is hovered, not what the event says.
            Input.click(at: icon.center, button: .right, approach: .warp)
            try? await Task.sleep(nanoseconds: UInt64(menuSettleMs) * 1_000_000)

            // A Dock menu sits directly above its icon, so the only acceptable
            // hit is one in that column, and the nearest one vertically is the
            // bottom entry. Matching on text alone picks the same word up
            // anywhere on screen — a terminal displaying this very command, for
            // one, which is exactly what happened and got clicked.
            //
            // There is deliberately NO fallback to "the first match anywhere".
            // A wrong click is worse than a refusal, and wrong clicks do not
            // announce themselves.
            for look in 0..<2 {
                if let shot = try? await Capture.viaCLI(windowID: nil, rect: bounds, deadline: 5),
                   let target = ((try? Text.find(menuItem, in: shot)) ?? [])
                       .filter({ abs($0.center.x - icon.center.x) < 220 && $0.center.y < icon.center.y })
                       .min(by: { abs($0.center.y - icon.center.y) < abs($1.center.y - icon.center.y) })?
                       .center
                {
                    Input.click(at: target, button: .left)
                    return target
                }
                if look == 0 { try? await Task.sleep(nanoseconds: 400_000_000) }
            }

            // No menu, or not this item. Dismiss and start the gesture again.
            try? Keyboard.press("escape")
            try? await Task.sleep(nanoseconds: 600_000_000)
            if attempt < 2 {
                // Start the next attempt from the reveal edge, and wait for the
                // layout again: an app that is not pinned to the Dock has its
                // icon added and removed on every launch and quit, so the whole
                // strip is still shifting when the previous attempt ran.
                Input.move(to: CGPoint(x: bounds.midX, y: bounds.maxY - 1), steps: 6)
                try? await Task.sleep(nanoseconds: 400_000_000)
                waitForStableLayout()
            }
        }

        throw DockError.menuItemNotFound(
            item: menuItem, app: name,
            detail: "after 3 attempts" + (lastIcon.map { " (icon at \($0.center))" } ?? ""))
    }
}
