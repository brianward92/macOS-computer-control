import Carbon.HIToolbox
import CoreGraphics
import Foundation
import MacControlKit

// Plain-swiftc tests: no XCTest, so they run on a machine with only Command
// Line Tools. Everything here is pure logic; nothing touches the screen.

nonisolated(unsafe) private var failures = 0


private func makeImage(_ size: Int) -> CGImage? {
    CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
    }
}

// MARK: - Text

expect(Text.fold("\u{041e}pen  7") == "open 7", "folds homoglyphs and whitespace")
expect(Text.fold("Café") == "cafe", "folds case and diacritics")
expect(Text.matches("Open", candidates: ["\u{041e}pen", "Opem"]), "find accepts Vision alternatives")
expect(!Text.matches("Open", candidates: ["Cancel", "Close"]), "find rejects unrelated alternatives")

let menu = "Terminal Shell Edit View"
if let r = Text.range(ofFolded: Text.fold("shell"), in: menu) {
    expect(menu[r] == "Shell", "a folded needle is located in the original text")
} else { expect(false, "needle not located in plain text") }
let mixed = "Menu  \u{041e}pen Now"
if let r = Text.range(ofFolded: Text.fold("open now"), in: mixed) {
    expect(mixed[r] == "\u{041e}pen Now", "homoglyphs and collapsed whitespace map back to the original range")
} else { expect(false, "needle not located across homoglyph and whitespace folding") }
if let r = Text.range(ofFolded: Text.fold("CAFE"), in: "un café noir") {
    expect("un café noir"[r] == "café", "diacritics fold without losing the range")
} else { expect(false, "needle not located across diacritic folding") }
if let r = Text.range(ofFolded: "on", in: "Button On") {
    expect("Button On"[r] == "On", "a whole-word occurrence is preferred over one inside another word")
} else { expect(false, "needle not located as a word") }
expect(Text.range(ofFolded: "zzz", in: menu) == nil, "an absent needle has no range")

typealias Quality = Text.MatchQuality
func quality(_ needle: String, _ text: String) -> Quality {
    Text.quality(ofFolded: Text.fold(needle), inFolded: Text.fold(text))
}
expect(quality("7", "7") == .exact, "a box whose whole text is the needle is an exact match")
expect(quality("7", "272.00004") == .substring, "a digit inside a number is only a substring")
expect(quality("8", "80") == .substring, "a digit at the start of a number is only a substring")
expect(quality("Shell", "Terminal Shell Edit View") == .word, "a word inside a line is a word match")
expect(quality("save", "Don't Save") == .word && quality("save", "Save…") == .word,
       "punctuation and string ends bound a word")
expect(quality("on", "Button On") == .word, "the best occurrence counts, not the first")
expect(quality("zzz", "abc") == .none && quality("", "abc") == .none, "no match, and an empty needle, are none")
expect(Text.keepBest([("display", Quality.substring), ("key", .exact), ("other", .substring)]) == ["key"],
       "only the best level survives")
expect(Text.keepBest([("a", Quality.word), ("b", .word)]) == ["a", "b"], "ties at the best level all survive")
expect(Text.keepBest([("a", Quality.none)]).isEmpty, "nothing matching is nothing")
expect(Text.range(ofFolded: "", in: menu) == nil, "an empty needle has no range")

let boxes = [
    Text.Found(text: "3x", rect: CGRect(x: 0, y: 10, width: 12, height: 10), confidence: 1),
    Text.Found(text: "Items", rect: CGRect(x: 18, y: 10, width: 24, height: 10), confidence: 1),
    Text.Found(text: "Separate", rect: CGRect(x: 80, y: 10, width: 35, height: 10), confidence: 1),
]
let lines = Text.mergeLines(boxes, captureHeight: 100)
expect(lines.map(\.text) == ["3x Items", "Separate"], "line merge stops at large horizontal gaps")

// MARK: - WindowRect

let rect = WindowRect(windowID: 1, pid: 2,
                      bounds: CGRect(x: 10, y: 20, width: 400, height: 300),
                      isFrontmost: true)
expect(rect.at(0, 0) == CGPoint(x: 10, y: 20), "window origin")
expect(rect.at(1, 1) == CGPoint(x: 410, y: 320), "window lower right")
expect(rect.at(0.5, 0.5) == CGPoint(x: 210, y: 170), "window centre")
expect(rect.windowCount == 1, "window count defaults to one")

// MARK: - Arguments

