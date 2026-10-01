import CoreGraphics
import Foundation

/// Did it actually happen?
///
/// Three answers, not two, plus a refusal. This is the whole point of the
/// library.
///
/// A synthetic click that lands on nothing reports success — the OS does not
/// know, the target app does not say, and `CGEvent.post` returns nothing. So
/// "I posted the event" is never evidence that anything happened, and the only
/// honest answer some of the time is that we could not tell.
///
/// Conflating "could not observe" with "did not happen" is what turns a flaky
/// reading into a wrong decision. Measured on this machine: searching for an
/// **animated** button label found it in 39 of 45 attempts, while a static
/// label was found 45 times out of 45. A single miss on an animated control is
/// not absence, it is a miss.
public enum Outcome: Sendable, Equatable {
    case satisfied
    case unsatisfied
    /// Could not observe. The reason is mandatory, because an unexplained
    /// unknown is indistinguishable from a bug in the checker.
    case unknown(reason: String)
    /// Would not act: no such app, an ambiguous name, no window, or a window
    /// that could not be brought to the front. Nothing was done.
    case refused(reason: String)

    public var exitCode: Int32 {
        switch self {
        case .satisfied: return 0
        case .unsatisfied: return 1
        case .unknown: return 2
        case .refused: return 4
        }
    }

    public var label: String {
        switch self {
        case .satisfied: return "satisfied"
        case .unsatisfied: return "unsatisfied"
        case .unknown(let reason): return "unknown: \(reason)"
        case .refused(let reason): return "refused: \(reason)"
        }
    }
}

public enum Verify {

    /// How many consecutive misses before absence is believed.
    ///
    /// Derived from measurement, not taste: an animated control was missed on
    /// roughly one read in eight, so one miss proves nothing and three
    /// consecutive misses put the odds of a false negative under one in five
    /// hundred.
    nonisolated(unsafe) public static var missesBeforeAbsent = 3

    /// Interval between samples.
    nonisolated(unsafe) public static var sampleIntervalMs: UInt32 = 120

    /// Why an app could not be looked at, and whether waiting can help.
    public enum Obstacle: Sendable, Equatable {
        /// No window on screen yet, or not at the front. Often clears within
        /// a moment: a sheet closing, a launch finishing, a Space switching.
        case window
        /// Not running. Clears only if something launches it.
        case notRunning
        /// The name means more than one app. Waiting cannot fix it.
        case ambiguous
    }

    /// What one look at the screen produced.
    ///
    /// The decision logic below is written against this rather than against
    /// the screen, so it can be exercised with a scripted sequence of looks.
    public enum Look: Sendable, Equatable {
        /// The text was seen, at these points, one per place it was seen.
        case seen([CGPoint])
        /// The screen was read and the text was not on it.
        case absent
        /// The screen could not be read. Not evidence of anything.
        case failed(String)
        /// The app could not be addressed.
        case refused(String, Obstacle)
    }

    private static func pause(_ ms: UInt32) async {
        guard ms > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
    }

    /// Is it there? Asymmetric on purpose.
    ///
    /// Finding it once is good evidence — no false positives were observed in
    /// measurement. *Not* finding it once is not evidence of anything, so
    /// absence has to survive `looks` consecutive misses before it is reported,
    /// and if the looks themselves fail the answer is unknown.
    public static func presence(
        looks: Int = missesBeforeAbsent,
        pauseMs: UInt32 = sampleIntervalMs,
        look: () async -> Look
    ) async -> Outcome {
        let looks = max(1, looks)
        var misses = 0
        var lastError: String?
        for attempt in 0..<looks {
            switch await look() {
            case .seen: return .satisfied
            case .absent: misses += 1
            case .failed(let why): lastError = why
            case .refused(let why, _): return .refused(reason: why)
            }
            if attempt + 1 < looks { await pause(pauseMs) }
        }
        if misses == 0 {
            return .unknown(reason: lastError ?? "every observation attempt failed")
        }
        if let lastError, misses < looks {
            return .unknown(reason: "only \(misses) of \(looks) looks succeeded; last error: \(lastError)")
        }
        return .unsatisfied
    }

    /// Does it appear before the deadline? Returns as soon as it does.
    ///
    /// A failed look, a missing window or an app that is not running yet is
    /// not an answer here — that is exactly what a caller waiting after a
    /// launch expects — so looking continues until the deadline. Only an
    /// ambiguous name stops the wait, because no amount of waiting fixes it.
    /// If nothing was ever observed the answer is unknown, with the last
    /// reason attached.
    public static func appearance(
        timeout: TimeInterval,
        pauseMs: UInt32 = sampleIntervalMs,
        look: () async -> Look
    ) async -> Outcome {
        let deadline = Date().addingTimeInterval(timeout)
        var everObserved = false
        var lastProblem: String?
        repeat {
            switch await look() {
            case .seen: return .satisfied
            case .absent: everObserved = true
            case .failed(let why): lastProblem = why
            case .refused(let why, .ambiguous): return .refused(reason: why)
            case .refused(let why, _): lastProblem = why
            }
            await pause(pauseMs)
        } while Date() < deadline
        if everObserved { return .unsatisfied }
        let detail = lastProblem.map { "; last problem: \($0)" } ?? ""
        return .unknown(reason: "never managed to observe the window before the timeout\(detail)")
    }

