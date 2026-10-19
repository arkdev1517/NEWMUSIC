import XCTest
@testable import BitChord

@MainActor
final class AppSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "bitchord-settings-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testAndroidDefaults() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.autoplay)
        XCTAssertEqual(settings.playbackSpeed, 1.0)
        XCTAssertEqual(settings.crossfadeSeconds, 0)
        XCTAssertTrue(settings.wifiOnlyDownloads)
        XCTAssertTrue(settings.syncedLyrics)
        XCTAssertEqual(settings.audioQualityWiFi, .lossless)
        XCTAssertEqual(settings.scrobbleMinDuration, 30)
        XCTAssertEqual(settings.scrobbleDelayPercent, 0.5, accuracy: 0.001)
        XCTAssertEqual(settings.scrobbleDelaySeconds, 180)
        XCTAssertFalse(settings.onboardingComplete)
    }

    func testEffectiveQualityFollowsConnection() {
        let settings = AppSettings(defaults: defaults)
        settings.audioQualityWiFi = .lossless
        settings.audioQualityCellular = .low
        XCTAssertEqual(settings.effectiveQuality(metered: true), .low)
        XCTAssertEqual(settings.effectiveQuality(metered: false), .lossless)
        XCTAssertEqual(settings.effectiveQuality(metered: nil), .lossless)
    }

    func testWifiOnlyDownloadsGate() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.downloadsAllowed(metered: true))
        XCTAssertTrue(settings.downloadsAllowed(metered: false))
        settings.wifiOnlyDownloads = false
        XCTAssertTrue(settings.downloadsAllowed(metered: true))
    }

    func testPersistenceAndBackupRoundTrip() {
        let settings = AppSettings(defaults: defaults)
        settings.autoplay = false
        settings.crossfadeSeconds = 6
        settings.repeatMode = .one
        settings.displayName = "Tester"

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertFalse(reloaded.autoplay)
        XCTAssertEqual(reloaded.crossfadeSeconds, 6)

        let other = AppSettings(defaults: UserDefaults(suiteName: "\(suiteName!)-other")!)
        other.importValues(reloaded.exportValues())
        XCTAssertFalse(other.autoplay)
        XCTAssertEqual(other.crossfadeSeconds, 6)
        XCTAssertEqual(other.repeatMode, .one)
        XCTAssertEqual(other.displayName, "Tester")
    }

    func testDisplayNameWritesThroughToPartyNickname() {
        let settings = AppSettings(defaults: defaults)
        settings.displayName = "Party Name"
        XCTAssertEqual(defaults.string(forKey: "bitchord-listen-together-nickname-v1"), "Party Name")
    }

    func testQualityLadderCeilings() {
        XCTAssertEqual(AudioQuality.low.maxKbps, 64)
        XCTAssertEqual(AudioQuality.lossless.maxKbps, Int.max)
    }
}