let options = [
    Arguments.Option("boxes"),
    Arguments.Option("region", takesValue: true),
    Arguments.Option("count", takesValue: true),
]
do {
    let parsed = try Arguments.parse(
        ["Example App", "Open", "--boxes", "--region", "0.3,0.65,0.7,0.3", "--count=2", "--", "--literal", "-3"],
        accepting: options)
    expect(parsed.flag("boxes"), "parses boolean flag")
    expect(parsed.option("region") == "0.3,0.65,0.7,0.3", "parses valued option")
    expect(parsed.option("count") == "2", "parses --name=value")
    expect(parsed.positionals == ["Example App", "Open", "--literal", "-3"],
           "flags never become positionals; everything after -- is positional")
} catch {
    expect(false, "valid arguments threw \(error)")
}
do {
    let parsed = try Arguments.parse(["App", "0.5", "0.5", "-3"], accepting: options)
    expect(parsed.positionals.count == 4, "a negative number is positional")
} catch {
    expect(false, "negative number threw \(error)")
}
func parseError(_ argv: [String]) -> Arguments.ParseError? {
    do { _ = try Arguments.parse(argv, accepting: options); return nil }
    catch let error as Arguments.ParseError { return error }
    catch { return nil }
}
expect(parseError(["--cont", "2"]) == .unknownFlag("--cont"), "unknown flag is an error, not ignored")
expect(parseError(["--count"]) == .missingValue("count"), "valued flag with nothing after it")
expect(parseError(["--boxes=1"]) == .unexpectedValue("boxes"), "boolean flag given a value")

// MARK: - Geometry: resolving an app name

typealias Candidate = Geometry.Candidate
let running = [
    Candidate(pid: 1, name: "Xcode", bundleID: "com.apple.dt.Xcode"),
    Candidate(pid: 2, name: "Visual Studio Code", bundleID: "com.microsoft.VSCode"),
    Candidate(pid: 3, name: "Code Helper (Renderer)", bundleID: "com.microsoft.VSCode.helper", policy: .prohibited),
    Candidate(pid: 4, name: "Safari", bundleID: "com.apple.Safari"),
    Candidate(pid: 5, name: "Safari", bundleID: "com.apple.Safari"),
    Candidate(pid: 6, name: "Code", bundleID: "com.example.code"),
    Candidate(pid: 7, name: "Xcode Agent", bundleID: "com.example.xcode-agent", policy: .accessory),
    Candidate(pid: 8, name: "Draft Overlay", bundleID: "com.example.overlay", policy: .accessory),
    Candidate(pid: 9, name: "Overlay Sync Agent", bundleID: "com.example.overlay-sync", policy: .accessory),
]
func resolve(_ raw: String) -> Result<Geometry.Resolution, GeometryError> {
    do { return .success(try Geometry.resolve(Geometry.AppQuery(raw), among: running)) }
    catch let error as GeometryError { return .failure(error) }
    catch { return .failure(.windowListUnavailable) }
}
func pids(_ raw: String) -> Set<pid_t>? {
    if case .success(let r) = resolve(raw) { return r.pids }
    return nil
}
func ambiguity(_ raw: String) -> [String]? {
    if case .failure(.ambiguousApp(_, let names)) = resolve(raw) { return names }
    return nil
}
expect(pids("Code") == [6], "an exact name beats every substring match")
expect(pids("visual studio code") == [2], "exact name is case-insensitive")
expect(pids("COM.APPLE.DT.XCODE") == [1], "exact bundle id is case-insensitive")
expect(pids("xcode") == [1], "a substring naming one ordinary app resolves, ignoring agents that also match")
expect(pids("stu") == [2], "substring inside one name")
expect(pids("safari") == [4, 5], "two processes of one app are one app")
expect(pids("Draft Overlay") == [8], "an agent is reachable by exact name")
expect(pids("draft") == [8], "an agent is reachable by a substring no ordinary app shares")
expect(ambiguity("overlay")?.count == 2, "a substring shared by two agents is ambiguous")
expect(ambiguity("cod")?.count == 3, "a substring naming several ordinary apps is refused, listing them")
expect(ambiguity("cod")?.contains("Xcode (com.apple.dt.Xcode)") == true, "the listing names each app with its bundle id")
if case .failure(.noMatchingApp) = resolve("helper") {} else {
    expect(false, "background-only helper processes are never candidates")
}
if case .failure(.noMatchingApp) = resolve("nothing") {} else {
    expect(false, "no match is reported as such")
}

