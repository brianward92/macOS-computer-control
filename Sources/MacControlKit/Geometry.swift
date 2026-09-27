import AppKit
import CoreGraphics
import Foundation

/// A window's position and size in screen points, top-left origin, together
/// with when it was read.
///
/// The timestamp is not decoration. A rect with no reading time is exactly the
/// artefact that costs an evening: a cached value said a window was at 113,112
/// while it was really at 152,33, and every coordinate derived from it was off
/// by 39 by 79 points. Nothing errored, because a click that lands on nothing
/// reports success.
public struct WindowRect: Sendable, Equatable {
    public let windowID: CGWindowID
    public let pid: pid_t
    public let bounds: CGRect
    /// Is this app's window the front one on screen right now?
    public let isFrontmost: Bool
    /// How many qualifying on-screen windows the app had when this was read,
    /// this one included. More than one means the caller is addressing the
    /// front window of several.
    public let windowCount: Int
    public let readAt: Date

    public init(
        windowID: CGWindowID,
        pid: pid_t,
        bounds: CGRect,
        isFrontmost: Bool,
        windowCount: Int = 1,
        readAt: Date = Date()
    ) {
        self.windowID = windowID
        self.pid = pid
        self.bounds = bounds
        self.isFrontmost = isFrontmost
        self.windowCount = windowCount
        self.readAt = readAt
    }

    public var x: CGFloat { bounds.origin.x }
    public var y: CGFloat { bounds.origin.y }
    public var width: CGFloat { bounds.width }
    public var height: CGFloat { bounds.height }

    /// A point at a fraction of this window, in screen points.
    public func at(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
        CGPoint(x: (x + fx * width).rounded(), y: (y + fy * height).rounded())
    }
}

/// Why a geometry read could not produce an answer.
///
/// Every one of these is a refusal, never a fallback. There is no "best guess"
/// rect, because the whole class of bug this library exists to prevent comes
/// from a plausible-looking rect that is wrong.
public enum GeometryError: Error, CustomStringConvertible, Equatable {
    case noMatchingApp(String)
    case ambiguousApp(String, [String])
    case noOnScreenWindow(String)
    case windowListUnavailable
    case notFrontmost(String, blockedBy: String?)

    public var description: String {
        switch self {
        case .noMatchingApp(let q):
            return "no running application matches \(q)"
        case .ambiguousApp(let q, let names):
            let shown = names.prefix(8).joined(separator: ", ")
            let more = names.count > 8 ? ", and \(names.count - 8) more" : ""
            return "\(q) matches more than one running application (\(shown)\(more)); use the exact name or bundle id"
        case .noOnScreenWindow(let q):
            return "\(q) is running but has no on-screen window"
        case .windowListUnavailable:
            return "the window server returned no window list"
        case .notFrontmost(let q, let blocker):
            let by = blocker.map { "; \($0) is in front" } ?? ""
            return "could not bring \(q) to the front\(by)"
        }
    }
}

public enum Geometry {

    /// How an app is named on the command line: a bundle id, or a name.
    public struct AppQuery: Sendable, CustomStringConvertible, Equatable {
        public let raw: String
        public init(_ raw: String) { self.raw = raw }
        public var description: String { raw }
    }

    /// How a process presents itself, as macOS classifies it.
    public enum Policy: Sendable, Equatable {
        /// An ordinary application: in the Dock, can have windows.
        case regular
        /// A menu-bar item or agent: no Dock icon, but may open windows.
        case accessory
        /// Background only. macOS does not let it create windows at all.
        case prohibited
    }

    /// A running application, reduced to what matching needs. Separated from
    /// `NSRunningApplication` so that resolution can be tested without one.
    public struct Candidate: Sendable, Equatable {
        public let pid: pid_t
        public let name: String?
        public let bundleID: String?
        public let policy: Policy

        public init(pid: pid_t, name: String?, bundleID: String?, policy: Policy = .regular) {
            self.pid = pid
            self.name = name
            self.bundleID = bundleID
            self.policy = policy
        }

        /// Helper processes (renderers, GPU processes, crash handlers) are
        /// background-only, and they share a name prefix with their app.
        /// Leaving them in would make every Electron and Chromium app
        /// ambiguous with itself.
        public var canHaveWindows: Bool { policy != .prohibited }
    }

    /// One application, as one or more processes of it.
    public struct Resolution: Sendable, Equatable {
        public let name: String
        public let bundleID: String?
        public let pids: Set<pid_t>
    }

    /// Everything running right now, as candidates.
    public static func candidates() -> [Candidate] {
        NSWorkspace.shared.runningApplications.map { app in
            let policy: Policy
            switch app.activationPolicy {
            case .regular: policy = .regular
            case .prohibited: policy = .prohibited
            case .accessory: policy = .accessory
            @unknown default: policy = .accessory
            }
            return Candidate(pid: app.processIdentifier,
                             name: app.localizedName,
                             bundleID: app.bundleIdentifier,
                             policy: policy)
        }
    }

