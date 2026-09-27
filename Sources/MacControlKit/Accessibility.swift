import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Driving standard controls through the accessibility tree, for the times a
/// posted mouse click is not enough.
///
/// The rest of this library reads pixels and posts events, because the app
/// being driven may expose no accessibility tree at all — a game or a web
/// canvas renders its interface as pixels and nothing else. That approach has
/// a hard limit, learned driving System Settings: a **modal sheet runs its own
/// event-tracking loop and silently swallows synthetic mouse events.** The
/// Night Shift schedule popup and the sheet's Done button both ignored a click,
/// a press-and-hold, everything posted at their coordinates — and none of it
/// errored, because a click that lands on nothing reports success.
///
/// The same controls answer the accessibility API instantly. `AXPress` on the
/// button by name opens the sheet; `AXPress` on the popup opens it; `AXPick` on
/// a menu item selects it. So this is the counterpart to the pixel path, for
/// the large class of ordinary AppKit and SwiftUI apps that do expose a tree:
/// name the control, act on the element, and read the result back rather than
/// guessing a coordinate and hoping the event was not eaten.
///
/// It is not a replacement. An app with no tree gets nothing here, which is
/// exactly why the pixel path exists and is the default.
public enum Accessibility {

    public enum AXError: Error, CustomStringConvertible, Equatable {
        case notTrusted
        case appNotFound(String)
        case noWindow(String)
        case noControl(app: String, needle: String)
        case ambiguous(needle: String, matches: [String])
        case notActionable(String)
        case actionFailed(String)
        case notAPopup(String)
        case valueNotInMenu(value: String, choices: [String])

        public var description: String {
            switch self {
            case .notTrusted:
                return "Accessibility permission is required to read or drive controls"
            case .appNotFound(let a):
                return "no running application matches \(a)"
            case .noWindow(let a):
                return "\(a) has no accessible window"
            case .noControl(let app, let needle):
                return "no control in \(app) matches \"\(needle)\""
            case .ambiguous(let needle, let matches):
                let shown = matches.prefix(8).joined(separator: ", ")
                let more = matches.count > 8 ? ", and \(matches.count - 8) more" : ""
                return "\"\(needle)\" matches more than one control (\(shown)\(more)); name it more precisely"
            case .notActionable(let name):
                return "the control \"\(name)\" cannot be pressed"
            case .actionFailed(let name):
                return "the accessibility action on \"\(name)\" was refused by the app"
            case .notAPopup(let name):
                return "the control \"\(name)\" is not a popup menu"
            case .valueNotInMenu(let value, let choices):
                return "no menu item matches \"\(value)\"; choices are \(choices.joined(separator: ", "))"
            }
        }
    }

    /// One control in the tree, reduced to what a caller needs to find and act
    /// on it.
    public struct Control: Sendable, Equatable {
        /// AXButton, AXPopUpButton, AXCheckBox, AXSlider, AXTextField, …
        public let role: String
        /// The label: title, or failing that the description.
        public let label: String
        /// The current value, when the control has one: the text in a field,
        /// the selection of a popup, "1"/"0" for a checkbox.
        public let value: String?
        /// Screen points, top-left origin — a click point, if it comes to that.
        public let center: CGPoint
        public let enabled: Bool
        /// Whether the control exposes the press action at all.
        public let pressable: Bool

        public init(role: String, label: String, value: String?, center: CGPoint,
                    enabled: Bool, pressable: Bool) {
            self.role = role
            self.label = label
            self.value = value
            self.center = center
            self.enabled = enabled
            self.pressable = pressable
        }

        /// Everything a caller might match against: label and value.
        var haystacks: [String] { [label, value].compactMap { $0 }.filter { !$0.isEmpty } }

        /// How the control reads in an error or an ambiguity list.
        var described: String { "\(role) \(label.isEmpty ? (value ?? "") : label)" }
    }

    /// A control paired with the tree element behind it, so a match can be
    /// acted on and not only described.
    typealias Match = (control: Control, element: AXUIElement)

    // MARK: - Reading the tree

