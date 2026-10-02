import AppKit
import CoreGraphics
import Foundation
import MacControlKit

// macctl — drive a Mac from a shell, and know whether it worked.
//
// Contract, in priority order:
//   * Exit codes are the API. 0 satisfied, 1 unsatisfied, 2 unknown/usage,
//     3 refused on a precondition, 4 refused before mutating anything.
//   * One JSON object per line on stdout. Human text goes to stderr.
//   * Every geometry-dependent result echoes the live rect it used and when it
//     read it, so a stale rect is a log line rather than a lost evening.
//
// The command table below is the single source of truth: the usage text, the
// flag parser and `help --json` are all generated from it, so they cannot
// disagree.

// MARK: - the contract, as data

/// A flag a command accepts. `value` is the placeholder shown in usage; nil
/// means the flag is boolean.
struct Flag: Sendable {
    let name: String
    let value: String?
    let choices: [String]
    let fallback: String?
    let summary: String

    init(_ name: String, value: String? = nil, choices: [String] = [], fallback: String? = nil, summary: String) {
        self.name = name
        self.value = value
        self.choices = choices
        self.fallback = fallback
        self.summary = summary
    }

    var option: Arguments.Option { Arguments.Option(name, takesValue: value != nil) }
    var usage: String { "--" + name + (value.map { " " + $0 } ?? "") }
}

struct Command: Sendable {
    let name: String
    let positionals: [String]
    let summary: String
    let flags: [Flag]
    /// Everything after the command is text, never flags.
    let raw: Bool

    init(_ name: String, _ positionals: [String] = [], summary: String, flags: [Flag] = [], raw: Bool = false) {
        self.name = name
        self.positionals = positionals
        self.summary = summary
        self.flags = flags
        self.raw = raw
    }

    var synopsis: String {
        (["macctl", name] + positionals + flags.map { "[\($0.usage)]" }).joined(separator: " ")
    }
}

let regionFlag = Flag("region", value: "fx,fy,fw,fh",
                      summary: "only this part of the window, as fractions: x,y,width,height")
let screenFlag = Flag("screen", summary: "the main display instead of an app's window")
let buttonFlag = Flag("button", value: "left|right", choices: ["left", "right"], fallback: "left",
                      summary: "which button")
let countFlag = Flag("count", value: "N", fallback: "1", summary: "clicks; 2 is a real double click")
let appFlag = Flag("app", value: "<app>",
                   summary: "bring this app to the front first; refuse if it will not come")
let controlFlags = [
    Flag("scope", value: "app|window", choices: ["app", "window"], fallback: "app",
         summary: "search the whole app or only its focused accessible window"),
    Flag("role", value: "AXRole", summary: "require this exact accessibility role"),
    Flag("identifier", value: "ID", summary: "require this exact app-provided accessibility identifier"),
    Flag("match", value: "TEXT", summary: "match a control's label or current value"),
    Flag("exact", summary: "require a whole label or value; disable substring fallback"),
]

let commands: [Command] = [
    Command("doctor", summary: "what is permitted and what is not"),
    Command("apps", summary: "running apps with windows"),
    Command("awake", summary: "stop the display sleeping during a long run", flags: [
        Flag("while-pid", value: "N", summary: "hold until process N exits (preferred)"),
        Flag("seconds", value: "N", summary: "hold for N seconds"),
        Flag("off", summary: "release our hold"),
        Flag("status", summary: "is anything holding the display awake"),
    ]),
    Command("launch", ["<app>"], summary: "launch, or bring forward, and wait for a window", flags: [
        Flag("via-spotlight", summary: "type into whatever owns cmd+space instead"),
        Flag("timeout", value: "S", fallback: "30", summary: "how long to wait for a window"),
    ]),
    Command("window", ["<app>"], summary: "live rect, always read now"),
    Command("front", summary: "which app is frontmost now, and where restore will land"),
    Command("focus", ["<app>"], summary: "bring an app to the front and stop"),
    Command("restore", summary: "bring back the app that was in front before the first focus change, and clear the record", flags: [
        Flag("forget", summary: "clear the record without moving focus, when the task was meant to land them elsewhere"),
    ]),
    Command("browser", ["<app>"], summary: "observe browser window, committed page URL, address text and tabs via accessibility"),
    Command("navigate", ["<app>", "<url>"], summary: "open a URL using browser policy, then wait for stable app text; may open a new tab", flags: [
        Flag("timeout", value: "S", fallback: "15", summary: "give up waiting for the page after this long"),
    ]),
    Command("wait-idle", ["<app>"], summary: "return the instant an app's text stops changing, instead of a fixed sleep", flags: [
        Flag("timeout", value: "S", fallback: "10", summary: "give up after this long"),
    ]),
    Command("move", ["<app>", "<fx>", "<fy>"], summary: "move the pointer; fractions of the window"),
    Command("click", ["<app>", "<fx>", "<fy>"], summary: "click; verified:false, delivery is not proof", flags: [
        countFlag, buttonFlag,
        Flag("hover-ms", value: "N", fallback: "120", summary: "rest on the target before pressing"),
        Flag("approach", value: "warp|stepped", choices: ["warp", "stepped"], fallback: "warp",
             summary: "jump there, or arrive with motion"),
    ]),
    Command("drag", ["<app>", "<fx1>", "<fy1>", "<fx2>", "<fy2>"], summary: "press, move in steps, release", flags: [
        Flag("steps", value: "N", fallback: "24", summary: "intermediate motion events"),
        buttonFlag,
        Flag("profile", value: "default|hid", choices: ["default", "hid"], fallback: "default",
             summary: "hid mimics a physical mouse more closely"),
    ]),
    Command("press", ["<app>", "<fx>", "<fy>"], summary: "hold the button down; do not release", flags: [buttonFlag]),
    Command("release", ["<app>", "<fx>", "<fy>"], summary: "move there while held, then release", flags: [buttonFlag]),
    Command("scroll", ["<app>", "<fx>", "<fy>", "<amount>"], summary: "scroll; negative is down", flags: [
        Flag("unit", value: "line|pixel", choices: ["line", "pixel"], fallback: "line", summary: "what amount counts"),
        Flag("trackpad", summary: "trackpad-shaped gesture with phases"),
    ]),
    Command("dock list", summary: "Dock icons and where they are"),
    Command("dock menu", ["<app>", "<item>"], summary: "right-click a Dock icon, pick a menu item"),
    Command("key", ["<chord>"], summary: "press a chord: cmd+q, cmd+shift+4, escape", flags: [appFlag]),
    Command("type", ["<text>..."], summary: "type literal text; everything after --app is text", flags: [appFlag], raw: true),
    Command("shot", ["<app>|--screen"], summary: "capture to a PNG", flags: [
        screenFlag,
        Flag("out", value: "FILE", fallback: "$TMPDIR/macctl-shot.png", summary: "where to write it; the default is private to your user"),
        regionFlag,
    ]),
    Command("read", ["<app>|--screen"], summary: "every text line, with click points", flags: [
        screenFlag, regionFlag,
        Flag("boxes", summary: "unmerged: one entry per text box, each with its own centre"),
    ]),
    Command("find", ["<app>|--screen", "<text>"], summary: "where a piece of text is; one look", flags: [
        screenFlag, regionFlag,
        Flag("boxes", summary: "accepted for symmetry with read; matching always checks boxes and lines"),
    ]),
    Command("click-text", ["<app>", "<text>"], summary: "find it, check it is unique, click it", flags: [
        regionFlag,
        Flag("timeout", value: "S", fallback: "0", summary: "keep looking this long; 0 is a single look"),
        buttonFlag, countFlag,
    ]),
    Command("verify", ["<app>", "<text>"], summary: "is this text on screen? absence needs three misses", flags: [regionFlag]),
    Command("wait-for", ["<app>", "<text>"], summary: "wait for text to appear, or with --gone to disappear", flags: [
        Flag("timeout", value: "S", fallback: "30", summary: "give up after this long"),
        Flag("gone", summary: "wait for the text to disappear instead — verify a sheet or dialog closed"),
        regionFlag,
    ]),
    Command("text", ["<app>"], summary: "read an app's text: accessibility first, OCR only as fallback", flags: [
        screenFlag,
        Flag("out", value: "FILE", summary: "write the text to a file instead of returning it inline"),
        Flag("ocr", summary: "force the OCR path, skipping accessibility"),
        Flag("min-chars", value: "N", fallback: "40", summary: "below this, accessibility is treated as empty and OCR takes over"),
        regionFlag,
    ]),
    Command("controls", ["<app>"], summary: "discover accessibility controls with identifiers and optional scope/filters", flags: controlFlags),
    Command("activate", ["<app>", "[<control>]"], summary: "press one accessibility control selected by label, role or identifier", flags: controlFlags),
    Command("set-value", ["<app>", "<value>"], summary: "set one accessibility text field directly and read its value back", flags: controlFlags),
    Command("choose", ["<app>", "<popup>", "<value>"], summary: "set a popup menu to a value through accessibility"),
    Command("help", summary: "this text", flags: [
        Flag("json", summary: "the whole contract, machine readable"),
    ]),
]