    /// Which application a query means.
    ///
    /// An exact match on bundle id or name wins outright. Failing that, a
    /// substring of the name is accepted as a convenience, but only when it
    /// names exactly one application: "Code" with both Xcode and Visual Studio
    /// Code running is refused rather than resolved to whichever happens to
    /// have the bigger window. A wrong app is the worst place a click can land,
    /// and it does not announce itself.
    ///
    /// Substrings are tried against ordinary applications — the ones in the
    /// Dock — before menu-bar items and agents. The system runs dozens of
    /// agents whose names would otherwise make almost any short substring
    /// ambiguous, while an agent that does show a window is still reachable by
    /// its exact name, or by a substring nothing ordinary shares.
    public static func resolve(_ query: AppQuery, among candidates: [Candidate]) throws -> Resolution {
        let raw = query.raw
        let live = candidates.filter(\.canHaveWindows)
        func same(_ a: String?, _ b: String) -> Bool {
            a?.caseInsensitiveCompare(b) == .orderedSame
        }

        var matched = live.filter { same($0.bundleID, raw) || same($0.name, raw) }
        if matched.isEmpty {
            let partial = live.filter { $0.name?.range(of: raw, options: .caseInsensitive) != nil }
            matched = partial.filter { $0.policy == .regular }
            if matched.isEmpty { matched = partial }
        }
        guard !matched.isEmpty else { throw GeometryError.noMatchingApp(raw) }

        // Several processes of one application (two instances, or an app that
        // spawns a second regular process) are the same answer. Different
        // applications are not.
        var order: [String] = []
        var groups: [String: [Candidate]] = [:]
        for candidate in matched {
            let key = candidate.bundleID ?? candidate.name ?? "pid \(candidate.pid)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(candidate)
        }
        guard order.count == 1, let members = groups[order[0]], let first = members.first else {
            let names = order.map { key -> String in
                guard let c = groups[key]?.first else { return key }
                switch (c.name, c.bundleID) {
                case (let n?, let b?): return "\(n) (\(b))"
                case (let n?, nil): return n
                case (nil, let b?): return b
                case (nil, nil): return key
                }
            }
            throw GeometryError.ambiguousApp(raw, names)
        }
        return Resolution(name: first.name ?? first.bundleID ?? raw,
                          bundleID: first.bundleID,
                          pids: Set(members.map(\.pid)))
    }

    public static func resolve(_ query: AppQuery) throws -> Resolution {
        try resolve(query, among: candidates())
    }

    /// One row of the window server's list, reduced to what selection needs.
    public struct WindowEntry: Sendable, Equatable {
        public let id: CGWindowID
        public let pid: pid_t
        public let layer: Int
        public let bounds: CGRect

        public init(id: CGWindowID, pid: pid_t, layer: Int, bounds: CGRect) {
            self.id = id
            self.pid = pid
            self.layer = layer
            self.bounds = bounds
        }
    }

    /// Windows smaller than this are not candidates.
    ///
    /// A naive first-window pick grabs the macOS screen-recording indicator,
    /// which is a real layer-0 window on the captured process and a few points
    /// tall. Nothing a person would call a window is this small.
    public static let minimumWindowSize = CGSize(width: 200, height: 150)

    /// The window list as the window server reports it: on-screen windows,
    /// front to back.
    public static func windowList() throws -> [WindowEntry] {
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else {
            throw GeometryError.windowListUnavailable
        }
        return raw.compactMap { entry in
            guard let layer = entry[kCGWindowLayer as String] as? Int,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            let id = (entry[kCGWindowNumber as String] as? CGWindowID) ?? 0
            return WindowEntry(id: id, pid: pid, layer: layer, bounds: bounds)
        }
    }

    /// Pick the app's window from a front-to-back list.
    ///
    /// The choice is the **front** qualifying window of the app, because that
    /// is the one the user is looking at and the one a sheet or dialog lands
    /// on. Picking the largest instead maps every coordinate onto the main
    /// window behind the dialog the app is actually showing.
    ///
    /// Frontmost is derived from the same list — the first qualifying window
    /// of any app — rather than from `NSWorkspace.frontmostApplication`, which
    /// is KVO-driven and never updates in a process with no main run loop.
    public static func select(
        from entries: [WindowEntry],
        pids: Set<pid_t>,
        readAt: Date = Date()
    ) -> (window: WindowRect?, frontmostPid: pid_t?) {
        var frontmostPid: pid_t?
        var chosen: WindowEntry?
        var count = 0
        for entry in entries {
            guard entry.layer == 0,
                  entry.bounds.width.isFinite, entry.bounds.height.isFinite,
                  entry.bounds.width >= minimumWindowSize.width,
                  entry.bounds.height >= minimumWindowSize.height
            else { continue }
            if frontmostPid == nil { frontmostPid = entry.pid }
            guard pids.contains(entry.pid) else { continue }
            count += 1
            if chosen == nil { chosen = entry }
        }
        guard let chosen else { return (nil, frontmostPid) }
        let rect = WindowRect(
            windowID: chosen.id,
            pid: chosen.pid,
            bounds: chosen.bounds,
            isFrontmost: frontmostPid.map { pids.contains($0) } ?? false,
            windowCount: count,
            readAt: readAt
        )
        return (rect, frontmostPid)
    }

