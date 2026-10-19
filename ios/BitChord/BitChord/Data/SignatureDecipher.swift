import Foundation
import JavaScriptCore

/// The JavaScript decipher layer — the iOS counterpart of the NewPipe
/// fallback inside Android's `StreamResolver` (`extractStream`).
///
/// Some InnerTube clients answer with `signatureCipher` instead of a direct
/// URL: the stream URL plus an obfuscated signature (`s`) that only the web
/// player's own JavaScript can unscramble, and an `n` query parameter that
/// the same script must transform or the CDN throttles/refuses the bytes.
/// This actor does what NewPipe's `YoutubeSignatureUtils` and
/// `YoutubeThrottlingDecipherer` do:
///
/// 1. find the player script (`base.js`) behind the embed page and cache it,
/// 2. locate the signature function and the helper object it calls,
/// 3. locate the `n` transform function (directly, or through the array
///    indirection newer players use),
/// 4. evaluate exactly those fragments in JavaScriptCore and call them.
///
/// Nothing is fabricated: when the fragments cannot be found or evaluated the
/// caller gets a failure and moves on to the next client. These patterns rot
/// as YouTube rotates its player — the same maintenance reality the Android
/// extractor lives with — so each lookup keeps the several shapes the player
/// has shipped, in order.
actor SignatureDecipher {
    enum DecipherError: Error {
        case playerScriptNotFound
        case functionNotFound(String)
        case evaluationFailed(String)
    }

    private let session: URLSession
    private var cachedScriptURL: URL?
    private var cachedScript: String?

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Unscrambles one format's `signatureCipher` value into a playable URL,
    /// then runs the `n` transform over the result. `videoID` locates the
    /// player script when the cache is cold.
    func decipherURL(signatureCipher: String, videoID: String) async throws -> URL {
        let fields = Self.formFields(signatureCipher)
        guard let rawURL = fields["url"], var components = URLComponents(string: rawURL) else {
            throw DecipherError.functionNotFound("url")
        }
        if let ciphered = fields["s"] {
            let signature = try await decipherSignature(ciphered, videoID: videoID)
            let parameter = fields["sp"] ?? "signature"
            var query = components.queryItems ?? []
            query.removeAll { $0.name == parameter }
            query.append(URLQueryItem(name: parameter, value: signature))
            components.queryItems = query
        }
        guard let signed = components.url else { throw DecipherError.functionNotFound("url") }
        return try await transformNParameter(in: signed, videoID: videoID)
    }

    /// Applies the `n` transform to a direct URL (direct URLs carry an
    /// untransformed `n` too; leaving it is what gets a client throttled).
    func transformNParameter(in url: URL, videoID: String) async throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let query = components.queryItems,
              let nIndex = query.firstIndex(where: { $0.name == "n" }),
              let rawN = query[nIndex].value, !rawN.isEmpty else { return url }
        let script = try await playerScript(videoID: videoID)
        let transformed = try Self.evaluate(functionNamed: try Self.nFunction(in: script), argument: rawN, script: script)
        var updated = query
        updated[nIndex] = URLQueryItem(name: "n", value: transformed)
        components.queryItems = updated
        return components.url ?? url
    }

    func decipherSignature(_ ciphered: String, videoID: String) async throws -> String {
        let script = try await playerScript(videoID: videoID)
        return try Self.evaluate(functionNamed: try Self.signatureFunction(in: script), argument: ciphered, script: script)
    }

    /// `signatureTimestamp` from the player script. WEB-family player
    /// responses are refused without it (`StreamResolver.signatureTimestamp`
    /// on Android exists for the same reason).
    func signatureTimestamp(videoID: String) async -> Int? {
        guard let script = try? await playerScript(videoID: videoID) else { return nil }
        return Self.signatureTimestamp(in: script)
    }

    // MARK: - Player script fetch & cache

    private func playerScript(videoID: String) async throws -> String {
        if let cachedScript { return cachedScript }
        let scriptURL = try await findPlayerScriptURL(videoID: videoID)
        if scriptURL == cachedScriptURL, let cachedScript { return cachedScript }
        var request = URLRequest(url: scriptURL)
        request.setValue(Self.webUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DecipherError.playerScriptNotFound
        }
        let script = String(decoding: data, as: UTF8.self)
        cachedScriptURL = scriptURL
        cachedScript = script
        return script
    }

    private func findPlayerScriptURL(videoID: String) async throws -> URL {
        // The embed page names the exact player build in its config; the
        // watch page does too, under the same `jsUrl` key. Embed first — it
        // is the smaller, less consent-walled document.
        let pages = [
            "https://www.youtube.com/embed/\(videoID)",
            "https://www.youtube.com/watch?v=\(videoID)"
        ]
        for page in pages {
            guard let pageURL = URL(string: page) else { continue }
            var request = URLRequest(url: pageURL)
            request.setValue(Self.webUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("SOCS=CAI", forHTTPHeaderField: "Cookie")
            guard let (data, _) = try? await session.data(for: request) else { continue }
            let html = String(decoding: data, as: UTF8.self)
            if let url = Self.playerScriptURL(inPage: html) { return url }
        }
        throw DecipherError.playerScriptNotFound
    }

    private static let webUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"

    // MARK: - Static extraction (pure, unit-tested)

    static func playerScriptURL(inPage html: String) -> URL? {
        let patterns = [
            #""jsUrl"\s*:\s*"([^"]+base\.js)""#,
            #"(/s/player/[^"']+/base\.js)"#
        ]
        for pattern in patterns {
            guard let raw = firstCapture(pattern, in: html) else { continue }
            let cleaned = raw.replacingOccurrences(of: "\\/", with: "/")
            if let absolute = URL(string: cleaned), absolute.scheme != nil { return absolute }
            return URL(string: "https://www.youtube.com\(cleaned.hasPrefix("/") ? "" : "/")\(cleaned)")
        }
        return nil
    }

    static func signatureTimestamp(in script: String) -> Int? {
        firstCapture(#"signatureTimestamp\s*[:=]\s*(\d+)"#, in: script).flatMap(Int.init)
    }

    /// The name of the function that unscrambles the `s` parameter.
    /// The shapes are NewPipe's, in its order: the `.sig||fn(` call site,
    /// then the split/join function shape itself.
    static func signatureFunction(in script: String) throws -> JSFunctionRef {
        if let name = firstCapture(#"\.sig\s*\|\|\s*([a-zA-Z0-9$_]+)\("#, in: script) {
            return JSFunctionRef(name: name, index: nil, arrayName: nil)
        }
        if let name = firstCapture(
            #"([a-zA-Z0-9$_]+)\s*=\s*function\(\s*([a-zA-Z0-9$_]+)\s*\)\s*\{\s*\2\s*=\s*\2\.split\(\s*(?:""|'')\s*\)\s*;"#,
            in: script
        ) {
            return JSFunctionRef(name: name, index: nil, arrayName: nil)
        }
        if let name = firstCapture(
            #"(?:function\s+|[,;])([a-zA-Z0-9$_]+)\(([\w$]+)\)\{\2=\2\.split\(\s*(?:""|'')\s*\)"#,
            in: script
        ) {
            return JSFunctionRef(name: name, index: nil, arrayName: nil)
        }
        throw DecipherError.functionNotFound("signature")
    }

    /// The `n` transform. Newer players keep it in an array and index it at
    /// the call site (`b = arr[3](b)`); older ones name it directly.
    static func nFunction(in script: String) throws -> JSFunctionRef {
        // Array form: `.get("n"))&&(b=ARR[IDX](b)` — capture array + index,
        // then read the function name out of the array literal.
        if let match = firstMatch(
            #"\.get\("n"\)\)?\s*&&\s*\(?\s*[\w$]+\s*=\s*([a-zA-Z0-9$_]+)\[(\d+)\]\("#,
            in: script
        ), let arrayName = match[1], let indexText = match[2], let index = Int(indexText) {
            if let name = arrayElement(named: arrayName, at: index, in: script) {
                return JSFunctionRef(name: name, index: nil, arrayName: nil)
            }
            return JSFunctionRef(name: nil, index: index, arrayName: arrayName)
        }
        if let name = firstCapture(
            #"\.get\("n"\)\)?\s*&&\s*\(?\s*[\w$]+\s*=\s*([a-zA-Z0-9$_]+)\("#,
            in: script
        ) {
            return JSFunctionRef(name: name, index: nil, arrayName: nil)
        }
        // Legacy shape: `n` assigned through a named transform in the URL
        // builder (`a.D && (b = fn(b))` family) — fall back to the well-known
        // lone function whose body rewrites the whole string and rejoins it.
        if let name = firstCapture(
            #"([a-zA-Z0-9$_]+)\s*=\s*function\(\s*([\w$]+)\s*\)\s*\{(?:(?!\};).)*?\.join\(""\)\s*\}"#,
            in: script
        ) {
            return JSFunctionRef(name: name, index: nil, arrayName: nil)
        }
        throw DecipherError.functionNotFound("n")
    }

    private static func arrayElement(named array: String, at index: Int, in script: String) -> String? {
        guard let literal = firstCapture(
            "(?:var\\s+)?\(NSRegularExpression.escapedPattern(for: array))\\s*=\\s*\\[([^\\]]+)\\]",
            in: script
        ) else { return nil }
        let elements = literal.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard elements.indices.contains(index) else { return nil }
        let element = elements[index]
        return element.isEmpty ? nil : element
    }

    /// Evaluates the named function (plus whatever it calls at the top level:
    /// its helper object and, for the array form, the whole array) and
    /// returns its string result for `argument`.
    static func evaluate(functionNamed ref: JSFunctionRef, argument: String, script: String) throws -> String {
        var fragments: [String] = []
        var callName: String

        if let arrayName = ref.arrayName, let index = ref.index {
            guard let arrayDecl = declaration(of: arrayName, in: script) else {
                throw DecipherError.functionNotFound(arrayName)
            }
            fragments.append(arrayDecl)
            // Every member the array names has to exist for the literal to
            // evaluate; pull each one's declaration in too.
            if let literal = firstCapture("\\[([^\\]]+)\\]", in: arrayDecl) {
                for member in literal.split(separator: ",") {
                    let name = member.trimmingCharacters(in: .whitespaces)
                    if let memberDecl = declaration(of: name, in: script) {
                        fragments.insert(memberDecl, at: 0)
                    }
                }
            }
            callName = "\(arrayName)[\(index)]"
        } else if let name = ref.name {
            guard let functionDecl = declaration(of: name, in: script) else {
                throw DecipherError.functionNotFound(name)
            }
            fragments.append(functionDecl)
            callName = name
        } else {
            throw DecipherError.functionNotFound("anonymous")
        }

        // Helper objects the chosen fragment(s) call (`XX.AbC(a,3)` style):
        // any identifier immediately used as `ID.` that is declared as an
        // object/array literal in the script comes along. Objects only —
        // admitting function assignments would let a one-letter parameter
        // name (`a.split(…)`) drag in some unrelated top-level `a`.
        let joined = fragments.joined(separator: "\n")
        for helper in helperObjectNames(in: joined) {
            if let helperDecl = declaration(of: helper, in: script, objectsOnly: true) {
                fragments.insert(helperDecl, at: 0)
            }
        }

        guard let context = JSContext() else { throw DecipherError.evaluationFailed("no JSContext") }
        var failure: String?
        context.exceptionHandler = { _, exception in failure = exception?.toString() ?? "JS error" }
        context.evaluateScript(fragments.joined(separator: "\n"))
        if let failure { throw DecipherError.evaluationFailed(failure) }
        // `objectForKeyedSubscript` answers an undefined value rather than
        // nil for a missing name, so the array form must go straight to
        // expression evaluation instead of falling back.
        let resolved: JSValue? = callName.contains("[")
            ? evaluatePath(callName, in: context)
            : context.objectForKeyedSubscript(callName)
        guard let fn = resolved, !fn.isUndefined else {
            throw DecipherError.evaluationFailed("\(callName) is not defined after evaluation")
        }
        guard let result = fn.call(withArguments: [argument]), !result.isUndefined, !result.isNull else {
            throw DecipherError.evaluationFailed("\(callName) returned nothing")
        }
        if let failure { throw DecipherError.evaluationFailed(failure) }
        // `n` transforms may return the string wrapped (e.g. after an
        // intermediate array join); toString is the honest read for both.
        guard let value = result.toString(), !value.isEmpty, value != "undefined" else {
            throw DecipherError.evaluationFailed("\(callName) returned an unusable value")
        }
        return value
    }

    private static func evaluatePath(_ path: String, in context: JSContext) -> JSValue? {
        // `arr[3]` is not a subscript key; evaluate the expression itself.
        context.evaluateScript(path)
    }

    private static func helperObjectNames(in fragment: String) -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        for capture in allCaptures(#"\b([a-zA-Z$_][\w$]*)\.[a-zA-Z$_][\w$]*\("#, in: fragment) {
            if seen.insert(capture).inserted { names.append(capture) }
        }
        return names
    }

    /// The full declaration of `name` — a `function name(…){…}` definition, a
    /// `name = function(…){…}` assignment, or a `var name = {…}` / `[…]`
    /// literal — extracted by balanced-bracket scanning rather than regex,
    /// because these bodies nest.
    static func declaration(of name: String, in script: String, objectsOnly: Bool = false) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let patterns = objectsOnly
            ? ["(?:var\\s+|[,;]\\s*)?\(escaped)\\s*=\\s*[\\{\\[]"]
            : [
                "function\\s+\(escaped)\\s*\\(",
                "(?:var\\s+)?\(escaped)\\s*=\\s*function\\s*\\(",
                "(?:var\\s+|[,;]\\s*)?\(escaped)\\s*=\\s*[\\{\\[]"
            ]
        for pattern in patterns {
            guard let match = firstMatchRange(pattern, in: script) else { continue }
            // Scan from the start of the match to the end of the statement.
            let start = match.lowerBound
            guard let end = statementEnd(in: script, from: start) else { continue }
            var text = String(script[start..<end])
                .trimmingCharacters(in: CharacterSet(charactersIn: ";, \t\n"))
            if !text.hasPrefix("var ") && !text.hasPrefix("function") {
                text = "var " + text
            }
            if !text.hasSuffix(";") && !text.hasSuffix("}") { text += ";" }
            return text
        }
        return nil
    }

    /// End of the JS statement beginning at `start`: walks the source
    /// skipping strings, template literals, comments and regex literals,
    /// tracking bracket depth; the statement ends at the first `;` or
    /// unmatched closer at depth zero after at least one opener closed.
    static func statementEnd(in script: String, from start: String.Index) -> String.Index? {
        var index = start
        var depth = 0
        var sawOpen = false
        var previousSignificant: Character?
        let openers: [Character: Character] = ["(": ")", "[": "]", "{": "}"]
        var stack: [Character] = []

        while index < script.endIndex {
            let char = script[index]
            let next = script.index(after: index)

            // Strings and templates.
            if char == "\"" || char == "'" || char == "`" {
                index = skipString(in: script, from: index, quote: char)
                previousSignificant = char
                continue
            }
            // Comments (and division, disambiguated by the next character).
            if char == "/", next < script.endIndex {
                let following = script[next]
                if following == "/" {
                    index = script[index...].firstIndex(of: "\n") ?? script.endIndex
                    continue
                }
                if following == "*" {
                    index = skipBlockComment(in: script, from: index)
                    continue
                }
                // A `/` after an operand-ish token is division; otherwise a
                // regex literal opens. Good enough for player code.
                if let previous = previousSignificant, previous.isLetter || previous.isNumber || previous == ")" || previous == "]" || previous == "\"" || previous == "'" {
                    previousSignificant = char
                    index = next
                    continue
                }
                index = skipRegex(in: script, from: index)
                previousSignificant = "/"
                continue
            }
            if let closer = openers[char] {
                stack.append(closer)
                depth += 1
                sawOpen = true
                previousSignificant = char
                index = next
                continue
            }
            if char == ")" || char == "]" || char == "}" {
                if stack.last == char {
                    stack.removeLast()
                    depth -= 1
                    previousSignificant = char
                    index = next
                    // A brace block closing back to depth zero ends the
                    // declaration (a function body, an object literal). A
                    // paren close does not — `function(a){…}` still has its
                    // body ahead of it; the scanner carries on to the `;`
                    // or the matching `}`.
                    if char == "}" && depth == 0 && sawOpen {
                        return index
                    }
                    continue
                }
                // Unmatched closer at this level: the statement already ended.
                return index
            }
            if char == ";" && depth == 0 {
                return script.index(after: index)
            }
            if !char.isWhitespace { previousSignificant = char }
            index = next
        }
        return script.endIndex
    }

    private static func skipString(in script: String, from start: String.Index, quote: Character) -> String.Index {
        var index = script.index(after: start)
        while index < script.endIndex {
            let char = script[index]
            if char == "\\" {
                index = script.index(after: index)
                if index < script.endIndex { index = script.index(after: index) }
                continue
            }
            if char == quote { return script.index(after: index) }
            index = script.index(after: index)
        }
        return script.endIndex
    }

    private static func skipBlockComment(in script: String, from start: String.Index) -> String.Index {
        var index = script.index(start, offsetBy: 2, limitedBy: script.endIndex) ?? script.endIndex
        while index < script.endIndex {
            if script[index] == "*" {
                let next = script.index(after: index)
                if next < script.endIndex, script[next] == "/" { return script.index(after: next) }
            }
            index = script.index(after: index)
        }
        return script.endIndex
    }

    private static func skipRegex(in script: String, from start: String.Index) -> String.Index {
        var index = script.index(after: start)
        var inClass = false
        while index < script.endIndex {
            let char = script[index]
            if char == "\\" {
                index = script.index(after: index)
                if index < script.endIndex { index = script.index(after: index) }
                continue
            }
            if char == "[" { inClass = true }
            else if char == "]" { inClass = false }
            else if char == "/", !inClass {
                // Trailing flags.
                var end = script.index(after: index)
                while end < script.endIndex, script[end].isLetter { end = script.index(after: end) }
                return end
            } else if char == "\n" {
                return index
            }
            index = script.index(after: index)
        }
        return script.endIndex
    }

    // MARK: - Small helpers

    struct JSFunctionRef: Equatable {
        var name: String?
        var index: Int?
        var arrayName: String?
    }

    static func formFields(_ encoded: String) -> [String: String] {
        var fields: [String: String] = [:]
        for pair in encoded.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0])
            let value = String(parts[1]).removingPercentEncoding ?? String(parts[1])
            fields[key] = value
        }
        return fields
    }

    private static func firstCapture(_ pattern: String, in source: String) -> String? {
        firstMatch(pattern, in: source)?.first ?? nil
    }

    private static func firstMatch(_ pattern: String, in source: String) -> [String?]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: source) else { return nil }
            return String(source[range])
        }
    }

    private static func firstMatchRange(_ pattern: String, in source: String) -> Range<String.Index>? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) else { return nil }
        return Range(match.range, in: source)
    }

    private static func allCaptures(_ pattern: String, in source: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap { match in
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[range])
        }
    }
}
