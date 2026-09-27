import AppKit
import CoreGraphics
import Foundation
import IOKit.pwr_mgt

/// Launching apps, and knowing whether we are allowed to do anything at all.
public enum System {

    public enum SystemError: Error, CustomStringConvertible {
        case appNotFound(String)
        case launchFailed(String, String)
        case sessionNotOnConsole

        public var description: String {
            switch self {
            case .appNotFound(let n): return "no application named \(n)"
            case .launchFailed(let n, let why): return "could not launch \(n): \(why)"
            case .sessionNotOnConsole:
                return "this login session is not on the console (locked, or fast user switched); synthetic input goes nowhere"
            }
        }
    }

    /// Is this session actually driving the screen?
    ///
    /// On a locked screen or a fast-user-switched session, synthetic events are
    /// accepted and discarded. Refusing here turns a silent no-op into an
    /// explicit failure.
    public static var isOnConsole: Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        return (info[kCGSessionOnConsoleKey as String] as? NSNumber)?.boolValue ?? true
    }

    /// Is the display actually showing anything?
    ///
    /// Worth asking before every single command, because a sleeping display
    /// fails in the most confusing way available. Capture still "succeeds" and
    /// hands back a completely black image, so OCR finds no text, every check
    /// reports the control is not on screen, and `wait-for` times out with
    /// "never managed to observe the window". It looks exactly like the app
    /// being in the wrong state, and it cost a session's worth of confusion.
    public static var isDisplayAsleep: Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    /// Is the screen saver covering the screen?
    ///
    /// Different failure from a sleeping display and it has to be checked
    /// separately: the display is awake and capture returns a perfectly valid
    /// image — of the screen saver. Reads then find text that belongs to
    /// nothing, which is worse than finding none.
    public static var isScreenSaverRunning: Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.ScreenSaver.Engine"
        ).isEmpty
    }

    /// Is the screen locked?
    ///
    /// Reported, never worked around. Waking a locked screen gets you the
    /// password prompt, and nothing this library does can or should get past
    /// it. The point of detecting it is to say so instead of failing obscurely.
    public static var isScreenLocked: Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (info["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }

    /// What the wake attempt found, and what it did about it.
    public struct Wake: Sendable {
        public let displayWasAsleep: Bool
        public let screenSaverWasRunning: Bool
        public let locked: Bool
        public let awakeNow: Bool

        /// Did this actually have to do something? Drives whether it is worth
        /// reporting; a no-op wake should not clutter every result.
        public var acted: Bool { displayWasAsleep || screenSaverWasRunning }
    }

    /// Wake the screen the way a person does: notice it is dark, tap the pad.
    ///
    /// Two mechanisms, because the two dark states are unrelated.
    ///
    /// A *sleeping display* wakes on `IOPMAssertionDeclareUserActivity`, the
    /// documented "a person is here" signal, which also resets the idle timer
    /// without pretending to be an input event.
    ///
    /// A *running screen saver* does not. Measured here: the assertion leaves
    /// it up, and so does a synthetic cursor move, because `ScreenSaverEngine`
    /// watches real HID input and never sees ours. Dismissing it means asking
    /// the engine to quit, which is exactly what a real dismissal does — the
    /// process exits either way. This cannot be used to get past a lock: with
    /// "require password" on, quitting the engine hands the screen to
    /// `loginwindow`, and `isScreenLocked` still reports the truth afterwards.
    @discardableResult
    public static func wakeScreen(timeout: TimeInterval = 5) -> Wake {
        let wasAsleep = isDisplayAsleep
        let hadSaver = isScreenSaverRunning
        guard wasAsleep || hadSaver else {
            return Wake(displayWasAsleep: false, screenSaverWasRunning: false,
                        locked: false, awakeNow: true)
        }

        var assertion: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity(
            "macctl is driving this machine" as CFString,
            kIOPMUserActiveLocal,
            &assertion
        )

        if hadSaver {
            let engines = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.ScreenSaver.Engine"
            )
            engines.forEach { $0.terminate() }
            usleep(500_000)
            // Ask nicely once; a screen saver mid-transition can ignore it.
            NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.ScreenSaver.Engine"
            ).forEach { $0.forceTerminate() }
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isDisplayAsleep && !isScreenSaverRunning { break }
            usleep(150_000)
        }

        // A woken display takes a moment to actually have pixels in it. Reading
        // one frame too early is the same black image by another route.
        if wasAsleep { usleep(400_000) }

        return Wake(displayWasAsleep: wasAsleep,
                    screenSaverWasRunning: hadSaver,
                    locked: isScreenLocked,
                    awakeNow: !isDisplayAsleep && !isScreenSaverRunning)
    }

    // MARK: - Staying awake

    /// Holding the display awake, which is the other half of waking it.
    ///
    /// `wakeScreen` recovers a screen that already went dark. This prevents it
    /// going dark in the first place, and for anything long-running that is the
    /// half that matters — because a display that sleeps while nobody is at the
    /// machine usually comes back **locked**, and nothing here can get past a
    /// password prompt. A recoverable problem becomes an unrecoverable one at
    /// whatever point the run happened to reach.
    ///
    /// Delegates to `caffeinate`, the OS's own supported way to take a power
    /// assertion. Two reasons rather than taking `IOPMAssertionCreateWithName`
    /// directly: an assertion only lives as long as the process holding it, and
    /// every `macctl` command exits in milliseconds; and `caffeinate -w` can be
    /// told to release when *another* process exits, so the assertion is tied to
    /// the lifetime of the run and there is nothing to leak if the run crashes.
    /// Where the tool keeps the little state it has between commands: the
    /// caffeinate pid, the origin app. `MACCTL_CACHE_DIR` overrides it so a
    /// test run never reads or clears the real machine's state.
    public static var cacheDirectory: URL {
        let dir: URL
        if let override = ProcessInfo.processInfo.environment["MACCTL_CACHE_DIR"], !override.isEmpty {
            dir = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/macctl", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Origin: where the person was before we started driving

    /// The app that was in front before the first command moved focus.
    ///
    /// Every multi-step flow has the same bookend: capture who is in front,
    /// drive, put them back. Leaving that to the caller means it is forgotten
    /// exactly when the flow gets interesting, so the tool records it itself.
    /// The first focus-changing command in a run writes the record if there is
    /// none; every later one leaves it alone, because focus has to stay on the
    /// app being driven across the steps. `macctl restore` brings the recorded
    /// app forward and clears the record, and that is the whole protocol.
    ///
    /// A record is only believed while the app it names is still running and
    /// it is younger than `maximumAge`. Pids are recycled and a run that
    /// crashed before restoring must not send tomorrow's session back to
    /// yesterday's window.
    public enum Origin {

        public struct Record: Sendable, Equatable {
            public let pid: pid_t
            public let name: String
            public let bundleID: String?
            public let recordedAt: Date

            public init(pid: pid_t, name: String, bundleID: String?, recordedAt: Date) {
                self.pid = pid
                self.name = name
                self.bundleID = bundleID
                self.recordedAt = recordedAt
            }
        }

        /// Older than this, a record is a leftover, not a place to go back to.
        public static let maximumAge: TimeInterval = 12 * 60 * 60

        static var file: URL { System.cacheDirectory.appendingPathComponent("origin.json") }

        /// The decision, separated from the file and the process table so it
        /// can be tested: is this record still worth acting on?
        public static func usable(_ record: Record?, running: (pid_t) -> Bool, now: Date = Date()) -> Record? {
            guard let record else { return nil }
            guard now.timeIntervalSince(record.recordedAt) <= maximumAge, now >= record.recordedAt else { return nil }
            guard running(record.pid) else { return nil }
            return record
        }

        static func load() -> Record? {
            guard let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = object["pid"] as? Int,
                  let name = object["name"] as? String,
                  let stamp = object["recordedAt"] as? String,
                  let recordedAt = ISO8601DateFormatter().date(from: stamp)
            else { return nil }
            return Record(pid: pid_t(pid), name: name, bundleID: object["bundleID"] as? String, recordedAt: recordedAt)
        }

        static func save(_ record: Record) {
            var object: [String: Any] = ["pid": Int(record.pid), "name": record.name,
                                         "recordedAt": ISO8601DateFormatter().string(from: record.recordedAt)]
            if let bundleID = record.bundleID { object["bundleID"] = bundleID }
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
            try? data.write(to: file, options: .atomic)
        }

        static func isRunning(_ pid: pid_t) -> Bool {
            guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
            return !app.isTerminated
        }

        /// The record in force, if any. A stale one is dropped on sight.
        public static func current() -> Record? {
            let record = load()
            let live = usable(record, running: isRunning)
            if record != nil, live == nil { forget() }
            return live
        }

        /// Record `front` as the origin unless one is already in force.
        ///
        /// Call it before changing focus. Returns the record now in force,
        /// which is the existing one when there is one: the origin is where
        /// the person was before the *first* step, not before the latest.
        @discardableResult
        public static func recordIfAbsent(_ front: Geometry.FrontApp?) -> Record? {
            if let existing = current() { return existing }
            guard let front else { return nil }
            let record = Record(pid: front.pid, name: front.name, bundleID: front.bundleID, recordedAt: Date())
            save(record)
            return record
        }

        /// Drop the record without touching focus.
        @discardableResult
        public static func forget() -> Record? {
            let record = load()
            try? FileManager.default.removeItem(at: file)
            return record
        }
    }

    public enum Awake {

        static var pidFile: URL { System.cacheDirectory.appendingPathComponent("awake.pid") }

        /// Is *anything* on this machine currently preventing display sleep?
        ///
        /// Asked of the system rather than of our own pidfile, because the
        /// useful question is whether the screen is safe, not whether we are the
        /// one keeping it safe. A video call or a running build counts.
        public static var displaySleepPrevented: Bool {
            var out: Unmanaged<CFDictionary>?
            guard IOPMCopyAssertionsStatus(&out) == kIOReturnSuccess,
                  let status = out?.takeRetainedValue() as? [String: Int]
            else { return false }
            let held = [
                kIOPMAssertionTypeNoDisplaySleep as String,
                kIOPMAssertionTypePreventUserIdleDisplaySleep as String,
            ]
            return held.contains { (status[$0] ?? 0) > 0 }
        }

        /// The executable behind a pid, if it is still alive.
        static func executable(of pid: pid_t) -> String? {
            var buffer = [CChar](repeating: 0, count: 4 * Int(PATH_MAX))
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            guard length > 0 else { return nil }
            return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }

        /// The `caffeinate` we started, if it is still alive.
        ///
        /// The pid in the file is only believed if that pid is still running
        /// `caffeinate`. Pids are recycled, and after a reboot or a crash the
        /// file can name a process that is now something else entirely; a
        /// release that trusted it would send SIGTERM to a stranger.
        public static var holder: pid_t? {
            guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
                  let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let path = executable(of: pid),
                  URL(fileURLWithPath: path).lastPathComponent == "caffeinate"
            else { return nil }
            return pid
        }

        /// Prevent display and idle sleep.
        ///
        /// Exactly one of `seconds` or `whilePID` should be given. Tying it to a
        /// pid is much the better option for a scripted run: pass the driving
        /// script's own pid and the assertion is released the moment that script
        /// ends, however it ends.
        @discardableResult
        public static func hold(seconds: Int? = nil, whilePID: pid_t? = nil) throws -> pid_t {
            release()
            var arguments = ["-d", "-i"]      // no display sleep, no idle system sleep
            if let whilePID { arguments += ["-w", String(whilePID)] }
            else if let seconds { arguments += ["-t", String(seconds)] }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            let pid = process.processIdentifier
            try? String(pid).write(to: pidFile, atomically: true, encoding: .utf8)
            return pid
        }

        /// Release ours, if we have one. Never touches anyone else's assertion.
        @discardableResult
        public static func release() -> Bool {
            defer { try? FileManager.default.removeItem(at: pidFile) }
            guard let pid = holder else { return false }
            kill(pid, SIGTERM)
            return true
        }
    }

    // MARK: - Launching

    /// A completion result carried out of a callback that Foundation calls on
    /// its own queue.
    private final class ErrorBox: @unchecked Sendable {
        var error: Error?
    }

    /// Ask LaunchServices to open an application by bundle id or by name.
    ///
    /// A bundle id goes straight to `NSWorkspace`. A name goes to `open -a`,
    /// which resolves display names exactly the way Finder does and fails
    /// cleanly when nothing matches, rather than launching a lookalike. There
    /// is no Spotlight query in between: the index can be off, or stale, and
    /// the name is never interpolated into anything.
    static func open(_ name: String) throws {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            let semaphore = DispatchSemaphore(value: 0)
            let box = ErrorBox()
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
                box.error = error
                semaphore.signal()
            }
            semaphore.wait()
            if let failure = box.error { throw SystemError.launchFailed(name, String(describing: failure)) }
            return
        }

        let process = Process()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        do { try process.run() } catch { throw SystemError.launchFailed(name, String(describing: error)) }
        process.waitUntilExit()
        let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            if message.localizedCaseInsensitiveContains("unable to find") {
                throw SystemError.appNotFound(name)
            }
            throw SystemError.launchFailed(name, message.isEmpty ? "open exited \(process.terminationStatus)" : message)
        }
    }

    /// Launch an app by name or bundle id and wait until it has a window.
    ///
    /// Uses LaunchServices rather than Spotlight. Spotlight is routinely
    /// replaced by Raycast or Alfred, can be disabled entirely, and racing
    /// type-ahead against it is a real failure mode. `--via-spotlight` exists as
    /// an explicit fallback for the cases where only the launcher knows the app.
    ///
    /// An app that is already running is brought forward instead. Whether it
    /// actually came to the front is reported in the rect, not enforced: the
    /// job here is a running app with a window. Input commands enforce it.
    @discardableResult
    public static func launch(_ name: String, timeout: TimeInterval = 30) throws -> WindowRect {
        let query = Geometry.AppQuery(name)

        var running = true
        do { _ = try Geometry.resolve(query) }
        catch GeometryError.noMatchingApp { running = false }

        if running {
            do { return try Geometry.activate(query) }
            catch GeometryError.notFrontmost { return try Geometry.windowRect(for: query) }
            catch GeometryError.noOnScreenWindow { /* running without a window yet: wait below */ }
        } else {
            try open(name)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let rect = try? Geometry.windowRect(for: query) {
                return (try? Geometry.activate(query, timeout: 1)) ?? rect
            }
            usleep(300_000)
        }
        throw SystemError.launchFailed(name, "launched but no window appeared within \(Int(timeout))s")
    }

    /// Launch by typing into whatever owns cmd+space.
    public static func launchViaSpotlight(_ name: String, timeout: TimeInterval = 30) throws -> WindowRect {
        try Keyboard.press("cmd+space")
        usleep(600_000)
        try Keyboard.type(name)
        usleep(700_000)
        try Keyboard.press("return")

        let query = Geometry.AppQuery(name)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let rect = try? Geometry.windowRect(for: query), rect.isFrontmost { return rect }
            usleep(300_000)
        }
        throw SystemError.launchFailed(name, "spotlight did not bring up a window within \(Int(timeout))s")
    }

    /// Every running app with a window, for discovery.
    public static func apps() -> [(name: String, bundleID: String, pid: pid_t)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let name = app.localizedName else { return nil }
                return (name, app.bundleIdentifier ?? "", app.processIdentifier)
            }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    // MARK: - Diagnosis

    /// What is working, and what is not.
    ///
    /// Exists because every capability here fails silently when its permission
    /// is missing. A capture returns nothing, a keystroke evaporates, a click
    /// lands nowhere — and the caller sees success. This is the one command that
    /// asks directly.
    public struct Diagnosis: Sendable {
        public let screenRecording: Bool
        public let accessibility: Bool
        public let postEvent: Bool
        public let secureInputActive: Bool
        public let onConsole: Bool
        public let displayAsleep: Bool
        public let screenSaverRunning: Bool
        public let screenLocked: Bool
        public let displaySleepPrevented: Bool

        public var allGood: Bool {
            screenRecording && postEvent && onConsole
                && !secureInputActive && !displayAsleep && !screenSaverRunning && !screenLocked
        }
    }

    /// Can this process post input events at all?
    ///
    /// Checked before every input command, because without the permission a
    /// posted event is accepted and dropped, and the command would otherwise
    /// report that it delivered a click nobody received.
    public static var canPostEvents: Bool { CGPreflightPostEventAccess() }

    public static func doctor() -> Diagnosis {
        Diagnosis(
            screenRecording: CGPreflightScreenCaptureAccess(),
            accessibility: AXIsProcessTrusted(),
            postEvent: canPostEvents,
            secureInputActive: Keyboard.isSecureInputActive,
            onConsole: isOnConsole,
            displayAsleep: isDisplayAsleep,
            screenSaverRunning: isScreenSaverRunning,
            screenLocked: isScreenLocked,
            displaySleepPrevented: Awake.displaySleepPrevented
        )
    }

    public static let settingsURLs: [String: String] = [
        "screenRecording": "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
        "accessibility": "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        "postEvent": "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
    ]
}
