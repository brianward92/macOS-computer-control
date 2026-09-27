import CoreGraphics
import Foundation
import Vision

/// Reading text off the screen, and turning it into somewhere to click.
///
/// This is the verification primitive. It exists because the app being driven
/// may have no useful accessibility tree at all — a game engine or a web view
/// renders its interface as pixels, so "what does the screen actually say here"
/// is the only question that can be answered.
public enum Text {

    /// One recognised piece of text and where it is.
    public struct Found: Sendable {
        public let text: String
        /// Vision's alternatives, best first. Matching accepts any of them.
        public let candidates: [String]
        /// Screen points, top-left origin.
        public let rect: CGRect
        public let confidence: Float

        public init(text: String, rect: CGRect, confidence: Float, candidates: [String] = []) {
            self.text = text
            self.rect = rect
            self.confidence = confidence
            self.candidates = candidates.isEmpty ? [text] : candidates
        }

        /// Where to click to hit it.
        public var center: CGPoint { CGPoint(x: rect.midX.rounded(), y: rect.midY.rounded()) }
    }

    /// A visual line: several recognised boxes that share a row.
    public struct Line: Sendable {
        public let text: String
        public let rect: CGRect
        public let parts: [Found]
        public var center: CGPoint { CGPoint(x: rect.midX.rounded(), y: rect.midY.rounded()) }
    }

    /// Recognise every text box in a shot, mapped back to screen points.
    ///
    /// Vision returns normalised boxes with a **bottom-left** origin, which is
    /// the opposite of every other coordinate in this library. The flip happens
    /// here, once, at the boundary.
    public static func boxes(in shot: Capture.Shot, minimumHeight: Float = 0.006) throws -> [Found] {
        let recognition = try recognize(shot, minimumHeight: minimumHeight)
        return recognition.observations.compactMap { observation in
            let candidates = observation.topCandidates(3)
            guard let candidate = candidates.first else { return nil }
            return Found(text: candidate.string,
                         rect: screenRect(for: observation.boundingBox, recognition, in: shot),
                         confidence: candidate.confidence,
                         candidates: candidates.map(\.string))
        }
    }

    /// One Vision pass, plus the border that was added around the image.
    ///
    /// A recognised box is normalised to the image Vision actually saw, so the
    /// caller needs the border to map it back. Bundling them keeps that from
    /// going wrong.
    struct Recognition {
        let observations: [VNRecognizedTextObservation]
        let border: Int
        let paddedWidth: Int
        let paddedHeight: Int
    }