// MARK: - Geometry: choosing the window

typealias Entry = Geometry.WindowEntry
let entries = [
    Entry(id: 10, pid: 99, layer: 25, bounds: CGRect(x: 0, y: 0, width: 2000, height: 30)),
    Entry(id: 11, pid: 7, layer: 0, bounds: CGRect(x: 0, y: 0, width: 300, height: 10)),
    Entry(id: 12, pid: 8, layer: 0, bounds: CGRect(x: 100, y: 100, width: 800, height: 600)),
    Entry(id: 13, pid: 7, layer: 0, bounds: CGRect(x: 200, y: 200, width: 400, height: 300)),
    Entry(id: 14, pid: 7, layer: 0, bounds: CGRect(x: 0, y: 0, width: 1600, height: 1000)),
]
let picked = Geometry.select(from: entries, pids: [7])
expect(picked.window?.windowID == 13, "the front qualifying window wins, not the largest")
expect(picked.window?.isFrontmost == false && picked.frontmostPid == 8, "another app's window in front is noticed")
expect(picked.window?.windowCount == 2, "slivers are not counted as windows")
expect(Geometry.select(from: entries, pids: [8]).window?.isFrontmost == true, "front app is frontmost")
expect(Geometry.select(from: entries, pids: [5]).window == nil, "no window for an app with none")
expect(Geometry.select(from: [entries[1]], pids: [7]).window == nil, "a sliver alone is no window")
expect(Geometry.select(from: [entries[0]], pids: [99]).window == nil, "layers above zero are not windows")

// MARK: - Verify: deciding from looks

final class Script: @unchecked Sendable {
    var looks: [Verify.Look]
    init(_ looks: [Verify.Look]) { self.looks = looks }
    func next() -> Verify.Look { looks.isEmpty ? .failed("script exhausted") : looks.removeFirst() }
}
let p = CGPoint(x: 1, y: 2), q = CGPoint(x: 3, y: 4)

var script = Script([.absent, .absent, .absent])
var outcome = await Verify.presence(looks: 3, pauseMs: 0) { script.next() }
expect(outcome == .unsatisfied, "three clean misses are absence")

script = Script([.absent, .seen([p])])
outcome = await Verify.presence(looks: 3, pauseMs: 0) { script.next() }
expect(outcome == .satisfied, "one sighting is presence")

script = Script([.failed("blank"), .absent, .absent])
outcome = await Verify.presence(looks: 3, pauseMs: 0) { script.next() }
if case .unknown = outcome {} else { expect(false, "a failed look among misses makes absence unknown") }

script = Script([.failed("a"), .failed("b"), .failed("c")])
outcome = await Verify.presence(looks: 3, pauseMs: 0) { script.next() }
if case .unknown = outcome {} else { expect(false, "all looks failing is unknown") }

script = Script([.refused("no such app", .notRunning)])
outcome = await Verify.presence(looks: 3, pauseMs: 0) { script.next() }
expect(outcome == .refused(reason: "no such app"), "a refusal is reported at once")

script = Script([.failed("a"), .refused("not yet", .window), .refused("not running", .notRunning), .seen([p])])
outcome = await Verify.appearance(timeout: 2, pauseMs: 1) { script.next() }
expect(outcome == .satisfied, "waiting keeps looking through failures, a missing window and an app not yet running")

script = Script([.refused("two apps", .ambiguous), .seen([p])])
outcome = await Verify.appearance(timeout: 2, pauseMs: 1) { script.next() }
expect(outcome == .refused(reason: "two apps"), "an ambiguous name is refused without waiting")

script = Script([.absent])
outcome = await Verify.appearance(timeout: 0.05, pauseMs: 1) { script.next() }
expect(outcome == .unsatisfied, "observed and never seen before the deadline is unsatisfied")

script = Script([])
outcome = await Verify.appearance(timeout: 0.05, pauseMs: 1) { script.next() }
if case .unknown(let reason) = outcome {
    expect(reason.contains("script exhausted"), "never observed carries the last problem: \(reason)")
} else {
    expect(false, "never observed is unknown")
}

script = Script([.seen([p])])
var found = await Verify.target("Open", timeout: 0, pauseMs: 0) { script.next() }
expect(found.0 == .satisfied && found.1 == p, "one hit is the target")

script = Script([.seen([p, q])])
found = await Verify.target("Open", timeout: 5, pauseMs: 0) { script.next() }
if case .unknown = found.0 {} else { expect(false, "two hits are a refusal to guess, timeout or not") }