let exitCodes: [String: String] = [
    "0": "satisfied",
    "1": "unsatisfied: acted, observed, it did not happen",
    "2": "unknown: could not observe (with a reason), or bad usage",
    "3": "refused: precondition (permission, secure input, locked screen, no console)",
    "4": "refused before mutating: no such app, ambiguous app, no window, could not bring to front",
]

let notes: [String] = [
    "Coordinates are fractions of the target window, top-left origin, so a command keeps working when the window moves. Geometry is read live inside every command and echoed back with readAt; never cache a rect.",
    "Input commands report verified:false. A posted event that lands on nothing reports success, so follow anything that matters with verify, wait-for or click-text.",
    "Exit 2 is 'could not observe', not 'did not happen'. Reading an animated control misses roughly one look in eight, so verify reports absence only after three consecutive misses.",
    "An app name is a bundle id, an exact name, or a substring of a name that matches exactly one running app. A substring matching several is refused (exit 4).",
    "The app's window is its front on-screen window. Input commands bring the app to the front first and refuse (exit 4) if it will not come.",
    "Use controls --scope window for focused discovery without the app's menus and other windows. Reuse the same scope and selectors for activate or set-value. Identifiers are supplied by the app and may be absent or duplicated; ambiguous selections are refused.",
    "browser observes the committed page URL separately from editable address text. Tab indices and identifiers are observations, not durable handles. Missing browser attributes are reported as unknown, never inferred from typed text.",
    "navigate follows the browser's external-open policy and may create a tab. settled means only app text stopped changing, not that the requested page or application data loaded. Check browser and an expected page condition.",
    "--screen reads the main display instead of a window. Anything outside the app — a system dialog, a Screen Time shield, the Dock — is only found this way.",
    "--region crops to a fraction of the window before reading. Text boxes sharing a row are merged into one line with no horizontal limit, so a whole-window read welds a row of items into one string; use --region or read --boxes for anything laid out in a row.",
    "Flags are --name or --name=value. Anything after a bare -- is positional. Unknown flags are errors, not ignored.",
    "key and type send keystrokes to whatever is in front. Give --app to bring the intended app to the front first and refuse if it will not come; for type, --app must come first and everything after it is text.",
    "click-text --timeout rides out UI transitions of a running app: a missing window or one not yet at the front is retried until the deadline. An app that is not running, or an ambiguous name, is refused at once. wait-for keeps waiting for an app to start.",
    "Every command wakes a dark display first and reports it as wokeScreen. A locked screen is reported, never worked around.",
    "Before a long unattended run: macctl awake --while-pid $$. A display that sleeps mid-run comes back locked, and nothing here can get past a password prompt.",
    "The first command that moves focus records which app was in front; later ones leave that record alone. Finish every run with macctl restore, which brings that app back and clears the record. front and doctor report the record as origin.",
]

func padded(_ text: String, to width: Int) -> String {
    text.count >= width ? text + "  " : text + String(repeating: " ", count: width - text.count)
}

var usage: String {
    var lines = ["macctl — drive a Mac from a shell, and know whether it worked", ""]
    for command in commands {
        let head = "  " + (["macctl", command.name] + command.positionals).joined(separator: " ")
        lines.append(padded(head, to: 42) + command.summary)
        for flag in command.flags {
            let fallback = flag.fallback.map { " (default \($0))" } ?? ""
            lines.append(padded("      " + flag.usage, to: 42) + flag.summary + fallback)
        }
    }
    lines.append("")
    lines.append("exit codes")
    for code in exitCodes.keys.sorted() {
        lines.append(padded("  " + code, to: 6) + exitCodes[code]!)
    }
    lines.append("")
    for note in notes {
        lines.append(wrap(note, width: 78))
    }
    return lines.joined(separator: "\n")
}