    /// Does it disappear before the deadline? Returns as soon as it is gone.
    ///
    /// The mirror of `appearance`, and the honest way to confirm an action
    /// took: after clicking Done, wait for the sheet's own text to vanish,
    /// rather than checking something behind it that was there all along. A
    /// single missed look is not "gone" — the same flakiness that makes one
    /// sighting weak makes one absence weak — so it takes `needed` consecutive
    /// absences, and any sighting resets the count.
    public static func disappearance(
        timeout: TimeInterval,
        needed: Int = missesBeforeAbsent,
        pauseMs: UInt32 = sampleIntervalMs,
        look: () async -> Look
    ) async -> Outcome {
        let deadline = Date().addingTimeInterval(timeout)
        let needed = max(1, needed)
        var absences = 0
        var everObserved = false
        var lastProblem: String?
        repeat {
            switch await look() {
            case .seen:
                everObserved = true
                absences = 0
            case .absent:
                everObserved = true
                absences += 1
                if absences >= needed { return .satisfied }
            case .failed(let why):
                lastProblem = why
                absences = 0
            case .refused(let why, .ambiguous):
                return .refused(reason: why)
            case .refused(let why, _):
                lastProblem = why
                absences = 0
            }
            await pause(pauseMs)
        } while Date() < deadline
        if everObserved { return .unsatisfied }
        let detail = lastProblem.map { "; last problem: \($0)" } ?? ""
        return .unknown(reason: "never managed to observe the window before the timeout\(detail)")
    }

    /// Where is it, so that it can be acted on? Refuses to guess.
    ///
    /// With no timeout this is a single look, and a single miss is reported as
    /// unknown rather than absent, because that is what a single miss is. With
    /// a timeout, looking continues until the deadline — through failed
    /// captures and a window that is missing or not yet at the front, which
    /// are the transitions the timeout exists to ride out. An app that is not
    /// running, or a name that is ambiguous, is refused at once: waiting out
    /// the whole timeout on those is dead air, and the caller's mistake is
    /// better reported immediately. More than one match is always a refusal to
    /// guess: a wrong click is worse than no click, and it does not announce
    /// itself.
    public static func target(
        _ what: String,
        timeout: TimeInterval,
        pauseMs: UInt32 = sampleIntervalMs,
        look: () async -> Look
    ) async -> (Outcome, CGPoint?) {
        let deadline = Date().addingTimeInterval(timeout)
        var everObserved = false
        var lastProblem: String?
        repeat {
            switch await look() {
            case .seen(let points):
                guard points.count == 1, let point = points.first else {
                    return (.unknown(reason: "\"\(what)\" matched \(points.count) places; refusing to guess which"), nil)
                }
                return (.satisfied, point)
            case .absent:
                everObserved = true
                if timeout <= 0 {
                    return (.unknown(reason: "did not find \"\(what)\" on this look; a single miss is not absence"), nil)
                }
            case .failed(let why):
                lastProblem = why
                if timeout <= 0 { return (.unknown(reason: why), nil) }
            case .refused(let why, .window):
                lastProblem = why
                if timeout <= 0 { return (.refused(reason: why), nil) }
            case .refused(let why, _):
                return (.refused(reason: why), nil)
            }
            await pause(pauseMs)
        } while Date() < deadline
        if everObserved { return (.unsatisfied, nil) }
        if let lastProblem { return (.refused(reason: lastProblem), nil) }
        return (.unknown(reason: "never managed to observe the window before the timeout"), nil)
    }

    // MARK: - Looking at a real window

    /// A region given as fractions of a window, mapped onto this rect.
    static func liveRegion(_ rect: WindowRect, region: CGRect?, fractions: CGRect?) -> CGRect? {
        if let region { return region }
        guard let f = fractions else { return nil }
        return CGRect(x: rect.x + f.minX * rect.width, y: rect.y + f.minY * rect.height,
                      width: f.width * rect.width, height: f.height * rect.height)
    }