script = Script([.absent])
found = await Verify.target("Open", timeout: 0, pauseMs: 0) { script.next() }
if case .unknown = found.0 {} else { expect(false, "a single miss with no timeout is unknown, not absent") }

script = Script([.refused("no window", .window)])
found = await Verify.target("Open", timeout: 0, pauseMs: 0) { script.next() }
expect(found.0 == .refused(reason: "no window"), "a refusal with no timeout is a refusal")

script = Script([.refused("no window", .window), .seen([p])])
found = await Verify.target("Open", timeout: 2, pauseMs: 1) { script.next() }
expect(found.0 == .satisfied && found.1 == p, "with a timeout, a missing window is waited out")

script = Script([.refused("not running", .notRunning), .seen([p])])
let t = Date()
found = await Verify.target("Open", timeout: 5, pauseMs: 1) { script.next() }
expect(found.0 == .refused(reason: "not running") && Date().timeIntervalSince(t) < 1,
       "an app that is not running is refused at once, not after the timeout")

script = Script([.refused("two apps", .ambiguous), .seen([p])])
found = await Verify.target("Open", timeout: 5, pauseMs: 1) { script.next() }
expect(found.0 == .refused(reason: "two apps"), "an ambiguous name is refused at once")

script = Script([.failed("blank"), .absent, .seen([q])])
found = await Verify.target("Open", timeout: 2, pauseMs: 1) { script.next() }
expect(found.1 == q, "with a timeout, looking continues until a hit")

script = Script([.absent])
found = await Verify.target("Open", timeout: 0.05, pauseMs: 1) { script.next() }
expect(found.0 == .unsatisfied, "observed, never seen, deadline passed: unsatisfied")


// disappearance — wait-for --gone
script = Script([.seen([p]), .seen([p]), .absent, .absent, .absent])
outcome = await Verify.disappearance(timeout: 2, needed: 3, pauseMs: 0) { script.next() }
expect(outcome == .satisfied, "three consecutive absences means gone")
script = Script([.absent, .seen([p]), .absent, .absent, .absent])
outcome = await Verify.disappearance(timeout: 2, needed: 3, pauseMs: 0) { script.next() }
expect(outcome == .satisfied, "a sighting resets the absence count")
outcome = await Verify.disappearance(timeout: 0.05, needed: 3, pauseMs: 1) { .seen([p]) }
expect(outcome == .unsatisfied, "still visible at the deadline is unsatisfied")
script = Script([.refused("two apps", .ambiguous)])
outcome = await Verify.disappearance(timeout: 2, needed: 3, pauseMs: 0) { script.next() }
expect(outcome == .refused(reason: "two apps"), "an ambiguous name is refused, not waited out")
outcome = await Verify.disappearance(timeout: 0.05, needed: 3, pauseMs: 1) { .failed("blind") }
expect(outcome.exitCode == 2, "never observing the window is unknown")

expect(Outcome.refused(reason: "x").exitCode == 4 && Outcome.unknown(reason: "x").exitCode == 2,
       "outcome exit codes follow the contract")

// MARK: - Verify: text targets must survive OCR and pointer preparation