func wrap(_ text: String, width: Int) -> String {
    var lines: [String] = []
    var current = ""
    for word in text.split(separator: " ") {
        if current.isEmpty {
            current = String(word)
        } else if current.count + 1 + word.count > width {
            lines.append(current)
            current = String(word)
        } else {
            current += " " + word
        }
    }
    if !current.isEmpty { lines.append(current) }
    return lines.joined(separator: "\n") + "\n"
}

func contract() -> [String: Any] {
    [
        "ok": true,
        "commands": commands.map(\.name),
        "spec": commands.map { command -> [String: Any] in
            [
                "name": command.name,
                "usage": command.synopsis,
                "summary": command.summary,
                "positionals": command.positionals,
                "rawText": command.raw,
                "flags": command.flags.map { flag -> [String: Any] in
                    var entry: [String: Any] = ["name": flag.name, "takesValue": flag.value != nil, "summary": flag.summary]
                    if let value = flag.value { entry["value"] = value }
                    if !flag.choices.isEmpty { entry["choices"] = flag.choices }
                    if let fallback = flag.fallback { entry["default"] = fallback }
                    return entry
                },
            ]
        },
        "exitCodes": exitCodes,
        "coordinates": "fractions of the target window, top-left origin, screen points",
        "output": [
            "stdout": "one JSON object per line, schema 1; human text goes to stderr",
            "verified": "input commands report verified:false; delivery is not proof",
            "window": "geometry-dependent results echo the live rect used and when it was read",
            "wokeScreen": "present when the display had to be woken before the command ran",
            "origin": "on front and doctor: the app recorded as in front before the first focus change, or null; macctl restore returns to it",
        ],
        "notes": notes,
    ]
}

// MARK: - plumbing

/// Set once, before dispatch, if the screen had to be woken. Reported on every
/// result rather than done silently: a command that quietly slept for a second
/// waiting for pixels should say why.
var wakeReport: [String: Any]?

@MainActor
func emit(_ object: [String: Any]) {
    var merged = object.merging(["schema": 1]) { a, _ in a }
    if let wakeReport { merged["wokeScreen"] = wakeReport }
    guard JSONSerialization.isValidJSONObject(merged),
          let data = try? JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys]),
          let line = String(data: data, encoding: .utf8)
    else {
        print(#"{"error":"result could not be serialised","ok":false,"schema":1}"#)
        return
    }
    print(line)
}

func note(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

@MainActor
func fail(_ message: String, code: Int32) -> Never {
    emit(["ok": false, "error": message])
    note("macctl: " + message)
    exit(code)
}

/// The exit code an error earns, by what kind of failure it is.
///
/// Every error type in the library says which of the contract's rows it
/// belongs to. A capture that timed out is "could not observe" (2); a missing
/// permission is a refused precondition (3); an app that is not running, or
/// two apps that both match, is a refusal before anything happened (4).
func exitCode(for error: Error) -> Int32 {
    switch error {
    case let e as GeometryError:
        if case .windowListUnavailable = e { return 2 }
        return 4
    case let e as Capture.CaptureError:
        if case .screenRecordingDenied = e { return 3 }
        return 2
    case let e as Keyboard.KeyboardError:
        if case .secureInputActive = e { return 3 }
        return 2
    case let e as System.SystemError:
        switch e {
        case .appNotFound: return 4
        case .launchFailed: return 1
        case .sessionNotOnConsole: return 3
        }
    case let e as Dock.DockError:
        switch e {
        case .accessibilityDenied: return 3
        case .dockNotRunning, .itemNotFound: return 4
        case .menuItemNotFound: return 1
        }
    case let e as Accessibility.AXError:
        switch e {
        case .notTrusted: return 3
        case .appNotFound, .noWindow, .noControl, .ambiguous, .notActionable, .notAPopup, .valueNotInMenu: return 4
        case .emptySelector, .incompleteSearch: return 2
        case .disabled, .notSettable, .secureField, .scopeChanged: return 4
        case .actionFailed: return 1
        }
    case let e as Browser.ObservationError:
        switch e {
        case .ambiguousProcesses, .ambiguousWindows: return 4
        case .incompleteWindowList, .changed: return 2
        }
    case is Arguments.ParseError:
        return 2
    default:
        return 2
    }
}

@MainActor
func fail(_ error: Error) -> Never {
    fail(String(describing: error), code: exitCode(for: error))
}

// MARK: - arguments

let argv = Array(CommandLine.arguments.dropFirst())
guard var commandName = argv.first else {
    note(usage)
    exit(2)
}
var rest = Array(argv.dropFirst())
if commandName == "--help" || commandName == "-h" { commandName = "help" }
if commandName == "dock" {
    commandName = "dock " + (rest.first ?? "list")
    if !rest.isEmpty { rest.removeFirst() }
}
guard let command = commands.first(where: { $0.name == commandName }) else {
    fail("unknown command: \(commandName); run macctl help", code: 2)
}

let parsed: Arguments = {
    if command.raw {
        // Raw text, with one exception: a leading --app names where the text
        // goes, so keystrokes can be refused rather than sent to whatever is in
        // front. Anything after it, flags included, is text.
        var text = rest
        var values: [String: String] = [:]
        if let first = text.first, first.hasPrefix("--app=") {
            values["app"] = String(first.dropFirst("--app=".count))
            text.removeFirst()
        } else if text.first == "--app", text.count >= 2 {
            values["app"] = text[1]
            text.removeFirst(2)
        }
        return Arguments(positionals: text, values: values)
    }
    do {
        return try Arguments.parse(rest, accepting: command.flags.map(\.option))
    } catch {
        fail("\(error)\nusage: \(command.synopsis)", code: 2)
    }
}()

for flag in command.flags where !flag.choices.isEmpty {
    if let value = parsed.option(flag.name), !flag.choices.contains(value) {
        fail("--\(flag.name) wants \(flag.choices.joined(separator: " or ")), not \(value)", code: 2)
    }
}

@MainActor
func usageFailure() -> Never {
    fail("usage: \(command.synopsis)", code: 2)
}

@MainActor
func need(_ count: Int) {
    if parsed.positionals.count < count { usageFailure() }
}

@MainActor
func number(_ index: Int) -> CGFloat {
    guard let value = Double(parsed.positionals[index]) else {
        fail("not a number: \(parsed.positionals[index])", code: 2)
    }
    return CGFloat(value)
}

@MainActor
func integer(_ name: String, fallback: Int) -> Int {
    guard let text = parsed.option(name) else { return fallback }
    guard let value = Int(text) else { fail("--\(name) wants a whole number, not \(text)", code: 2) }
    return value
}

@MainActor
func seconds(_ name: String, fallback: TimeInterval) -> TimeInterval {
    guard let text = parsed.option(name) else { return fallback }
    guard let value = TimeInterval(text), value >= 0 else { fail("--\(name) wants seconds, not \(text)", code: 2) }
    return value
}

/// A `--region` as fractions of the window, validated but not yet mapped.
///
/// Fractions rather than pixels for the same reason as every other
/// coordinate: a region cannot go stale the way a caller-supplied pixel rect
/// can. It is mapped onto the live rect inside the command that reads.
@MainActor
func regionFractions() -> CGRect? {
    guard let text = parsed.option("region") else { return nil }
    let parts = text.split(separator: ",").compactMap { Double($0) }
    guard parts.count == 4 else { fail("--region wants fx,fy,fw,fh as fractions", code: 2) }
    return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
}

func mapped(_ fractions: CGRect?, onto base: CGRect) -> CGRect? {
    guard let f = fractions else { return nil }
    return CGRect(x: base.minX + f.minX * base.width,
                  y: base.minY + f.minY * base.height,
                  width: f.width * base.width,
                  height: f.height * base.height)
}

func rectInfo(_ r: WindowRect) -> [String: Any] {
    ["window": ["id": Int(r.windowID),
                "pid": Int(r.pid),
                "bounds": [r.x, r.y, r.width, r.height],
                "frontmost": r.isFrontmost,
                "windows": r.windowCount,
                "readAt": ISO8601DateFormatter().string(from: r.readAt)]]
}

@MainActor
func controlSelector(positional: String? = nil) -> Accessibility.Selector {
    if positional != nil, parsed.option("match") != nil {
        fail("use either a positional control label or --match, not both", code: 2)
    }
    for name in ["role", "identifier", "match"] {
        if let value = parsed.option(name), value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fail("--\(name) must not be empty", code: 2)
        }
    }
    let needle = positional ?? parsed.option("match")
    if let needle, needle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        fail("a control label must not be empty", code: 2)
    }
    if parsed.flag("exact"), needle == nil {
        fail("--exact needs a control label or --match", code: 2)
    }
    return Accessibility.Selector(needle: needle, role: parsed.option("role"),
                                  identifier: parsed.option("identifier"), exact: parsed.flag("exact"))
}

