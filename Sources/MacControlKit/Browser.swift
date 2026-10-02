import ApplicationServices
import Foundation

/// Read-only browser observations from the native accessibility tree.
/// Address-bar edits are deliberately separate from the committed document URL.
public enum Browser {
    public enum ObservationError: Error, CustomStringConvertible {
        case ambiguousProcesses
        case ambiguousWindows
        case incompleteWindowList
        case changed

        public var description: String {
            switch self {
            case .ambiguousProcesses: return "browser query matches multiple processes; could not select a window unambiguously"
            case .ambiguousWindows: return "browser exposes multiple windows without a focused or main window; could not select one unambiguously"
            case .incompleteWindowList: return "could not read all browser windows; observe again"
            case .changed: return "browser window or page changed while reading; observe again"
            }
        }
    }

    /// Reduced AX evidence, also usable for deterministic tests without a browser.
    public struct Node: Sendable, Equatable {
        public var role: String
        public var subrole: String?
        public var title: String?
        public var identifier: String?
        public var url: String?
        public var document: String?
        public var value: String?
        public var focused: Bool?
        public var loaded: Bool?
        public var loadingProgress: Double?
        public var busy: Bool?
        public var index: Int?
        public var selected: Bool?
        public var children: [Node]
        /// False when traversal was truncated or children could not be read.
        public var complete: Bool

        public init(role: String, children: [Node] = [], complete: Bool = true) {
            self.role = role
            self.children = children
            self.complete = complete
        }
    }