do {
    let observed = WindowRect(windowID: 10, pid: 20,
                              bounds: CGRect(x: 100, y: 80, width: 400, height: 300),
                              isFrontmost: true, readAt: Date(timeIntervalSince1970: 1))
    let point = observed.at(0.5, 0.5)
    func changed(id: CGWindowID = 10, pid: pid_t = 20, bounds: CGRect? = nil,
                 frontmost: Bool = true) -> WindowRect {
        WindowRect(windowID: id, pid: pid, bounds: bounds ?? observed.bounds,
                   isFrontmost: frontmost, windowCount: 2, readAt: Date(timeIntervalSince1970: 2))
    }
    let races: [(String, Result<WindowRect, GeometryError>, Int32)] = [
        ("focus moved to another app", .success(changed(frontmost: false)), 4),
        ("a different window came forward", .success(changed(id: 11)), 4),
        ("another process replaced the target", .success(changed(pid: 21)), 4),
        ("the window moved", .success(changed(bounds: observed.bounds.offsetBy(dx: 30, dy: 20))), 4),
        ("the window resized", .success(changed(bounds: CGRect(x: 100, y: 80, width: 500, height: 300))), 4),
        ("the window closed", .failure(.noOnScreenWindow("Example App")), 4),
        ("the app quit", .failure(.noMatchingApp("Example App")), 4),
        ("the window server could not be read", .failure(.windowListUnavailable), 2),
    ]
    for (why, reading, code) in races {
        // The same race can occur during capture/OCR or during the intentional
        // hover delay. Neither phase may deliver the old absolute click point.
        for duringHover in [false, true] {
            var prepared = false
            var clicks: [CGPoint] = []
            let result = Verify.clickObservedTarget(at: point, window: observed,
                readWindow: {
                    if duringHover && !prepared { return observed }
                    return try reading.get()
                },
                prepare: { _ in prepared = true },
                click: { clicks.append($0) })
            expect(result.exitCode == code, "\(why), hover=\(duringHover): preserves refusal/unknown outcome")
            expect(clicks.isEmpty, "\(why), hover=\(duringHover): no stale click is posted")
            expect(prepared == duringHover, "\(why): a race already observed after OCR does not move the pointer")
        }
    }
    var steps: [String] = []
    var clicks: [CGPoint] = []
    let delivered = Verify.clickObservedTarget(at: point, window: observed,
        readWindow: { steps.append("check"); return changed() },
        prepare: { _ in steps.append("prepare") },
        click: { steps.append("click"); clicks.append($0) })
    expect(delivered == .satisfied && clicks == [point], "unchanged geometry delivers the observed point once")
    expect(steps == ["check", "prepare", "check", "click"],
           "the last geometry check follows hover preparation immediately before delivery")
}

// MARK: - Accessibility: selecting a control

typealias AXControl = Accessibility.Control
func ctl(_ role: String, _ label: String, _ value: String? = nil) -> AXControl {
    AXControl(role: role, label: label, value: value, center: .zero, enabled: true, pressable: true)
}
let axControls = [
    ctl("AXButton", "Done"),
    ctl("AXButton", "Cancel"),
    ctl("AXPopUpButton", "", "Off"),
    ctl("AXButton", "Details"),
]
func axPick(_ needle: String) -> Int? {
    if case .success(let i) = Accessibility.select(needle, from: axControls) { return i }
    return nil
}
expect(axPick("Done") == 0, "exact label match")
expect(axPick("done") == 0, "matching is case-insensitive")
expect(axPick("Off") == 2, "a popup is matched by its current value when it has no label")
expect(axPick("etail") == 3, "a substring naming one control resolves")
if case .failure(.noControl) = Accessibility.select("Missing", from: axControls) {} else {
    expect(false, "no match is reported as noControl")
}
if case .failure(.ambiguous(_, let matches)) = Accessibility.select("e", from: axControls) {
    expect(matches.count >= 3, "a substring shared by several controls is refused, listing them")
} else {
    expect(false, "a substring in several controls should be ambiguous")
}
let saveButtons = [ctl("AXButton", "Save"), ctl("AXButton", "Save As…")]
if case .success(let i) = Accessibility.select("Save", from: saveButtons) {
    expect(i == 0, "an exact whole-label match wins over a longer label that merely contains the needle")
} else {
    expect(false, "'Save' should resolve to the exact button, not be ambiguous with 'Save As…'")
}

// MARK: - Input

expect(Input.distribute(10, over: 3) == [3, 3, 4], "remainder goes on the last step")
expect(Input.distribute(-7, over: 2) == [-3, -4], "negative totals distribute too")
expect(Input.distribute(5, over: 0) == [5], "zero steps is one step")
expect(Input.distribute(-13, over: 6).reduce(0, +) == -13, "parts always sum to the total")

// MARK: - Keyboard

if let lower = Keyboard.stroke(for: "a") {
    expect(!lower.shift, "a lowercase letter is an unshifted key")
    expect(Keyboard.stroke(for: "A") == Keyboard.Stroke(code: lower.code, shift: true),
           "its capital is the same key with shift held")
} else {
    expect(false, "the active layout has no key for 'a'")
}
expect(Keyboard.stroke(for: "\n")?.code == CGKeyCode(kVK_Return), "newline types the Return key")
expect(Keyboard.stroke(for: "\t")?.code == CGKeyCode(kVK_Tab), "tab types the Tab key")
expect(Keyboard.stroke(for: "😀") == nil, "a character no key produces travels as text")

// MARK: - Text: OCR border coordinate mapping