    /// Who is in front right now, across every app.
    ///
    /// The counterpart to capturing a starting point: read this before driving
    /// anything, put the same app back afterward, and the person returns to
    /// exactly what they left. Derived from the window list, like `isFrontmost`
    /// elsewhere, rather than `NSWorkspace.frontmostApplication`, which is
    /// KVO-driven and stale in a process with no run loop.
    public struct FrontApp: Sendable, Equatable {
        public let pid: pid_t
        public let name: String
        public let bundleID: String?
    }

    public static func frontmost() throws -> FrontApp? {
        for entry in try windowList() {
            guard entry.layer == 0,
                  entry.bounds.width >= minimumWindowSize.width,
                  entry.bounds.height >= minimumWindowSize.height,
                  let app = NSRunningApplication(processIdentifier: entry.pid)
            else { continue }
            return FrontApp(pid: entry.pid, name: app.localizedName ?? "", bundleID: app.bundleIdentifier)
        }
        return nil
    }

    /// The window rect for an app, read **now**.
    ///
    /// There is deliberately no cached variant and no public entry point that
    /// accepts a caller-supplied rect. Geometry is read inside the call that
    /// uses it, immediately before the action, and reported back with the time
    /// it was read so a stale rect is a log line rather than an evening.
    public static func windowRect(for query: AppQuery) throws -> WindowRect {
        let resolution = try resolve(query)
        let (window, _) = select(from: try windowList(), pids: resolution.pids)
        guard let window else { throw GeometryError.noOnScreenWindow(resolution.name) }
        return window
    }

    /// Bring an app to the front and wait until the window server agrees.
    ///
    /// Synthetic input goes to whatever is frontmost; canvas-rendered apps in
    /// particular ignore input and hover on an unfocused window. Waiting on the
    /// observable effect rather than sleeping a fixed interval is the same rule
    /// that applies everywhere else in this library. If the app cannot be
    /// brought forward — a modal dialog from another app, a full-screen Space
    /// that will not yield — this throws rather than returning a rect that
    /// input would sail past into whatever is really in front.
    @discardableResult
    public static func activate(_ query: AppQuery, timeout: TimeInterval = 3) throws -> WindowRect {
        try activate(try resolve(query), raw: query.raw, timeout: timeout)
    }

    /// Bring one specific process forward, by pid rather than by name.
    ///
    /// For `restore`: the origin was recorded as a pid, and a name lookup
    /// could land on a second instance or a same-named app started since.
    public static func activate(pid: pid_t, timeout: TimeInterval = 3) throws -> WindowRect {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            throw GeometryError.noMatchingApp("pid \(pid)")
        }
        let resolution = Resolution(name: app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)",
                                    bundleID: app.bundleIdentifier, pids: [pid])
        return try activate(resolution, raw: resolution.name, timeout: timeout)
    }

    static func activate(_ resolution: Resolution, raw: String, timeout: TimeInterval) throws -> WindowRect {
        let apps = NSWorkspace.shared.runningApplications
            .filter { resolution.pids.contains($0.processIdentifier) }
        guard !apps.isEmpty else { throw GeometryError.noMatchingApp(raw) }

        var (window, frontmostPid) = select(from: try windowList(), pids: resolution.pids)
        if let window, window.isFrontmost { return window }

        // Activate the process that owns the front window when there is one.
        // A hidden app has no window to choose by, so every process of it is
        // asked, which for the usual single-process app is the same thing.
        let owners = window.map { w in apps.filter { $0.processIdentifier == w.pid } } ?? apps
        owners.forEach { $0.activate() }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            usleep(80_000)
            guard let entries = try? windowList() else { continue }
            (window, frontmostPid) = select(from: entries, pids: resolution.pids)
            if let window, window.isFrontmost { return window }
        }
        guard window != nil else { throw GeometryError.noOnScreenWindow(resolution.name) }
        let blocker = frontmostPid.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
        throw GeometryError.notFrontmost(resolution.name, blockedBy: blocker)
    }
}
