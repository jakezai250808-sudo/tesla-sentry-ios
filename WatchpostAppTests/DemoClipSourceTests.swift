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

    private func events() async throws -> [RecordedEvent] { try await source().events() }

    private func event(_ category: ClipCategory, minutesAgo: Double, in events: [RecordedEvent]) throws -> RecordedEvent {
        let id = "\(category.rawValue)/\(Self.stamp(Self.start(minutesAgo: minutesAgo)))"
        return try #require(events.first { $0.id == id }, "The demo event \(id)")
    }

    private func removeExport(named fileName: String) {
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent(fileName))
    }

    // MARK: The list

    @Test func theDemoIsNineEventsNewestFirstOnWholeMinutes() async throws {
        let events = try await events()
        #expect(events.count == 9)
        #expect(events.filter { $0.category == .sentry }.count == 5)
        #expect(events.filter { $0.category == .saved }.count == 2)
        #expect(events.filter { $0.category == .recent }.count == 2)
        #expect(zip(events, events.dropFirst()).allSatisfy { $0.start > $1.start })
        // Like a real event, the first minute starts on a whole minute.
        #expect(events.allSatisfy { $0.start.timeIntervalSince1970.truncatingRemainder(dividingBy: 60) == 0 })
        // Something from today: the newest event is six minutes old, the oldest a little over five days.
        let first = try #require(events.first)
        let last = try #require(events.last)
        #expect(first.id == "SentryClips/\(Self.stamp(Self.start(minutesAgo: 6)))")
        #expect(Self.now.timeIntervalSince(first.start) < 24 * 3600)
        #expect(Self.now.timeIntervalSince(last.start) > 5 * 24 * 3600)
        #expect(last.id == "SentryClips/\(Self.stamp(Self.start(minutesAgo: 7247)))")
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
        #expect(parked.meta.city == "示例市")
        #expect(parked.meta.street == "虚构停车场A区")
        let trigger = try #require(parked.meta.timestamp)
        #expect(abs(trigger.timeIntervalSince(parked.start) - 6.5) < 0.0001)
        // A recent clip is not an event: nothing is claimed about it.
        let recent = try event(.recent, minutesAgo: 9, in: events)
        #expect(recent.meta.timestamp == nil)
        #expect(recent.meta.reason == nil)
        #expect(recent.isLocked == nil)
    }

    @Test func everyClipIsTwelveSecondsAndWeighsWhatTheFileWeighs() async throws {
        let events = try await events()
        let videos = events.flatMap(\.groups).flatMap(\.videos)
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