    /// One Vision pass over a shot, on an image padded with a quiet border.
    ///
    /// Vision loses the first glyph of a line that sits flush against the edge
    /// of the image: "Founding" came back as "-ounding", "What" as "Vhat", off
    /// a region cropped tight to the text. The recogniser needs a margin of
    /// background around a character to see it. So the image is padded with a
    /// border in the background's own colour (light or dark, sampled from the
    /// image, so the contrast that OCR depends on is preserved), and the border
    /// is subtracted back out when boxes are mapped to the screen.
    static func recognize(_ shot: Capture.Shot, minimumHeight: Float = 0.006) throws -> Recognition {
        let border = paddingBorder(shot.image)
        let image: CGImage
        let effectiveBorder: Int
        if border > 0, let padded = pad(shot.image, border: border, dark: isDark(shot.image)) {
            image = padded
            effectiveBorder = border
        } else {
            image = shot.image
            effectiveBorder = 0
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Interface text often contains proper nouns and product names;
        // language correction can turn them into unrelated dictionary words.
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = minimumHeight
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return Recognition(observations: request.results ?? [],
                           border: effectiveBorder,
                           paddedWidth: image.width, paddedHeight: image.height)
    }

    /// The border width to pad a capture with before OCR: about 1% of the
    /// smaller side, never less than 12 pixels.
    public static func paddingBorder(_ image: CGImage) -> Int {
        max(12, min(image.width, image.height) / 100)
    }

    /// Is the image mostly dark? Drives whether the OCR border is black or
    /// white, so a dark UI keeps its light-on-dark contrast at the edge.
    static func isDark(_ image: CGImage) -> Bool {
        var pixel: [UInt8] = [0, 0, 0, 0]
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let luminance = (0.299 * Double(pixel[0]) + 0.587 * Double(pixel[1]) + 0.114 * Double(pixel[2])) / 255
        return luminance < 0.5
    }

    /// Draw the image centred on a larger canvas of a flat background colour.
    static func pad(_ image: CGImage, border: Int, dark: Bool) -> CGImage? {
        guard border > 0 else { return image }
        let width = image.width + 2 * border, height = image.height + 2 * border
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let shade: CGFloat = dark ? 0 : 1
        context.setFillColor(red: shade, green: shade, blue: shade, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: border, y: border, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// A normalised Vision box (bottom-left origin, relative to the padded
    /// image) mapped back to screen points on the original capture.
    ///
    /// Pure arithmetic, split out so the border bookkeeping can be tested
    /// without running Vision. With `border` zero it reduces to the plain
    /// normalised-to-screen mapping.
    public static func screenRect(
        nx: CGFloat, ny: CGFloat, nw: CGFloat, nh: CGFloat,
        border: Int, paddedWidth: Int, paddedHeight: Int,
        imageWidth: Int, imageHeight: Int, shotRect: CGRect
    ) -> CGRect {
        let paddedW = CGFloat(paddedWidth), paddedH = CGFloat(paddedHeight)
        let b = CGFloat(border)
        // Normalised (bottom-left) to padded-pixel (top-left).
        let xPadded = nx * paddedW
        let yPadded = (1 - ny - nh) * paddedH
        let wPadded = nw * paddedW
        let hPadded = nh * paddedH
        // Padded pixels to original pixels, then to screen points.
        let sx = shotRect.width / CGFloat(imageWidth)
        let sy = shotRect.height / CGFloat(imageHeight)
        return CGRect(
            x: shotRect.minX + (xPadded - b) * sx,
            y: shotRect.minY + (yPadded - b) * sy,
            width: wPadded * sx,
            height: hPadded * sy
        )
    }

    static func screenRect(for box: CGRect, _ recognition: Recognition, in shot: Capture.Shot) -> CGRect {
        screenRect(nx: box.origin.x, ny: box.origin.y, nw: box.size.width, nh: box.size.height,
                   border: recognition.border,
                   paddedWidth: recognition.paddedWidth, paddedHeight: recognition.paddedHeight,
                   imageWidth: shot.image.width, imageHeight: shot.image.height, shotRect: shot.rect)
    }

    /// Merge boxes that share a row into visual lines.
    ///
    /// Vision returns "3x" and the label beside it as separate boxes, so
    /// anything reading a list has to group them or every row parses as a label
    /// with no count.
    ///
    /// The tolerance cuts both ways, and this is worth knowing before trusting
    /// the output: too generous and a neighbouring row bleeds in. That produced
    /// a real failure — an adjacent row's count landed inside the row above,
    /// the merged text matched nothing the caller knew about, the row was
    /// treated as unwanted, and an automated edit removed every copy of
    /// something it was supposed to keep. Never act destructively on text that
    /// failed to match.
    public static func mergeLines(
        _ found: [Found],
        captureHeight: CGFloat,
        tolerance: CGFloat = 0.012,
        maximumGapScale: CGFloat = 1.5
    ) -> [Line] {
        let found = found.sorted {
            $0.rect.midY == $1.rect.midY ? $0.rect.minX < $1.rect.minX : $0.rect.midY < $1.rect.midY
        }
        let band = tolerance * captureHeight
        let heights = found.map(\.rect.height).sorted()
        let medianHeight = heights.isEmpty ? 0 : heights[heights.count / 2]
        let maximumGap = maximumGapScale * medianHeight
        var lines: [[Found]] = []
        for box in found {
            if let index = lines.firstIndex(where: { line in
                guard abs((line.first?.rect.midY ?? 0) - box.rect.midY) < band else { return false }
                let rightEdge = line.map(\.rect.maxX).max() ?? box.rect.minX
                return box.rect.minX - rightEdge <= maximumGap
            }) {
                lines[index].append(box)
            } else {
                lines.append([box])
            }
        }
        return lines.map { parts in
            let ordered = parts.sorted { $0.rect.minX < $1.rect.minX }
            let union = ordered.dropFirst().reduce(ordered[0].rect) { $0.union($1.rect) }
            return Line(text: ordered.map(\.text).joined(separator: " "), rect: union, parts: ordered)
        }
    }

    public static func lines(in shot: Capture.Shot, tolerance: CGFloat = 0.012) throws -> [Line] {
        mergeLines(try boxes(in: shot), captureHeight: shot.rect.height, tolerance: tolerance)
    }

    /// Vision substitutes visually identical letters from other alphabets — a
    /// Latin-looking label can come back with Cyrillic in it — so observed
    /// substitutions are folded back before matching. Deliberately narrower
    /// than transliteration: only lookalikes, never phonetic equivalents.
    static let homoglyphs: [Character: Character] = [
        "\u{0430}": "a", "\u{0435}": "e", "\u{043e}": "o", "\u{0440}": "p",
        "\u{0441}": "c", "\u{0443}": "y", "\u{0445}": "x", "\u{0456}": "i",
        "\u{0410}": "A", "\u{0415}": "E", "\u{041e}": "O", "\u{0420}": "P",
        "\u{0421}": "C", "\u{0422}": "T", "\u{0425}": "X", "\u{041a}": "K",
        "\u{0412}": "B", "\u{041c}": "M", "\u{041d}": "H", "\u{0406}": "I",
        "\u{0391}": "A", "\u{0392}": "B", "\u{0395}": "E", "\u{039f}": "O",
        "\u{03a1}": "P", "\u{03a4}": "T", "\u{0396}": "Z", "\u{039d}": "N",
        // Additional substitutions observed in Vision output. Some are only
        // approximate, so this remains deliberately narrower than transliteration.
        "\u{0439}": "i", "\u{0438}": "n", "\u{043d}": "h", "\u{043a}": "k",
        "\u{0442}": "t", "\u{0432}": "b", "\u{043c}": "m", "\u{0433}": "r",
        "\u{0455}": "s", "\u{0458}": "j", "\u{04bb}": "h", "\u{0405}": "S",
        "\u{0408}": "J", "\u{0417}": "3", "\u{0409}": "L",
    ]

    /// Normalise recognised text for comparison: fold lookalikes, lowercase,
    /// and collapse whitespace. Matching should not care which alphabet Vision
    /// reached for.
    public static func fold(_ text: String) -> String {
        let mapped = String(text.map { homoglyphs[$0] ?? $0 })
        return mapped.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// How well a needle matches a piece of recognised text.
    ///
    /// A button labelled "7" is a box whose whole text is "7". The digit 7
    /// inside "272.00004" on a display is not that button, and neither is the
    /// "8" in "80". So matches are read the way a person reads labels: the
    /// whole label first, then a whole word inside a longer label, and only
    /// then any substring. `find` keeps only the best level found, so a
    /// display showing a total does not make the keypad ambiguous.
    public enum MatchQuality: Int, Comparable, Sendable {
        case none = 0
        case substring = 1
        case word = 2
        case exact = 3

        public static func < (a: MatchQuality, b: MatchQuality) -> Bool { a.rawValue < b.rawValue }
    }

    /// Is this occurrence a whole word: bounded by non-alphanumerics or ends?
    static func isWholeWord(_ occurrence: Range<String.Index>, in text: String) -> Bool {
        let before = occurrence.lowerBound == text.startIndex
            ? nil : text[text.index(before: occurrence.lowerBound)]
        let after = occurrence.upperBound == text.endIndex ? nil : text[occurrence.upperBound]
        func bounds(_ c: Character?) -> Bool { c.map { !$0.isLetter && !$0.isNumber } ?? true }
        return bounds(before) && bounds(after)
    }

    /// Every occurrence of `wanted` in `text`, overlapping ones included.
    static func occurrences(of wanted: String, in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var from = text.startIndex
        while from < text.endIndex,
              let hit = text.range(of: wanted, options: [], range: from..<text.endIndex) {
            found.append(hit)
            from = text.index(after: hit.lowerBound)
        }
        return found
    }

    /// The quality of the best occurrence. Both arguments already folded.
    public static func quality(ofFolded wanted: String, inFolded text: String) -> MatchQuality {
        guard !wanted.isEmpty else { return .none }
        if text == wanted { return .exact }
        let hits = occurrences(of: wanted, in: text)
        guard !hits.isEmpty else { return .none }
        return hits.contains { isWholeWord($0, in: text) } ? .word : .substring
    }

    /// Keep only the items that match at the best level present.
    public static func keepBest<T>(_ items: [(T, MatchQuality)]) -> [T] {
        guard let best = items.map(\.1).max(), best > .none else { return [] }
        return items.filter { $0.1 == best }.map(\.0)
    }

    /// Where an already-folded needle sits inside unfolded text.
    ///
    /// Folding is not reversible — it drops diacritics, swaps alphabets and
    /// collapses whitespace — so the text is folded one character at a time
    /// with a map back to where each folded character came from. The result
    /// is a range in the original string, which is what Vision needs to say
    /// where on screen that part of the line is. A whole-word occurrence is
    /// preferred over one buried inside another word.
    public static func range(ofFolded wanted: String, in text: String) -> Range<String.Index>? {
        guard !wanted.isEmpty else { return nil }
        var folded = ""
        var origins: [String.Index] = []
        var lastWasSpace = true
        for index in text.indices {
            let character = text[index]
            if character.isWhitespace {
                if lastWasSpace { continue }
                folded.append(" ")
                origins.append(index)
                lastWasSpace = true
                continue
            }
            lastWasSpace = false
            let mapped = String(homoglyphs[character] ?? character)
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            for piece in mapped {
                folded.append(piece)
                origins.append(index)
            }
        }
        let hits = occurrences(of: wanted, in: folded)
        guard let hit = hits.first(where: { isWholeWord($0, in: folded) }) ?? hits.first else { return nil }
        let start = folded.distance(from: folded.startIndex, to: hit.lowerBound)
        let end = folded.distance(from: folded.startIndex, to: hit.upperBound)
        guard end > start, end <= origins.count else { return nil }
        return origins[start]..<text.index(after: origins[end - 1])
    }

    /// Find text on screen, returning somewhere to click.
    ///
    /// Matching is case-insensitive, against individual boxes first and merged
    /// lines second, because a label may be split across boxes. Within boxes
    /// the best match level wins — whole label, then whole word, then any
    /// substring — and a hit inside a longer box is narrowed to the matched
    /// words. A hit found only through a merged line carries that whole line's
    /// rect, so its centre can sit between two controls: read with `--boxes`
    /// and click the box when the row holds more than one thing.
    public static func find(_ needle: String, in shot: Capture.Shot) throws -> [Found] {
        let wanted = fold(needle)
        guard !wanted.isEmpty else { return [] }
        let recognition = try recognize(shot)
        let observations = recognition.observations

        // Vision reports a whole line of words as one observation, so a hit
        // on "Shell" inside "Terminal Shell Edit View" is narrowed to the box
        // of that word. Without this, the click point is the middle of the
        // line, which is the gap between two other menus.
        //
        // Every hit is ranked by how well it matches, and only the best level
        // survives: a keypad button whose label is "7" beats the 7 inside the
        // total on the display, so the display cannot make the keypad
        // ambiguous, and cannot be clicked in its place.
        var ranked: [(Found, MatchQuality)] = []
        var all: [Found] = []
        for observation in observations {
            let candidates = observation.topCandidates(3)
            guard let top = candidates.first else { continue }
            let whole = screenRect(for: observation.boundingBox, recognition, in: shot)
            all.append(Found(text: top.string, rect: whole, confidence: top.confidence,
                             candidates: candidates.map(\.string)))
            var best: (VNRecognizedText, MatchQuality)?
            for candidate in candidates {
                let quality = quality(ofFolded: wanted, inFolded: fold(candidate.string))
                if quality > (best?.1 ?? .none) { best = (candidate, quality) }
            }
            guard let (matched, quality) = best else { continue }
            var narrowed = whole
            if quality != .exact,
               let range = range(ofFolded: wanted, in: matched.string),
               let part = try? matched.boundingBox(for: range) {
                let candidate = screenRect(for: part.boundingBox, recognition, in: shot)
                if candidate.width > 0, candidate.height > 0 { narrowed = candidate }
            }
            ranked.append((Found(text: top.string, rect: narrowed, confidence: matched.confidence,
                                 candidates: candidates.map(\.string)), quality))
        }
        let hits = keepBest(ranked)
        if !hits.isEmpty { return hits }
        return mergeLines(all, captureHeight: shot.rect.height)
            .filter { fold($0.text).contains(wanted) }
            .map { Found(text: $0.text, rect: $0.rect, confidence: 1) }
    }

    public static func matches(_ needle: String, candidates: [String]) -> Bool {
        let wanted = fold(needle)
        return candidates.contains { fold($0).contains(wanted) }
    }
}