// With no border, the normalised->screen mapping is the plain one.
let plain = Text.screenRect(nx: 0.5, ny: 0.5, nw: 0.1, nh: 0.1,
                            border: 0, paddedWidth: 200, paddedHeight: 100,
                            imageWidth: 200, imageHeight: 100,
                            shotRect: CGRect(x: 10, y: 20, width: 400, height: 300))
expect(plain == CGRect(x: 10 + 0.5*400, y: 20 + (1-0.5-0.1)*300, width: 0.1*400, height: 0.1*300),
       "border 0 reduces to the direct normalised-to-screen mapping")

// A 10px border on a 200x100 image: padded is 220x120. A box at the very top-
// left of the ORIGINAL content sits at padded-normalised x=10/220, and its
// screen point must map back to the shot's own origin, not 10px inside it.
// Box at padded top-left pixel (10,10), size 20x8. Vision's origin is
// bottom-left, so ny = (paddedHeight - topPixel - height)/paddedHeight.
let originBox = Text.screenRect(
    nx: 10.0/220.0, ny: (120.0 - 10.0 - 8.0)/120.0, nw: 20.0/220.0, nh: 8.0/120.0,
    border: 10, paddedWidth: 220, paddedHeight: 120,
    imageWidth: 200, imageHeight: 100,
    shotRect: CGRect(x: 0, y: 0, width: 200, height: 100))
expect(abs(originBox.minX - 0) < 0.001 && abs(originBox.minY - 0) < 0.001,
       "a glyph flush to the original top-left maps back to the shot origin, border subtracted")
expect(abs(originBox.width - 20) < 0.001 && abs(originBox.height - 8) < 0.001,
       "the border does not distort width or height at 1:1 scale")

// Border sizing and dark detection are simple but load-bearing.
expect(Text.paddingBorder(makeImage(3024)!) == 30, "border is ~1% of the smaller side")
expect(Text.paddingBorder(makeImage(50)!) == 12, "border never drops below 12px")

// MARK: - Capture: cropping

func blankImage(_ size: Int) -> CGImage? {
    CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
}
if let image = blankImage(100) {
    let shot = Capture.Shot(image: image, rect: CGRect(x: 0, y: 0, width: 50, height: 50),
                            scale: 2, scaleSource: .measured)
    do {
        let cropped = try Capture.crop(shot, to: CGRect(x: 25, y: 25, width: 50, height: 50))
        expect(cropped.rect == CGRect(x: 25, y: 25, width: 25, height: 25),
               "a region hanging off the edge is clipped and its rect says so")
        expect(cropped.image.width == 50 && cropped.image.height == 50, "clipped pixels match the clipped rect")
        let inside = try Capture.crop(shot, to: CGRect(x: 10, y: 20, width: 20, height: 10))
        expect(inside.rect == CGRect(x: 10, y: 20, width: 20, height: 10) && inside.image.width == 40,
               "a region inside the shot maps to pixels at the measured scale")
    } catch {
        expect(false, "crop threw \(error)")
    }
    expect((try? Capture.crop(shot, to: CGRect(x: 100, y: 100, width: 10, height: 10))) == nil,
           "a region outside the shot is an error, not a whole-shot fallback")
} else {
    expect(false, "could not make a test image")
}

// MARK: - Origin: is a record still worth acting on?

do {
    let now = Date()
    let fresh = System.Origin.Record(pid: 4242, name: "Terminal", bundleID: "com.apple.Terminal", recordedAt: now.addingTimeInterval(-60))
    expect(System.Origin.usable(fresh, running: { $0 == 4242 }, now: now) == fresh,
           "a fresh record whose app is running is usable")
    expect(System.Origin.usable(fresh, running: { _ in false }, now: now) == nil,
           "a record whose app has quit is dropped: pids are recycled")
    let old = System.Origin.Record(pid: 4242, name: "Terminal", bundleID: nil,
                                   recordedAt: now.addingTimeInterval(-System.Origin.maximumAge - 1))
    expect(System.Origin.usable(old, running: { _ in true }, now: now) == nil,
           "a record older than maximumAge is a leftover, not a destination")
    let future = System.Origin.Record(pid: 4242, name: "Terminal", bundleID: nil, recordedAt: now.addingTimeInterval(3600))
    expect(System.Origin.usable(future, running: { _ in true }, now: now) == nil,
           "a record from the future (clock moved) is not trusted")
    expect(System.Origin.usable(nil, running: { _ in true }, now: now) == nil, "no record is no origin")
}

if failures > 0 { exit(1) }
print("ok: macctl unit tests")
