import Foundation
import JavaScriptCore

/// Deciphers YouTube `signatureCipher` payloads and transforms the `n`
/// throttling parameter by executing the functions defined in the current
/// YouTube HTML5 player script inside `JavaScriptCore`.
///
/// Supports both:
/// - Modern `_yt_player` IIFE bundles using Zemer player configs (`sig`
///   dispatcher + `g.<nClass>` URL constructor) and dynamic `nClass`
///   discovery on `g` for newly rotated player hashes.
/// - Classic standalone function extraction for older/synthetic scripts.
actor SignatureDecipher {
    struct PlayerConfig: Sendable {
        let scriptURL: URL?
        let signatureTimestamp: Int?
        let encryptedHostFlags: String?
    }

    struct ZemerPlayerConfig: Sendable {
        let sig: String
        let nClass: String
        let sts: Int?
        let aliases: [String]
    }

    private let session: URLSession
    private let userAgent: String

    private var cachedScriptURL: URL?
    private var cachedScript: String?
    private var cachedTimestamp: Int?
    private var cachedFetchedAt: Date?
    private var cachedHostFlagsByVideo: [String: String] = [:]
    private var cachedRemoteConfigs: [String: ZemerPlayerConfig]?
    private var cachedSolverScriptURL: URL?
    private var cachedSolverContext: JSContext?

    private static let remoteConfigURL = URL(
        string: "https://raw.githubusercontent.com/ZemerTeam/zemer-cipher/master/library/src/main/assets/player_configs.json"
    )!

    init(
        session: URLSession = .shared,
        userAgent: String = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"
    ) {
        self.session = session
        self.userAgent = userAgent
    }

    /// Returns the active player script's `signatureTimestamp` (`sts`) and
    /// per-video `encryptedHostFlags` (needed by `WEB_EMBEDDED_PLAYER` and
    /// `WEB_REMIX` / `TVHTML5` `playbackContext.contentPlaybackContext`).
    func playerConfig(videoID: String) async -> PlayerConfig {
        do {
            return try await ensurePlayerConfig(videoID: videoID)
        } catch {
            return PlayerConfig(
                scriptURL: cachedScriptURL,
                signatureTimestamp: cachedTimestamp,
                encryptedHostFlags: cachedHostFlagsByVideo[videoID]
            )
        }
    }

    /// Returns the active player script's `signatureTimestamp`, required in
    /// `playbackContext.contentPlaybackContext` when requesting ciphered formats.
    func signatureTimestamp(videoID: String) async -> Int? {
        if let ts = cachedTimestamp, let fetched = cachedFetchedAt, Date().timeIntervalSince(fetched) < 3600 {
            return ts
        }
        let config = await playerConfig(videoID: videoID)
        if let sts = config.signatureTimestamp {
            return sts
        }
        do {
            let (_, timestamp) = try await loadPlayerScript(videoID: videoID)
            return timestamp
        } catch {
            return nil
        }
    }

    /// Turns a `signatureCipher` form-encoded string (`s=...&sp=sig&url=...`)
    /// into a ready-to-play URL with both signature and `n` parameter resolved.
    func decipherURL(signatureCipher: String, videoID: String) async throws -> URL {
        let fields = Self.formFields(signatureCipher)
        guard let rawURL = fields["url"], let baseURL = URL(string: rawURL) else {
            throw MusicRequestError.invalidResponse
        }
        guard let encryptedSig = fields["s"] else {
            return (try? await transformNParameter(in: baseURL, videoID: videoID)) ?? baseURL
        }
        let sigParam = fields["sp"]?.isEmpty == false ? fields["sp"]! : "sig"
        let (script, _) = try await loadPlayerScript(videoID: videoID)
        let configs = await loadZemerConfigs()
        let hash = cachedScriptURL.flatMap(Self.playerHash(from:))
        let zemerConfig = hash.flatMap { configs[$0] }
        let signature = try evaluateSignature(
            encryptedSig,
            script: script,
            scriptURL: cachedScriptURL,
            config: zemerConfig
        )

        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw MusicRequestError.invalidResponse
        }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == sigParam }
        items.append(URLQueryItem(name: sigParam, value: signature))
        components.queryItems = items
        guard let signedURL = components.url else {
            throw MusicRequestError.invalidResponse
        }
        return (try? await transformNParameter(in: signedURL, videoID: videoID)) ?? signedURL
    }

    /// Transforms the `n` query parameter in a stream URL if present. Without
    /// this transform YouTube throttles downloads to ~30–50 KB/s. If the
    /// transform does not produce a valid token, the original URL is returned
    /// untouched so a bad regex match never corrupts a working direct URL.
    func transformNParameter(in url: URL, videoID: String) async throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              var items = components.queryItems,
              let index = items.firstIndex(where: { $0.name == "n" }),
              let rawN = items[index].value, !rawN.isEmpty else {
            return url
        }
        let (script, _) = try await loadPlayerScript(videoID: videoID)
        let configs = await loadZemerConfigs()
        let hash = cachedScriptURL.flatMap(Self.playerHash(from:))
        let zemerConfig = hash.flatMap { configs[$0] }
        let transformed = try evaluateNTransform(
            rawN,
            script: script,
            scriptURL: cachedScriptURL,
            config: zemerConfig
        )
        guard Self.isValidTransformedN(transformed, original: rawN) else {
            return url
        }
        items[index].value = transformed
        components.queryItems = items
        return components.url ?? url
    }

    // MARK: - Player config & script loading

    private func ensurePlayerConfig(videoID: String) async throws -> PlayerConfig {
        let embedURL = URL(string: "https://www.youtube.com/embed/\(videoID)?html5=1")!
        let embedHTML = try await fetchText(embedURL, referer: "https://www.reddit.com/")
        let scriptURL = Self.playerScriptURL(inPage: embedHTML) ?? cachedScriptURL
        let flags = Self.encryptedHostFlags(inPage: embedHTML)
        if let flags {
            cachedHostFlagsByVideo[videoID] = flags
        }
        var sts = Self.signatureTimestamp(in: embedHTML)
        if sts == nil, let scriptURL, let hash = Self.playerHash(from: scriptURL) {
            let configs = await loadZemerConfigs()
            sts = configs[hash]?.sts
        }
        if let scriptURL, cachedScriptURL != scriptURL {
            cachedScriptURL = scriptURL
            cachedScript = nil
            cachedSolverContext = nil
            cachedSolverScriptURL = nil
        }
        if let sts {
            cachedTimestamp = sts
            cachedFetchedAt = Date()
        }
        return PlayerConfig(
            scriptURL: scriptURL,
            signatureTimestamp: sts ?? cachedTimestamp,
            encryptedHostFlags: flags
        )
    }

    private func loadPlayerScript(videoID: String) async throws -> (String, Int?) {
        if let script = cachedScript,
           let fetched = cachedFetchedAt,
           Date().timeIntervalSince(fetched) < 3600 {
            return (script, cachedTimestamp)
        }

        var scriptURL = cachedScriptURL
        var embedSts = cachedTimestamp
        if scriptURL == nil {
            let config = try? await ensurePlayerConfig(videoID: videoID)
            scriptURL = config?.scriptURL
            embedSts = config?.signatureTimestamp ?? embedSts
        }
        if scriptURL == nil {
            let watchURL = URL(string: "https://www.youtube.com/watch?v=\(videoID)&bpctr=9999999999&has_verified=1")!
            let watchHTML = try await fetchText(watchURL)
            scriptURL = Self.playerScriptURL(inPage: watchHTML)
            if embedSts == nil {
                embedSts = Self.signatureTimestamp(in: watchHTML)
            }
        }
        guard let resolvedScriptURL = scriptURL else {
            throw MusicRequestError.noPlayableStream
        }

        let script = try await fetchText(resolvedScriptURL)
        var timestamp = Self.signatureTimestamp(in: script) ?? embedSts
        if timestamp == nil, let hash = Self.playerHash(from: resolvedScriptURL) {
            let configs = await loadZemerConfigs()
            timestamp = configs[hash]?.sts
        }
        cachedScriptURL = resolvedScriptURL
        cachedScript = script
        cachedTimestamp = timestamp
        cachedFetchedAt = Date()
        return (script, timestamp)
    }

    private func fetchText(_ url: URL, referer: String? = nil) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        if let referer {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw MusicRequestError.httpStatus(http.statusCode)
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Zemer Player Configs & IIFE Solver

    private func loadZemerConfigs() async -> [String: ZemerPlayerConfig] {
        if let cachedRemoteConfigs {
            return cachedRemoteConfigs
        }
        var merged = Self.bundledZemerConfigs
        var request = URLRequest(url: Self.remoteConfigURL)
        request.timeoutInterval = 5
        if let (data, response) = try? await session.data(for: request),
           let http = response as? HTTPURLResponse,
           (200..<300).contains(http.statusCode),
           let text = String(data: data, encoding: .utf8) {
            let parsed = Self.parseZemerConfigsJSON(text)
            for (key, value) in parsed {
                merged[key] = value
            }
        }
        cachedRemoteConfigs = merged
        return merged
    }

    private func evaluateSignature(
        _ encryptedSig: String,
        script: String,
        scriptURL: URL?,
        config: ZemerPlayerConfig?
    ) throws -> String {
        if let result = evaluateInPlayerBundle(
            functionName: "_decryptSig",
            argument: encryptedSig,
            script: script,
            scriptURL: scriptURL,
            config: config
        ), !result.isEmpty, result != "undefined", result != "null", result != encryptedSig {
            return result
        }
        let sigFn = try Self.signatureFunction(in: script)
        return try Self.evaluate(functionNamed: sigFn, argument: encryptedSig, script: script)
    }

    private func evaluateNTransform(
        _ rawN: String,
        script: String,
        scriptURL: URL?,
        config: ZemerPlayerConfig?
    ) throws -> String {
        if let result = evaluateInPlayerBundle(
            functionName: "_transformN",
            argument: rawN,
            script: script,
            scriptURL: scriptURL,
            config: config
        ), Self.isValidTransformedN(result, original: rawN) {
            return result
        }
        if let dynamicResult = evaluateInPlayerBundle(
            functionName: "_dynamicTransformN",
            argument: rawN,
            script: script,
            scriptURL: scriptURL,
            config: config
        ), Self.isValidTransformedN(dynamicResult, original: rawN) {
            return dynamicResult
        }
        let nFn = try Self.nFunction(in: script)
        return try Self.evaluate(functionNamed: nFn, argument: rawN, script: script)
    }

    private func evaluateInPlayerBundle(
        functionName: String,
        argument: String,
        script: String,
        scriptURL: URL?,
        config: ZemerPlayerConfig?
    ) -> String? {
        guard let context = solverContext(for: script, scriptURL: scriptURL, config: config) else {
            return nil
        }
        guard let fn = context.objectForKeyedSubscript(functionName),
              !fn.isUndefined,
              let result = fn.call(withArguments: [argument]),
              !result.isUndefined,
              !result.isNull,
              result.isString else {
            return nil
        }
        return result.toString()
    }

    private func solverContext(
        for script: String,
        scriptURL: URL?,
        config: ZemerPlayerConfig?
    ) -> JSContext? {
        if let cachedSolverContext, let scriptURL, cachedSolverScriptURL == scriptURL {
            return cachedSolverContext
        }
        guard let modified = Self.buildPlayerBundleSolverScript(script: script, config: config) else {
            return nil
        }
        guard let context = JSContext() else { return nil }
        context.evaluateScript(Self.browserGlobalsSetupScript)
        context.evaluateScript(modified)
        if context.exception != nil {
            context.exception = nil
        }
        context.evaluateScript("""
        var _decryptSig = (typeof _yt_player !== 'undefined' && _yt_player._decryptSig) ? _yt_player._decryptSig : undefined;
        var _transformN = (typeof _yt_player !== 'undefined' && _yt_player._transformN) ? _yt_player._transformN : undefined;
        var _dynamicTransformN = (typeof _yt_player !== 'undefined' && _yt_player._dynamicTransformN) ? _yt_player._dynamicTransformN : undefined;
        """)
        if let scriptURL {
            cachedSolverScriptURL = scriptURL
            cachedSolverContext = context
        }
        return context
    }

    // MARK: - Pure extraction helpers (internal for unit tests)

    static func isValidTransformedN(_ transformed: String, original: String) -> Bool {
        guard transformed != original,
              transformed.count >= 5,
              transformed.count <= 64,
              transformed != "undefined",
              transformed != "null",
              transformed.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
            return false
        }
        return true
    }

    static func playerHash(from url: URL) -> String? {
        firstCapture(#"/s/player/([a-fA-F0-9]{8})/"#, in: url.absoluteString)?.lowercased()
    }

    static func encryptedHostFlags(inPage html: String) -> String? {
        firstCapture(#""encryptedHostFlags"\s*:\s*"([^"]+)""#, in: html)
    }

    static func buildPlayerBundleSolverScript(script: String, config: ZemerPlayerConfig?) -> String? {
        let trailer = "})(_yt_player);"
        guard let range = script.range(of: trailer, options: .backwards) else {
            return nil
        }
        var exports = """
        ;g._dynamicTransformN=function(n){try{if(!g._discoveredNClass){var p="KdrqFlzJXl9EcCwlmEy";var ks=Object.keys(g);for(var i=0;i<ks.length;i++){var f=g[ks[i]];if(typeof f==="function"&&f.prototype&&typeof f.prototype.get==="function"&&typeof f.prototype.set==="function"){try{var u=new f("https://x.googlevideo.com/videoplayback?n="+p,true);var o=u&&typeof u.get==="function"?u.get("n"):null;if(typeof o==="string"&&o!==p&&o.length>=5&&/^[A-Za-z0-9_-]+$/.test(o)){g._discoveredNClass=f;break;}}catch(e){}}}}if(g._discoveredNClass){var u2=new g._discoveredNClass("https://x.googlevideo.com/videoplayback?n="+n,true);var t2=u2.get("n");if(typeof t2==="string"&&t2!==n)return t2;}}catch(e){}return n;};
        """
        if let config {
            let sigExpr = config.sig.replacingOccurrences(of: "INPUT", with: "sig")
            exports += ";g._decryptSig=function(sig){return \(sigExpr);};"
            exports += ";g._transformN=function(n){try{var u=new g.\(config.nClass)('https://x.googlevideo.com/videoplayback?n='+n,true);var t=u.get('n');return(t&&t!==n)?t:n;}catch(e){return n;}};"
        }
        var result = script
        result.replaceSubrange(range, with: exports + trailer)
        return result
    }

    static func parseZemerConfigsJSON(_ json: String) -> [String: ZemerPlayerConfig] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        let players = (root["players"] as? [String: Any]) ?? root
        var out: [String: ZemerPlayerConfig] = [:]
        for (hash, rawEntry) in players {
            guard hash.count == 8,
                  let entry = rawEntry as? [String: Any],
                  let sig = entry["sig"] as? String,
                  let nClass = entry["nClass"] as? String,
                  !sig.isEmpty,
                  !nClass.isEmpty else {
                continue
            }
            let sts = (entry["sts"] as? Int) ?? (entry["sts"] as? NSNumber)?.intValue
            let aliases = (entry["aliases"] as? [String]) ?? []
            let config = ZemerPlayerConfig(sig: sig, nClass: nClass, sts: sts, aliases: aliases)
            out[hash.lowercased()] = config
            for alias in aliases where alias.count == 8 {
                out[alias.lowercased()] = config
            }
        }
        return out
    }

    static func formFields(_ encoded: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in encoded.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
            let rawValue = String(parts[1]).replacingOccurrences(of: "+", with: " ")
            let value = rawValue.removingPercentEncoding ?? rawValue
            result[key] = value
        }
        return result
    }

    static func playerScriptURL(inPage html: String) -> URL? {
        let patterns = [
            #""jsUrl"\s*:\s*"([^"]+/base\.js)""#,
            #""PLAYER_JS_URL"\s*:\s*"([^"]+/base\.js)""#,
            #"src="([^"]+/s/player/[^"]+/base\.js)""#,
            #"(/s/player/[A-Za-z0-9_-]+/[^"'\s]+/base\.js)"#
        ]
        for pattern in patterns {
            if let raw = firstCapture(pattern, in: html) {
                let path = raw.replacingOccurrences(of: #"\/"#, with: "/")
                if path.hasPrefix("http") { return URL(string: path) }
                return URL(string: "https://www.youtube.com\(path)")
            }
        }
        return nil
    }

    static func signatureTimestamp(in text: String) -> Int? {
        let patterns = [
            #"signatureTimestamp"?\s*[:=]\s*(\d+)"#,
            #""(?:sts|STS)"\s*:\s*(\d{5})"#
        ]
        for pattern in patterns {
            if let digits = firstCapture(pattern, in: text), let value = Int(digits) {
                return value
            }
        }
        return nil
    }

    struct JSFunctionRef: Equatable {
        let name: String
        let index: Int?
        let arrayName: String?
    }

    static func signatureFunction(in script: String) throws -> JSFunctionRef {
        // Matches modern YouTube call sites and function declarations (same
        // family as yt-dlp / NewPipeExtractor's DecipherFunction).
        let patterns = [
            #"\b[cs]\s*&&\s*[adf]\.set\([^,]+\s*,\s*encodeURIComponent\s*\(\s*([a-zA-Z0-9$]+)\("#,
            #"\b[a-zA-Z0-9]+\s*&&\s*[a-zA-Z0-9]+\.set\([^,]+\s*,\s*encodeURIComponent\s*\(\s*([a-zA-Z0-9$]+)\("#,
            #"\bm=([a-zA-Z0-9$]{2,})\(decodeURIComponent\(h\.s\)\)"#,
            #"\bc\s*&&\s*\(c=([a-zA-Z0-9$]{2,})\(decodeURIComponent\(c\)\)"#,
            #"([a-zA-Z0-9$]+)\s*=\s*function\(\s*a\s*\)\s*\{\s*a\s*=\s*a\.split\(\s*""\s*\);[a-zA-Z0-9$]{2}\.[a-zA-Z0-9$]{2}\(a,\d+\)"#,
            #"([a-zA-Z0-9$]+)\s*=\s*function\(\s*a\s*\)\s*\{\s*a\s*=\s*a\.split\(\s*""\s*\)"#,
            #"(["'])signature\1\s*,\s*([a-zA-Z0-9$]+)\("#
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(script.startIndex..<script.endIndex, in: script)
                if let match = regex.firstMatch(in: script, range: range) {
                    let groupIndex = match.numberOfRanges - 1
                    if let groupRange = Range(match.range(at: groupIndex), in: script) {
                        return JSFunctionRef(name: String(script[groupRange]), index: nil, arrayName: nil)
                    }
                }
            }
        }
        throw MusicRequestError.noPlayableStream
    }

    static func nFunction(in script: String) throws -> JSFunctionRef {
        // Primary: `.get("n"))&&(b=XX[idx](b))` or `.get("n"))&&(b=XX(b))`.
        let callPatterns = [
            #"\.get\("n"\)\)&&\(b=([a-zA-Z0-9$]+)(?:\[(\d+)\])?\([a-zA-Z0-9]\)"#,
            #"&&\(b=([a-zA-Z0-9$]+)(?:\[(\d+)\])?\(b\)\),[a-zA-Z0-9]+\.set\("n",b\)"#,
            #"\([a-zA-Z0-9]\.get\("n"\)\)&&\(b=([a-zA-Z0-9$]+)(?:\[(\d+)\])?\("#
        ]
        for pattern in callPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(script.startIndex..<script.endIndex, in: script)
                if let match = regex.firstMatch(in: script, range: range),
                   let nameRange = Range(match.range(at: 1), in: script) {
                    let rawName = String(script[nameRange])
                    var idx: Int?
                    if match.numberOfRanges > 2,
                       let idxRange = Range(match.range(at: 2), in: script) {
                        idx = Int(script[idxRange])
                    }
                    if let idx,
                       let resolved = resolveArrayElement(arrayName: rawName, index: idx, in: script) {
                        return JSFunctionRef(name: resolved, index: idx, arrayName: rawName)
                    }
                    return JSFunctionRef(name: rawName, index: nil, arrayName: nil)
                }
            }
        }
        // Legacy shape: `n` transform function that splits the input string and rejoins it.
        if let name = firstCapture(
            #"([a-zA-Z0-9$_]+)\s*=\s*function\(\s*([\w$]+)\s*\)\s*\{\s*\2\s*=\s*\2\.split\(""\)(?:(?!\};).)*?\.join\(""\)\s*\}"#,
            in: script
        ) {
            return JSFunctionRef(name: name, index: nil, arrayName: nil)
        }
        throw MusicRequestError.noPlayableStream
    }

    private static func resolveArrayElement(arrayName: String, index: Int, in script: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: arrayName)
        let pattern = #"var\s+\#(escaped)\s*=\s*\[([^\]]+)\]"#
        guard let body = firstCapture(pattern, in: script) else { return nil }
        let items = body.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard items.indices.contains(index) else { return nil }
        return items[index]
    }

    /// Evaluates a standalone or helper-referencing function from `script` in
    /// `JavaScriptCore` without executing the entire 2 MB player bundle.
    static func evaluate(functionNamed ref: JSFunctionRef, argument: String, script: String) throws -> String {
        guard let fnDecl = declaration(of: ref.name, in: script) else {
            throw MusicRequestError.noPlayableStream
        }
        // Pull in any two-character helper object (`var XY={...};`) referenced
        // inside the function body (e.g. the classic `XY.ab(a,3)` cipher table).
        var prelude = ""
        let helperNames = referencedHelperObjects(in: fnDecl, excluding: ref.name)
        for helper in helperNames {
            if let helperDecl = declaration(of: helper, in: script) {
                prelude.append("var \(helper) = \(helperDecl);\n")
            }
        }
        if let arrayName = ref.arrayName, let arrayDecl = declaration(of: arrayName, in: script) {
            prelude.append("var \(arrayName) = \(arrayDecl);\n")
        }

        let context = JSContext()
        let program = """
        \(prelude)
        var __target = \(fnDecl);
        """
        context?.evaluateScript(program)
        if context?.exception != nil {
            throw MusicRequestError.noPlayableStream
        }
        guard let target = context?.objectForKeyedSubscript("__target"),
              let result = target.call(withArguments: [argument]),
              !result.isUndefined,
              !result.isNull,
              result.isString,
              let str = result.toString() else {
            throw MusicRequestError.noPlayableStream
        }
        return str
    }

    /// Finds `var <name> = <expr>` or `<name> = function(...) { ... }` in
    /// `script` and returns `<expr>` with balanced braces/brackets/strings.
    static func declaration(of name: String, in script: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let startPatterns = [
            #"(?:var|let|const)\s+\#(escaped)\s*=\s*"#,
            #"(?:^|[;,}\n])\s*\#(escaped)\s*=\s*function\b"#,
            #"function\s+\#(escaped)\s*\("#
        ]
        for (idx, pattern) in startPatterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: script, range: NSRange(script.startIndex..<script.endIndex, in: script)),
                  let matchRange = Range(match.range, in: script) else {
                continue
            }
            let exprStart: String.Index
            if idx == 0 {
                exprStart = matchRange.upperBound
            } else if idx == 1 {
                guard let fnRange = script.range(of: "function", range: matchRange) else { continue }
                exprStart = fnRange.lowerBound
            } else {
                guard let fnRange = script.range(of: "function", range: matchRange) else { continue }
                exprStart = fnRange.lowerBound
            }
            if let extracted = extractBalancedJSExpression(from: script, startingAt: exprStart) {
                return extracted
            }
        }
        return nil
    }

    private static func extractBalancedJSExpression(from script: String, startingAt start: String.Index) -> String? {
        var index = start
        var depthBrace = 0
        var depthBracket = 0
        var depthParen = 0
        var seenBraceOrBracket = false
        var inSingle = false
        var inDouble = false
        var inTemplate = false
        var inRegex = false
        var escaped = false
        var prevNonSpace: Character = "="

        while index < script.endIndex {
            let ch = script[index]
            if escaped {
                escaped = false
                index = script.index(after: index)
                continue
            }
            if ch == "\\" && (inSingle || inDouble || inTemplate || inRegex) {
                escaped = true
                index = script.index(after: index)
                continue
            }
            if inSingle {
                if ch == "'" { inSingle = false }
                index = script.index(after: index)
                continue
            }
            if inDouble {
                if ch == "\"" { inDouble = false }
                index = script.index(after: index)
                continue
            }
            if inTemplate {
                if ch == "`" { inTemplate = false }
                index = script.index(after: index)
                continue
            }
            if inRegex {
                if ch == "/" { inRegex = false }
                index = script.index(after: index)
                continue
            }

            switch ch {
            case "'":
                inSingle = true
            case "\"":
                inDouble = true
            case "`":
                inTemplate = true
            case "/":
                let nextIdx = script.index(after: index)
                if nextIdx < script.endIndex && script[nextIdx] == "/" {
                    while index < script.endIndex && script[index] != "\n" {
                        index = script.index(after: index)
                    }
                    continue
                }
                if "=(,[!&|?:;{+-*~^%".contains(prevNonSpace) {
                    inRegex = true
                }
            case "{":
                depthBrace += 1
                seenBraceOrBracket = true
            case "}":
                depthBrace -= 1
                if seenBraceOrBracket && depthBrace == 0 && depthBracket == 0 && depthParen == 0 {
                    let end = script.index(after: index)
                    return String(script[start..<end])
                }
            case "[":
                depthBracket += 1
                seenBraceOrBracket = true
            case "]":
                depthBracket -= 1
                if seenBraceOrBracket && depthBrace == 0 && depthBracket == 0 && depthParen == 0 {
                    let end = script.index(after: index)
                    return String(script[start..<end])
                }
            case "(":
                depthParen += 1
            case ")":
                depthParen -= 1
            default:
                break
            }

            if !ch.isWhitespace {
                prevNonSpace = ch
            }
            index = script.index(after: index)
        }
        return nil
    }

    private static func referencedHelperObjects(in body: String, excluding selfName: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\b([a-zA-Z_$][a-zA-Z0-9_$]{1,3})\.[a-zA-Z_$][a-zA-Z0-9_$]*\s*\("#) else {
            return []
        }
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        var seen = Set<String>()
        var result: [String] = []
        let builtins: Set<String> = ["Math", "JSON", "Date", "Object", "Array", "String", "Number", "RegExp", "a", "b", "c", "d", "e"]
        for match in regex.matches(in: body, range: range) {
            if let groupRange = Range(match.range(at: 1), in: body) {
                let candidate = String(body[groupRange])
                if candidate != selfName && !builtins.contains(candidate) && seen.insert(candidate).inserted {
                    result.append(candidate)
                }
            }
        }
        return result
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let groupRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[groupRange])
    }

    // MARK: - Browser globals & bundled Zemer player configs

    private static let browserGlobalsSetupScript = """
    var window = this;
    var self = this;
    var globalThis = this;
    function XMLHttpRequest() {}
    XMLHttpRequest.prototype = { open: function(){}, send: function(){}, setRequestHeader: function(){} };
    var location = {
        href: 'https://www.youtube.com/watch?v=yt-dlp-wins',
        protocol: 'https:',
        host: 'www.youtube.com',
        hostname: 'www.youtube.com',
        pathname: '/watch',
        search: '?v=yt-dlp-wins',
        hash: '',
        origin: 'https://www.youtube.com',
        toString: function() { return this.href; }
    };
    var document = {
        createElement: function(tag) { return { tagName: tag, style: {}, setAttribute: function(){}, appendChild: function(){} }; },
        createElementNS: function() { return { style: {} }; },
        head: { appendChild: function(){} },
        body: { appendChild: function(){} },
        documentElement: { style: {} },
        addEventListener: function(){},
        removeEventListener: function(){},
        querySelector: function(){ return null; },
        querySelectorAll: function(){ return []; },
        getElementById: function(){ return null; },
        getElementsByTagName: function(){ return []; },
        cookie: '',
        location: location,
        referrer: 'https://www.youtube.com/',
        domain: 'www.youtube.com',
         URL: 'https://www.youtube.com/watch?v=yt-dlp-wins',
         baseURI: 'https://www.youtube.com/watch?v=yt-dlp-wins'
    };
    var navigator = {
        userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        platform: 'Win32',
        language: 'en-US',
        languages: ['en-US', 'en'],
        onLine: true,
        cookieEnabled: true,
        mediaCapabilities: { decodingInfo: function() { return Promise.resolve({ supported: true, smooth: true, powerEfficient: true }); } }
    };
    var screen = { width: 1920, height: 1080, availWidth: 1920, availHeight: 1040, colorDepth: 24, pixelDepth: 24 };
    var history = { pushState: function(){}, replaceState: function(){}, go: function(){}, back: function(){}, forward: function(){} };
    var localStorage = { getItem: function(){ return null; }, setItem: function(){}, removeItem: function(){} };
    var sessionStorage = { getItem: function(){ return null; }, setItem: function(){}, removeItem: function(){} };
    var performance = { now: function(){ return Date.now(); }, mark: function(){}, measure: function(){}, getEntriesByName: function(){ return []; }, timing: { navigationStart: Date.now() } };
    var matchMedia = function() { return { matches: false, addListener: function(){}, removeListener: function(){}, addEventListener: function(){}, removeEventListener: function(){} }; };
    var setTimeout = function(fn) { return 0; };
    var clearTimeout = function() {};
    var setInterval = function(fn) { return 0; };
    var clearInterval = function() {};
    var requestAnimationFrame = function() { return 0; };
    var cancelAnimationFrame = function() {};
    var getComputedStyle = function() { return { getPropertyValue: function(){ return ''; } }; };
    window.location = location;
    window.document = document;
    window.navigator = navigator;
    window.screen = screen;
    window.history = history;
    window.localStorage = localStorage;
    window.sessionStorage = sessionStorage;
    window.performance = performance;
    window.XMLHttpRequest = XMLHttpRequest;
    var _yt_player = {};
    """

    private static let bundledZemerConfigs: [String: ZemerPlayerConfig] = parseZemerConfigsJSON("""
    {
      "players": {
        "9f972691": { "sig": "DQ(3,7009,INPUT)", "nClass": "dV", "sts": 20712, "aliases": ["b922b50e"] },
        "609426be": { "sig": "Vp(3,7009,INPUT)", "nClass": "MV", "sts": 20712, "aliases": ["9d30dfd1"] },
        "5407e3d0": { "sig": "mL(3,7009,INPUT)", "nClass": "lx", "sts": 20712, "aliases": ["959cb928", "6eb934f1", "3f6be31c", "ecb23058", "a3199f29"] },
        "4ac126d1": { "sig": "qB(12,4884,INPUT)", "nClass": "th", "sts": 20713, "aliases": ["11b3b4d2"] },
        "91d61487": { "sig": "xL(12,4884,INPUT)", "nClass": "o7", "sts": 20713, "aliases": ["32477a05"] },
        "d7ddd053": { "sig": "qy(12,4884,INPUT)", "nClass": "eg", "sts": 20713, "aliases": ["c88074fc", "3d12c3f5", "0bec9f13"] },
        "59181ec7": { "sig": "Rf(12,4884,INPUT)", "nClass": "Lm", "sts": 20713, "aliases": ["44540ef7"] },
        "aacb0e70": { "sig": "OU(1,5029,INPUT)", "nClass": "TX", "sts": 20714, "aliases": ["eaa8cf5a"] },
        "00f2569f": { "sig": "GI(1,5029,INPUT)", "nClass": "OQ", "sts": 20714, "aliases": ["872718bc", "6ca92876", "fdaec37f", "9a694a30", "715df75b"] },
        "780cac39": { "sig": "wQ(22,8364,INPUT)", "nClass": "bB", "sts": 20716, "aliases": ["b7e74872", "dac2d7b2", "66792dac", "46fbab61", "c9526929"] },
        "12502845": { "sig": "yv(40,3024,INPUT)", "nClass": "X3", "sts": 20717, "aliases": ["54009940", "82f45653", "54c0d407", "48ca10b5", "1ec7a7df"] },
        "b9553db2": { "sig": "hQ(40,3024,INPUT)", "nClass": "ZO", "sts": 20717, "aliases": ["0bcb2b7f", "7460dd14", "57523767", "ccb8b03c", "637df651"] },
        "7d98ded3": { "sig": "ze(4,4798,INPUT)", "nClass": "Wj", "sts": 20718, "aliases": ["23a33f06", "8696311b", "b26eecb0"] },
        "cdcadd62": { "sig": "LC(2,2651,INPUT)", "nClass": "cC", "sts": 20719, "aliases": ["282fe6c0"] },
        "e20e4fb7": { "sig": "LC(2,2651,INPUT)", "nClass": "tl", "sts": 20719, "aliases": ["d8fa0781", "1d23325d", "4611238c", "8854c9cd", "3c982ef8", "fb50cd46", "638e10a4", "fac91e21", "bda59663", "ac0d3516", "a23f4ed8", "2b1a14fe", "4981eeb3", "2c1fb55e", "830a3f2b", "ba6da7e7", "ec37a3a2"] },
        "68e537d4": { "sig": "Y9(20,3149,INPUT)", "nClass": "yQ", "sts": 20720, "aliases": ["bfcc08c0"] },
        "61718fdf": { "sig": "j0(20,3149,INPUT)", "nClass": "lo", "sts": 20720, "aliases": ["87de0722"] },
        "abc8bfe7": { "sig": "O_(20,3149,INPUT)", "nClass": "ud", "sts": 20720, "aliases": ["42e5c363"] },
        "80ffa016": { "sig": "fG(21,4691,INPUT)", "nClass": "XO", "sts": 20721, "aliases": ["ee64c359", "852fbe33", "8da9649f"] },
        "df74a4c3": { "sig": "yw(21,4691,INPUT)", "nClass": "Xs", "sts": 20721, "aliases": ["3ca566a8"] },
        "703ed7e6": { "sig": "c7(21,4691,INPUT)", "nClass": "uH", "sts": 20721, "aliases": ["3c861897"] },
        "57bae81f": { "sig": "Rf(16,3049,INPUT)", "nClass": "WP", "sts": 20723, "aliases": ["0c75da8c"] },
        "eb27e5fd": { "sig": "Su(11,3932,INPUT)", "nClass": "cg", "sts": 20724, "aliases": ["5a1f4285", "2e2330c5", "5695b162", "b505552d", "e348eab6"] },
        "d9d7a37f": { "sig": "T5(11,3932,INPUT)", "nClass": "bt", "sts": 20724, "aliases": ["a2d687db", "51b9845e", "48dad48d"] },
        "29f806df": { "sig": "ly(11,3932,INPUT)", "nClass": "vy", "sts": 20724, "aliases": ["e87e2f46"] },
        "c92cd8d2": { "sig": "rF(11,3932,INPUT)", "nClass": "Ok", "sts": 20724, "aliases": ["2efa6f58"] },
        "a6176ebe": { "sig": "Qn(65,5918,INPUT)", "nClass": "CJ", "sts": 20725, "aliases": ["75d3237d", "59a0be78", "60a06f3e", "445f1377", "25afbb31", "87c7e880", "dadaa088", "ce46cb56", "32f205c3", "8ab5c328", "cb5904c6", "496dd26b", "d19f284b"] },
        "3a0dd1ca": { "sig": "q9(65,5918,INPUT)", "nClass": "R3", "sts": 20725, "aliases": ["02205850"] },
        "9b0517e1": { "sig": "Et(65,5918,INPUT)", "nClass": "dW", "sts": 20725, "aliases": ["afd657fc"] },
        "92b29aca": { "sig": "jL(5,5551,INPUT)", "nClass": "RJ", "sts": 20726, "aliases": ["6fd22f8d"] },
        "1f293754": { "sig": "Sc(5,5551,INPUT)", "nClass": "t$", "sts": 20726, "aliases": ["a4c4a5b4"] },
        "8fa7bfe4": { "sig": "PYu(2,6157,INPUT)", "nClass": "WW", "sts": 20727, "aliases": ["11d5aa1d"] },
        "dbc4ebfb": { "sig": "wh(9,7481,INPUT)", "nClass": "jJ", "sts": 20728, "aliases": ["3b71b485", "1b3be681", "e2d73494", "f3f47d72", "f8ac6630", "a63fdf02", "ad9754e8"] },
        "93572bf8": { "sig": "Hf(28,1950,INPUT)", "nClass": "ol", "sts": 20731, "aliases": ["b4a68e1c", "f2999a12"] },
        "a5b84ee3": { "sig": "DV(2,3435,INPUT)", "nClass": "YS", "sts": 20732, "aliases": ["80239721"] },
        "2373b006": { "sig": "rb(2,3435,INPUT)", "nClass": "bo", "sts": 20732, "aliases": ["b2d6f01c", "5203c085", "df6bd35f"] },
        "89b63303": { "sig": "kw(2,3435,INPUT)", "nClass": "LP", "sts": 20732, "aliases": ["46fe8fdc"] },
        "98a02d32": { "sig": "HD(40,5835,INPUT)", "nClass": "Tb", "sts": 20733, "aliases": ["8973b4ce", "7daa59ad", "56a32ca6"] },
        "de55d811": { "sig": "lF(40,5835,INPUT)", "nClass": "Ay", "sts": 20733, "aliases": ["1ed54fe5", "f36ef2f0", "ec429320"] },
        "0c3df268": { "sig": "vJ(40,5835,INPUT)", "nClass": "l4", "sts": 20733, "aliases": ["0f8136dd"] },
        "73252d67": { "sig": "G9(7,6899,INPUT)", "nClass": "BG", "sts": 20734, "aliases": ["68f28071", "a9596022"] },
        "adbaabd3": { "sig": "wG(7,6899,INPUT)", "nClass": "pE", "sts": 20734, "aliases": ["6d9f8d21"] },
        "99afa6f1": { "sig": "Hw(7,6899,INPUT)", "nClass": "vF", "sts": 20734, "aliases": ["bb06c5fa", "6e539070", "24c7e547"] },
        "8c76af16": { "sig": "sx(3,8741,INPUT)", "nClass": "dZ", "sts": 20735, "aliases": ["786c8c02", "e550fe71", "ef853915"] },
        "6ae32111": { "sig": "Aj(3,8741,INPUT)", "nClass": "dZ", "sts": 20735, "aliases": ["8b73fefd"] },
        "22cb88bc": { "sig": "s8(54,5263,INPUT)", "nClass": "vA", "sts": 20737, "aliases": ["2cc02ffd", "6718331f"] },
        "5cdc404f": { "sig": "nD(5,5449,INPUT)", "nClass": "Di", "sts": 20738, "aliases": ["8c7aac80", "d5e58f95", "3c899c93", "ee9658aa"] },
        "226b9b94": { "sig": "RG(5,5449,INPUT)", "nClass": "xa", "sts": 20738, "aliases": ["d1e6e263", "21090930"] },
        "4db0dd7d": { "sig": "Ya(5,5449,INPUT)", "nClass": "Pb", "sts": 20738, "aliases": ["e5b5c44d", "41847f6b"] },
        "4c5cfab3": { "sig": "oF(17,1206,INPUT)", "nClass": "QK", "sts": 20739, "aliases": ["5342137e", "ab64b233", "1996f5f7"] },
        "4c3b0988": { "sig": "P1(17,1206,INPUT)", "nClass": "bB", "sts": 20739, "aliases": ["e071f443", "0229cd64", "8dfbe68b", "8da84994", "0d9899a8"] },
        "6870cdc1": { "sig": "ec(72,7798,INPUT)", "nClass": "fi", "sts": 20740, "aliases": ["c02b67da"] },
        "25178217": { "sig": "qw(72,7798,INPUT)", "nClass": "Dr", "sts": 20740, "aliases": ["202905cb", "94e937f9", "f4141a4f"] },
        "24299858": { "sig": "a0(72,7798,INPUT)", "nClass": "kq", "sts": 20740, "aliases": ["7b58401d", "c271e571", "95d777dc"] },
        "40dba4d7": { "sig": "vL(25,4433,INPUT)", "nClass": "QI", "sts": 20741, "aliases": ["f44465e3", "e29a2e88", "52726943", "b6eda4df", "8f9b066a"] },
        "0ed38f41": { "sig": "Sx(25,4433,INPUT)", "nClass": "dH", "sts": 20741, "aliases": ["1748cd0b"] },
        "4d596e5d": { "sig": "Le(25,1424,INPUT)", "nClass": "qt", "sts": 20742, "aliases": ["83f0e2d1", "ec8a4d33", "a0385a48", "6636507e"] },
        "922b5303": { "sig": "sa(25,1424,INPUT)", "nClass": "ez", "sts": 20742, "aliases": ["81618434"] }
      }
    }
    """)
}
