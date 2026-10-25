import Foundation
import MacControlKit

func runSystemTests(_ expect: (Bool, String) -> Void) {
    typealias State = System.WakeState
    let ready = State(displayAsleep: false, screenSaverRunning: false, locked: false)
    let lock = State(displayAsleep: false, screenSaverRunning: false, locked: true)
    let dark = State(displayAsleep: true, screenSaverRunning: false, locked: true)
    let saver = State(displayAsleep: false, screenSaverRunning: true, locked: false)

    func recover(_ states: [State], timeout: TimeInterval = 1) -> (System.Wake, Int, Int, TimeInterval) {
        var index = 0
        var activity = 0
        var dismissals = 0
        var time: TimeInterval = 0
        let result = System.recoverScreen(timeout: timeout, observe: {
            let state = states[min(index, states.count - 1)]
            index += 1
            return state
        }, requestActivity: { activity += 1 }, dismissSaver: { dismissals += 1 },
           now: { time }, pause: { time += $0 })
        return (result, activity, dismissals, time)
    }

    let noop = recover([ready])
    expect(!noop.0.acted && noop.0.awakeNow && !noop.0.locked && noop.1 == 0 && noop.3 == 0,
           "an already usable session neither wakes nor waits")

    let transient = recover([lock, lock, ready])
    expect(transient.0.sessionWasLocked && transient.0.acted && !transient.0.locked,
           "an awake display with a transient lock flag receives normal wake recovery")
    expect(transient.1 == 1 && transient.2 == 0 && transient.3 > 0,
           "lock recovery requests activity once and waits for fresh session evidence")

    let permanent = recover([lock])
    expect(permanent.0.locked && permanent.0.awakeNow && permanent.3 == 1,
           "a persistent lock remains locked at the deadline even with an awake display")

    let failed = recover([dark])
    expect(!failed.0.awakeNow && failed.0.locked && failed.3 == 1,
           "an unsuccessful wake never reports an awake or unlocked session")

    let saverClears = recover([saver, saver, ready])
    expect(saverClears.2 == 1 && saverClears.0.screenSaverWasRunning && saverClears.0.awakeNow,
           "a screen saver is dismissed and then observed until it clears")

    let lateLock = recover([dark, ready, lock])
    expect(lateLock.0.locked && lateLock.0.awakeNow,
           "lock state is refreshed after waiting for display pixels")
    let immediate = recover([lock], timeout: 0)
    expect(immediate.0.locked && immediate.3 == 0,
           "zero timeout requests wake but never invents an unlocked state")
}
