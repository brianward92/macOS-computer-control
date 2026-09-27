import CoreGraphics
import Foundation

/// Synthetic pointer input.
///
/// Three things here are load-bearing and are the reason this is a library
/// rather than five one-liners. Each was learned by watching an automation run
/// fail silently, because a posted event that lands on nothing reports success.
///
/// 1. **Deltas.** Canvas-rendered apps (Unity, for one) read
///    `kCGMouseEventDeltaX/DeltaY` and ignore a move whose delta is zero.
///    Absolute position alone is not enough to make such an app notice the
///    pointer.
/// 2. **Cursor re-association.** `CGWarpMouseCursorPosition` disassociates the
///    hardware mouse from the cursor for roughly 250ms. Posting motion inside
///    that window produces rubber-banding, which looks exactly like a drag that
///    did not take. Every warp is followed immediately by
///    `CGAssociateMouseAndMouseCursorPosition(1)`.
/// 3. **Multi-click.** A double click is not two clicks. The click count goes
///    on `.mouseEventClickState` of *both* the down and the up of the nth pair,
///    with the pairs close enough together to stay inside the system's
///    double-click interval.
public enum Input {

    public enum Approach: String, Sendable { case warp, stepped }
    public enum ScrollUnit: String, Sendable { case line, pixel }
    public enum DragProfile: String, Sendable { case `default`, hid }

    // MARK: - Tunables

    /// Milliseconds the pointer rests on a target before a press, so the app
    /// registers hover. Some apps otherwise treat the press as arriving on
    /// whatever they thought was under the cursor before.
    nonisolated(unsafe) public static var hoverSettleMs: UInt32 = 120
    /// Milliseconds between the down and up of one click.
    nonisolated(unsafe) public static var pressHoldMs: UInt32 = 40
    /// Milliseconds between the pairs of a multi-click. Must stay under the
    /// system double-click interval, which defaults to 500ms.
    nonisolated(unsafe) public static var multiClickGapMs: UInt32 = 30

    // MARK: - Primitives

    /// Where the cursor is now, in screen points, top-left origin.
    public static var cursorPosition: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    /// Post one mouse event, stamped fresh and carrying a delta.
    ///
    /// The timestamp is refreshed immediately before posting: a prebuilt event
    /// carries a stale timestamp, and some targets use it to decide whether two
    /// events belong to the same gesture.
    private static func post(
        _ type: CGEventType,
        at point: CGPoint,
        button: CGMouseButton,
        clickState: Int64? = nil,
        delta: CGPoint? = nil,
        source: CGEventSource? = nil,
        pressure: Double? = nil,
        eventNumber: Int64? = nil
    ) {
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button
        ) else { return }

