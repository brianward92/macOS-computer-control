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
        case emptySelector
        case incompleteSearch
        case disabled(String)
        case notSettable(String)
        case secureField(String)
        case scopeChanged

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
            case .emptySelector:
                return "name a control, role, or exact identifier before acting"
            case .incompleteSearch:
                return "the accessibility search was incomplete; observe again or narrow the scope before acting"
            case .disabled(let name):
                return "the control \"\(name)\" is disabled"
            case .notSettable(let name):
                return "the value of \"\(name)\" cannot be set through accessibility"
            case .secureField(let name):
                return "the control \"\(name)\" is a secure field"
            case .scopeChanged:
                return "the accessible window or control changed during discovery; observe it again"
            }
        }
    }

    public enum Scope: String, Sendable, CaseIterable { case app, window }

    /// Filters are combined. Identifiers and roles are exact and case-sensitive;
    /// human labels, values, and placeholders use the usual folded text match.
    public struct Selector: Sendable, Equatable {
        public let needle: String?
        public let role: String?
        public let identifier: String?
        public let exact: Bool

        public init(needle: String? = nil, role: String? = nil,
                    identifier: String? = nil, exact: Bool = false) {
            self.needle = needle
            self.role = role
            self.identifier = identifier
            self.exact = exact
        }

        public var isEmpty: Bool {
            [needle, role, identifier].compactMap { $0 }
                .allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }

        var described: String {
            [needle, role, identifier.map { "identifier=\($0)" }]
                .compactMap { $0 }.joined(separator: " ")
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
        public let identifier: String?
        public let url: String?
        public let placeholder: String?
        public let bounds: CGRect?
        public let focused: Bool?
        public let valueSettable: Bool
        public let secure: Bool

        public init(role: String, label: String, value: String?, center: CGPoint,
                    enabled: Bool, pressable: Bool, identifier: String? = nil,
                    url: String? = nil, placeholder: String? = nil, bounds: CGRect? = nil,
                    focused: Bool? = nil, valueSettable: Bool = false, secure: Bool = false) {
            self.role = role
            self.label = label
            self.value = value
            self.center = center
            self.enabled = enabled
            self.pressable = pressable
            self.identifier = identifier
            self.url = url
            self.placeholder = placeholder
            self.bounds = bounds
            self.focused = focused
            self.valueSettable = valueSettable
            self.secure = secure
        }

        /// Machine identifiers and destinations deliberately do not participate
        /// in human-label matching.
        var haystacks: [String] { [label, value, placeholder].compactMap { $0 }.filter { !$0.isEmpty } }

        /// How the control reads in an error or an ambiguity list.
        var described: String {
            let name = label.isEmpty ? (placeholder ?? value ?? "") : label
            return "\(role) \(name)" + (identifier.map { " [\($0)]" } ?? "")
        }
    }

    public struct Discovery: Sendable, Equatable {
        public let controls: [Control]
        public let truncated: Bool
        public let visited: Int
    }

    public struct ValueChange: Sendable, Equatable {
        public let control: Control
        public let before: String?
        public let after: String?
        /// nil means the app accepted AXValue but its value could not be read.
        public let verified: Bool?
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

    /// Selection and mutation require distinguishing an absent optional
    /// attribute from a failed read. Otherwise an unreadable identifier or
    /// label can hide a second match in an otherwise complete tree.
    private static func checkedCopy(_ element: AXUIElement, _ attribute: String) throws -> AnyObject? {
        var value: AnyObject?
        switch AXUIElementCopyAttributeValue(element, attribute as CFString, &value) {
        case .attributeUnsupported, .noValue:
            return nil
        case .success:
            guard let value else { throw AXError.incompleteSearch }
            return value
        default:
            throw AXError.incompleteSearch
        }
    }

    private static func checkedString(_ element: AXUIElement, _ attribute: String) throws -> String? {
        guard let raw = try checkedCopy(element, attribute) else { return nil }
        if let s = raw as? String { return s }
        if let n = raw as? NSNumber { return n.stringValue }
        // Some controls expose non-text AXValue objects. They are not strings
        // to match, but their successful read is not a communication failure.
        return nil
    }

    private static func actionNames(_ element: AXUIElement) throws -> [String] {
        var names: CFArray?
        switch AXUIElementCopyActionNames(element, &names) {
        case .actionUnsupported, .attributeUnsupported, .noValue, .notImplemented:
            return []
        case .success:
            guard let list = names as? [String] else { throw AXError.incompleteSearch }
            return list
        default:
            throw AXError.incompleteSearch
        }
    }

    private static func valueIsSettable(_ element: AXUIElement) throws -> Bool {
        var settable = DarwinBoolean(false)
        switch AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) {
        case .attributeUnsupported, .noValue, .notImplemented:
            return false
        case .success:
            return settable.boolValue
        default:
            throw AXError.incompleteSearch
        }
    }

    private static func isEnabled(_ element: AXUIElement) throws -> Bool {
        guard let raw = try checkedCopy(element, kAXEnabledAttribute as String) else { return true }
        guard let enabled = raw as? NSNumber else { throw AXError.incompleteSearch }
        return enabled.boolValue
    }

    private static func bounds(_ element: AXUIElement) -> CGRect? {
        var origin = CGPoint.zero, size = CGSize.zero
        guard let p = copy(element, kAXPositionAttribute as String),
              let s = copy(element, kAXSizeAttribute as String),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID(),
              AXValueGetValue(p as! AXValue, .cgPoint, &origin),
              AXValueGetValue(s as! AXValue, .cgSize, &size),
              origin.x.isFinite, origin.y.isFinite, size.width.isFinite, size.height.isFinite
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func label(_ element: AXUIElement) throws -> String {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
            if let value = try checkedString(element, attribute as String), !value.isEmpty { return value }
        }
        return ""
    }

    private static func control(from element: AXUIElement, role: String) throws -> Control {
        // Establish security before any AXValue read. A failed subrole query
        // must not turn a protected text field into an ordinary one.
        let secure: Bool
        if role == "AXSecureTextField" {
            secure = true
        } else {
            secure = try checkedString(element, kAXSubroleAttribute as String) == "AXSecureTextField"
        }
        let rect = bounds(element)
        let canSet = try valueIsSettable(element)
        let rawURL = copy(element, "AXURL")
        let url = (rawURL as? URL)?.absoluteString ?? (rawURL as? String)
        return try Control(
            role: role,
            label: label(element),
            value: secure ? nil : checkedString(element, kAXValueAttribute as String),
            center: rect.map { CGPoint(x: $0.midX.rounded(), y: $0.midY.rounded()) } ?? .zero,
            enabled: isEnabled(element),
            pressable: actionNames(element).contains(kAXPressAction as String),
            identifier: checkedString(element, kAXIdentifierAttribute as String),
            url: url,
            placeholder: checkedString(element, "AXPlaceholderValue"),
            bounds: rect,
            focused: (copy(element, kAXFocusedAttribute as String) as? NSNumber)?.boolValue,
            valueSettable: canSet,
            secure: secure
        )
    }

    /// Roles worth surfacing: the things a person acts on, not every group and
    /// label in the tree.
    private static let interestingRoles: Set<String> = [
        "AXButton", "AXPopUpButton", "AXMenuButton", "AXCheckBox", "AXRadioButton",
        "AXSlider", "AXTextField", "AXTextArea", "AXComboBox", "AXDisclosureTriangle",
        "AXSegmentedControl", "AXTabGroup", "AXStepper", "AXLink", "AXMenuItem", "AXSecureTextField",
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
        truncated: inout Bool,
        into found: inout [Match]
    ) {
        guard depth < 100, budget > 0 else { truncated = true; return }
        budget -= 1
        // Role is required for classifying controls. An inaccessible node may
        // conceal a second matching control, even if its siblings remain readable.
        let role = copy(element, kAXRoleAttribute as String) as? String
        if role == nil || role?.isEmpty == true { truncated = true }
        if let role, interestingRoles.contains(role) {
            do {
                found.append((try control(from: element, role: role), element))
            } catch {
                // Do not let a metadata read failure hide an ambiguous match.
                truncated = true
            }
        }
        do {
            let children = try childElements(element)
            for (index, child) in children.enumerated() {
                walk(child, depth: depth + 1, budget: &budget, truncated: &truncated, into: &found)
                if budget == 0 { if index + 1 < children.count { truncated = true }; break }
            }
        } catch {
            truncated = true
        }
    }

    /// Unsupported children or an absent value are normal for leaves. A failed
    /// AX request, or a successful response of the wrong type, is not an empty
    /// subtree and must never establish uniqueness for an action.
    private static func childElements(_ element: AXUIElement) throws -> [AXUIElement] {
        var raw: AnyObject?
        let status = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &raw)
        switch status {
        case .attributeUnsupported, .noValue:
            return []
        case .success:
            guard let children = raw as? [AXUIElement] else { throw AXError.incompleteSearch }
            return children
        default:
            throw AXError.incompleteSearch
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

    private struct Snapshot {
        let app: AXUIElement
        let root: AXUIElement
        let matches: [Match]
        let truncated: Bool
        let visited: Int
    }

    private static func elementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let raw = copy(element, attribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    /// Window scope excludes the menu bar and other windows. A modal sheet
    /// owns interaction while attached, so prefer it to the document behind it.
    private static func root(_ app: AXUIElement, scope: Scope, name: String) throws -> AXUIElement {
        guard scope == .window else { return app }
        func isWindow(_ element: AXUIElement) -> Bool {
            let role = copy(element, kAXRoleAttribute as String) as? String
            return role == "AXWindow" || role == "AXSheet"
        }
        let focused = elementAttribute(app, kAXFocusedWindowAttribute as String).flatMap { isWindow($0) ? $0 : nil }
        let main = elementAttribute(app, kAXMainWindowAttribute as String).flatMap { isWindow($0) ? $0 : nil }
        // Safari can expose an AXScrollArea in AXWindows. It is not a window
        // and must not become the scope just because it is the sole entry.
        let windows = (copy(app, kAXWindowsAttribute as String) as? [AXUIElement] ?? []).filter(isWindow)
        guard let window = focused ?? main ?? (windows.count == 1 ? windows.first : nil) else {
            throw AXError.noWindow(name)
        }
        let children = try childElements(window)
        var sheets: [AXUIElement] = []
        for child in children {
            guard let role = copy(child, kAXRoleAttribute as String) as? String, !role.isEmpty else {
                throw AXError.incompleteSearch
            }
            if role == "AXSheet" { sheets.append(child) }
        }
        guard sheets.count <= 1 else { throw AXError.scopeChanged }
        return sheets.first ?? window
    }

    private static func snapshot(_ query: Geometry.AppQuery, scope: Scope) throws -> Snapshot {
        let (app, name) = try appElement(query)
        enableWebAccessibility(app)
        let selected = try root(app, scope: scope, name: name)
        var budget = 6000
        var truncated = false
        var found: [Match] = []
        walk(selected, budget: &budget, truncated: &truncated, into: &found)
        return Snapshot(app: app, root: selected, matches: found, truncated: truncated, visited: 6000 - budget)
    }

    private static func elements(_ query: Geometry.AppQuery) throws -> [Match] {
        let result = try snapshot(query, scope: .app)
        guard !result.truncated else { throw AXError.incompleteSearch }
        return result.matches
    }

    /// Every actionable control in an app's windows, for discovery.
    ///
    /// This is the accessibility counterpart to `read`: where `read` says what
    /// text is on screen, this says what can be operated and by what name,
    /// with no coordinate-guessing. For a standard app it is the faster and
    /// surer way in.
    public static func controls(_ query: Geometry.AppQuery) throws -> [Control] {
        try discover(query).controls
    }

    public static func discover(_ query: Geometry.AppQuery, scope: Scope = .app,
                                selector: Selector = Selector()) throws -> Discovery {
        let result = try snapshot(query, scope: scope)
        return Discovery(controls: filter(selector, from: result.matches.map(\.control)),
                         truncated: result.truncated, visited: result.visited)
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
        select(Selector(needle: needle), from: controls)
    }

    private static func matchingIndices(_ selector: Selector, from controls: [Control]) -> [Int] {
        controls.indices.filter { index in
            let control = controls[index]
            if let role = selector.role, control.role != role { return false }
            if let identifier = selector.identifier, control.identifier != identifier { return false }
            guard let needle = selector.needle else { return true }
            let wanted = Text.fold(needle)
            guard !wanted.isEmpty else { return false }
            return control.haystacks.contains {
                selector.exact ? Text.fold($0) == wanted : Text.fold($0).contains(wanted)
            }
        }
    }

    /// Discovery lists every matching control; it does not discard substring
    /// results just because one of the controls has an exact label.
    public static func filter(_ selector: Selector, from controls: [Control]) -> [Control] {
        matchingIndices(selector, from: controls).map { controls[$0] }
    }

    /// Selection is shared by both mutations. Partial discovery never proves
    /// uniqueness, even when the observed portion contains just one match.
    public static func select(_ selector: Selector, from controls: [Control],
                              truncated: Bool = false) -> Result<Int, AXError> {
        guard !selector.isEmpty else { return .failure(.emptySelector) }
        guard !truncated else { return .failure(.incompleteSearch) }
        var pool = matchingIndices(selector, from: controls)
        if let needle = selector.needle, !selector.exact {
            let wanted = Text.fold(needle)
            let exact = pool.filter { controls[$0].haystacks.contains { Text.fold($0) == wanted } }
            if !exact.isEmpty { pool = exact }
        }
        guard let first = pool.first else { return .failure(.noControl(app: "", needle: selector.described)) }
        guard pool.count == 1 else {
            return .failure(.ambiguous(needle: selector.described, matches: pool.map { controls[$0].described }))
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
        try activate(query, selector: Selector(needle: needle))
    }

    /// These preconditions are separate from selection so that a disabled or
    /// protected unique match is refused, rather than ignored in favour of a
    /// less precise but operable match.
    public static func validateMutation(_ control: Control, settingValue: Bool = false) -> Result<Void, AXError> {
        guard control.enabled else { return .failure(.disabled(control.described)) }
        guard !control.secure else { return .failure(.secureField(control.described)) }
        if settingValue {
            guard control.valueSettable else { return .failure(.notSettable(control.described)) }
        } else {
            guard control.pressable else { return .failure(.notActionable(control.described)) }
        }
        return .success(())
    }

    private static func target(_ query: Geometry.AppQuery, scope: Scope,
                               selector: Selector, settingValue: Bool) throws -> Match {
        guard !selector.isEmpty else { throw AXError.emptySelector }
        func selected(_ result: Snapshot) throws -> Match {
            do {
                let index = try select(selector, from: result.matches.map(\.control),
                                       truncated: result.truncated).get()
                return result.matches[index]
            } catch AXError.noControl {
                throw AXError.noControl(app: query.raw, needle: selector.described)
            }
        }
        let first = try snapshot(query, scope: scope)
        let original = try selected(first)
        // Resolve again in a fresh tree: changing tabs can replace a field
        // without changing its containing window, and a new duplicate can make
        // a formerly unique label ambiguous. Neither permits reusing the first
        // match, even if that AX element still answers property reads.
        let result = try snapshot(query, scope: scope)
        let currentTarget = try selected(result)
        guard CFEqual(first.root, result.root), CFEqual(original.element, currentTarget.element) else {
            throw AXError.scopeChanged
        }
        // Re-read both identity and capabilities immediately before delivery.
        // AX has no atomic compare-and-act transaction, so callers must still
        // verify the effect after mutation.
        let currentRoot = try root(result.app, scope: scope, name: query.raw)
        guard CFEqual(result.root, currentRoot) else { throw AXError.scopeChanged }
        guard let role = string(currentTarget.element, kAXRoleAttribute as String) else { throw AXError.scopeChanged }
        let current = try control(from: currentTarget.element, role: role)
        guard !filter(selector, from: [current]).isEmpty else { throw AXError.scopeChanged }
        try validateMutation(current, settingValue: settingValue).get()
        return (current, currentTarget.element)
    }

    @discardableResult
    public static func activate(_ query: Geometry.AppQuery, scope: Scope = .app,
                                selector: Selector) throws -> Control {
        let (control, element) = try target(query, scope: scope, selector: selector, settingValue: false)
        guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else {
            throw AXError.actionFailed(control.label)
        }
        return control
    }

    /// Set AXValue on the uniquely selected native control, then read that same
    /// element back. Verification compares the literal value, without folding.
    public static func setValue(_ query: Geometry.AppQuery, scope: Scope = .app,
                                selector: Selector, value: String) throws -> ValueChange {
        let (control, element) = try target(query, scope: scope, selector: selector, settingValue: true)
        guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString) == .success else {
            throw AXError.actionFailed(control.described)
        }
        let after = string(element, kAXValueAttribute as String)
        return ValueChange(control: control, before: control.value, after: after,
                           verified: after.map { $0 == value })
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
        var truncated = false
        var opened: [Match] = []
        walk(element, budget: &budget, truncated: &truncated, into: &opened)
        guard !truncated else {
            AXUIElementPerformAction(element, kAXCancelAction as CFString)
            throw AXError.incompleteSearch
        }
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

        let after = try string(element, kAXValueAttribute as String) ?? label(element)
        return (before, after)
    }
}
