import Foundation

/// LRC parsing, ported from `LrcLib.parseLrc` / `parseWordRuns` in the shared
/// Kotlin code, including its gap rules:
///
/// - `[mm:ss.xx]` line stamps, `<mm:ss.xx>` enhanced word stamps;
/// - a stamp with no words marks an instrumental break, kept only where the
///   silence that follows runs at least `MIN_GAP_MS` (4s) — otherwise the
///   line would blink out between two sung phrases;
/// - a trailing stamp closes the final line and always survives;
/// - when the first sung line starts at least 4s in, the intro gets its own
///   gap line at 0;
/// - word runs glue into one word while no whitespace separates them (a run
///   with no space after it is one syllable of a word that carries on).
enum LRCParser {
    static let minGapMs = 4_000

    private static let lineStampRegex = try! NSRegularExpression(
        pattern: #"\[(\d{1,2}):(\d{2})[.:](\d{2,3})]"#
    )
    private static let wordStampRegex = try! NSRegularExpression(
        pattern: #"<(\d{1,3}):(\d{2})[.:](\d{2,3})>"#
    )
    private static let alignmentMarker = "<R>"

    static func parse(_ lrc: String) -> [LyricLine] {
        var all: [LyricLine] = []
        for rawLine in lrc.components(separatedBy: .newlines) {
            let range = NSRange(rawLine.startIndex..., in: rawLine)
            guard let match = lineStampRegex.firstMatch(in: rawLine, range: range),
                  let stampRange = Range(match.range, in: rawLine),
                  let timeMs = stampMs(match, in: rawLine) else { continue }
            var body = String(rawLine[stampRange.upperBound...])
            // The RTL marker written by Android's enhanced-LRC writer.
            if body.hasPrefix(alignmentMarker) { body = String(body.dropFirst(alignmentMarker.count)) }
            let text = wordStampRegex.stringByReplacingMatches(
                in: body, range: NSRange(body.startIndex..., in: body), withTemplate: ""
            ).trimmingCharacters(in: .whitespaces)
            all.append(LyricLine(timeMs: timeMs, text: text, words: parseWordRuns(body)))
        }
        all.sort { $0.timeMs < $1.timeMs }

        let kept = all.enumerated().filter { index, line in
            if !line.isGap { return true }
            // A trailing stamp closes off the last line — that's the outro.
            guard index + 1 < all.count else { return true }
            return all[index + 1].timeMs - line.timeMs >= minGapMs
        }.map { $0.element }

        guard let first = kept.first else { return kept }
        if !first.isGap && first.timeMs >= minGapMs {
            return [LyricLine(timeMs: 0, text: "")] + kept
        }
        return kept
    }

    /// Untimed lines for plain-text lyrics (YouTube Music's tab, embedded
    /// text): one `LyricLine` per non-empty line, all stamped 0.
    static func parsePlain(_ text: String) -> [LyricLine] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { LyricLine(timeMs: 0, text: $0) }
    }

    /// Whether a text blob carries LRC timestamps (embedded lyrics are
    /// sometimes already synced LRC).
    static func looksSynced(_ text: String) -> Bool {
        lineStampRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func parseWordRuns(_ body: String) -> [LyricWord] {
        let matches = wordStampRegex.matches(in: body, range: NSRange(body.startIndex..., in: body))
        guard !matches.isEmpty else { return [] }

        struct Run { var startMs: Int; var raw: String }
        var runs: [Run] = []
        for (index, match) in matches.enumerated() {
            guard let stampRange = Range(match.range, in: body), let start = stampMs(match, in: body) else { continue }
            let endBound: String.Index
            if index + 1 < matches.count, let nextRange = Range(matches[index + 1].range, in: body) {
                endBound = nextRange.lowerBound
            } else {
                endBound = body.endIndex
            }
            runs.append(Run(startMs: start, raw: String(body[stampRange.upperBound..<endBound])))
        }

        // Each run ends where the next begins (the final bare stamp is a
        // terminator that exists only to give the last word an end).
        // Runs glue while no whitespace separates them.
        let glue = runs.contains { $0.raw.contains(where: { $0.isWhitespace }) }
        var words: [LyricWord] = []
        var currentText = ""
        var currentStart = 0
        var currentEnd = 0

        func flush() {
            if !currentText.isEmpty {
                words.append(LyricWord(startMs: currentStart, endMs: max(currentStart, currentEnd), text: currentText))
                currentText = ""
            }
        }

        for (index, run) in runs.enumerated() {
            let content = run.raw.trimmingCharacters(in: .whitespaces)
            let runEnd = index + 1 < runs.count ? runs[index + 1].startMs : run.startMs
            if content.isEmpty {
                currentEnd = max(currentEnd, runEnd)
                flush()
                continue
            }
            // A word boundary is marked by whitespace on either side of the
            // seam: most writers trail it on the finished word (`lo ␣`),
            // some lead it on the next one (`␣world`). No whitespace on
            // either side means this run is the same word carrying on.
            let previousEndedWord = index > 0 && (runs[index - 1].raw.last?.isWhitespace ?? false)
            let joins = glue && !currentText.isEmpty && !previousEndedWord
                && !(run.raw.first?.isWhitespace ?? false)
            if !joins { flush() }
            if currentText.isEmpty { currentStart = run.startMs }
            currentText += content
            currentEnd = runEnd
        }
        flush()
        return words
    }

    private static func stampMs(_ match: NSTextCheckingResult, in source: String) -> Int? {
        func group(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: source) else { return nil }
            return String(source[range])
        }
        guard let minutes = group(1).flatMap(Int.init),
              let seconds = group(2).flatMap(Int.init),
              let fraction = group(3) else { return nil }
        // Two digits mean centiseconds, three mean milliseconds.
        let fractionMs: Int
        switch fraction.count {
        case 2: fractionMs = (Int(fraction) ?? 0) * 10
        case 3: fractionMs = Int(fraction) ?? 0
        default: fractionMs = 0
        }
        return minutes * 60_000 + seconds * 1_000 + fractionMs
    }
}

/// The title/artist cleanup LRCLIB matching needs, ported from `String.clean`
/// in `LrcLib.kt`: YouTube Music titles carry "(From …)", "| Official Video"
/// and "(Lyrical)" noise that LRCLIB's exact endpoint won't match.
enum LyricsQueryCleaner {
    private static let noiseRegex = try! NSRegularExpression(
        pattern: #"\((?:from|feat\.?|official|lyrical|video|audio|remix)[^)]*\)|\[[^\]]*\]|\b(?:official (?:video|audio|music video)|lyrical|full song|4k video)\b"#,
        options: [.caseInsensitive]
    )
    private static let whitespaceRegex = try! NSRegularExpression(pattern: #"\s+"#)

    static func clean(_ value: String) -> String {
        var result = noiseRegex.stringByReplacingMatches(
            in: value, range: NSRange(value.startIndex..., in: value), withTemplate: " "
        )
        if let pipe = result.range(of: " | ") {
            result = String(result[..<pipe.lowerBound])
        }
        result = whitespaceRegex.stringByReplacingMatches(
            in: result, range: NSRange(result.startIndex..., in: result), withTemplate: " "
        ).trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? value : result
    }
}
