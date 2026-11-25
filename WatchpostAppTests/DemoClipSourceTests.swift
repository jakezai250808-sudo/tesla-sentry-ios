import Foundation
import Testing
@testable import WatchpostApp

/// `DemoClipSource`: the offline demo, made from the files that ship with the app and the moment it is opened.
struct DemoClipSourceTests {
    /// A fixed moment, so the made-up events land where the test says. 2027-01-15 08:00:17 UTC.
    private static let now = Date(timeIntervalSince1970: 1800000017)

    /// `yyyy-MM-dd_HH-mm-ss` on the phone's clock, as the demo writes its names.
    private static func stamp(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02d_%02d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                      parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    /// `minutesAgo` as the demo places an event: back from now, then down to the whole minute.
    private static func start(minutesAgo minutes: Double) -> Date {
        Date(timeIntervalSince1970: floor((now.timeIntervalSince1970 - minutes * 60) / 60) * 60)
    }

    private static func bundled(_ name: String, _ ext: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext)
            ?? Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "DemoAssets")
    }

    private func source() -> DemoClipSource { DemoClipSource(now: Self.now) }

    /// What the copy of `demo-events.json` that the app reads says about an event's place.
    private static func placeInTheAppLanguage(for footage: DemoClipSource.Footage) throws -> (city: String, street: String) {
        let url = try #require(bundled("demo-events", "json"))
        return try place(in: url, footage: footage)
    }

    /// The place of the first event of `footage` in one copy of `demo-events.json`, and how many events have one.
    private static func place(in url: URL, footage: DemoClipSource.Footage) throws -> (city: String, street: String) {
        let root = JSONValue(data: try Data(contentsOf: url))
        for row in root["events"]?.array ?? [] where row["footage"]?.string == footage.rawValue {
            if let city = row["city"]?.string, let street = row["street"]?.string { return (city, street) }
        }
        struct NoPlace: Error { let message: String }
        throw NoPlace(message: "no event with a place on \(footage.rawValue) footage in \(url.path)")
    }

    private func events() async throws -> [RecordedEvent] { try await source().events() }

    private func event(_ category: ClipCategory, minutesAgo: Double, in events: [RecordedEvent]) throws -> RecordedEvent {
        let id = "\(category.rawValue)/\(Self.stamp(Self.start(minutesAgo: minutesAgo)))"
        return try #require(events.first { $0.id == id }, "The demo event \(id)")
    }

    private func removeExport(named fileName: String) {
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent(fileName))
    }

    // MARK: The list

    @Test func theDemoIsTenEventsNewestFirstOnWholeMinutes() async throws {
        let events = try await events()
        #expect(events.count == 10)
        // The real recording is a sentry clip too, next to the five drawn ones.
        #expect(events.filter { $0.category == .sentry }.count == 6)
        #expect(events.filter { $0.category == .sentry && !$0.isRealSample }.count == 5)
        #expect(events.filter { $0.category == .saved }.count == 2)
        #expect(events.filter { $0.category == .recent }.count == 2)
        #expect(zip(events, events.dropFirst()).allSatisfy { $0.start > $1.start })
        // Like a real event, the first minute starts on a whole minute.
        #expect(events.allSatisfy { $0.start.timeIntervalSince1970.truncatingRemainder(dividingBy: 60) == 0 })
        // Something from today: the newest event is three minutes old, the oldest a little over five days.
        let first = try #require(events.first)
        let last = try #require(events.last)
        #expect(first.id == "SentryClips/\(Self.stamp(Self.start(minutesAgo: 3)))")
        #expect(Self.now.timeIntervalSince(first.start) < 24 * 3600)
        #expect(Self.now.timeIntervalSince(last.start) > 5 * 24 * 3600)
        #expect(last.id == "SentryClips/\(Self.stamp(Self.start(minutesAgo: 7247)))")
    }

    // MARK: The real recording

    /// The one event that is not drawn: the real file, and nothing made up about it. Its moment is only
    /// where it sits in the list, so no screen shows that moment as when it was recorded.
    @Test func theRealRecordingIsOneEventThatInventsNothing() async throws {
        let events = try await events()
        let samples = events.filter(\.isRealSample)
        #expect(samples.count == 1)
        #expect(events.filter { !$0.isRealSample }.allSatisfy { $0.realSampleSeconds == nil })
        let sample = try #require(samples.first)
        #expect(events.first == sample)
        #expect(sample.id == "SentryClips/\(Self.stamp(Self.start(minutesAgo: 3)))")
        // No reason, no place and no time of its own.
        #expect(sample.meta == EventMeta.empty)
        #expect(sample.isLocked == nil)
        #expect(sample.realSampleSeconds == 20)
        // One file for the whole event, under its own name, weighing what the shipped file weighs.
        #expect(sample.groups.count == 1)
        #expect(sample.groups.first?.start == sample.start)
        let video = try #require(sample.groups.first?.videos.first)
        #expect(sample.groups.first?.videos.count == 1)
        #expect(video.file == "watchpost-real-six-camera-20s.mp4")
        #expect(video.duration == 20)
        #expect(video.path == "/media/SentryClips/\(sample.name)/watchpost-real-six-camera-20s.mp4")
        #expect(!video.file.hasPrefix("demo-"), "The media generator removes what starts with demo-")
        let shipped = try #require(Self.bundled(DemoClipSource.RealSample.clip, "mp4"))
        let size = Int64(try #require(shipped.resourceValues(forKeys: [.fileSizeKey]).fileSize))
        #expect(size == 4_195_326)
        #expect(sample.sizeBytes == size)
    }

    @Test func theRealRecordingsStillPlaybackAndExportAreItsOwnFile() async throws {
        let source = source()
        let sample = try #require(try await source.events().first { $0.isRealSample })
        let video = try #require(sample.groups.first?.videos.first)
        let shipped = try #require(Self.bundled(DemoClipSource.RealSample.clip, "mp4"))
        // The still is a frame of the clip itself, whichever moment is asked for.
        let still = source.thumbnail(for: video, at: 0)
        #expect(still.url.lastPathComponent == "watchpost-real-six-camera-20s-still.jpg")
        #expect(source.thumbnail(for: video, at: 17).url == still.url)
        #expect(try await source.imageData(for: still).starts(with: [0xFF, 0xD8]), "A JPEG")
        // Every quality is the one file: there is no other picture to show in its place.
        for quality in Quality.allCases {
            let plan = try await source.playbackPlan(for: video, quality: quality)
            #expect(plan.initial.url == shipped)
            #expect(plan.initial.quality == quality)
            #expect(await Fixtures.upgrades(of: plan) == [])
        }
        // A drive like the others, but one nothing was recorded for: no telemetry is made up for it.
        #expect(try await source.telemetry(for: video) == .none)
        // An export hands over that very file, under its own name.
        let handle = try await source.startExport(event: sample, video: video, quality: .hd480)
        defer { removeExport(named: handle.fileName) }
        #expect(handle.id.hasPrefix("demo-"))
        #expect(handle.eventID == sample.id)
        #expect(handle.fileName == "watchpost-real-six-camera-20s.mp4")
        #expect(try await source.exportJob(handle).state == .running)
        let file = try await source.downloadExport(handle) { _ in }
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try Data(contentsOf: file) == Data(contentsOf: shipped))
    }

    /// A build that lost the recording: the list still has it, and it fails as a clip that is gone fails.
    /// Nothing drawn plays, shows or exports in its place.
    @Test func withoutItsFilesTheRealRecordingFailsAndNothingStandsIn() async throws {
        // A bundle with the demo's list and none of its media, as such a build would be.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("DemoClipSourceTests.\(UUID().uuidString).bundle", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let assets = folder.appendingPathComponent("DemoAssets/en.lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try #require(Self.bundled("demo-events", "json")),
                                         to: assets.appendingPathComponent("demo-events.json"))
        let info = ["CFBundleIdentifier": "watchpost.tests.made", "CFBundleDevelopmentRegion": "en",
                    "CFBundleLocalizations": ["en"]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: folder.appendingPathComponent("Info.plist"))
        let source = DemoClipSource(now: Self.now, bundle: try #require(Bundle(url: folder)))

        let events = try await source.events()
        // The drawn events fail too in such a bundle; what matters is that the list is the real one.
        #expect(events.count == 10)
        let sample = try #require(events.first { $0.isRealSample })
        #expect(sample.realSampleSeconds == 20)
        #expect(sample.sizeBytes == 0)
        let video = try #require(sample.groups.first?.videos.first)
        // No still: like a clip the demo does not know, it asks for a picture that is nowhere.
        let still = source.thumbnail(for: video, at: 0)
        #expect(still.url.path == "/dev/null")
        await #expect(throws: UpstreamError.http(status: 404, message: nil)) { try await source.imageData(for: still) }
        for quality in Quality.allCases {
            await #expect(throws: UpstreamError.http(status: 404, message: nil)) {
                _ = try await source.playbackPlan(for: video, quality: quality)
            }
        }
        // Nothing to export: no job starts, one from before is over, and nothing downloads.
        await #expect(throws: ExportFailure.server("")) {
            _ = try await source.startExport(event: sample, video: video, quality: .hd480)
        }
        let handle = DemoClipSource.handle(event: sample, video: video, quality: .hd480, id: "demo-1")
        #expect(try await source.exportJob(handle).state == .error)
        await #expect(throws: ExportFailure.expired) { _ = try await source.downloadExport(handle) { _ in } }
    }

    @Test func anEventWithTwoGroupsSpansTwoMinutes() async throws {
        let events = try await events()
        let drive = try event(.recent, minutesAgo: 21, in: events)
        let start = Self.start(minutesAgo: 21)
        #expect(drive.groups.count == 2)
        #expect(drive.groups[0].start == start)
        #expect(drive.groups[1].start == start.addingTimeInterval(60))
        // Up to the end of the last clip, which is twelve seconds long.
        #expect(drive.end == start.addingTimeInterval(72))
        for (index, group) in drive.groups.enumerated() {
            let files = Self.stamp(start.addingTimeInterval(TimeInterval(index) * 60))
            // In switcher order, whatever order the file listed them in.
            #expect(group.videos.map(\.camera) == [.leftRepeater, .front, .rightRepeater, .back])
            #expect(group.videos.map(\.file) == [Camera.leftRepeater, .front, .rightRepeater, .back].map { "\(files)-\($0.rawValue).mp4" })
            #expect(group.videos.allSatisfy { $0.path == "/media/RecentClips/\(drive.name)/\($0.file)" })
        }
    }

    // MARK: Language

    /// The place names come from the copy of `demo-events.json` in the app's language, and the export samples
    /// from that language's folder too: an English phone shows no Chinese place in the list and none burned
    /// into a file it exports. A Chinese phone keeps the Chinese ones.
    @Test(arguments: ["zh-Hans", "en"])
    func eachLanguageHasItsOwnPlaceNamesAndExportSamples(language: String) throws {
        let english = language == "en"
        let city = english ? "Sample City" : "示例市"
        let parkedStreet = english ? "Sample Car Park A" : "虚构停车场A区"
        let driveStreet = english ? "12 Demo Road" : "演示路12号"
        let url = try #require(Bundle.main.url(forResource: "demo-events", withExtension: "json", subdirectory: nil, localization: language),
                               "demo-events.json in \(language)")
        let root = JSONValue(data: try Data(contentsOf: url))
        var placed = 0
        for row in root["events"]?.array ?? [] {
            guard row["city"]?.string != nil else { continue }
            placed += 1
            #expect(row["city"]?.string == city)
            #expect(row["street"]?.string == (row["footage"]?.string == "parked" ? parkedStreet : driveStreet))
        }
        // Eight events have a place: the real recording has none, and so does one of the drawn ones.
        #expect(placed == 8)
        if english {
            // An English name is written in English letters.
            for name in [city, parkedStreet, driveStreet] {
                #expect(!name.unicodeScalars.contains { $0.value > 0x2E7F })
            }
        }
        // One export sample per camera of each set, in the same language's folder.
        let samples = Camera.allCases.map { "demo-export-\($0.rawValue)" }
            + [Camera.leftRepeater, .front, .rightRepeater, .back].map { "demo-drive-export-\($0.rawValue)" }
        for name in samples {
            let sample = try #require(Bundle.main.url(forResource: name, withExtension: "mp4", subdirectory: nil, localization: language), "\(name)")
            let size = (try sample.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            #expect(size > 10_000)
        }
        // The list shows this copy's place.
        let shown = try Self.place(in: url, footage: .drive)
        #expect(shown.street == driveStreet)
    }

    @Test func theCamerasComeFromTheFileOrFromTheFootage() async throws {
        let events = try await events()
        // A parked event that names no cameras has all six; the trigger camera is the number.
        let parked = try event(.sentry, minutesAgo: 6, in: events)
        #expect(parked.meta.cameraNumber == 5)
        #expect(parked.cameras == [.leftRepeater, .front, .rightRepeater, .leftPillar, .back, .rightPillar])
        // An event that names its cameras has just those.
        let four = try event(.sentry, minutesAgo: 184, in: events)
        #expect(four.cameras == [.leftRepeater, .front, .rightRepeater, .back])
        #expect(four.meta.cameraNumber == 6)
        // Driving footage has the four cameras a typical car has, in switcher order.
        let drive = try event(.saved, minutesAgo: 1565, in: events)
        #expect(drive.cameras == [.leftRepeater, .front, .rightRepeater, .back])
    }

    @Test func theTriggerIsPlacedInsideTheMinute() async throws {
        let events = try await events()
        let parked = try event(.sentry, minutesAgo: 6, in: events)
        #expect(parked.meta.reason == "sentry_aware_object_detection")
        // The place is whatever the copy of demo-events.json in the app's language says.
        let place = try Self.placeInTheAppLanguage(for: .parked)
        #expect(parked.meta.city == place.city)
        #expect(parked.meta.street == place.street)
        let trigger = try #require(parked.meta.timestamp)
        #expect(abs(trigger.timeIntervalSince(parked.start) - 6.5) < 0.0001)
        // A recent clip is not an event: nothing is claimed about it.
        let recent = try event(.recent, minutesAgo: 9, in: events)
        #expect(recent.meta.timestamp == nil)
        #expect(recent.meta.reason == nil)
        #expect(recent.isLocked == nil)
    }

    @Test func everyDrawnClipIsTwelveSecondsAndWeighsWhatTheFileWeighs() async throws {
        let events = try await events()
        // The real recording is twenty seconds long; every drawn clip is twelve.
        let videos = events.filter { !$0.isRealSample }.flatMap(\.groups).flatMap(\.videos)
        #expect(!videos.isEmpty)
        #expect(videos.allSatisfy { $0.duration == 12 })
        let parked = try event(.sentry, minutesAgo: 6, in: events)
        var expected: Int64 = 0
        for video in parked.groups.flatMap(\.videos) {
            let url = try #require(Self.bundled("demo-\(video.camera.rawValue)", "mp4"))
            expected += Int64(try #require(url.resourceValues(forKeys: [.fileSizeKey]).fileSize))
        }
        #expect(parked.sizeBytes == expected)
        #expect(parked.sizeBytes > 0)
    }

    @Test func theStatusIsWhatTheFileSaysAndNothingMoreIsKnown() async throws {
        let source = source()
        #expect(source.identity == .demo)
        let status = try await source.syncStatus()
        #expect(status.syncRunning == false)
        #expect(status.lastSyncAgo == 384)
        #expect(status.ffmpegAvailable == true)
        #expect(status.archiveUsedBytes == 412_000_000_000)
        #expect(status.archiveLimitBytes == 2_000_000_000_000)
        #expect(abs((status.archiveFraction ?? 0) - 0.206) < 0.0001)
        #expect(!status.isArchiveNearlyFull)
        #expect(status.pendingFiles == nil)
        #expect(status.usbUsedBytes == nil)
        #expect(status.measuredAt != nil)
        // The demo knows nothing that only a player's request would tell.
        let event = try await event(.saved, minutesAgo: 2920, in: source.events())
        #expect(try await source.detailedEvent(event) == event)
    }

    // MARK: Stills and playback

    @Test func aThumbnailIsTheStillThatShipsForThatCamera() async throws {
        let source = source()
        let events = try await source.events()
        let parked = try event(.sentry, minutesAgo: 6, in: events)
        let drive = try event(.saved, minutesAgo: 1565, in: events)
        let parkedStill = source.thumbnail(for: try #require(parked.groups.first?.videos.first), at: 3)
        #expect(parkedStill.url.lastPathComponent == "demo-thumb-left_repeater.png")
        #expect(parkedStill.headers.isEmpty)
        let driveStill = source.thumbnail(for: try #require(drive.groups.first?.video(for: .rightRepeater)), at: 0)
        #expect(driveStill.url.lastPathComponent == "demo-drive-thumb-right_repeater.png")
        let data = try await source.imageData(for: parkedStill)
        #expect(data.count > 1000)
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]), "A PNG")
        #expect(try await source.imageData(for: driveStill).starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func aClipUnknownToTheDemoHasNoStillAndNothingToPlay() async throws {
        let source = source()
        let stranger = Fixtures.video()
        let still = source.thumbnail(for: stranger, at: 0)
        #expect(still.url.path == "/dev/null")
        await #expect(throws: UpstreamError.http(status: 404, message: nil)) { try await source.imageData(for: still) }
        await #expect(throws: UpstreamError.http(status: 404, message: nil)) {
            try await source.playbackPlan(for: stranger, quality: .hd720)
        }
        #expect(try await source.telemetry(for: stranger) == .none)
    }

    @Test(arguments: Quality.allCases)
    func everyQualityIsTheOneFile(_ quality: Quality) async throws {
        let source = source()
        let events = try await source.events()
        let parked = try event(.sentry, minutesAgo: 6, in: events)
        let drive = try event(.recent, minutesAgo: 9, in: events)
        let front = try #require(drive.groups.first?.video(for: .front))
        for (video, name) in [(try #require(parked.groups.first?.videos.first), "demo-left_repeater.mp4"),
                              (front, "demo-drive-front.mp4")] {
            let plan = try await source.playbackPlan(for: video, quality: quality)
            #expect(plan.initial.url.isFileURL)
            #expect(plan.initial.url.lastPathComponent == name)
            #expect(plan.initial.quality == quality)
            #expect(plan.initial.headers.isEmpty)
            #expect(plan.requested == quality)
            #expect(await Fixtures.upgrades(of: plan) == [])
        }
    }

    @Test func onlyDrivingClipsCarryTelemetry() async throws {
        let source = source()
        let events = try await source.events()
        let drive = try event(.saved, minutesAgo: 1565, in: events)
        let parked = try event(.sentry, minutesAgo: 6, in: events)
        let front = try #require(drive.groups.first?.video(for: .front))
        guard case .track(let track) = try await source.telemetry(for: front) else {
            Issue.record("A drive should have a track")
            return
        }
        #expect(track.samples.count == 25)
        #expect(track.samples.first?.speedKmh == 30)
        #expect(track.samples.first?.gear == "D")
        #expect(try await source.telemetry(for: #require(parked.groups.first?.videos.first)) == .none)
    }

    // MARK: Export

    @Test func anExportIsMadeOnThePhoneAndBroughtInSteps() async throws {
        let source = source()
        let events = try await source.events()
        let event = try self.event(.sentry, minutesAgo: 6, in: events)
        let video = try #require(event.groups.first?.videos.first)
        #expect(try await source.watermarkAvailability() == .available)
        let handle = try await source.startExport(event: event, video: video, quality: .original)
        defer { removeExport(named: handle.fileName) }
        #expect(handle.id.hasPrefix("demo-"))
        #expect(handle.eventID == event.id)
        #expect(handle.file == video.file)
        #expect(handle.camera == .leftRepeater)
        #expect(handle.quality == .original)
        #expect(handle.fileName == "\(event.name)_left_repeater.mp4")
        // Just asked: the job is running.
        let soon = try await source.exportJob(handle)
        #expect(soon.state == .running)
        #expect((0..<100).contains(soon.percent ?? -1))
        let progress = Box<[ExportProgress]>([])
        let file = try await source.downloadExport(handle) { value in progress.update { $0.append(value) } }
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(file == FileManager.default.temporaryDirectory.appendingPathComponent(handle.fileName))
        let shipped = try #require(Self.bundled("demo-export-left_repeater", "mp4"))
        #expect(try Data(contentsOf: file) == Data(contentsOf: shipped))
        // The copy is seen as a download is: in steps, each one a little more, to the whole file.
        let steps = progress.get()
        #expect(steps.count >= 2)
        let total = Int64(try #require(shipped.resourceValues(forKeys: [.fileSizeKey]).fileSize))
        #expect(steps.last == .downloading(received: total, total: total))
    }

    @Test func aJobFromBeforeIsDoneAndAnUnknownOneIsAnError() async throws {
        let source = source()
        let events = try await source.events()
        let event = try self.event(.sentry, minutesAgo: 6, in: events)
        let video = try #require(event.groups.first?.videos.first)
        let tenSecondsAgo = Int64(Date().timeIntervalSince1970 * 1000) - 10_000
        let old = DemoClipSource.handle(event: event, video: video, quality: .hd720, id: "demo-\(tenSecondsAgo)")
        let shipped = try #require(Self.bundled("demo-export-left_repeater", "mp4"))
        let size = Int64(try #require(shipped.resourceValues(forKeys: [.fileSizeKey]).fileSize))
        #expect(try await source.exportJob(old) == ExportJobStatus(state: .done, percent: 100, message: nil, sizeBytes: size))
        // A job dated in the future is over too; a job the demo did not start is an error.
        let ahead = DemoClipSource.handle(event: event, video: video, quality: .hd720, id: "demo-\(tenSecondsAgo + 60_000)")
        #expect(try await source.exportJob(ahead).state == .done)
        let foreign = DemoClipSource.handle(event: event, video: video, quality: .hd720, id: "2026-11-08_19-43-36-ex482913")
        #expect(try await source.exportJob(foreign) == ExportJobStatus(state: .error, percent: nil, message: nil, sizeBytes: nil))
    }

    @Test func whatTheDemoHasNoFootageForCannotBeExported() async throws {
        let source = source()
        let event = try await self.event(.sentry, minutesAgo: 6, in: source.events())
        let stranger = Fixtures.video()
        let handle = DemoClipSource.handle(event: event, video: stranger, quality: .hd480, id: "demo-1")
        defer { removeExport(named: handle.fileName) }
        await #expect(throws: ExportFailure.server("")) {
            _ = try await source.startExport(event: event, video: stranger, quality: .hd480)
        }
        await #expect(throws: ExportFailure.expired) {
            _ = try await source.downloadExport(handle) { _ in }
        }
    }

    @Test func aDownloadThatIsStoppedThrows() async throws {
        let source = source()
        let events = try await source.events()
        let event = try self.event(.saved, minutesAgo: 1565, in: events)
        let video = try #require(event.groups.first?.video(for: .front))
        let handle = DemoClipSource.handle(event: event, video: video, quality: .hd720, id: "demo-1")
        defer { removeExport(named: handle.fileName) }
        let task = Task { try await source.downloadExport(handle) { _ in } }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