    /// One look for `needle` in the app's window, geometry read now.
    static func look(
        for needle: String,
        app: Geometry.AppQuery,
        region: CGRect?,
        fractions: CGRect?,
        activating: Bool,
        observedWindow: ((WindowRect) -> Void)? = nil
    ) async -> Look {
        let rect: WindowRect
        do {
            rect = activating ? try Geometry.activate(app) : try Geometry.windowRect(for: app)
        } catch let error as GeometryError {
            let why = String(describing: error)
            switch error {
            case .windowListUnavailable: return .failed(why)
            case .noMatchingApp: return .refused(why, .notRunning)
            case .ambiguousApp: return .refused(why, .ambiguous)
            case .noOnScreenWindow, .notFrontmost: return .refused(why, .window)
            }
        } catch {
            return .failed(String(describing: error))
        }
        let live = liveRegion(rect, region: region, fractions: fractions)
        switch await Capture.windowResilient(rect.windowID, rect: rect.bounds, region: live) {
        case .success(let shot):
            do {
                let hits = try Text.find(needle, in: shot)
                observedWindow?(rect)
                return hits.isEmpty ? .absent : .seen(hits.map(\.center))
            } catch {
                return .failed(String(describing: error))
            }
        case .failure(let error):
            return .failed(String(describing: error))
        }
    }

    /// Is this text on screen, in the app's window?
    public static func textPresent(
        _ needle: String,
        app: Geometry.AppQuery,
        region: CGRect? = nil,
        regionFractions: CGRect? = nil
    ) async -> Outcome {
        await presence {
            await look(for: needle, app: app, region: region, fractions: regionFractions, activating: false)
        }
    }

    /// Wait for text to appear. Returns as soon as it does.
    public static func waitForText(
        _ needle: String,
        app: Geometry.AppQuery,
        timeout: TimeInterval = 30,
        region: CGRect? = nil,
        regionFractions: CGRect? = nil
    ) async -> Outcome {
        await appearance(timeout: timeout) {
            await look(for: needle, app: app, region: region, fractions: regionFractions, activating: false)
        }
    }

    /// Wait for text to disappear. Returns as soon as it is gone.
    public static func waitUntilGone(
        _ needle: String,
        app: Geometry.AppQuery,
        timeout: TimeInterval = 30,
        region: CGRect? = nil,
        regionFractions: CGRect? = nil
    ) async -> Outcome {
        await disappearance(timeout: timeout) {
            await look(for: needle, app: app, region: region, fractions: regionFractions, activating: false)
        }
    }

    /// Deliver an observed target only while its window still matches.
    ///
    /// Check before pointer preparation and again immediately before the press:
    /// capture/OCR and hover settling both give focus or geometry time to change.
    /// The callbacks keep this race check testable without posting real input.
    /// `click` must post directly, without another approach or hover delay.
    public static func clickObservedTarget(
        at point: CGPoint,
        window observed: WindowRect,
        readWindow: () throws -> WindowRect,
        prepare: (CGPoint) -> Void,
        click: (CGPoint) -> Void
    ) -> Outcome {
        func check() -> Outcome? {
            do {
                let current = try readWindow()
                guard current.pid == observed.pid, current.windowID == observed.windowID,
                      current.bounds == observed.bounds else {
                    return .refused(reason: "target window changed after text was read; no click sent")
                }
                guard current.isFrontmost else {
                    return .refused(reason: "target window lost focus after text was read; no click sent")
                }
            } catch GeometryError.windowListUnavailable {
                return .unknown(reason: "could not recheck the target window; no click sent")
            } catch let error as GeometryError {
                return .refused(reason: "\(error); no click sent")
            } catch {
                return .unknown(reason: "could not recheck the target window: \(error); no click sent")
            }
            return nil
        }
        if let problem = check() { return problem }
        prepare(point)
        if let problem = check() { return problem }
        click(point)
        return .satisfied
    }

    /// Find text and click it, rechecking the observed window after OCR and hover.
    /// A changed window is refused without reactivating it or using stale points.
    @discardableResult
    public static func clickText(
        _ needle: String,
        app: Geometry.AppQuery,
        button: Input.Button = .left,
        count: Int = 1,
        timeout: TimeInterval = 0,
        region: CGRect? = nil,
        regionFractions: CGRect? = nil
    ) async -> (Outcome, CGPoint?) {
        var observed: WindowRect?
        let (outcome, point) = await target(needle, timeout: timeout) {
            await look(for: needle, app: app, region: region, fractions: regionFractions,
                       activating: true, observedWindow: { observed = $0 })
        }
        guard let point else { return (outcome, nil) }
        guard let observed else {
            return (.unknown(reason: "target window was not recorded; no click sent"), nil)
        }
        let delivered = clickObservedTarget(at: point, window: observed,
            readWindow: { try Geometry.windowRect(for: app) },
            prepare: { point in
                Input.warp(to: point)
                usleep(Input.hoverSettleMs * 1000)
            },
            click: { Input.click(at: $0, button: button, count: count, approach: nil) })
        return (delivered, delivered == .satisfied ? point : nil)
    }
}