    public struct Window: Codable, Sendable, Equatable {
        public let identifier: String?
        public let title: String?
        public let source: String
        private enum CodingKeys: String, CodingKey { case identifier, title, source }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(identifier, forKey: .identifier)
            try c.encode(title, forKey: .title)
            try c.encode(source, forKey: .source)
        }
    }

    public struct Page: Codable, Sendable, Equatable {
        public let url: String?
        public let title: String?
        public let loaded: Bool?
        public let loadingProgress: Double?
        public let busy: Bool?
        public let source: String?
        public let reason: String?
        private enum CodingKeys: String, CodingKey { case url, title, loaded, loadingProgress, busy, source, reason }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(url, forKey: .url)
            try c.encode(title, forKey: .title)
            try c.encode(loaded, forKey: .loaded)
            try c.encode(loadingProgress, forKey: .loadingProgress)
            try c.encode(busy, forKey: .busy)
            try c.encode(source, forKey: .source)
            try c.encode(reason, forKey: .reason)
        }
    }

    public struct Address: Codable, Sendable, Equatable {
        public let value: String?
        public let focused: Bool?
        public let source: String?
        private enum CodingKeys: String, CodingKey { case value, focused, source }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(value, forKey: .value)
            try c.encode(focused, forKey: .focused)
            try c.encode(source, forKey: .source)
        }
    }

    public struct Tab: Codable, Sendable, Equatable {
        public let index: Int?
        public let title: String?
        public let selected: Bool?
        /// An observed AX identifier, not a durable tab handle.
        public let identifier: String?
        private enum CodingKeys: String, CodingKey { case index, title, selected, identifier }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(index, forKey: .index)
            try c.encode(title, forKey: .title)
            try c.encode(selected, forKey: .selected)
            try c.encode(identifier, forKey: .identifier)
        }
    }

    public struct Observation: Codable, Sendable, Equatable {
        public let window: Window
        public let page: Page
        public let address: Address
        public let tabs: [Tab]
        public let complete: Bool
    }

    public struct Snapshot: Codable, Sendable, Equatable {
        public let readAt: String
        public let app: String
        public let pid: pid_t
        public let window: Window
        public let page: Page
        public let address: Address
        public let tabs: [Tab]
        public let complete: Bool
    }

    /// Interpret only evidence in this window. Nested web areas are frames,
    /// so stop at the outer document and never mistake an iframe URL for it.
    public static func inspect(window: Node, source: String) -> Observation {
        var webAreas: [Node] = [], addresses: [Node] = [], tabs: [Tab] = []
        var complete = true
        func visit(_ node: Node, inTabs: Bool = false) {
            complete = complete && node.complete
            if node.role == "AXWebArea" {
                webAreas.append(node)
                return
            }
            if node.role == "AXTextField", node.identifier == "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD" {
                addresses.append(node)
            }
            if node.subrole == "AXTabButton" || (inTabs && node.role == "AXRadioButton") {
                let selected = node.selected ?? node.value.flatMap { $0 == "1" ? true : ($0 == "0" ? false : nil) }
                tabs.append(Tab(index: node.index, title: node.title, selected: selected, identifier: node.identifier))
            }
            for child in node.children { visit(child, inTabs: inTabs || node.role == "AXTabGroup") }
        }
        visit(window)

        let document = nonempty(window.document)
        let page: Page
        if webAreas.count > 1 {
            page = Page(url: nil, title: nil, loaded: nil, loadingProgress: nil, busy: nil,
                        source: nil, reason: "multiple outer web areas; could not identify the current document")
        } else if !complete {
            page = Page(url: document, title: document == nil ? nil : window.title,
                        loaded: nil, loadingProgress: nil, busy: nil,
                        source: document == nil ? nil : "AXWindow.AXDocument",
                        reason: "accessibility tree incomplete; document evidence may be unavailable")
        } else if let area = webAreas.first {
            let webURL = nonempty(area.url)
            let url = webURL ?? document
            page = Page(url: url, title: nonempty(area.title) ?? window.title,
                        loaded: area.loaded, loadingProgress: area.loadingProgress, busy: area.busy,
                        source: webURL != nil ? "AXWebArea.AXURL" : (document != nil ? "AXWindow.AXDocument" : nil),
                        reason: url == nil ? "current document URL is not exposed by accessibility" : nil)
        } else {
            page = Page(url: document, title: document == nil ? nil : window.title,
                        loaded: nil, loadingProgress: nil, busy: nil,
                        source: document == nil ? nil : "AXWindow.AXDocument",
                        reason: document == nil ? "no document URL or web area exposed; address text is not a committed URL" : nil)
        }
        let address = complete && addresses.count == 1 ? addresses.first : nil
        return Observation(window: Window(identifier: window.identifier, title: window.title, source: source),
                           page: page,
                           address: Address(value: address?.value, focused: address?.focused,
                                            source: address == nil ? nil : "AXTextField.WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD"),
                           tabs: tabs, complete: complete)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// Loading progress may advance between reads, but the observed document,
    /// window and tab selection must still describe the same browser state.
    public static func isCoherent(_ first: Observation, _ second: Observation) -> Bool {
        first.window == second.window && first.page.url == second.page.url
            && first.page.title == second.page.title && first.page.source == second.page.source
            && first.page.reason == second.page.reason && first.tabs == second.tabs
            && first.address == second.address && first.complete == second.complete
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    /// AXURL is commonly a CFURL; AXDocument is commonly a string.
    public static func stringValue(_ value: AnyObject?) -> String? {
        guard let value else { return nil }
        if let url = value as? URL { return url.absoluteString }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        stringValue(attribute(element, name))
    }

    private static func selectedWindow(_ app: AXUIElement) throws -> (AXUIElement, String)? {
        for name in ["AXFocusedWindow", "AXMainWindow"] {
            guard let raw = attribute(app, name), CFGetTypeID(raw) == AXUIElementGetTypeID() else { continue }
            let element = raw as! AXUIElement
            if string(element, "AXRole") == "AXWindow" { return (element, name) }
        }
        // A background browser may expose neither focused nor main window.
        // Its sole actual window is still unambiguous. Safari sometimes adds
        // non-window elements such as AXScrollArea to AXWindows; exclude them.
        var raw: AnyObject?
        let status = AXUIElementCopyAttributeValue(app, "AXWindows" as CFString, &raw)
        if status == .attributeUnsupported || status == .noValue { return nil }
        guard status == .success, let candidates = raw as? [AXUIElement] else {
            throw ObservationError.incompleteWindowList
        }
        var windows: [AXUIElement] = []
        for candidate in candidates {
            guard let role = string(candidate, "AXRole"), !role.isEmpty else {
                throw ObservationError.incompleteWindowList
            }
            if role == "AXWindow", !windows.contains(where: { CFEqual($0, candidate) }) {
                windows.append(candidate)
            }
        }
        guard windows.count <= 1 else { throw ObservationError.ambiguousWindows }
        return windows.first.map { ($0, "AXWindows.unique") }
    }

    private static func read(_ element: AXUIElement, depth: Int = 0, budget: inout Int) -> Node {
        guard depth < 60, budget > 0 else { return Node(role: "AXUnknown", complete: false) }
        budget -= 1
        var attributesComplete = true
        func observed(_ name: String) -> AnyObject? {
            var value: AnyObject?
            switch AXUIElementCopyAttributeValue(element, name as CFString, &value) {
            case .attributeUnsupported, .noValue:
                return nil
            case .success:
                if value == nil { attributesComplete = false }
                return value
            default:
                // An unreadable identifier or subrole can hide an address
                // field or tab. Partial metadata cannot establish uniqueness.
                attributesComplete = false
                return nil
            }
        }
        func observedString(_ name: String) -> String? { stringValue(observed(name)) }
        var node = Node(role: observedString("AXRole") ?? "AXUnknown")
        if node.role == "AXUnknown" { node.complete = false }
        node.subrole = observedString("AXSubrole")
        node.title = observedString("AXTitle")
        node.identifier = observedString("AXIdentifier")
        if node.role == "AXWindow" { node.document = observedString("AXDocument") }
        if node.role == "AXWebArea" {
            node.url = observedString("AXURL")
            node.loaded = (observed("AXLoaded") as? NSNumber)?.boolValue
            node.loadingProgress = (observed("AXLoadingProgress") as? NSNumber)?.doubleValue
            node.busy = (observed("AXElementBusy") as? NSNumber)?.boolValue
            node.complete = node.complete && attributesComplete
            return node
        }
        if node.role == "AXTextField" || node.role == "AXRadioButton" || node.subrole == "AXTabButton" {
            node.value = observedString("AXValue")
            node.focused = (observed("AXFocused") as? NSNumber)?.boolValue
            node.selected = (observed("AXSelected") as? NSNumber)?.boolValue
            node.index = (observed("AXIndex") as? NSNumber)?.intValue
        }

        var raw: AnyObject?
        let status = AXUIElementCopyAttributeValue(element, "AXChildren" as CFString, &raw)
        if status == .success, let children = raw as? [AXUIElement] {
            for child in children {
                guard budget > 0 else { node.complete = false; break }
                node.children.append(read(child, depth: depth + 1, budget: &budget))
            }
        } else if status != .attributeUnsupported && status != .noValue {
            node.complete = false
        }
        node.complete = node.complete && attributesComplete
        return node
    }

    /// Does not launch, focus, type, activate a tab, or enable AX attributes.
    /// Two matching observations guard against mixing two windows or tabs.
    public static func snapshot(_ query: Geometry.AppQuery) throws -> Snapshot {
        guard AXIsProcessTrusted() else { throw Accessibility.AXError.notTrusted }
        let resolution = try Geometry.resolve(query)
        guard resolution.pids.count == 1, let pid = resolution.pids.first else {
            throw ObservationError.ambiguousProcesses
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        guard let (window, source) = try selectedWindow(app) else { throw Accessibility.AXError.noWindow(resolution.name) }
        var budget = 6000
        let first = inspect(window: read(window, budget: &budget), source: source)
        guard let (again, againSource) = try selectedWindow(app), CFEqual(window, again), source == againSource else {
            throw ObservationError.changed
        }
        budget = 6000
        let second = inspect(window: read(again, budget: &budget), source: againSource)
        // Progress may advance while the same page is read. Identity, URL,
        // title, tab selection and address edits must stay coherent.
        guard isCoherent(first, second),
              let (last, _) = try selectedWindow(app), CFEqual(window, last) else {
            throw ObservationError.changed
        }
        return Snapshot(readAt: ISO8601DateFormatter().string(from: Date()), app: resolution.name, pid: pid,
                        window: second.window, page: second.page, address: second.address,
                        tabs: second.tabs, complete: second.complete)
    }
}