func controlScope() -> Accessibility.Scope {
    Accessibility.Scope(rawValue: parsed.option("scope") ?? "app") ?? .app
}

func controlInfo(_ c: Accessibility.Control) -> [String: Any] {
    var entry: [String: Any] = ["role": c.role, "label": c.label,
                               "at": [c.center.x, c.center.y], "enabled": c.enabled,
                               "pressable": c.pressable, "valueSettable": c.valueSettable,
                               "secure": c.secure]
    entry["value"] = c.value.map { $0 as Any } ?? NSNull()
    entry["identifier"] = c.identifier.map { $0 as Any } ?? NSNull()
    entry["url"] = c.url.map { $0 as Any } ?? NSNull()
    entry["placeholder"] = c.placeholder.map { $0 as Any } ?? NSNull()
    entry["focused"] = c.focused.map { $0 as Any } ?? NSNull()
    if let bounds = c.bounds {
        entry["bounds"] = [bounds.minX, bounds.minY, bounds.width, bounds.height]
    } else { entry["bounds"] = NSNull() }
    return entry
}

@MainActor
func button() -> Input.Button {
    parsed.option("button") == "right" ? .right : .left
}

/// Keystrokes go to whatever is in front. With --app, that is made to be the
/// named app first, or the command refuses; the window used is echoed back.
@MainActor
func keystrokeTarget() -> [String: Any] {
    guard let app = parsed.option("app") else { return [:] }
    do { return rectInfo(try Geometry.activate(Geometry.AppQuery(app))) }
    catch { fail(error) }
}

/// The bookend the caller always forgets. Before the first command that moves
/// focus, note who is in front; `restore` puts them back. Later commands find
/// the record already there and leave it, so focus stays on the app being
/// driven across the steps. Commands that only read never record, and neither
/// does one that is about to be refused: this runs only after a command has
/// passed its usage and precondition checks, or a typo would leave a record
/// behind and the next `restore` would act on it.
let focusChangers: Set<String> = ["launch", "focus", "navigate", "move", "click", "press", "release",
                                  "scroll", "drag", "click-text", "activate", "choose", "dock menu"]

@MainActor
func recordOriginIfFocusChanging() {
    let changes = focusChangers.contains(command.name)
        || ((command.name == "key" || command.name == "type") && parsed.option("app") != nil)
    guard changes else { return }
    System.Origin.recordIfAbsent(try? Geometry.frontmost())
}

/// Refuse before doing anything that needs input to actually land.
///
/// Every one of these fails silently otherwise: a posted event is accepted
/// and dropped, and the command would report that it delivered a click nobody
/// received. Once every check has passed, the origin is recorded, because the
/// command is now going to act.
@MainActor
func requireInputPreconditions() {
    defer { recordOriginIfFocusChanging() }
    if !System.canPostEvents {
        fail("this process is not permitted to post input events; grant Accessibility (and Input Monitoring) to the terminal that runs macctl, then relaunch it: \(System.settingsURLs["accessibility"] ?? "")", code: 3)
    }
    if !System.isOnConsole {
        fail("this login session is not on the console; synthetic input goes nowhere", code: 3)
    }
    if System.isScreenLocked {
        fail("the screen is locked; synthetic input goes to the password prompt", code: 3)
    }
}

/// Notice the screen is dark and tap the trackpad, before anything reads it.
///
/// This runs for *every* command, not just the ones that capture, because the
/// two halves fail together: a dark screen makes reads return black frames and
/// makes clicks land on a screen the user cannot see. Doing it here rather than
/// inside each command means there is no command that can forget.
@MainActor
func wakeScreenFirst() {
    let wake = System.wakeScreen()
    guard wake.acted else { return }
    wakeReport = [
        "displayWasAsleep": wake.displayWasAsleep,
        "screenSaverWasRunning": wake.screenSaverWasRunning,
        "awakeNow": wake.awakeNow,
    ]
    if !wake.awakeNow {
        fail("the screen is asleep and did not wake; every capture would be black", code: 3)
    }
    if wake.locked {
        note("woke the screen, but it is locked — everything behind the password prompt is unreachable.")
    }
}

