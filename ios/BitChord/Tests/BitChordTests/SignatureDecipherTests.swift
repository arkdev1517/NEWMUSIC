import XCTest
@testable import BitChord

/// The decipher layer's pure extraction logic, exercised against player-JS
/// shaped fixtures (the live player script itself is YouTube's moving
/// target; these pin the shapes the extractor looks for).
final class SignatureDecipherTests: XCTestCase {
    func testFormFieldsDecodeCipher() {
        let fields = SignatureDecipher.formFields(
            "s=ABC%3D%3D&sp=sig&url=https%3A%2F%2Fr1.example.com%2Fvideoplayback%3Fitag%3D140"
        )
        XCTAssertEqual(fields["s"], "ABC==")
        XCTAssertEqual(fields["sp"], "sig")
        XCTAssertEqual(fields["url"], "https://r1.example.com/videoplayback?itag=140")
    }

    func testPlayerScriptURLFromEmbedPage() {
        let html = #"<script>var cfg = {"jsUrl":"\/s\/player\/abc123\/player_ias.vflset\/en_US\/base.js"}</script>"#
        XCTAssertEqual(
            SignatureDecipher.playerScriptURL(inPage: html)?.absoluteString,
            "https://www.youtube.com/s/player/abc123/player_ias.vflset/en_US/base.js"
        )
    }

    func testSignatureTimestampExtraction() {
        XCTAssertEqual(SignatureDecipher.signatureTimestamp(in: "x={signatureTimestamp:20312}"), 20312)
        XCTAssertEqual(SignatureDecipher.signatureTimestamp(in: #"{"sts":20742}"#), 20742)
        XCTAssertNil(SignatureDecipher.signatureTimestamp(in: "nothing here"))
    }

    func testSignatureFunctionFromCallSite() throws {
        let script = "a.set('signature', a.sig || Zx(a.s)); var Zx=function(a){a=a.split('');return a.join('')}"
        let ref = try SignatureDecipher.signatureFunction(in: script)
        XCTAssertEqual(ref.name, "Zx")
    }

    func testNFunctionDirectName() throws {
        let script = "if(c.get('n'))&&(b=Nf(b)); var Nf=function(a){return a.split('').reverse().join('')}"
        // The call-site shape in the extractor uses double quotes for "n".
        let modern = "if(c.get(\"n\"))&&(b=Nf(b)); var Nf=function(a){return a}"
        let ref = try SignatureDecipher.nFunction(in: modern)
        XCTAssertEqual(ref.name, "Nf")
        _ = script
    }

    func testNFunctionThroughArray() throws {
        let script = "var QA=[x1,Nf,y2]; if(c.get(\"n\"))&&(b=QA[1](b)); var Nf=function(a){return a}"
        let ref = try SignatureDecipher.nFunction(in: script)
        XCTAssertEqual(ref.name, "Nf")
    }

    func testDeclarationExtractionBalancesBracesAndStrings() {
        let script = "var Helper={rv:function(a){a.reverse()},sw:function(a,b){var c=a[0];a[0]='}';a[b]=c}};var Other=1;"
        let decl = SignatureDecipher.declaration(of: "Helper", in: script)
        XCTAssertNotNil(decl)
        XCTAssertTrue(decl?.contains("sw:function") ?? false)
        XCTAssertFalse(decl?.contains("Other") ?? true)
    }

    func testEvaluateSignatureLikeTransform() throws {
        // A reverse "decipher" over a helper object — the classic shape.
        let script = """
        var ZP={rv:function(a){a.reverse()}};
        var Zx=function(a){a=a.split("");ZP.rv(a);return a.join("")};
        x.set("signature", x.sig||Zx(x.s));
        """
        let ref = try SignatureDecipher.signatureFunction(in: script)
        let result = try SignatureDecipher.evaluate(functionNamed: ref, argument: "abcdef", script: script)
        XCTAssertEqual(result, "fedcba")
    }

    func testValidTransformedNRejectsInvalidTokens() {
        XCTAssertTrue(SignatureDecipher.isValidTransformedN("AbCdEfGh123_-", original: "RawNToken9876"))
        XCTAssertFalse(SignatureDecipher.isValidTransformedN("RawNToken9876", original: "RawNToken9876"))
        XCTAssertFalse(SignatureDecipher.isValidTransformedN("undefined", original: "RawNToken9876"))
        XCTAssertFalse(SignatureDecipher.isValidTransformedN("[object Object]", original: "RawNToken9876"))
        XCTAssertFalse(SignatureDecipher.isValidTransformedN("abc", original: "RawNToken9876"))
    }

    func testParseZemerConfigsIncludesAliases() {
        let json = """
        {
          "players": {
            "4d596e5d": { "sig": "Le(25,1424,INPUT)", "nClass": "qt", "sts": 20742, "aliases": ["83f0e2d1"] }
          }
        }
        """
        let parsed = SignatureDecipher.parseZemerConfigsJSON(json)
        XCTAssertEqual(parsed["4d596e5d"]?.nClass, "qt")
        XCTAssertEqual(parsed["83f0e2d1"]?.sig, "Le(25,1424,INPUT)")
        XCTAssertEqual(parsed["83f0e2d1"]?.sts, 20742)
    }
}