        if let clickState {
            event.setIntegerValueField(.mouseEventClickState, value: clickState)
        }
        if let delta {
            event.setIntegerValueField(.mouseEventDeltaX, value: Int64(delta.x.rounded()))
            event.setIntegerValueField(.mouseEventDeltaY, value: Int64(delta.y.rounded()))
        }
        if let pressure { event.setDoubleValueField(.mouseEventPressure, value: pressure) }
        if let eventNumber { event.setIntegerValueField(.mouseEventNumber, value: eventNumber) }
        event.timestamp = CGEventTimestamp(DispatchTime.now().uptimeNanoseconds)
        event.post(tap: .cghidEventTap)
    }

    private static func sleepMs(_ ms: UInt32) {
        guard ms > 0 else { return }
        usleep(ms * 1000)
    }

    /// Put the cursor at a point without pretending it was a gesture.
    ///
    /// Warping is what actually relocates the pointer; the follow-up
    /// `mouseMoved` is what tells the app about it, and the re-association is
    /// what stops the next 250ms of motion being fought by the real mouse.
    public static func warp(to point: CGPoint) {
        let from = cursorPosition
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)
        post(.mouseMoved, at: point, button: .left,
             delta: CGPoint(x: point.x - from.x, y: point.y - from.y))
    }

    /// Move the cursor in `steps` increments, so a canvas app sees real motion.
    public static func move(to point: CGPoint, steps: Int = 1) {
        guard steps > 1 else { warp(to: point); return }
        let from = cursorPosition
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let next = CGPoint(x: from.x + (point.x - from.x) * t,
                               y: from.y + (point.y - from.y) * t)
            let prev = cursorPosition
            post(.mouseMoved, at: next, button: .left,
                 delta: CGPoint(x: next.x - prev.x, y: next.y - prev.y))
            sleepMs(12)
        }
    }

    // MARK: - Clicks

    public enum Button: String, Sendable {
        case left, right

        var cg: CGMouseButton { self == .left ? .left : .right }
        var down: CGEventType { self == .left ? .leftMouseDown : .rightMouseDown }
        var up: CGEventType { self == .left ? .leftMouseUp : .rightMouseUp }
        var dragged: CGEventType { self == .left ? .leftMouseDragged : .rightMouseDragged }
    }

    /// Click `count` times at a point. `count: 2` is a real double click.
    ///
    /// Approaches with motion first so hover registers, then posts each pair
    /// with the running click count on both the down and the up.
    public static func click(
        at point: CGPoint,
        button: Button = .left,
        count: Int = 1,
        approach: Approach? = .warp,
        hoverMs: UInt32? = nil
    ) {
        if let approach {
            if approach == .stepped { move(to: point, steps: 10) } else { warp(to: point) }
            sleepMs(hoverMs ?? hoverSettleMs)
        }
        let count = max(1, count)
        for n in 1...count {
            post(button.down, at: point, button: button.cg, clickState: Int64(n))
            sleepMs(pressHoldMs)
            post(button.up, at: point, button: button.cg, clickState: Int64(n))
            if n < count { sleepMs(multiClickGapMs) }
        }
    }

    /// Press and hold, without releasing. Pair with `release`.
    ///
    /// Needed for Dock menus: the menu opens on the press and the selection is
    /// made by moving while still held, then releasing over the item.
    public static func press(at point: CGPoint, button: Button = .left) {
        warp(to: point)
        sleepMs(hoverSettleMs)
        post(button.down, at: point, button: button.cg, clickState: 1)
    }

    /// Release a held button at a point, dragging to it first.
    public static func release(at point: CGPoint, button: Button = .left, steps: Int = 12) {
        drag(to: point, button: button, steps: steps)
        post(button.up, at: point, button: button.cg, clickState: 1)
    }

    /// Move while a button is held. Posts `mouseDragged`, not `mouseMoved`.
    public static func drag(to point: CGPoint, button: Button = .left, steps: Int = 12) {
        let from = cursorPosition
        let steps = max(1, steps)
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let next = CGPoint(x: from.x + (point.x - from.x) * t,
                               y: from.y + (point.y - from.y) * t)
            let prev = cursorPosition
            post(button.dragged, at: next, button: button.cg, clickState: 1,
                 delta: CGPoint(x: next.x - prev.x, y: next.y - prev.y))
            sleepMs(16)
        }
    }

    /// Press at one point, move in small steps, release at another.
    ///
    /// The release is in a `defer` so a throw part-way through cannot leave the
    /// desktop stuck mid-drag with the button held.
    public static func dragAndDrop(
        from source: CGPoint,
        to target: CGPoint,
        button: Button = .left,
        steps: Int = 24,
        settleMs: UInt32 = 220,
        profile: DragProfile = .default
    ) {
        var lastPoint = source
        let eventSource = profile == .hid ? CGEventSource(stateID: .hidSystemState) : nil
        let eventNumber = Int64(DispatchTime.now().uptimeNanoseconds & 0x7fff_ffff)
        if profile == .hid { move(to: source, steps: 10) } else { warp(to: source) }
        sleepMs(profile == .hid ? 500 : settleMs)
        post(button.down, at: source, button: button.cg, clickState: 1,
             source: eventSource, pressure: profile == .hid ? 1 : nil,
             eventNumber: profile == .hid ? eventNumber : nil)
        defer {
            post(button.up, at: lastPoint, button: button.cg, clickState: 1,
                 source: eventSource, pressure: profile == .hid ? 0 : nil,
                 eventNumber: profile == .hid ? eventNumber : nil)
        }
        sleepMs(160)
        if profile == .hid {
            for offset in 1...3 {
                let next = CGPoint(x: source.x + CGFloat(offset), y: source.y)
                post(button.dragged, at: next, button: button.cg, clickState: 1,
                     delta: CGPoint(x: 1, y: 0), source: eventSource, pressure: 1,
                     eventNumber: eventNumber)
                lastPoint = next
                sleepMs(16)
            }
        }
        let steps = max(1, steps)
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let next = CGPoint(x: source.x + (target.x - source.x) * t,
                               y: source.y + (target.y - source.y) * t)
            post(button.dragged, at: next, button: button.cg, clickState: 1,
                 delta: CGPoint(x: next.x - lastPoint.x, y: next.y - lastPoint.y),
                 source: eventSource, pressure: profile == .hid ? 1 : nil,
                 eventNumber: profile == .hid ? eventNumber : nil)
            lastPoint = next
            sleepMs(16)
        }
        sleepMs(160)
    }

    // MARK: - Scrolling

    /// Scroll at a point. Negative lines scroll down.
    public static func scroll(at point: CGPoint, lines: Int32, unit: CGScrollEventUnit = .line) {
        warp(to: point)
        sleepMs(80)
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil, units: unit,
            wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0
        ) else { return }
        event.location = point
        event.timestamp = CGEventTimestamp(DispatchTime.now().uptimeNanoseconds)
        event.post(tap: .cghidEventTap)
    }

    /// Split a scroll distance into `steps` integer parts that sum to exactly
    /// the total. The remainder goes on the last step, so a gesture never
    /// travels further or shorter than asked.
    public static func distribute(_ total: Int32, over steps: Int) -> [Int32] {
        let steps = max(1, steps)
        let base = total / Int32(steps)
        var parts = Array(repeating: base, count: steps)
        parts[steps - 1] += total - base * Int32(steps)
        return parts
    }

    /// Trackpad-shaped pixel scrolling: a began phase, `steps` changed phases
    /// carrying the distance, and an ended phase, the way the hardware does it.
    public static func scrollTrackpad(at point: CGPoint, vertical: Int32, horizontal: Int32 = 0, steps: Int = 6) {
        warp(to: point)
        sleepMs(80)

        func post(phase: Int64, dy: Int32, dx: Int32) {
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                      wheel1: dy, wheel2: dx, wheel3: 0)
            else { return }
            event.location = point
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy))
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx))
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            event.timestamp = CGEventTimestamp(DispatchTime.now().uptimeNanoseconds)
            event.post(tap: .cghidEventTap)
        }

        let began: Int64 = 1, changed: Int64 = 2, ended: Int64 = 4
        let vertical = distribute(vertical, over: steps)
        let horizontal = distribute(horizontal, over: steps)
        post(phase: began, dy: 0, dx: 0)
        sleepMs(12)
        for (dy, dx) in zip(vertical, horizontal) {
            post(phase: changed, dy: dy, dx: dx)
            sleepMs(12)
        }
        post(phase: ended, dy: 0, dx: 0)
    }
}