/// Capture the target of shot/read/find: an app's window, or the main display.
@MainActor
func captureTarget(app: String?, fractions: CGRect?) async throws -> Capture.Shot {
    if let app {
        let r = try Geometry.windowRect(for: Geometry.AppQuery(app))
        return try await Capture.windowResilient(r.windowID, rect: r.bounds,
                                                region: mapped(fractions, onto: r.bounds)).get()
    }
    guard Capture.isScreenRecordingGranted else { throw Capture.CaptureError.screenRecordingDenied }
    // Whole screen: the CLI path is tried first here because it is the one
    // that can be killed if it wedges.
    let bounds = CGDisplayBounds(CGMainDisplayID())
    let region = mapped(fractions, onto: bounds)
    if let full = try? await Capture.viaCLI(windowID: nil, rect: bounds, deadline: Capture.timeout) {
        guard let region else { return full }
        return try Capture.crop(full, to: region)
    }
    return try await Capture.screen(region: region)
}

// MARK: - watchdog

// A command that never returns is the worst failure this tool has, because the
// caller cannot tell "still working" from "never coming back" and will wait
// forever. Two macctl processes were found alive after three and a half hours,
// wedged inside a capture whose own five second deadline could not fire.
//
// The capture deadline is fixed now, but a deadline that lives inside the thing
// it is policing is only ever one bug away from this again. So the process also
// polices itself from the outside: an independent thread that force-exits with
// the "could not observe" code no matter what the rest of the program is doing.
// `_exit` rather than `exit`, because atexit handlers can block on the very
// thing that is stuck.
//
// Only a command that takes --timeout gets a longer leash, and only from that
// flag: text typed with `type` is never scanned for one.
let watchdogSeconds: Double = {
    let takesTimeout = command.flags.contains { $0.name == "timeout" }
    let asked = takesTimeout ? parsed.option("timeout").flatMap(Double.init) : nil
    return max(45, (asked ?? 0) + 30)
}()
let watchdogMessage = "\(command.name) did not finish within \(Int(watchdogSeconds))s"
let watchdog = Thread {
    Thread.sleep(forTimeInterval: watchdogSeconds)
    FileHandle.standardError.write(Data("macctl: \(watchdogMessage); abandoning it\n".utf8))
    FileHandle.standardOutput.write(Data(
        "{\"error\":\"watchdog: \(watchdogMessage)\",\"ok\":false,\"schema\":1}\n".utf8))
    _exit(2)
}
watchdog.stackSize = 64 * 1024
watchdog.start()

// Before anything else, and before `doctor` reads its state, so doctor reports
// the screen it is about to hand to the next command rather than the one it
// found. `help` prints text and touches no screen.
if command.name != "help" {
    wakeScreenFirst()
}

func originInfo(_ record: System.Origin.Record?) -> Any {
    guard let record else { return NSNull() }
    return ["name": record.name, "pid": Int(record.pid),
            "bundleID": record.bundleID as Any? ?? NSNull(),
            "recordedAt": ISO8601DateFormatter().string(from: record.recordedAt)]
}

// MARK: - dispatch

