import Foundation
import Testing
@testable import WatchpostApp

struct WireTests {
    // MARK: JSONValue

    @Test func jsonReadsEveryKind() {
        let root = Fixtures.json(#"{"name": "2026-11-08_19-43-36", "size": 73400320, "on": true, "missing": null, "list": [1, "2", false]}"#)
        #expect(root["name"] == .string("2026-11-08_19-43-36"))
        #expect(root["size"] == .number(73_400_320))
        #expect(root["on"] == .bool(true))
        #expect(root["missing"]?.isNull == true)
        #expect(root["list"] == .array([.number(1), .string("2"), .bool(false)]))
        #expect(root["name"]?.object == nil)
        #expect(root["list"]?[1] == .string("2"))
        #expect(root["list"]?[9] == nil)
        #expect(root["nope"] == nil)
        #expect(root.object?.count == 5)
    }

    @Test func aBareValueIsJSONTooAndNothingElseIs() {
        #expect(JSONValue(data: Data("42".utf8)) == .number(42))
        #expect(JSONValue(data: Data("true".utf8)) == .bool(true))
        #expect(JSONValue(data: Data("\"2026-11-08_19-43-36\"".utf8)) == .string("2026-11-08_19-43-36"))
        #expect(JSONValue(data: Data("{".utf8)) == .null)
        #expect(JSONValue(data: Data("<html>login</html>".utf8)) == .null)
        #expect(JSONValue(data: Data()) == .null)
    }

    @Test func aNumberMayBeWrittenAsStringAndTheOtherWayRound() {
        #expect(JSONValue.number(2).string == "2")
        #expect(JSONValue.number(2.5).string == "2.5")
        #expect(JSONValue.bool(false).string == "false")
        #expect(JSONValue.string("  上海  ").nonEmptyString == "上海")
        #expect(JSONValue.string("   ").nonEmptyString == nil)
        #expect(JSONValue.string(" 12.5 ").double == 12.5)
        #expect(JSONValue.bool(true).double == 1)
        #expect(JSONValue.string("3.6").int == 4)
        #expect(JSONValue.string("-3.6").int == -4)
        #expect(JSONValue.string("x").int == nil)
        #expect(JSONValue.number(1e19).int == nil)
        #expect(JSONValue.number(1e18).int64 == 1_000_000_000_000_000_000)
        #expect(JSONValue.number(1e19).int64 == nil)
        #expect(JSONValue.string(" 73400320 ").int64 == 73_400_320)
        #expect(JSONValue.string("1").bool == true)
        #expect(JSONValue.string("YES").bool == true)
        #expect(JSONValue.string("on").bool == true)
        #expect(JSONValue.string("0").bool == false)
        #expect(JSONValue.string("maybe").bool == nil)
        #expect(JSONValue.number(3).bool == true)
        #expect(JSONValue.null.bool == nil)
        #expect(JSONValue.array([.number(1)])["x"] == nil)
        #expect(JSONValue.array([.number(1)]).object == nil)
    }

    /// A number too big for an `Int` is read as its digits; `string` turns whole numbers through `Int64`.
    @Test func aHugeWholeNumberDoesNotTrap() {
        let huge = JSONValue(data: Data("1e300".utf8))
        #expect(huge == .number(1e300))
        _ = huge.string
    }

    // MARK: /api/events

    private static func carClock(_ text: String) -> Date? {
        ClipTime.date(text)
    }

    @Test func eventsAreListedNewestFirstOverTheThreeCategories() {
        let events = Wire.recordedEvents(fromEvents: Fixtures.json(Fixtures.eventsJSON))
        #expect(events.map(\.id) == ["RecentClips/2026-11-08_20-01-00", "SentryClips/2026-11-08_19-43-36", "SavedClips/2026-11-07_08-15-00"])
    }

    @Test func aSentryEventIsReadAsTheServerWroteIt() throws {
        let event = Fixtures.sentryEvent
        #expect(event.category == .sentry)
        #expect(event.name == Fixtures.event)
        #expect(event.sizeBytes == 73_400_320)
        #expect(event.isLocked == false)
        #expect(event.groups.count == 1)
        let group = try #require(event.groups.first)
        #expect(group.start == Self.carClock("2026-11-08T19:43:36"))
        #expect(group.videos.map(\.camera) == [.front, .leftPillar])
        #expect(group.videos.map(\.duration) == [nil, nil])
        let front = try #require(group.video(for: .front))
        #expect(front == Fixtures.video())
        #expect(front.thumbnailPath == "/thumb/SentryClips/2026-11-08_19-43-36/2026-11-08_19-43-36-front.mp4")
        #expect(front.archivePath == "/archive/SentryClips/2026-11-08_19-43-36/2026-11-08_19-43-36-front.mp4")
        #expect(event.meta.reason == "sentry_aware_object_detection")
        #expect(event.meta.cameraNumber == 0)
        #expect(event.meta.timestamp == Self.carClock("2026-11-08T19:43:40"))
        #expect(event.meta.city == "上海")
        #expect(event.meta.street == "南京西路")
        #expect(event.meta.latitude == 31.2304)
        #expect(event.meta.longitude == 121.4737)
        // The web page's own rule: the camera `event.json` names, in the minute of its timestamp, 4 s in, opened 5 s earlier.
        #expect(event.trigger == TriggerInfo(camera: .front, groupIndex: 0, offset: 4, isExact: true, cameraMissing: false))
        #expect(event.trigger.playbackStart == 0)
        #expect(event.cover?.video == front)
        #expect(event.cover?.time == 4)
        #expect(event.cameras == [.front, .leftPillar])
        #expect(event.end == group.start)
    }

    @Test func aSavedEventOpensOnTheFrontCamera() {
        let saved = Fixtures.savedEvent
        #expect(saved.isLocked == true)
        #expect(saved.meta.reason == "user_interaction_dashcam_saved")
        // 08:15:12 falls into the clip that starts at 08:15:00.
        #expect(saved.trigger == TriggerInfo(camera: .front, groupIndex: 0, offset: 12, isExact: true, cameraMissing: false))
        #expect(saved.trigger.playbackStart == 7)
        #expect(saved.cover?.time == 12)
    }

    @Test func aRecentClipWithoutAMetadataOpensWhateverIsThere() {
        let recent = Fixtures.recentEvent
        #expect(recent.meta == EventMeta.empty)
        #expect(recent.isLocked == false)
        // No trigger camera is named, so the one camera that exists is not "missing".
        #expect(recent.trigger == TriggerInfo(camera: .back, groupIndex: 0, offset: 0, isExact: false, cameraMissing: false))
        #expect(recent.cover?.time == 1)
    }

    private static let twoMinutes = """
        {"SentryClips": [{"name": "2026-11-08_19-43-36",
          "videos": [
            {"url": "/media/SentryClips/2026-11-08_19-43-36/2026-11-08_19-43-36-back.mp4", "cam": "back", "f": "2026-11-08_19-43-36-back.mp4"},
            {"url": "/media/SentryClips/2026-11-08_19-43-36/2026-11-08_19-43-36-front.mp4", "cam": "front", "f": "2026-11-08_19-43-36-front.mp4"},
            {"url": "/media/SentryClips/2026-11-08_19-43-36/2026-11-08_19-44-36-front.mp4", "cam": "front", "f": "2026-11-08_19-44-36-front.mp4"}
          ],
          "size": 110100480, "meta": {"reason": "sentry_aware_door", "camera": "5", "timestamp": "2026-11-08T19:44:39"},
          "locked": false, "lock_unknown": false}]}
        """

    @Test func anEventIsSplitIntoMinutesAndItsTriggerCameraIsMissedHonestly() throws {
        let event = try #require(Wire.recordedEvents(fromEvents: Fixtures.json(Self.twoMinutes)).first)
        #expect(event.groups.count == 2)
        #expect(event.groups.map(\.start) == [Self.carClock("2026-11-08T19:43:36"), Self.carClock("2026-11-08T19:44:36")])
        #expect(event.groups[0].cameras == [.front, .back])
        #expect(event.groups[1].cameras == [.front])
        // `camera: 5` is the left repeater, which has no footage here: the second minute's front camera opens instead.
        #expect(event.trigger == TriggerInfo(camera: .front, groupIndex: 1, offset: 3, isExact: true, cameraMissing: true))
        #expect(event.trigger.playbackStart == 0)
        #expect(event.cover?.video.camera == .front)
        #expect(event.cover?.time == 3)
        #expect(event.cameras == [.front, .back])
    }

    @Test func nothingToPlayIsNothingToList() {
        let events = Wire.recordedEvents(fromEvents: Fixtures.json(#"""
            {"SentryClips": [{"name": "", "videos": [{"f": "2026-11-08_19-43-36-front.mp4", "cam": "front"}]},
                            {"name": "2026-11-08_19-43-36", "videos": []},
                            {"name": "2026-11-08_19-43-36", "videos": [{"f": "event.json"}]}],
             "SavedClips": [{"name": "2026-11-07_08-15-00"}],
             "RecentClips": [{"name": "2026-11-08_20-01-00", "videos": [{"f": "clip.mp4", "cam": "back"}],
                              "meta": {"timestamp": "2026-11-08T20:01:20"}}]}
            """#))
        #expect(events.map(\.id) == ["RecentClips/2026-11-08_20-01-00"])
        // A file whose name is not a time still belongs to the event: one minute, at the event's own time.
        #expect(events[0].groups.map(\.start) == [Self.carClock("2026-11-08T20:01:20")])
        #expect(events[0].groups[0].videos.map(\.file) == ["clip.mp4"])
        #expect(events[0].start == Self.carClock("2026-11-08T20:01:20"))
    }

    @Test func anEventOfEqualTimeIsOrderedByName() {
        let a = Fixtures.sentryEvent
        let later = RecordedEvent(category: .sentry, name: "2026-11-08_19-43-37", meta: a.meta, groups: a.groups, sizeBytes: 0, isLocked: nil)
        #expect(Wire.newestFirst([a, later]).map(\.name) == ["2026-11-08_19-43-37", "2026-11-08_19-43-36"])
        #expect(Wire.newestFirst([later, a]).map(\.name) == ["2026-11-08_19-43-37", "2026-11-08_19-43-36"])
    }

    @Test func aVideoIsNamedByItsFileAndPlacedUnderMedia() {
        func video(_ json: String, category: ClipCategory = .sentry) -> ClipVideo? {
            Wire.clipVideo(Fixtures.json(json), category: category, event: Fixtures.event)
        }
        // `f` wins over `url`; a name with a space and Chinese characters is kept as it is.
        #expect(video(#"{"f": "2026-11-08 19-43-36-left_pillar.mp4", "url": "/media/SentryClips/2026-11-08 19-43-36/2026-11-08 19-43-36-left_pillar.mp4"}"#)?.file
                == "2026-11-08 19-43-36-left_pillar.mp4")
        #expect(video(#"{"f": "片段-01.mp4", "cam": "back"}"#)?.camera == .back)
        // Without `f` and `cam` both are read from the URL.
        let fromURL = video(#"{"url": "/media/SavedClips/2026-11-07_08-15-00/2026-11-07_08-15-00-front.mp4"}"#)
        #expect(fromURL?.file == "2026-11-07_08-15-00-front.mp4")
        #expect(fromURL?.camera == .front)
        // The camera comes from the file name when `cam` is not one of the six.
        #expect(video(#"{"f": "2026-11-08_19-43-36-front.mp4", "cam": "Front"}"#)?.camera == .front)
        // A URL outside `/media/` is put where the server keeps the clip.
        #expect(video(#"{"f": "2026-11-08_19-43-36-front.mp4", "url": "/elsewhere/x.mp4"}"#)?.path
                == "/media/SentryClips/2026-11-08_19-43-36/2026-11-08_19-43-36-front.mp4")
        #expect(video(#"{"url": "2026-11-08_19-43-36-front.mp4"}"#, category: .saved)?.path
                == "/media/SavedClips/2026-11-08_19-43-36/2026-11-08_19-43-36-front.mp4")
        // Only a positive length counts.
        #expect(video(#"{"f": "2026-11-08_19-43-36-front.mp4", "duration": 59.6}"#)?.duration == 59.6)
        #expect(video(#"{"f": "2026-11-08_19-43-36-front.mp4", "duration": 0}"#)?.duration == nil)
        #expect(video(#"{"f": "2026-11-08_19-43-36-front.mp4", "duration": -3}"#)?.duration == nil)
        #expect(video(#"{"f": "2026-11-08_19-43-36-front.mp4", "duration": null}"#)?.duration == nil)
        // No usable file, no camera, or a path where a file name should be.
        #expect(video(#"{"url": "/media/SentryClips/2026-11-08_19-43-36/"}"#) == nil)
        #expect(video(#"{"f": "2026-11-08_19-43-36-side.mp4"}"#) == nil)
        #expect(video(#"{"f": "2026-11-08_19-43-36.mp4"}"#) == nil)
        #expect(video(#"{"f": "a/b.mp4", "cam": "back"}"#) == nil)
        #expect(video(#"{"cam": "back"}"#) == nil)
    }

    @Test func eventJSONIsReadLoosely() {
        #expect(Wire.eventMeta(nil) == EventMeta.empty)
        #expect(Wire.eventMeta(Fixtures.json("{}")) == EventMeta.empty)
        #expect(Wire.eventMeta(.null) == EventMeta.empty)
        let meta = Wire.eventMeta(Fixtures.json(#"{"reason": "user_interaction_honk", "camera": "0", "timestamp": "2026-11-08 19:43:40", "city": "  ", "est_lat": 0, "est_lon": "31.2"}"#))
        #expect(meta.reason == "user_interaction_honk")
        #expect(meta.cameraNumber == 0)
        #expect(meta.timestamp == Self.carClock("2026-11-08T19:43:40"))
        #expect(meta.city == nil)
        #expect(meta.street == nil)
        // Cars that record no position write 0.
        #expect(meta.latitude == nil)
        #expect(meta.longitude == 31.2)
    }

    // MARK: /api/timeline

    @Test func theTimelineAddsTheLengthOfEachClip() throws {
        let timeline = Wire.recordedEvents(fromTimeline: Fixtures.json(Fixtures.timelineJSON), category: .sentry)
        let event = try #require(timeline.first)
        #expect(event.id == Fixtures.sentryEvent.id)
        #expect(event.groups.first?.video(for: .front)?.duration == 59.6)
        #expect(event.groups.first?.video(for: .leftPillar)?.duration == nil)
        #expect(event.end == (try #require(Self.carClock("2026-11-08T19:43:36"))) + 59.6)
        #expect(Wire.recordedEvents(fromTimeline: Fixtures.json(ServerFixtures.timelineInvalid), category: .sentry).isEmpty)
        #expect(Wire.recordedEvents(fromTimeline: Fixtures.json(ServerFixtures.timelinePending), category: .sentry).isEmpty)
        #expect(Wire.recordedEvents(fromTimeline: Fixtures.json("[]"), category: .sentry).isEmpty)
        #expect(Wire.recordedEvents(fromTimeline: .null, category: .sentry).isEmpty)
    }

    // MARK: /api/telemetry

    @Test func telemetryRowsAreReadByPosition() {
        // One row as `parse_telemetry` writes it (`sentry-viewer.py` L11201–11216): 14 cells by position.
        let row = Fixtures.json(#"[2.25, "1", -0.4, 120, -149.7, 1, 2, 3, 0, 0, 16.4, 1.14, -0.07, 9.80]"#)
        let sample = Wire.telemetrySample(row)
        #expect(sample?.time == 2.25)
        #expect(sample?.gear == "D")
        #expect(sample?.speedKmh == 0)
        #expect(sample?.throttlePercent == 100)
        #expect(sample?.steeringDegrees == -149.7)
        #expect(sample?.brake == true)
        #expect(sample?.turnSignal == .right)
        #expect(sample?.autopilotState == 3)
        #expect(sample?.latitude == nil)
        #expect(sample?.longitude == nil)
        #expect(sample?.heading == 16.4)
        // Gear written as the car's number, or not a gear at all.
        func gear(_ cell: JSONValue) -> String? { Wire.telemetrySample(Self.row(.number(0), cell))?.gear }
        #expect(gear(.number(0)) == "P")
        #expect(gear(.number(2)) == "R")
        #expect(gear(.number(3)) == "N")
        #expect(gear(.string("r")) == "R")
        #expect(gear(.string("x")) == nil)
        #expect(gear(.null) == nil)
        // A row with fewer than 7 cells, or without a time, is not a sample.
        #expect(Wire.telemetrySample(.array([.number(0), .string("D"), .number(1), .number(2), .number(3), .number(0)])) == nil)
        #expect(Wire.telemetrySample(.array([.string("t"), .string("D"), .number(1), .number(2), .number(3), .number(0), .number(0)])) == nil)
        #expect(Wire.telemetrySample(.string("0")) == nil)
        // A turn signal the app does not know is "not recorded".
        #expect(Wire.telemetrySample(Self.row(.number(0), .string("D"), .number(1), .number(2), .number(3), .number(0), .number(7)))?.turnSignal == nil)
        #expect(Wire.telemetrySample(Self.row(.number(0), .string("D"), .number(-3)))?.speedKmh == 0)
        #expect(Wire.telemetrySample(Self.row(.number(0), .string("D"), .number(5), .number(120)))?.throttlePercent == 100)
        #expect(Wire.gearName(" p ") == "P")
        #expect(Wire.gearName("4") == nil)
    }

    @Test func aTelemetryAnswerIsATrackOrNothing() throws {
        let track = try #require(Self.track(ServerFixtures.telemetry))
        #expect(track.samples.map(\.time) == [0, 6.5, 9.5])
        #expect(track.samples.map(\.speedKmh) == [30, 27.8, 13.9])
        #expect(track.samples.map(\.brake) == [false, true, false])
        #expect(track.samples.map(\.turnSignal) == [.off, .off, .right])
        #expect(track.samples.map(\.autopilotState) == [0, 0, 3])
        #expect(track.samples.map(\.latitude) == [31.2304, 31.2305, 31.2306])
        // A parked clip has no telemetry; that is an answer, not a failure.
        #expect(Wire.telemetry(Fixtures.json(ServerFixtures.telemetryNoSEI)) == .none)
        #expect(Wire.telemetry(Fixtures.json(ServerFixtures.telemetryBadPath)) == .none)
        #expect(Wire.telemetry(Fixtures.json(#"{"ok": true, "frames": []}"#)) == .none)
        #expect(Wire.telemetry(Fixtures.json(#"{"ok": true}"#)) == .none)
        #expect(Self.track(#"{"ok": "true", "frames": [[1, "D", 1, 0, 0, 0, 0, 0]]}"#) != nil)
        #expect(Wire.telemetry(.null) == .none)
    }

    /// The track in an answer, or nil when the answer was not one.
    private static func track(_ body: String) -> TelemetryTrack? {
        guard case .track(let track) = Wire.telemetry(Fixtures.json(body)) else { return nil }
        return track
    }

    /// A telemetry row with the given first cells, the rest zero: the server always writes 14.
    private static func row(_ cells: JSONValue...) -> JSONValue {
        .array(cells + Array(repeating: .number(0), count: max(0, 14 - cells.count)))
    }

    @Test func aTrackIsAskedForTheSampleThatDescribesAMoment() throws {
        let track = try #require(Self.track(#"{"ok": true, "frames": [[10, "D", 1, 0, 0, 0, 0, 0], [0, "D", 1, 0, 0, 0, 0, 0], [1, "D", 2, 0, 0, 0, 0, 0], [2, "D", 3, 0, 0, 0, 0, 0]]}"#))
        // Kept in time order whatever order the rows came in.
        #expect(track.samples.map(\.time) == [0, 1, 2, 10])
        // Gaps of 1, 1 and 8: the typical one is 1, and a sample counts for 2.5 s.
        #expect(track.spacing == 1)
        #expect(track.tolerance == 2.5)
        #expect(track.sample(at: 0)?.time == 0)
        #expect(track.sample(at: 1.4)?.time == 1)
        #expect(track.sample(at: 2)?.time == 2)
        #expect(track.sample(at: 3.9)?.time == 2)
        #expect(track.sample(at: 4.6) == nil)
        #expect(track.sample(at: 9.9) == nil)
        #expect(track.sample(at: 10)?.time == 10)
        #expect(track.sample(at: 12.4)?.time == 10)
        #expect(track.sample(at: 12.6) == nil)
        #expect(track.sample(at: -0.5)?.time == 0)
        let one = TelemetryTrack(samples: [try #require(Wire.telemetrySample(Self.row(.number(3), .string("P"))))])
        #expect(one.spacing == 0)
        #expect(one.tolerance == 1)
        #expect(one.sample(at: 3.9)?.time == 3)
        #expect(one.sample(at: 4.1) == nil)
        #expect(TelemetryTrack(samples: []).sample(at: 0) == nil)
    }

    // MARK: /api/live

    @Test func liveIsReadFromDiskAndSys() {
        let now = Date(timeIntervalSince1970: 1_762_600_000)
        let status = Wire.syncStatus(fromLive: Fixtures.json(ServerFixtures.live), now: now)
        #expect(status.measuredAt == now)
        #expect(status.syncRunning == true)
        #expect(status.pendingFiles == 2)
        #expect(status.lastSyncAgo == 384)
        #expect(status.ffmpegAvailable == true)
        #expect(status.archiveUsedBytes == 412_000_000_000)
        #expect(status.archiveLimitBytes == 2_000_000_000_000)
        #expect(status.usbUsedBytes == 41_204_699_136)
        #expect(status.usbCapacityBytes == 64_424_509_440)
        #expect(status.diskUsedBytes == 618_457_903_104)
        #expect(status.diskCapacityBytes == 1_000_204_888_064)
        #expect(abs((status.archiveFraction ?? 0) - 0.206) < 1e-12)
        #expect(status.usbFraction == Double(41_204_699_136) / Double(64_424_509_440))
        #expect(status.diskFraction == Double(618_457_903_104) / Double(1_000_204_888_064))
        #expect(!status.isArchiveNearlyFull)
    }

    @Test func whatTheBoxDoesNotKnowStaysUnknown() {
        let unknown = Wire.syncStatus(fromLive: Fixtures.json(ServerFixtures.liveUnknown))
        #expect(unknown.syncRunning == false)
        #expect(unknown.pendingFiles == 0)
        #expect(unknown.lastSyncAgo == nil)
        #expect(unknown.ffmpegAvailable == false)
        #expect(unknown.archiveUsedBytes == nil)
        #expect(unknown.usbUsedBytes == nil)
        #expect(unknown.diskCapacityBytes == nil)
        let sparse = Wire.syncStatus(fromLive: Fixtures.json(#"{"ago": -5, "disk": {"img_used": 0, "img_nominal": 0, "arc_used": "123", "disk_total": 4096}}"#))
        #expect(sparse.lastSyncAgo == nil)
        #expect(sparse.usbUsedBytes == nil)
        #expect(sparse.usbCapacityBytes == nil)
        #expect(sparse.archiveUsedBytes == 123)
        #expect(sparse.diskCapacityBytes == 4096)
        #expect(sparse.syncRunning == nil)
        var nothing = Wire.syncStatus(fromLive: nil)
        // Measured now, and nothing known.
        #expect(nothing.measuredAt != nil)
        nothing.measuredAt = nil
        #expect(nothing == SyncStatus.unknown)
        #expect(Wire.syncStatus(fromLive: .null, now: .distantPast).measuredAt == .distantPast)
    }

    @Test func fractionsClampAndTheArchiveIsNearlyFullPast85Percent() {
        var status = SyncStatus()
        #expect(status.archiveFraction == nil)
        #expect(!status.isArchiveNearlyFull)
        status.archiveUsedBytes = 85
        status.archiveLimitBytes = 100
        #expect(status.archiveFraction == 0.85)
        #expect(!status.isArchiveNearlyFull)
        status.archiveUsedBytes = 86
        #expect(status.isArchiveNearlyFull)
        status.archiveUsedBytes = 150
        #expect(status.archiveFraction == 1)
        status.archiveLimitBytes = 0
        #expect(status.archiveFraction == nil)
    }

    // MARK: /api/ver, /api/auth/info, the cookie

    @Test func versionAndPasswordNeedAreRead() {
        #expect(Wire.version(Fixtures.json(ServerFixtures.version)) == "2.8.45")
        #expect(Wire.version(Fixtures.json(#"{"v": ""}"#)) == nil)
        #expect(Wire.version(Fixtures.json("{}")) == nil)
        #expect(Wire.version(.null) == nil)
        #expect(Wire.version(Fixtures.json(#"{"v": 2}"#)) == "2")
        #expect(Wire.requiresPassword(Fixtures.json(ServerFixtures.authInfoOn)) == true)
        #expect(Wire.requiresPassword(Fixtures.json(ServerFixtures.authInfoOff)) == false)
        #expect(Wire.requiresPassword(Fixtures.json(#"{"on": "false"}"#)) == false)
        #expect(Wire.requiresPassword(Fixtures.json(#"{"on": 0}"#)) == false)
        #expect(Wire.requiresPassword(Fixtures.json("{}")) == nil)
    }

    @Test func theLoginCookieIsReadFromSetCookie() {
        let plain = "tsf_sess=1761600000.ffffffffffffffffffffffffffffffff; Path=/; Max-Age=2592000; HttpOnly; SameSite=Lax"
        let token = Wire.sessionToken(setCookie: plain)
        #expect(token?.value == "1761600000.ffffffffffffffffffffffffffffffff")
        #expect(token?.expiresAt == Date(timeIntervalSince1970: 1_761_600_000))
        // Behind HTTPS the server adds `Secure`; another cookie in the same header is skipped.
        #expect(Wire.sessionToken(setCookie: plain + "; Secure") == token)
        #expect(Wire.sessionToken(setCookie: "TSF_SESS=1761600000.ffff; Path=//") == nil)
        #expect(Wire.sessionToken(setCookie: "other=1; " + plain)?.value == token?.value)
        // No signature, an empty value (what `/logout` sends), or no cookie at all.
        #expect(Wire.sessionToken(setCookie: "tsf_sess=1761600000; Path=/") == nil)
        #expect(Wire.sessionToken(setCookie: "tsf_sess=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax") == nil)
        #expect(Wire.sessionToken(setCookie: nil) == nil)
        #expect(Wire.sessionToken(setCookie: "") == nil)
        // A token without a plain expiry falls back to `Max-Age`.
        let aged = Wire.sessionToken(setCookie: "tsf_sess=opaque.sig; Path=/; Max-Age=86400; HttpOnly")
        #expect(aged?.value == "opaque.sig")
        #expect(aged?.expiresAt.map { abs($0.timeIntervalSinceNow - 86_400) < 5 } == true)
    }

    @Test func aCookieIsValidUntilAMinuteBeforeItLapses() {
        let now = Date(timeIntervalSince1970: 1_761_500_000)
        let token = SessionToken(value: "x.y", expiresAt: now.addingTimeInterval(120))
        #expect(token.isValid(now: now))
        #expect(!SessionToken(value: "x.y", expiresAt: now.addingTimeInterval(60)).isValid(now: now))
        #expect(!SessionToken(value: "x.y", expiresAt: now.addingTimeInterval(-60)).isValid(now: now))
        #expect(SessionToken(value: "x.y", expiresAt: nil).isValid(now: now))
        // The shared fixture's cookie has lapsed: it is dated to the second it expires.
        #expect(!Fixtures.token.isValid(now: Date(timeIntervalSince1970: 1_761_500_000)))
    }

    // MARK: Playback and export

    @Test func playbackStatesAreNamedByTheServerAnythingElseIsMissing() {
        for (text, state) in [("ready", PlaybackSourceState.ready), ("pending", .pending), ("cooling", .cooling), ("failed", .failed), ("missing", .missing)] {
            #expect(Wire.playbackSourceState(Fixtures.json(#"{"state": "\#(text)"}"#)) == state)
        }
        #expect(Wire.playbackSourceState(Fixtures.json(ServerFixtures.playbackParts)) == .missing)
        #expect(Wire.playbackSourceState(Fixtures.json("{}")) == .missing)
        #expect(Wire.playbackSourceState(.null) == .missing)
        #expect(Wire.playbackSourceState(nil) == .missing)
    }

    @Test func theFontAnswerIsYesOrNo() {
        #expect(Wire.fontAvailable(Fixtures.json(ServerFixtures.fontPresent)) == true)
        #expect(Wire.fontAvailable(Fixtures.json(ServerFixtures.fontMissing)) == false)
        #expect(Wire.fontAvailable(Fixtures.json("{}")) == nil)
        #expect(Wire.fontAvailable(Fixtures.json(#"{"ok": "false"}"#)) == false)
    }

    @Test func aJobIsStartedOrTheServerSaysWhyNot() {
        #expect(Wire.exportJobStarted(Fixtures.json(ServerFixtures.exportStarted)) == .success("2026-11-08_19-43-36-ex482913"))
        #expect(Wire.exportJobStarted(Fixtures.json(ServerFixtures.burnEventMissing)) == .failure(ServerRefusal(message: "事件不存在")))
        #expect(Wire.exportJobStarted(Fixtures.json(#"{"ok": false, "msg": "请求体过大"}"#)) == .failure(ServerRefusal(message: "请求体过大")))
        // An id without `ok`, `ok` without an id, and no text at all.
        #expect(Wire.exportJobStarted(Fixtures.json(#"{"id": "x"}"#)) == .failure(ServerRefusal(message: "")))
        #expect(Wire.exportJobStarted(Fixtures.json(#"{"ok": true}"#)) == .failure(ServerRefusal(message: "")))
        #expect(Wire.exportJobStarted(Fixtures.json(#"{"ok": false}"#)) == .failure(ServerRefusal(message: "")))
        #expect(Wire.exportJobStarted(.null) == .failure(ServerRefusal(message: "")))
    }

    @Test func aJobsProgressIsReadFromItsStatus() {
        func status(_ body: String, http: Int? = 200) -> ExportJobStatus {
            Wire.exportJobStatus(Fixtures.json(body), httpStatus: http)
        }
        #expect(status(ServerFixtures.stitchRunning(percent: 42)) == ExportJobStatus(state: .running, percent: 42, message: nil, sizeBytes: 0))
        #expect(status(ServerFixtures.stitchDone) == ExportJobStatus(state: .done, percent: 100, message: nil, sizeBytes: 1_048_576))
        #expect(status(#"{"state": "DONE", "pct": "100"}"#).state == .done)
        #expect(status(#"{"state": "running", "pct": 101}"#).percent == nil)
        #expect(status(#"{"state": "running", "pct": -1}"#).percent == nil)
        #expect(status(#"{"state": "running", "pct": 42.6}"#).percent == 43)
        #expect(status(#"{"state": "running", "size": "123"}"#).sizeBytes == 123)
        // A state the app does not know is "ask again"; with a reason it is a failure.
        #expect(status(#"{"state": "parts", "seconds": 1}"#).state == .unknown)
        #expect(status(#"{"state": "error", "msg": "转码超时"}"#) == ExportJobStatus(state: .error, percent: nil, message: "转码超时", sizeBytes: nil))
        // The job is gone: answered as an error with 404.
        let gone = status(ServerFixtures.stitchGone, http: 404)
        #expect(gone.state == .error)
        #expect(gone.message == "任务不存在或已过期")
    }

    @Test func aFailedJobCarriesTheServersOwnErr() {
        let failed = Wire.exportJobStatus(Fixtures.json(ServerFixtures.stitchFailed))
        #expect(failed.state == .error)
        #expect(failed.message == "转码超时")
        let gone = Wire.exportJobStatus(Fixtures.json(ServerFixtures.stitchGone), httpStatus: 404)
        #expect(gone.message == "任务不存在或已过期")
    }
}
