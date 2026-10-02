import CoreGraphics
import MacControlKit

func runControlTests(_ expect: (Bool, String) -> Void) {
    typealias Control = Accessibility.Control
    typealias Selector = Accessibility.Selector

    func control(_ role: String, _ label: String = "", value: String? = nil,
                 id: String? = nil, placeholder: String? = nil,
                 enabled: Bool = true, pressable: Bool = true,
                 settable: Bool = false, secure: Bool = false) -> Control {
        Control(role: role, label: label, value: value, center: .zero,
                enabled: enabled, pressable: pressable, identifier: id,
                url: "https://example.invalid/unrelated-destination",
                placeholder: placeholder, valueSettable: settable, secure: secure)
    }

    func selected(_ selector: Selector, _ controls: [Control], truncated: Bool = false) -> Int? {
        try? Accessibility.select(selector, from: controls, truncated: truncated).get()
    }

    let controls = [
        control("AXButton", "Save", id: "save-primary"),
        control("AXMenuItem", "Save", id: "save-menu"),
        control("AXButton", "Save As…", id: "save-as"),
        control("AXTextField", id: "people-search", placeholder: "Search people", settable: true),
        control("AXLink", "People", id: "people-link"),
    ]

    expect(Accessibility.filter(Selector(), from: controls) == controls,
           "empty discovery selector lists controls")
    expect(Accessibility.filter(Selector(needle: "Save"), from: controls).count == 3,
           "discovery retains substring matches alongside exact labels")
    expect(Accessibility.filter(Selector(needle: "Save", exact: true), from: controls).count == 2,
           "exact discovery excludes longer labels")
    expect(selected(Selector(needle: "Save"), controls) == nil,
           "duplicate exact labels refuse mutation")
    expect(selected(Selector(needle: "Save", role: "AXButton"), controls) == 0,
           "role constraint resolves duplicate labels before exact preference")
    expect(selected(Selector(needle: "Save", role: "AXLink"), controls) == nil,
           "role and label filters combine rather than compete")
    expect(selected(Selector(identifier: "people-search"), controls) == 3,
           "exact identifier targets an unnamed field")
    expect(selected(Selector(identifier: "PEOPLE-SEARCH"), controls) == nil,
           "machine identifiers are case-sensitive")
    expect(selected(Selector(identifier: "people"), controls) == nil,
           "machine identifiers never use substring fallback")
    expect(selected(Selector(role: "AXTextField"), controls) == 3,
           "a unique role can target an unnamed field")
    expect(selected(Selector(role: "AXButton"), controls) == nil,
           "a role alone refuses several controls")
    expect(selected(Selector(needle: "Search people", exact: true), controls) == 3,
           "placeholder text identifies an unnamed control")
    expect(selected(Selector(needle: "PEOPLE"), controls) == 4,
           "folded exact label beats a partial placeholder")
    expect(selected(Selector(needle: "ave", role: "AXMenuItem"), controls) == 1,
           "a unique substring remains backward compatible")
    expect(selected(Selector(needle: "ave", role: "AXMenuItem", exact: true), controls) == nil,
           "explicit exact mode prevents substring fallback")
    expect(selected(Selector(needle: "people-search"), controls) == nil,
           "identifier metadata does not expand label matching")
    expect(selected(Selector(needle: "unrelated-destination"), controls) == nil,
           "URL metadata does not expand label matching")
    expect(selected(Selector(needle: ""), controls) == nil,
           "empty text cannot silently select all controls")
    expect(selected(Selector(), [controls[0]]) == nil,
           "mutation requires an explicit selector even with one control")
    expect(selected(Selector(needle: "   "), [controls[0]]) == nil,
           "whitespace-only mutation selector refuses")
    if case .failure(.incompleteSearch) = Accessibility.select(
        Selector(identifier: "people-search"), from: controls, truncated: true
    ) {
        expect(true, "partial discovery cannot establish unique identifier")
    } else {
        expect(false, "partial discovery cannot establish unique identifier")
    }

    let disabled = control("AXButton", "Save", enabled: false)
    if case .failure(.disabled) = Accessibility.validateMutation(disabled) {} else {
        expect(false, "disabled action is refused")
    }
    let notPressable = control("AXTextField", "Name", pressable: false, settable: true)
    if case .failure(.notActionable) = Accessibility.validateMutation(notPressable) {} else {
        expect(false, "non-pressable field cannot be activated")
    }
    if case .success = Accessibility.validateMutation(notPressable, settingValue: true) {} else {
        expect(false, "AXValue setting does not require AXPress")
    }
    if case .failure(.notSettable) = Accessibility.validateMutation(controls[0], settingValue: true) {} else {
        expect(false, "non-settable value is refused")
    }
    let secure = control("AXTextField", "Password", settable: true, secure: true)
    if case .failure(.secureField) = Accessibility.validateMutation(secure, settingValue: true) {} else {
        expect(false, "secure field refuses native value setting")
    }
    expect(selected(Selector(identifier: "same"), [
        control("AXButton", "One", id: "same"), control("AXButton", "Two", id: "same"),
    ]) == nil, "duplicate machine identifiers still refuse")
    expect(Accessibility.Scope(rawValue: "window") == .window
           && Accessibility.Scope(rawValue: "app") == .app
           && Accessibility.Scope(rawValue: "page") == nil,
           "scope accepts only the two documented choices")
}
