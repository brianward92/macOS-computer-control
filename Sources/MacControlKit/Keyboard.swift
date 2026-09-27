import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Keyboard input via CGEvent.
///
/// Deliberately not AppleScript. Passing text through `osascript` means
/// building a script string, and a quote or a backslash in the text then breaks
/// out of it — which in one real case turned a single allow-listed command into
/// a route to arbitrary AppleScript. Text never becomes source here.
public enum Keyboard {

    public enum KeyboardError: Error, CustomStringConvertible {
        case secureInputActive(pid: pid_t?)
        case unknownKey(String)
        case untypableCharacter(Character)

        public var description: String {
            switch self {
            case .secureInputActive(let pid):
                let owner = pid.map { " (held by pid \($0))" } ?? ""
                return "Secure Event Input is active\(owner); synthetic keystrokes are ignored system-wide"
            case .unknownKey(let k):
                return "unknown key: \(k)"
            case .untypableCharacter(let c):
                return "cannot type character: \(c)"
            }
        }
    }

    /// Is some app holding Secure Event Input?
    ///
    /// While a password field or Terminal's Secure Keyboard Entry holds it,
    /// every synthetic keystroke is silently discarded. Nothing errors, the
    /// characters simply never arrive — so this is checked and refused rather
    /// than discovered by watching an empty text field.
    public static var isSecureInputActive: Bool { IsSecureEventInputEnabled() }

    /// Keys that have names rather than characters.
    private static let namedKeys: [String: CGKeyCode] = [
        "return": CGKeyCode(kVK_Return), "enter": CGKeyCode(kVK_Return),
        "tab": CGKeyCode(kVK_Tab), "space": CGKeyCode(kVK_Space),
        "delete": CGKeyCode(kVK_Delete), "backspace": CGKeyCode(kVK_Delete),
        "forwarddelete": CGKeyCode(kVK_ForwardDelete), "fwddelete": CGKeyCode(kVK_ForwardDelete),
        "escape": CGKeyCode(kVK_Escape), "esc": CGKeyCode(kVK_Escape),
        "left": CGKeyCode(kVK_LeftArrow), "right": CGKeyCode(kVK_RightArrow),
        "up": CGKeyCode(kVK_UpArrow), "down": CGKeyCode(kVK_DownArrow),
        "home": CGKeyCode(kVK_Home), "end": CGKeyCode(kVK_End),
        "pageup": CGKeyCode(kVK_PageUp), "pagedown": CGKeyCode(kVK_PageDown),
        "f1": CGKeyCode(kVK_F1), "f2": CGKeyCode(kVK_F2), "f3": CGKeyCode(kVK_F3),
        "f4": CGKeyCode(kVK_F4), "f5": CGKeyCode(kVK_F5), "f6": CGKeyCode(kVK_F6),
        "f7": CGKeyCode(kVK_F7), "f8": CGKeyCode(kVK_F8), "f9": CGKeyCode(kVK_F9),
        "f10": CGKeyCode(kVK_F10), "f11": CGKeyCode(kVK_F11), "f12": CGKeyCode(kVK_F12),
    ]