switch command.name {

case "help":
    if parsed.flag("json") { emit(contract()) } else { note(usage) }

case "doctor":
    let d = System.doctor()
    let origin = System.Origin.current()
    var missing: [String] = []
    if !d.screenRecording { missing.append("screenRecording") }
    if !d.postEvent { missing += ["accessibility", "postEvent"] }
    emit(["ok": d.allGood,
          "screenRecording": d.screenRecording,
          "accessibility": d.accessibility,
          "postEvent": d.postEvent,
          "secureInputActive": d.secureInputActive,
          "onConsole": d.onConsole,
          "displayAsleep": d.displayAsleep,
          "screenSaverRunning": d.screenSaverRunning,
          "screenLocked": d.screenLocked,
          "displaySleepPrevented": d.displaySleepPrevented,
          "origin": originInfo(origin),
          "grantAt": missing.compactMap { System.settingsURLs[$0] }])
    if !d.screenRecording { note("Screen Recording is not granted — shot, read, find, verify, wait-for and click-text will all refuse.") }
    if !d.postEvent { note("Posting input events is not permitted. Grant Accessibility (and Input Monitoring) to the terminal that runs macctl, then RELAUNCH it: the check is process-cached with no live probe.") }
    if !d.accessibility { note("Accessibility is not granted; dock list and dock menu need it.") }
    if d.secureInputActive { note("Secure Event Input is held by some app; keystrokes are being discarded system-wide.") }
    if d.displayAsleep { note("The display is asleep and would not wake; captures will be black.") }
    if d.screenSaverRunning { note("The screen saver is running; captures show it, not the app.") }
    if d.screenLocked { note("The screen is locked; input goes to the password prompt. Only a person at the machine can clear this.") }
    if !d.displaySleepPrevented { note("Nothing is holding the display awake. Before a long unattended run: macctl awake --while-pid $$") }
    if let origin { note("An earlier run left \(origin.name) recorded as the origin and never restored. macctl restore puts it back; macctl restore --forget drops it.") }
    exit(d.allGood ? 0 : 3)

case "awake":
    // The counterpart to waking a dark screen, and the more important half for
    // anything that runs unattended: a display that sleeps mid-run comes back
    // LOCKED, and a lock is not something this tool can recover from. Prefer
    // --while-pid over --seconds, so the assertion ends exactly when the run
    // does instead of on a guess about how long it will take.
    if parsed.flag("off") {
        emit(["ok": true, "released": System.Awake.release()])
        break
    }
    if parsed.flag("status") {
        emit(["ok": true,
              "holding": System.Awake.holder.map { Int($0) as Any } ?? NSNull(),
              "displaySleepPrevented": System.Awake.displaySleepPrevented])
        break
    }
    let whilePID = parsed.option("while-pid").flatMap { pid_t($0) }
    let seconds = parsed.option("seconds").flatMap { Int($0) }
    if whilePID == nil, seconds == nil { usageFailure() }
    if let whilePID, kill(whilePID, 0) != 0 {
        fail("no process \(whilePID) to tie the assertion to", code: 4)
    }
    do {
        let pid = try System.Awake.hold(seconds: seconds, whilePID: whilePID)
        emit(["ok": true, "holding": Int(pid),
              "until": whilePID.map { "pid \($0) exits" } ?? "\(seconds ?? 0)s"])
    } catch { fail(error) }

case "apps":
    emit(["ok": true, "apps": System.apps().map {
        ["name": $0.name, "bundleID": $0.bundleID, "pid": Int($0.pid)]
    }])

case "launch":
    need(1)
    requireInputPreconditions()
    let app = parsed.positionals[0]
    let viaSpotlight = parsed.flag("via-spotlight")
    let timeout = seconds("timeout", fallback: 30)
    do {
        let r = viaSpotlight
            ? try System.launchViaSpotlight(app, timeout: timeout)
            : try System.launch(app, timeout: timeout)
        emit(["ok": true, "app": app, "via": viaSpotlight ? "spotlight" : "workspace"]
            .merging(rectInfo(r)) { a, _ in a })
    } catch { fail(error) }

case "window":
    need(1)
    do {
        let r = try Geometry.windowRect(for: Geometry.AppQuery(parsed.positionals[0]))
        emit(["ok": true, "app": parsed.positionals[0]].merging(rectInfo(r)) { a, _ in a })
    } catch { fail(error) }

case "front":
    // Read this before driving anything, put the same app back afterward, and
    // the person returns to exactly what they left.
    do {
        let origin = originInfo(System.Origin.current())
        guard let front = try Geometry.frontmost() else {
            emit(["ok": true, "front": NSNull(), "origin": origin]); break
        }
        emit(["ok": true, "front": ["name": front.name, "pid": Int(front.pid),
                                    "bundleID": front.bundleID as Any? ?? NSNull()],
              "origin": origin])
    } catch { fail(error) }

case "restore":
    // The other half of the record taken before the first focus change. One
    // word at the end of a run, whatever the run did: the person is back where
    // they were and the record is gone. --forget drops it without moving
    // focus, for a task whose whole point was to land them somewhere new.
    if parsed.flag("forget") {
        emit(["ok": true, "forgot": originInfo(System.Origin.forget())])
        break
    }
    guard let origin = System.Origin.current() else {
        fail("nothing to restore: no app was recorded before driving began, or the record is stale", code: 4)
    }
    requireInputPreconditions()
    do {
        let r = try Geometry.activate(pid: origin.pid)
        System.Origin.forget()
        emit(["ok": true, "restored": originInfo(origin)].merging(rectInfo(r)) { a, _ in a })
    } catch { fail(error) }

case "focus":
    // Bring an app forward and stop — no click, no keystroke. The restore half
    // of `front`: put the person back where they were once the work is done.
    need(1)
    recordOriginIfFocusChanging()
    do {
        let r = try Geometry.activate(Geometry.AppQuery(parsed.positionals[0]))
        emit(["ok": true, "app": parsed.positionals[0]].merging(rectInfo(r)) { a, _ in a })
    } catch { fail(error) }

case "browser":
    need(1)
    do {
        let snapshot = try Browser.snapshot(Geometry.AppQuery(parsed.positionals[0]))
        let data = try JSONEncoder().encode(snapshot)
        var result = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        result["ok"] = snapshot.complete
        result["source"] = "accessibility"
        if !snapshot.complete { result["outcome"] = "unknown: browser accessibility tree was incomplete" }
        emit(result)
        exit(snapshot.complete ? 0 : 2)
    } catch { fail(error) }

case "navigate":
    // External-open policy may create a tab. Text stability is only an
    // observation; a stable browser shell does not prove a page has loaded.
    need(2)
    recordOriginIfFocusChanging()
    let app = parsed.positionals[0]
    var url = parsed.positionals[1]
    if !url.contains("://") { url = "https://" + url }
    let navTimeout = seconds("timeout", fallback: 15)
    let baseline = (try? Accessibility.text(Geometry.AppQuery(app), settleMs: 0))?.text

    let opener = Process()
    opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    opener.arguments = ["-a", app, url]
    opener.standardError = FileHandle.nullDevice
    do { try opener.run(); opener.waitUntilExit() }
    catch { fail("could not run open: \(error)", code: 4) }
    guard opener.terminationStatus == 0 else {
        fail("open could not load \(url) in \(app)", code: 4)
    }
    // Wait for the app to come up if it was not running, then settle.
    let upDeadline = Date().addingTimeInterval(min(navTimeout, 20))
    while Date() < upDeadline, (try? Geometry.resolve(Geometry.AppQuery(app))) == nil {
        usleep(200_000)
    }
    do {
        let settled = try Accessibility.settle(Geometry.AppQuery(app), changedFrom: baseline, timeout: navTimeout)
        var result: [String: Any] = ["ok": settled.stabilised, "app": app, "url": url,
              "settled": settled.stabilised, "verified": false, "observation": "app-text-stability",
              "waited": (settled.waited * 100).rounded() / 100, "chars": settled.text.text.count]
        if !settled.stabilised { result["outcome"] = "unknown: app text did not settle before the timeout" }
        emit(result)
        exit(settled.stabilised ? 0 : 2)
    } catch { fail(error) }

case "wait-idle":
    // Return the moment the app's text stops changing. The condition-based
    // replacement for `sleep N` after a click or a load.
    need(1)
    let idleTimeout = seconds("timeout", fallback: 10)
    do {
        let settled = try Accessibility.settle(Geometry.AppQuery(parsed.positionals[0]), timeout: idleTimeout)
        emit(["ok": settled.stabilised, "app": parsed.positionals[0], "settled": settled.stabilised,
              "waited": (settled.waited * 100).rounded() / 100, "chars": settled.text.text.count])
        exit(settled.stabilised ? 0 : 2)
    } catch { fail(error) }

case "move", "click", "press", "release", "scroll", "drag":
    need(1)
    requireInputPreconditions()
    let app = parsed.positionals[0]
    let r: WindowRect
    do { r = try Geometry.activate(Geometry.AppQuery(app)) } catch { fail(error) }

    switch command.name {
    case "move":
        need(3)
        let p = r.at(number(1), number(2))
        Input.move(to: p, steps: 10)
        emit(["ok": true, "at": [p.x, p.y]].merging(rectInfo(r)) { a, _ in a })

    case "click":
        need(3)
        let p = r.at(number(1), number(2))
        let count = integer("count", fallback: 1)
        let hoverMs = parsed.option("hover-ms").flatMap { UInt32($0) }
        let approach = Input.Approach(rawValue: parsed.option("approach") ?? "warp") ?? .warp
        Input.click(at: p, button: button(), count: count, approach: approach, hoverMs: hoverMs)
        emit(["ok": true, "verified": false, "evidence": "delivery_accepted",
              "at": [p.x, p.y], "count": count, "button": button().rawValue]
            .merging(rectInfo(r)) { a, _ in a })

    case "press":
        need(3)
        let p = r.at(number(1), number(2))
        Input.press(at: p, button: button())
        emit(["ok": true, "verified": false, "held": true, "at": [p.x, p.y]]
            .merging(rectInfo(r)) { a, _ in a })

    case "release":
        need(3)
        let p = r.at(number(1), number(2))
        Input.release(at: p, button: button())
        emit(["ok": true, "verified": false, "at": [p.x, p.y]]
            .merging(rectInfo(r)) { a, _ in a })

    case "scroll":
        need(4)
        let p = r.at(number(1), number(2))
        guard let amount = Int32(parsed.positionals[3]) else {
            fail("not a whole number: \(parsed.positionals[3])", code: 2)
        }
        let unit = Input.ScrollUnit(rawValue: parsed.option("unit") ?? "line") ?? .line
        let trackpad = parsed.flag("trackpad")
        if trackpad {
            Input.scrollTrackpad(at: p, vertical: amount)
        } else {
            Input.scroll(at: p, lines: amount, unit: unit == .pixel ? .pixel : .line)
        }
        emit(["ok": true, "verified": false, "amount": Int(amount), "at": [p.x, p.y],
              "unit": unit.rawValue, "trackpad": trackpad]
            .merging(rectInfo(r)) { a, _ in a })

    default: // drag
        need(5)
        let from = r.at(number(1), number(2)), to = r.at(number(3), number(4))
        let steps = integer("steps", fallback: 24)
        let profile = Input.DragProfile(rawValue: parsed.option("profile") ?? "default") ?? .default
        Input.dragAndDrop(from: from, to: to, button: button(), steps: steps, profile: profile)
        emit(["ok": true, "verified": false, "evidence": "delivery_accepted",
              "from": [from.x, from.y], "to": [to.x, to.y], "steps": steps,
              "profile": profile.rawValue]
            .merging(rectInfo(r)) { a, _ in a })
    }

case "key":
    need(1)
    requireInputPreconditions()
    let chord = parsed.positionals[0]
    let target = keystrokeTarget()
    do {
        try Keyboard.press(chord)
        emit(["ok": true, "key": chord, "verified": false].merging(target) { a, _ in a })
    } catch { fail(error) }

case "type":
    need(1)
    requireInputPreconditions()
    let text = parsed.positionals.joined(separator: " ")
    let target = keystrokeTarget()
    do {
        try Keyboard.type(text)
        emit(["ok": true, "typed": text.count, "verified": false].merging(target) { a, _ in a })
    } catch { fail(error) }

case "shot", "read", "find":
    let wholeScreen = parsed.flag("screen")
    let fractions = regionFractions()
    let app: String? = wholeScreen ? nil : parsed.positionals.first
    if !wholeScreen, app == nil { usageFailure() }
    var needle: String?
    if command.name == "find" {
        let index = wholeScreen ? 0 : 1
        guard index < parsed.positionals.count else { usageFailure() }
        needle = parsed.positionals[index]
    }

    let shot: Capture.Shot
    do { shot = try await captureTarget(app: app, fractions: fractions) } catch { fail(error) }

    let where_: [String: Any] = [
        "region": [shot.rect.minX, shot.rect.minY, shot.rect.width, shot.rect.height],
        "pixels": [shot.image.width, shot.image.height],
        "scale": shot.scale, "scaleSource": shot.scaleSource.rawValue,
        "capturePath": shot.path.rawValue,
    ]

    switch command.name {
    case "shot":
        // The per-user temporary directory, not the shared /tmp: a screenshot
        // can hold anything that was on screen.
        let path = parsed.option("out") ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("macctl-shot.png").path
        do { try Capture.writePNG(shot, to: URL(fileURLWithPath: path)) }
        catch { fail(error) }
        emit(["ok": true, "out": path].merging(where_) { a, _ in a })

    case "read":
        // A recognition failure is reported as one. Swallowing it would emit an
        // empty list, and an empty list means "nothing on screen", which is
        // the exact confusion this tool exists to prevent.
        do {
            if parsed.flag("boxes") {
                // --boxes returns what Vision actually saw: one entry per text
                // box, each with its own centre. The default merges boxes
                // sharing a row into a line, which is useful for a label beside
                // a value and wrong for a row of separate controls, where the
                // merged centre can land between them.
                let found = try Text.boxes(in: shot)
                emit(["ok": true, "boxes": found.map {
                    ["text": $0.text, "at": [$0.center.x, $0.center.y],
                     "rect": [$0.rect.minX, $0.rect.minY, $0.rect.width, $0.rect.height],
                     "confidence": $0.confidence]
                }].merging(where_) { a, _ in a })
            } else {
                let lines = try Text.lines(in: shot)
                emit(["ok": true, "lines": lines.map {
                    ["text": $0.text, "at": [$0.center.x, $0.center.y]]
                }].merging(where_) { a, _ in a })
            }
        } catch { fail("text recognition failed: \(error)", code: 2) }

    default: // find
        guard let needle else { usageFailure() }
        let hits: [Text.Found]
        do { hits = try Text.find(needle, in: shot) }
        catch { fail("text recognition failed: \(error)", code: 2) }
        emit(["ok": !hits.isEmpty, "needle": needle, "hits": hits.map {
            ["text": $0.text, "at": [$0.center.x, $0.center.y],
             "rect": [$0.rect.minX, $0.rect.minY, $0.rect.width, $0.rect.height]]
        }].merging(where_) { a, _ in a })
        exit(hits.isEmpty ? 1 : 0)
    }

case "click-text":
    need(2)
    requireInputPreconditions()
    let app = parsed.positionals[0], needle = parsed.positionals[1]
    let count = integer("count", fallback: 1)
    let timeout = seconds("timeout", fallback: 0)
    let fractions = regionFractions()
    let (outcome, point) = await Verify.clickText(
        needle, app: Geometry.AppQuery(app), button: button(), count: count,
        timeout: timeout, regionFractions: fractions)
    // satisfied here means "found a unique target and delivered a click to
    // it" — not that the app reacted. A posted click can still be swallowed
    // (a modal sheet eats them; see `activate`), so the effect is unverified
    // like every other input command. Confirm the result with `verify`, or
    // `wait-for --gone` on something the action should remove.
    emit(["ok": outcome == .satisfied, "needle": needle, "outcome": outcome.label,
          "verified": false, "at": point.map { [$0.x, $0.y] } ?? []])
    exit(outcome.exitCode)

case "verify":
    need(2)
    let app = parsed.positionals[0], needle = parsed.positionals[1]
    let fractions = regionFractions()
    let outcome = await Verify.textPresent(needle, app: Geometry.AppQuery(app), regionFractions: fractions)
    emit(["ok": outcome == .satisfied, "needle": needle, "outcome": outcome.label])
    exit(outcome.exitCode)

case "wait-for":
    need(2)
    let app = parsed.positionals[0], needle = parsed.positionals[1]
    let timeout = seconds("timeout", fallback: 30)
    let gone = parsed.flag("gone")
    let fractions = regionFractions()
    let outcome = gone
        ? await Verify.waitUntilGone(needle, app: Geometry.AppQuery(app), timeout: timeout, regionFractions: fractions)
        : await Verify.waitForText(needle, app: Geometry.AppQuery(app), timeout: timeout, regionFractions: fractions)
    emit(["ok": outcome == .satisfied, "needle": needle, "outcome": outcome.label,
          "waitedFor": gone ? "gone" : "present", "timeout": timeout])
    exit(outcome.exitCode)

case "text":
    // Read content the cheap, lossless way — the accessibility tree — and drop
    // to OCR only when that comes up empty (a canvas, a game, an app with no
    // text tree). This is the inverse of `read`, which is OCR-first and returns
    // click points; `text` returns the words, fast and verbatim.
    let wholeScreen = parsed.flag("screen")
    let app: String? = wholeScreen ? nil : parsed.positionals.first
    if !wholeScreen, app == nil { usageFailure() }
    let minChars = integer("min-chars", fallback: 40)
    let fractions = regionFractions()

    var source = "accessibility"
    var text = ""
    var nodes = 0
    if let app, !parsed.flag("ocr") {
        if let extracted = try? Accessibility.text(Geometry.AppQuery(app)) {
            text = extracted.text
            nodes = extracted.nodes
        }
    }
    if text.count < minChars {
        // Fallback: OCR the window (or screen), joining the lines in order.
        source = "ocr"
        let shot: Capture.Shot
        do { shot = try await captureTarget(app: app, fractions: fractions) } catch { fail(error) }
        let lines = (try? Text.lines(in: shot)) ?? []
        text = lines.map(\.text).joined(separator: "\n")
    }

    var result: [String: Any] = ["ok": !text.isEmpty, "source": source, "chars": text.count, "nodes": nodes]
    if let out = parsed.option("out") {
        do { try text.write(toFile: out, atomically: true, encoding: .utf8) }
        catch { fail("could not write \(out): \(error)", code: 4) }
        result["out"] = out
    } else {
        result["text"] = text
    }
    emit(result)
    exit(text.isEmpty ? 1 : 0)

case "controls":
    need(1)
    let selector = controlSelector()
    let scope = controlScope()
    do {
        let found = try Accessibility.discover(Geometry.AppQuery(parsed.positionals[0]), scope: scope, selector: selector)
        var result: [String: Any] = ["ok": !found.truncated, "app": parsed.positionals[0],
                                    "scope": scope.rawValue, "truncated": found.truncated,
                                    "visited": found.visited, "controls": found.controls.map(controlInfo)]
        if found.truncated { result["outcome"] = "unknown: accessibility search was truncated; results may be incomplete" }
        emit(result)
        exit(found.truncated ? 2 : 0)
    } catch { fail(error) }

case "activate":
    need(1)
    guard parsed.positionals.count <= 2 else { usageFailure() }
    let selector = controlSelector(positional: parsed.positionals.count == 2 ? parsed.positionals[1] : nil)
    guard selector.needle != nil || selector.role != nil || selector.identifier != nil else {
        fail("activate needs a control label, --match, --role, or --identifier", code: 2)
    }
    let scope = controlScope()
    requireInputPreconditions()
    let app = parsed.positionals[0]
    do {
        let control = try Accessibility.activate(Geometry.AppQuery(app), scope: scope, selector: selector)
        // verified:false for the same reason as click: the action was
        // delivered to the element, which is far surer than a posted click,
        // but is still not proof the app finished reacting. Confirm with
        // verify or wait-for --gone when it matters.
        emit(["ok": true, "app": app, "needle": selector.needle.map { $0 as Any } ?? NSNull(),
              "scope": scope.rawValue, "verified": false, "control": controlInfo(control)])
    } catch { fail(error) }

case "set-value":
    need(2)
    guard parsed.positionals.count == 2 else { usageFailure() }
    let selector = controlSelector()
    guard selector.needle != nil || selector.role != nil || selector.identifier != nil else {
        fail("set-value needs --match, --role, or --identifier", code: 2)
    }
    let scope = controlScope()
    requireInputPreconditions()
    let app = parsed.positionals[0]
    do {
        let change = try Accessibility.setValue(Geometry.AppQuery(app), scope: scope,
                                                selector: selector, value: parsed.positionals[1])
        let code: Int32 = change.verified.map { $0 ? 0 : 1 } ?? 2
        let outcome = change.verified.map { $0 ? "satisfied" : "unsatisfied" }
            ?? "unknown: the field value could not be read back"
        emit(["ok": code == 0, "app": app, "scope": scope.rawValue,
              "verified": change.verified.map { $0 as Any } ?? NSNull(), "outcome": outcome,
              "before": change.before.map { $0 as Any } ?? NSNull(),
              "after": change.after.map { $0 as Any } ?? NSNull(), "control": controlInfo(change.control)])
        exit(code)
    } catch { fail(error) }

case "choose":
    need(3)
    requireInputPreconditions()
    let app = parsed.positionals[0], popup = parsed.positionals[1], value = parsed.positionals[2]
    do {
        let (before, after) = try Accessibility.choose(Geometry.AppQuery(app), popup: popup, value: value)
        // choose reads the popup's value back, so it can actually verify: ok
        // is whether the selection now matches what was asked for.
        let matched = Text.fold(after).contains(Text.fold(value))
        emit(["ok": matched, "app": app, "popup": popup, "value": value,
              "verified": true, "before": before, "after": after])
        exit(matched ? 0 : 1)
    } catch { fail(error) }

case "dock list":
    // Locating and using Dock icons. They carry no on-screen text, so this is
    // the one place accessibility is required rather than optional.
    do {
        emit(["ok": true, "items": try Dock.items().map {
            ["title": $0.title, "at": [$0.center.x, $0.center.y],
             "frame": [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height]]
        }])
    } catch { fail(error) }

case "dock menu":
    need(2)
    requireInputPreconditions()
    let appName = parsed.positionals[0], itemName = parsed.positionals[1]
    do {
        let point = try await Dock.chooseFromMenu(app: appName, item: itemName)
        emit(["ok": true, "app": appName, "item": itemName, "releasedAt": [point.x, point.y]])
    } catch { fail(error) }

default:
    fail("unknown command: \(command.name)", code: 2)
}
exit(0)
