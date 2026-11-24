import Foundation
import Testing
@testable import WatchpostApp

/// The small model types whose spelling is the server's.
struct ModelTests {
    @Test func qualitiesAreNamedAsTheServerNamesThem() {
        #expect(Quality.allCases.map(\.rawValue) == ["orig", "720p", "480p", "360p"])
        #expect(Quality.menuOrder == [.original, .hd720, .hd480, .hd360])
        #expect(Quality.standard == .hd480)
        #expect(Quality.original.isTranscoded == false)
        #expect(Quality.hd720.isTranscoded)
        #expect(Quality.hd480.title == "480p")
        #expect(Quality(rawValue: "720p") == .hd720)
        #expect(Quality(rawValue: "1080p") == nil)
    }

    @Test func camerasAreNamedByTheirFileSuffix() {
        #expect(Camera.allCases.map(\.rawValue) == ["front", "back", "left_pillar", "right_pillar", "left_repeater", "right_repeater"])
        #expect(Camera.displayOrder == [.leftRepeater, .front, .rightRepeater, .leftPillar, .back, .rightPillar])
        #expect(Camera.displayOrder.map(\.displayRank) == Array(0...5))
        #expect(Camera.fallback == .front)
        // The `camera` number of a sentry event's `event.json`.
        #expect(Camera.triggerCamera(0) == .front)
        #expect(Camera.triggerCamera(3) == .leftPillar)
        #expect(Camera.triggerCamera(4) == .rightPillar)
        #expect(Camera.triggerCamera(5) == .leftRepeater)
        #expect(Camera.triggerCamera(6) == .rightRepeater)
        #expect(Camera.triggerCamera(7) == .back)
        #expect(Camera.triggerCamera(1) == nil, "0 front, 3-7 as above; 1 and 2 are not cameras")
        #expect(Camera.triggerCamera(nil) == nil)
        // The suffix of a clip file name.
        #expect(Camera.camera(inFileName: "2026-11-08_19-43-36-left_pillar.mp4") == .leftPillar)
        #expect(Camera.camera(inFileName: "2026-11-08_19-43-36-front.mp4") == .front)
        #expect(Camera.camera(inFileName: "2026-11-08_19-43-36.jpg") == nil)
        #expect(Camera.camera(inFileName: "front") == nil)
    }

    @Test func categoriesAndFailuresKeepTheServersWords() {
        #expect(ClipCategory.sentry.rawValue == "SentryClips")
        #expect(ClipCategory.saved.rawValue == "SavedClips")
        #expect(ClipCategory.recent.rawValue == "RecentClips")
        #expect(ClipCategory(rawValue: "DriveClips") == nil, "Not shown by the app")
        #expect(PlaybackSourceState(rawValue: "cooling") == .cooling)
        #expect(PlaybackSourceState(rawValue: "paused") == nil, "Only what the server writes; anything else is read as missing")
        #expect(ExportJobState(rawValue: "error") == .error)
        #expect(ExportFailure.server("x") != .watermarkUnavailable)
    }

    @Test func aClipKnowsWhereItsStillAndItsTelemetryAre() {
        let video = Fixtures.video(.leftPillar)
        #expect(video.id == "/media/SentryClips/2026-11-08_19-43-36/2026-11-08_19-43-36-left_pillar.mp4")
        #expect(video.thumbnailPath == "/thumb/SentryClips/2026-11-08_19-43-36/2026-11-08_19-43-36-left_pillar.mp4")
        #expect(video.archivePath == "/archive/SentryClips/2026-11-08_19-43-36/2026-11-08_19-43-36-left_pillar.mp4")
    }

    @Test func aServerIsShownByHostAndPort() throws {
        func label(_ text: String) throws -> String { ServerRecord(address: try ServerAddress.normalize(text)).hostLabel }
        #expect(try label("192.168.1.50:8080") == "192.168.1.50:8080")
        #expect(try label("192.168.1.50") == "192.168.1.50")
        #expect(try label("https://cam.example.com") == "cam.example.com")
        #expect(try label("https://cam.example.com:443") == "cam.example.com", "The default port is not worth showing")
        #expect(try label("https://cam.example.com:80") == "cam.example.com:80")
        #expect(try label("box.local") == "box.local")
    }

    @Test @MainActor func savedServersSurviveTheRoundTripThroughDefaults() throws {
        let suite = "com.watchpost.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ServerStore(defaults: defaults, secrets: SecretStore(service: "com.watchpost.tests.secrets"))
        #expect(store.records.isEmpty)
        #expect(store.lastServerID == nil)
        let first = ServerRecord(address: try ServerAddress.normalize("192.168.1.50:8080"))
        var second = ServerRecord(address: try ServerAddress.normalize("10.0.0.5"), preferredQuality: .hd720)
        store.save(first)
        store.save(second)
        store.lastServerID = first.id
        second.serverVersion = "2.8.45"
        store.save(second)
        #expect(store.records.map(\.id) == [first.id, second.id])
        #expect(store.record(id: second.id)?.serverVersion == "2.8.45")
        store.setQuality(.original, for: first.id)
        store.touch(second.id)
        #expect(store.record(id: first.id)?.preferredQuality == .original)
        let touched = try #require(store.record(id: second.id))
        #expect(touched.lastUsedAt > second.lastUsedAt)

        // What was written is what the next launch reads.
        let reopened = ServerStore(defaults: defaults, secrets: SecretStore(service: "com.watchpost.tests.secrets"))
        #expect(reopened.records == store.records)
        #expect(reopened.lastServerID == first.id)
        reopened.remove(first.id)
        #expect(reopened.records.map(\.id) == [second.id])
        #expect(reopened.lastServerID == nil, "The last server was the one forgotten")
    }

    // MARK: Swapping what plays

    @Test func anotherCameraKeepsTheMomentAndThePlayState() {
        let playing = PlaybackModel.swapStart(playedOut: false, wasPlaying: true, hadNothing: false, at: 7.5)
        #expect(playing.startAt == 7.5 && playing.autoplay)
        let paused = PlaybackModel.swapStart(playedOut: false, wasPlaying: false, hadNothing: false, at: 7.5)
        #expect(paused.startAt == 7.5 && !paused.autoplay)
    }

    @Test func afterTheMinutePlayedOutTheNextFileStartsOverAndPlays() {
        // The playhead is at the end: a fresh file sought there shows nothing.
        let start = PlaybackModel.swapStart(playedOut: true, wasPlaying: false, hadNothing: false, at: 12)
        #expect(start.startAt == 0 && start.autoplay)
    }

    @Test func theFirstFileAfterAMinuteWithoutOnePlays() {
        let start = PlaybackModel.swapStart(playedOut: false, wasPlaying: false, hadNothing: true, at: 0)
        #expect(start.startAt == 0 && start.autoplay)
    }
}