    /// The ANSI US layout, used only when the active layout cannot be read.
    private static let ansiCodes: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8,
        "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33,
        "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
        "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
    ]

    /// A key, and whether shift is held, that produces one character.
    public struct Stroke: Sendable, Equatable {
        public let code: CGKeyCode
        public let shift: Bool
        public init(code: CGKeyCode, shift: Bool) {
            self.code = code
            self.shift = shift
        }
    }

    /// Which key produces each character under the keyboard layout in use.
    ///
    /// Asked of the layout itself rather than assumed to be ANSI US, because a
    /// chord is a key code and a key code is a position: on a QWERTZ or AZERTY
    /// keyboard `cmd+z` sent with the US code lands on `y` or `w`, and the app
    /// does something else without complaint. Unshifted keys are asked first,
    /// then shifted ones, so `a` and `A` share a key and differ by shift.
    private static let layoutStrokes: [Character: Stroke] = {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return [:] }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var map: [Character: Stroke] = [:]
        data.withUnsafeBytes { raw in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return }
            for (modifiers, shift) in [(UInt32(0), false), (UInt32(shiftKey >> 8), true)] {
                for code in CGKeyCode(0)..<128 {
                    var deadKeys: UInt32 = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    var length = 0
                    let status = UCKeyTranslate(
                        layout, code, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
                        UInt32(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars
                    )
                    guard status == noErr, length == 1, let scalar = Unicode.Scalar(chars[0]) else { continue }
                    let character = Character(scalar)
                    if map[character] == nil { map[character] = Stroke(code: code, shift: shift) }
                }
            }
        }
        return map
    }()

    /// The keystroke that types one character on the active layout, if any.
    /// Newline and tab are the Return and Tab keys; anything the layout cannot
    /// produce (an emoji, another script) is nil and travels as text instead.
    public static func stroke(for character: Character) -> Stroke? {
        switch character {
        case "\n", "\r", "\r\n": return Stroke(code: CGKeyCode(kVK_Return), shift: false)
        case "\t": return Stroke(code: CGKeyCode(kVK_Tab), shift: false)
        default: return layoutStrokes[character] ?? ansiCodes[character].map { Stroke(code: $0, shift: false) }
        }
    }

    /// The key code for a chord part: a named key, or one character.
    static func keyCode(for name: String) -> CGKeyCode? {
        if let code = namedKeys[name] { return code }
        guard name.count == 1, let character = name.first else { return nil }
        return stroke(for: character)?.code
    }

    private static let modifiers: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand,
        "shift": .maskShift,
        "opt": .maskAlternate, "option": .maskAlternate, "alt": .maskAlternate,
        "ctrl": .maskControl, "control": .maskControl,
        "fn": .maskSecondaryFn,
    ]

    /// Press a chord such as `cmd+q`, `cmd+shift+4`, `escape`.
    public static func press(_ chord: String) throws {
        guard !isSecureInputActive else { throw KeyboardError.secureInputActive(pid: nil) }

        var flags: CGEventFlags = []
        var keyName: String?
        for part in chord.lowercased().split(separator: "+").map(String.init) {
            if let modifier = modifiers[part] {
                flags.insert(modifier)
            } else {
                keyName = part
            }
        }
        guard let keyName, let code = keyCode(for: keyName) else {
            throw KeyboardError.unknownKey(keyName ?? chord)
        }

        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        usleep(20_000)
        up.post(tap: .cghidEventTap)
    }

    /// Type literal text, one real keystroke per character.
    ///
    /// Each character is posted as its own key down and up, carrying the key
    /// code the active layout uses for it, the shift flag if it needs one, and
    /// the character itself. Batching several characters into one event is
    /// tempting and wrong: a text field inserts the whole string, but anything
    /// that reads keys rather than text — a calculator, a game, a terminal —
    /// sees one keypress and drops the rest. Measured: "12" typed as one event
    /// reached Calculator as "1".
    ///
    /// A character the layout cannot produce still arrives, as text on a key
    /// event with no meaningful key code, which is what an input method sends.
    public static func type(_ text: String, perKeyMs: UInt32 = 5) throws {
        guard !isSecureInputActive else { throw KeyboardError.secureInputActive(pid: nil) }

        let source = CGEventSource(stateID: .hidSystemState)
        for character in text {
            let stroke = stroke(for: character)
            let code = stroke?.code ?? 0
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
            else { continue }
            if stroke?.shift == true {
                down.flags = .maskShift
                up.flags = .maskShift
            }
            let carried: String = (character == "\n" || character == "\r\n") ? "\r" : String(character)
            let units = Array(carried.utf16)
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            down.post(tap: .cghidEventTap)
            usleep(perKeyMs * 1000)
            up.post(tap: .cghidEventTap)
            usleep(perKeyMs * 1000)
        }
    }
}
