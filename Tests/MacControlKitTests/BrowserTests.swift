import Foundation
import MacControlKit

func runBrowserTests(_ expect: (Bool, String) -> Void) {
    var address = Browser.Node(role: "AXTextField")
    address.identifier = "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD"
    address.value = "https://typed.example/unsent"
    address.focused = true
    var page = Browser.Node(role: "AXWebArea")
    page.url = "https://committed.example/document"
    page.title = "Document"
    page.loaded = true
    page.loadingProgress = 1
    page.busy = false
    var tab = Browser.Node(role: "AXRadioButton")
    tab.subrole = "AXTabButton"
    tab.title = "Document"
    tab.value = "1"
    tab.index = 3
    tab.identifier = "observed-tab-flags"
    var window = Browser.Node(role: "AXWindow", children: [address, page, tab])
    window.title = "Document window"
    window.identifier = "observed-window"
    let observed = Browser.inspect(window: window, source: "AXFocusedWindow")
    expect(observed.page.url == page.url, "browser URL comes from committed document, not address edit")
    expect(observed.address.value == address.value && observed.address.focused == true, "browser preserves separate address edit")
    expect(observed.page.source == "AXWebArea.AXURL", "browser reports URL provenance")
    expect(observed.page.loaded == true && observed.page.busy == false, "browser preserves loading evidence")
    expect(observed.tabs.first?.index == 3 && observed.tabs.first?.selected == true, "browser reports observed tab index and selection")

    var changingWindow = window
    changingWindow.identifier = "another-window"
    expect(!Browser.isCoherent(observed, Browser.inspect(window: changingWindow, source: "AXFocusedWindow")), "browser rejects a changed window identity")
    changingWindow = window
    changingWindow.children[1].url = "https://another.example/document"
    expect(!Browser.isCoherent(observed, Browser.inspect(window: changingWindow, source: "AXFocusedWindow")), "browser rejects document changes within the same window")
    changingWindow = window
    changingWindow.children[2].value = "0"
    expect(!Browser.isCoherent(observed, Browser.inspect(window: changingWindow, source: "AXFocusedWindow")), "browser rejects changed tab selection even with the same document title")
    changingWindow = window
    changingWindow.children[1].loadingProgress = 0.5
    expect(Browser.isCoherent(observed, Browser.inspect(window: changingWindow, source: "AXFocusedWindow")), "browser permits load progress to change without conflating documents")

    let startPage = Browser.inspect(window: Browser.Node(role: "AXWindow", children: [address]), source: "AXMainWindow")
    expect(startPage.page.url == nil, "address bar alone never becomes committed URL")
    expect(startPage.page.loaded == nil && startPage.page.title == nil, "no web area does not invent loaded document")

    var fallback = Browser.Node(role: "AXWindow", children: [address])
    fallback.document = "https://document.example/"
    let fallbackResult = Browser.inspect(window: fallback, source: "AXMainWindow")
    expect(fallbackResult.page.url == fallback.document && fallbackResult.page.source == "AXWindow.AXDocument", "window document supplies committed fallback")

    var frame = Browser.Node(role: "AXWebArea")
    frame.url = "https://frame.example/"
    var outer = page
    outer.children = [frame]
    let framed = Browser.inspect(window: Browser.Node(role: "AXWindow", children: [outer]), source: "AXFocusedWindow")
    expect(framed.page.url == page.url, "nested iframe URL does not compete with outer document")
    let ambiguous = Browser.inspect(window: Browser.Node(role: "AXWindow", children: [page, frame]), source: "AXFocusedWindow")
    expect(ambiguous.page.url == nil && ambiguous.page.loaded == nil, "multiple outer web areas remain unknown")

    let partial = Browser.inspect(window: Browser.Node(role: "AXWindow", children: [page], complete: false), source: "AXFocusedWindow")
    expect(!partial.complete && partial.page.url == nil, "incomplete tree cannot establish a unique web area")
    let partialAddress = Browser.inspect(window: Browser.Node(role: "AXWindow", children: [address], complete: false), source: "AXFocusedWindow")
    expect(partialAddress.address.value == nil && partialAddress.address.source == nil, "incomplete tree cannot establish a unique address control")
    fallback.complete = false
    let partialDocument = Browser.inspect(window: fallback, source: "AXFocusedWindow")
    expect(!partialDocument.complete && partialDocument.page.url == fallback.document, "direct document evidence survives incomplete child tree")

    let duplicateAddress = Browser.inspect(window: Browser.Node(role: "AXWindow", children: [address, address, page]), source: "AXFocusedWindow")
    expect(duplicateAddress.address.value == nil, "ambiguous address controls are not guessed")
    expect(Browser.stringValue(URL(string: "https://url.example/path")! as NSURL) == "https://url.example/path", "browser handles CFURL/NSURL evidence")
    expect(Browser.stringValue("https://string.example/" as NSString) == "https://string.example/", "browser handles AXDocument string evidence")

    do {
        let encoded = try JSONEncoder().encode(startPage)
        let json = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        let encodedPage = json?["page"] as? [String: Any]
        expect(encodedPage?["url"] is NSNull && encodedPage?["loaded"] is NSNull, "unknown browser facts encode explicit JSON null")
        let decoded = try JSONDecoder().decode(Browser.Observation.self, from: encoded)
        expect(decoded == startPage, "browser observations round trip through Codable")
    } catch {
        expect(false, "browser JSON encoding: \(error)")
    }
}