    private static func copy(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let raw = copy(element, attribute) else { return nil }
        if let s = raw as? String { return s }
        if let n = raw as? NSNumber { return n.stringValue }
        return nil
    }

    private static func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let list = names as? [String] else { return [] }
        return list
    }

    private static func center(_ element: AXUIElement) -> CGPoint {
        var origin = CGPoint.zero, size = CGSize.zero
        if let p = copy(element, kAXPositionAttribute as String) { AXValueGetValue(p as! AXValue, .cgPoint, &origin) }
        if let s = copy(element, kAXSizeAttribute as String) { AXValueGetValue(s as! AXValue, .cgSize, &size) }
        return CGPoint(x: (origin.x + size.width / 2).rounded(), y: (origin.y + size.height / 2).rounded())
    }

    private static func label(_ element: AXUIElement) -> String {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
            if let value = string(element, attribute as String), !value.isEmpty { return value }
        }
        return ""
    }

    private static func control(from element: AXUIElement, role: String) -> Control {
        Control(
            role: role,
            label: label(element),
            value: string(element, kAXValueAttribute as String),
            center: center(element),
            enabled: (copy(element, kAXEnabledAttribute as String) as? NSNumber)?.boolValue ?? true,
            pressable: actionNames(element).contains(kAXPressAction as String)
        )
    }

    /// Roles worth surfacing: the things a person acts on, not every group and
    /// label in the tree.
    private static let interestingRoles: Set<String> = [
        "AXButton", "AXPopUpButton", "AXMenuButton", "AXCheckBox", "AXRadioButton",
        "AXSlider", "AXTextField", "AXTextArea", "AXComboBox", "AXDisclosureTriangle",
        "AXSegmentedControl", "AXTabGroup", "AXStepper", "AXLink", "AXMenuItem",
    ]

    /// The application element for a query, with a messaging timeout set.
    ///
    /// The timeout matters: an accessibility request to a process that is
    /// spinning a menu-tracking loop otherwise never returns, and a primitive
    /// that can hang forever is worse than one that fails.
    private static func appElement(_ query: Geometry.AppQuery) throws -> (element: AXUIElement, name: String) {
        guard AXIsProcessTrusted() else { throw AXError.notTrusted }
        let resolution = try Geometry.resolve(query)
        guard let pid = resolution.pids.first else { throw AXError.appNotFound(query.raw) }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 2.0)
        return (element, resolution.name)
    }

    /// Walk the tree under an element, collecting controls and, when asked,
    /// the raw elements alongside them so a caller can act.
    private static func walk(
        _ element: AXUIElement,
        depth: Int = 0,
        budget: inout Int,
        into found: inout [Match]
    ) {
        guard depth < 40, budget > 0 else { return }
        budget -= 1
        let role = string(element, kAXRoleAttribute as String) ?? "AXUnknown"
        if interestingRoles.contains(role) {
            found.append((control(from: element, role: role), element))
        }
        if let children = copy(element, kAXChildrenAttribute as String) as? [AXUIElement] {
            for child in children { walk(child, depth: depth + 1, budget: &budget, into: &found) }
        }
    }

    /// The text an app is showing, straight from its accessibility tree.
    ///
    /// The fast, lossless way to read content, and the reason OCR should be a
    /// fallback rather than the default: one call returns the page verbatim,
    /// with real punctuation and no coordinate to miss, where OCR takes a
    /// screenshot per screenful, garbles lookalike glyphs, clips edges, and
    /// leaves a pile of PNGs behind. Measured on a LinkedIn job posting: the
    /// whole description came back in 0.2s as 12 KB of clean text, versus eight
    /// scroll-and-OCR passes and several hundred KB of images each.
    ///
    /// WebKit (and Chromium) populate the web-area tree only on request, to
    /// save work, so `AXManualAccessibility` is set first to switch it on. An
    /// app that exposes no text tree at all — a game, a canvas — returns little
    /// or nothing here, which is the signal for the caller to fall back to OCR.
    public struct Extracted: Sendable, Equatable {
        public let text: String
        /// How many text nodes were gathered. Low counts on a page that plainly
        /// has text mean the tree is not exposed; fall back to OCR.
        public let nodes: Int
    }

    /// Ask WebKit/Chromium to populate the web-area tree. Best-effort and
    /// low-side-effect; ignored by apps that do not use it.
    private static func enableWebAccessibility(_ app: AXUIElement) {
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// Gather the text under an element, right now, without settling.
    private static func gatherText(_ element: AXUIElement) -> Extracted {
        var pieces: [String] = []
        var budget = 400_000
        func gather(_ element: AXUIElement, depth: Int) {
            guard depth < 300, budget > 0 else { return }
            budget -= 1
            let role = string(element, kAXRoleAttribute as String) ?? ""
            switch role {
            case "AXStaticText", "AXTextArea", "AXTextField", "AXComboBox":
                if let value = string(element, kAXValueAttribute as String), !value.isEmpty {
                    pieces.append(value)
                }
            default:
                break
            }
            if let children = copy(element, kAXChildrenAttribute as String) as? [AXUIElement] {
                for child in children { gather(child, depth: depth + 1) }
            }
        }
        gather(element, depth: 0)

        // Collapse consecutive duplicates (repeated labels, decorative echoes).
        var lines: [String] = []
        for piece in pieces {
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if lines.last != trimmed { lines.append(trimmed) }
        }
        return Extracted(text: lines.joined(separator: "\n"), nodes: pieces.count)
    }

    public static func text(_ query: Geometry.AppQuery, settleMs: UInt32 = 400) throws -> Extracted {
        let (app, _) = try appElement(query)
        enableWebAccessibility(app)
        if settleMs > 0 { usleep(settleMs * 1000) }
        return gatherText(app)
    }

    /// What a settle produced: the text, whether it actually stabilised before
    /// the deadline, and how long it took.
    public struct Settled: Sendable, Equatable {
        public let text: Extracted
        public let stabilised: Bool
        public let waited: TimeInterval
    }

    /// Wait until an app's text stops changing, then return it.
    ///
    /// This is the answer to a hard-coded `sleep` after a click or a load: poll
    /// the accessibility text and return the instant it holds still for a beat,
    /// rather than always waiting the worst case. A fresh navigation is caught
    /// with `changedFrom`: the settle is not believed until the text differs
    /// from that baseline, so a still-showing old page is not mistaken for the
    /// new one having loaded. If nothing ever stabilises, the last reading is
    /// returned at the deadline with `stabilised` false.
    public static func settle(
        _ query: Geometry.AppQuery,
        changedFrom baseline: String? = nil,
        timeout: TimeInterval = 10,
        stableReads: Int = 2,
        pollMs: UInt32 = 250,
        warmupMs: UInt32 = 300
    ) throws -> Settled {
        let (app, _) = try appElement(query)
        enableWebAccessibility(app)
        let start = Date()
        if warmupMs > 0 { usleep(warmupMs * 1000) }
        let deadline = start.addingTimeInterval(timeout)
        let needed = max(1, stableReads)

        var previous = ""
        var stable = 0
        var current = gatherText(app)
        while Date() < deadline {
            let changed = baseline == nil || current.text != baseline
            if !current.text.isEmpty, current.text == previous, changed {
                stable += 1
                if stable >= needed {
                    return Settled(text: current, stabilised: true, waited: Date().timeIntervalSince(start))
                }
            } else {
                stable = 0
            }
            previous = current.text
            usleep(pollMs * 1000)
            current = gatherText(app)
        }
        return Settled(text: current, stabilised: false, waited: Date().timeIntervalSince(start))
    }

    private static func elements(_ query: Geometry.AppQuery) throws -> [Match] {
        let (app, _) = try appElement(query)
        var budget = 6000
        var found: [Match] = []
        walk(app, budget: &budget, into: &found)
        return found
    }

    /// Every actionable control in an app's windows, for discovery.
    ///
    /// This is the accessibility counterpart to `read`: where `read` says what
    /// text is on screen, this says what can be operated and by what name,
    /// with no coordinate-guessing. For a standard app it is the faster and
    /// surer way in.
    public static func controls(_ query: Geometry.AppQuery) throws -> [Control] {
        try elements(query).map(\.control)
    }

    // MARK: - Acting

    /// Which control a needle picks out, as an index, or why it cannot.
    ///
    /// Pure and testable without a live tree. An exact, whole-label (or whole
    /// value) match wins; failing that, a single control that contains the
    /// needle. More than one is a refusal, because acting on the wrong control
    /// is worse than acting on none and does not announce itself. Matching
    /// folds case and lookalikes the same way on-screen text does, so a name
    /// read off `controls` matches what the caller types.
    public static func select(_ needle: String, from controls: [Control]) -> Result<Int, AXError> {
        let wanted = Text.fold(needle)
        let exact = controls.indices.filter { controls[$0].haystacks.contains { Text.fold($0) == wanted } }
        let pool = exact.isEmpty
            ? controls.indices.filter { controls[$0].haystacks.contains { Text.fold($0).contains(wanted) } }
            : exact
        guard let first = pool.first else { return .failure(.noControl(app: "", needle: needle)) }
        guard pool.count == 1 else {
            return .failure(.ambiguous(needle: needle, matches: pool.map { controls[$0].described }))
        }
        return .success(first)
    }

    private static func unique(_ needle: String, among candidates: [Match]) throws -> Match {
        switch select(needle, from: candidates.map(\.control)) {
        case .success(let index): return candidates[index]
        case .failure(let error): throw error
        }
    }

    /// Press the control named `needle` through accessibility.
    ///
    /// Reliable where a posted click is not: the action goes to the identified
    /// element, so a modal sheet's own event loop cannot swallow it, and there
    /// is no coordinate to miss. Returns the control it acted on. Refuses,
    /// before doing anything, if the name is ambiguous.
    @discardableResult
    public static func activate(_ query: Geometry.AppQuery, matching needle: String) throws -> Control {
        let candidates = try elements(query)
        let (control, element): (Control, AXUIElement)
        do { (control, element) = try unique(needle, among: candidates) }
        catch AXError.noControl { throw AXError.noControl(app: query.raw, needle: needle) }
        guard control.pressable else { throw AXError.notActionable(control.label) }
        guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else {
            throw AXError.actionFailed(control.label)
        }
        return control
    }

    /// Open the popup identified by `popup` and pick the item matching `value`.
    ///
    /// `popup` is matched against the popup's current selection, which is how
    /// AppKit labels one: the Night Shift schedule popup reads "Off" until it
    /// is set. Returns what it was and what it now is, read back from the same
    /// control, so the caller gets verification for free rather than trusting
    /// that the pick took.
    @discardableResult
    public static func choose(
        _ query: Geometry.AppQuery,
        popup needle: String,
        value: String
    ) throws -> (before: String, after: String) {
        let candidates = try elements(query)
        let popups = candidates.filter { $0.control.role == "AXPopUpButton" || $0.control.role == "AXComboBox" }
        guard !popups.isEmpty else { throw AXError.notAPopup(needle) }
        let (control, element): (Control, AXUIElement)
        do { (control, element) = try unique(needle, among: popups) }
        catch AXError.noControl { throw AXError.noControl(app: query.raw, needle: needle) }

        let before = control.value ?? control.label
        guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else {
            throw AXError.actionFailed(control.label)
        }
        usleep(300_000)

        var budget = 2000
        var opened: [Match] = []
        walk(element, budget: &budget, into: &opened)
        let items = opened.filter { $0.control.role == "AXMenuItem" }
        let wanted = Text.fold(value)
        let exact = items.first { Text.fold($0.control.label) == wanted }
        let picked = exact ?? items.first { Text.fold($0.control.label).contains(wanted) }
        guard let picked else {
            AXUIElementPerformAction(element, kAXCancelAction as CFString)
            throw AXError.valueNotInMenu(value: value, choices: items.map(\.control.label))
        }
        guard AXUIElementPerformAction(picked.element, kAXPickAction as CFString) == .success
            || AXUIElementPerformAction(picked.element, kAXPressAction as CFString) == .success else {
            throw AXError.actionFailed(picked.control.label)
        }
        usleep(300_000)

        let after = string(element, kAXValueAttribute as String) ?? label(element)
        return (before, after)
    }
}
