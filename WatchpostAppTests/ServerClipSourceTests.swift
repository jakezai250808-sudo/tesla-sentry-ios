import Foundation
import Testing
@testable import WatchpostApp

/// `ServerClipSource`: every endpoint the app uses, as a `ClipSource`.
struct ServerClipSourceTests {
    private static var cookie: String { "tsf_sess=\(Fixtures.token.value)" }
    private static let sourcePath = "/api/playback-source"
    private static let media = "/media/SentryClips/2026-11-08_19-43-36/2026-11-08_19-43-36-front.mp4"

    private static func temporaryExports() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("WatchpostExports", isDirectory: true)
    }

    /// Per-path answers, for the tests whose playback plan sends a hint on the side while it waits.
    private static func routingTransport(sourceAnswers: [StubTransport.Reply]) -> RoutingTransport {
        let transport = RoutingTransport()
        transport.route(sourcePath, sourceAnswers)
        transport.route("/api/kick", endless: .ok(ServerFixtures.kickAnswer))
        transport.route("/api/live/demand", endless: .ok(ServerFixtures.demandAnswer))
        return transport
    }

    // MARK: Identity

    @Test func theSourceBelongsToItsSessionAndMakesUpClientIDs() {
        let transport = StubTransport([])
        let source = Fixtures.source(transport)
        #expect(source.identity == .server(source.session.id))
        let a = ServerClipSource.makeClientID()
        let b = ServerClipSource.makeClientID()
        for id in [a, b] {
            #expect(id.count == 32)
            #expect(id.allSatisfy { "0123456789abcdef".contains($0) })
        }
        #expect(a != b)
    }

    // MARK: Events and status

    @Test func eventsComeFromTheServerNewestFirst() async throws {
        let transport = StubTransport([.ok(Fixtures.eventsJSON)])
        let events = try await Fixtures.source(transport).events()
        #expect(events.map(\.id) == Fixtures.events.map(\.id))
        let sent = try #require(transport.sent.first)
        #expect(sent.path == "/api/events")
        #expect(sent.header("Accept") == "*/*")
        #expect(sent.header("Cookie") == Self.cookie)
        // A failed list is the server's status, in its own words; a page is no list at all.
        let failed = StubTransport([.status(500, #"{"error": "服务端错误"}"#)])
        await #expect(throws: UpstreamError.http(status: 500, message: "服务端错误")) { try await Fixtures.source(failed).events() }
        let page = StubTransport([.ok("<!DOCTYPE html><html><body>login</body></html>")])
        #expect(try await Fixtures.source(page).events().isEmpty)
    }

    @Test func theTimelineAddsWhatOnlyThePlayerKnows() async throws {
        let transport = StubTransport([.ok(Fixtures.timelineJSON)])
        let detailed = try await Fixtures.source(transport).detailedEvent(Fixtures.sentryEvent)
        #expect(detailed.groups.first?.video(for: .front)?.duration == 59.6)
        let sent = try #require(transport.sent.first)
        #expect(sent.path == "/api/timeline")
        #expect(sent.query == "cat=SentryClips&event=2026-11-08_19-43-36&gaps=0")
        // Another event's timeline, or one that is still being scanned, leaves the clip as it was.
        for answer in [StubTransport.Reply.status(202, ServerFixtures.timelinePending), .status(400, ServerFixtures.timelineInvalid),
                       .ok("[]"), .status(500, "busy")] {
            let transport = StubTransport([answer])
            #expect(try await Fixtures.source(transport).detailedEvent(Fixtures.sentryEvent) == Fixtures.sentryEvent)
        }
    }

    @Test func aTimelineThatCannotBeFetchedIsNotAnErrorForThePlayer() async throws {
        let transport = StubTransport([.raises(URLError(.timedOut))])
        #expect(try await Fixtures.source(transport).detailedEvent(Fixtures.sentryEvent) == Fixtures.sentryEvent)
        #expect(transport.sent.count == 1)
    }

    @Test func aTimelineFetchStopsWhenTheTaskIsCancelled() async throws {
        let transport = RoutingTransport(otherwise: .status(500, "unexpected"))
        transport.route("/api/timeline", .held(.ok(Fixtures.timelineJSON)))
        let source = Fixtures.source(transport)
        let task = Task { try await source.detailedEvent(Fixtures.sentryEvent) }
        #expect(await waitUntil { transport.sent(to: "/api/timeline").count == 1 })
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func theStatusIsTheLiveAnswerOrTheServersComplaint() async throws {
        let ok = StubTransport([.ok(ServerFixtures.live)])
        let status = try await Fixtures.source(ok).syncStatus()
        #expect(status.pendingFiles == 2)
        #expect(status.syncRunning == true)
        #expect(ok.sent.first?.path == "/api/live")
        let failed = StubTransport([.status(503, "busy")])
        await #expect(throws: UpstreamError.http(status: 503, message: "busy")) { try await Fixtures.source(failed).syncStatus() }
    }

    // MARK: Stills and telemetry

    @Test(arguments: [(0.4, 0), (3.6, 4), (-5, 0), (5_000, 3_600), (.infinity, 0), (.nan, 0)])
    func aThumbnailAsksForTheSecondRoundedAndClamped(_ time: TimeInterval, _ seconds: Int) {
        let source = Fixtures.source(StubTransport([]))
        let request = source.thumbnail(for: Fixtures.video(), at: time)
        #expect(request.url.absoluteString == "http://192.168.1.50:8080/thumb/SentryClips/2026-11-08_19-43-36/2026-11-08_19-43-36-front.mp4?t=\(seconds)")
        #expect(request.headers == ["Cookie": Self.cookie])
    }

    @Test func aThumbnailPathIsEncoded() {
        let source = Fixtures.source(StubTransport([]))
        let request = source.thumbnail(for: Fixtures.video(minute: "2026-11-08 19-43-36"), at: 12)
        #expect(request.url.absoluteString == "http://192.168.1.50:8080/thumb/SentryClips/2026-11-08_19-43-36/2026-11-08%2019-43-36-front.mp4?t=12")
    }

    @Test func anImageIsFetchedFromWhereItWasAskedWithTheCookieAsItIsNow() async throws {
        let transport = StubTransport([.ok("PNG", headers: ["Content-Type": "image/png"]), .status(404)])
        let source = Fixtures.source(transport)
        // Built while another cookie was current, as a still asked for after a new login can be.
        let request = MediaRequest(url: try #require(URL(string: "http://192.168.1.50:8080/thumb/x.png?t=1")), headers: ["Cookie": "tsf_sess=other"])
        #expect(try await source.imageData(for: request) == Data("PNG".utf8))
        // The cookie is decided in one place, the session, and a login-and-retry needs it there:
        // the request's own cookie is not what goes out.
        #expect(transport.sent.first?.url == request.url)
        #expect(transport.sent.first?.header("Cookie") == Self.cookie)
        #expect(transport.sent.first?.header("Accept") == "*/*")
        await #expect(throws: UpstreamError.http(status: 404, message: nil)) { try await source.imageData(for: MediaRequest(url: request.url)) }
    }

    @Test func telemetryIsAskedByArchivePathAndAMissingFileIsNoTelemetry() async throws {
        let transport = StubTransport([.ok(ServerFixtures.telemetry), .status(404, ServerFixtures.telemetryBadPath),
                                       .ok(ServerFixtures.telemetryNoSEI), .status(500, "busy")])
        let source = Fixtures.source(transport)
        let outcome = try await source.telemetry(for: Fixtures.video())
        guard case .track(let track) = outcome else {
            Issue.record("Expected a track")
            return
        }
        #expect(track.samples.count == 3)
        let sent = try #require(transport.sent.first)
        #expect(sent.path == "/api/telemetry")
        #expect(sent.query == "path=/archive/SentryClips/2026-11-08_19-43-36/2026-11-08_19-43-36-front.mp4")
        #expect(try await source.telemetry(for: Fixtures.video()) == .none)
        #expect(try await source.telemetry(for: Fixtures.video()) == .none)
        await #expect(throws: UpstreamError.http(status: 500, message: "busy")) { try await source.telemetry(for: Fixtures.video()) }
    }

    // MARK: Watermark

    @Test func theFontIsAskedAndOnlyTheServerKnows() async throws {
        #expect(try await Fixtures.source(StubTransport([.ok(ServerFixtures.fontPresent)])).watermarkAvailability() == .available)
        #expect(try await Fixtures.source(StubTransport([.ok(ServerFixtures.fontMissing)])).watermarkAvailability() == .unavailable)
        let silent = StubTransport([.ok("{}")])
        await #expect(throws: UpstreamError.badResponse) { try await Fixtures.source(silent).watermarkAvailability() }
        let failed = StubTransport([.status(500, "busy")])
        await #expect(throws: UpstreamError.http(status: 500, message: "busy")) { try await Fixtures.source(failed).watermarkAvailability() }
        #expect(silent.sent.first?.path == "/api/font")
    }

    // MARK: Playback plans

    @Test func theOriginalNeedsNoAsk() async throws {
        let transport = StubTransport([])
        let plan = try await Fixtures.source(transport).playbackPlan(for: Fixtures.video(), quality: .original)
        #expect(plan.requested == .original)
        #expect(plan.initial.quality == .original)
        #expect(plan.initial.url.absoluteString == "http://192.168.1.50:8080\(Self.media)")
        #expect(plan.initial.headers == ["Cookie": Self.cookie])
        #expect(await Fixtures.upgrades(of: plan).isEmpty)
        #expect(transport.sent.isEmpty)
    }

    @Test func aReadyTranscodeIsPlayedAtOnceAndStrictly() async throws {
        let transport = StubTransport([.ok(ServerFixtures.playbackReady)])
        let plan = try await Fixtures.source(transport).playbackPlan(for: Fixtures.video(), quality: .hd720)
        #expect(plan.requested == .hd720)
        #expect(plan.initial.quality == .hd720)
        #expect(plan.initial.url.absoluteString == "http://192.168.1.50:8080\(Self.media)?q=720p&exact=1")
        #expect(plan.initial.headers == ["Cookie": Self.cookie])
        #expect(await Fixtures.upgrades(of: plan).isEmpty)
        let sent = try #require(transport.sent.first)
        #expect(sent.path == Self.sourcePath)
        #expect(sent.query == "file=\(Self.media)&q=720p")
        #expect(transport.sent(to: "/api/kick").isEmpty, "Nothing to wait for, nothing to nudge")
    }

    @Test(arguments: [ServerFixtures.playbackFailed, ServerFixtures.playbackMissing, ServerFixtures.playbackParts, "{}"])
    func whatCannotBeMadeIsUnavailableAtOnce(_ answer: String) async throws {
        let transport = StubTransport([.ok(answer)])
        let plan = try await Fixtures.source(transport).playbackPlan(for: Fixtures.video(), quality: .hd480)
        #expect(plan.initial.quality == .original)
        #expect(plan.requested == .hd480)
        #expect(await Fixtures.upgrades(of: plan) == [.unavailable])
        #expect(transport.sent.count == 1)
        // The status matters less than the state: 400 and 404 come with `{"state": "missing"}` too.
        let notFound = StubTransport([.status(404, ServerFixtures.playbackMissing)])
        let plan404 = try await Fixtures.source(notFound).playbackPlan(for: Fixtures.video(), quality: .hd480)
        #expect(await Fixtures.upgrades(of: plan404) == [.unavailable])
    }

    @Test func aTranscodeInTheMakingIsWaitedForAndNudged() async throws {
        let transport = Self.routingTransport(sourceAnswers: [.ok(ServerFixtures.playbackPending), .ok(ServerFixtures.playbackPending), .ok(ServerFixtures.playbackReady)])
        let source = Fixtures.source(transport, clientID: "0123456789abcdef0123456789abcdef")
        let plan = try await source.playbackPlan(for: Fixtures.video(), quality: .hd480)
        let ready = URL(string: "http://192.168.1.50:8080\(Self.media)?q=480p&exact=1")!
        #expect(await Fixtures.upgrades(of: plan) == [
            .preparing, .preparing,
            .ready(PlaybackAsset(url: ready, quality: .hd480, headers: ["Cookie": Self.cookie])),
        ])
        // One ask before playing, then one look after each wait.
        #expect(transport.sent(to: Self.sourcePath).count == 3)
        // The hint goes out on the side: which clip is about to be played, so it is made first.
        #expect(await waitUntil { transport.sent(to: "/api/kick").count == 1 })
        let kick = try #require(transport.sent(to: "/api/kick").first)
        #expect(kick.method == "POST")
        #expect(kick.header("Content-Type") == "application/json")
        #expect(kick.json["q"] == .string("480p"))
        #expect(kick.json["paths"] == .array([.string(Self.media)]))
        #expect(transport.sent(to: "/api/live/demand").isEmpty)
    }

    @Test func waitingEndsAfterSoManyLooks() async throws {
        let transport = StubTransport(endless: .ok(ServerFixtures.playbackPending))
        let plan = try await Fixtures.source(transport).playbackPlan(for: Fixtures.video(), quality: .hd360)
        #expect(await Fixtures.upgrades(of: plan) == [.preparing, .preparing, .preparing, .preparing, .unavailable])
        #expect(transport.sent(to: Self.sourcePath).count == 4)
    }

    @Test func aTranscodeThatFailsWhileWaitingIsUnavailable() async throws {
        let transport = Self.routingTransport(sourceAnswers: [.ok(ServerFixtures.playbackPending), .ok(ServerFixtures.playbackCooling), .ok(ServerFixtures.playbackFailed)])
        let plan = try await Fixtures.source(transport).playbackPlan(for: Fixtures.video(), quality: .hd720)
        #expect(await Fixtures.upgrades(of: plan) == [.preparing, .preparing, .unavailable])
    }

    @Test func aRecentClipNudgesThroughTheLiveDemandAndASavedOneThroughTheKick() async throws {
        let transport = Self.routingTransport(sourceAnswers: [.ok(ServerFixtures.playbackCooling), .ok(ServerFixtures.playbackCooling)])
        let source = Fixtures.source(transport, clientID: "fedcba9876543210fedcba9876543210")
        let recent = Fixtures.video(.back, category: "RecentClips", minute: "2026-11-08_20-01-00")
        let saved = Fixtures.video(.leftPillar, category: "SavedClips")
        _ = try await source.playbackPlan(for: recent, quality: .hd720)
        _ = try await source.playbackPlan(for: saved, quality: .hd720)
        #expect(await waitUntil { transport.sent(to: "/api/live/demand").count == 1 && transport.sent(to: "/api/kick").count == 1 })
        let demand = try #require(transport.sent(to: "/api/live/demand").first)
        #expect(demand.method == "POST")
        #expect(demand.json["client"] == .string("fedcba9876543210fedcba9876543210"))
        #expect(demand.json["rev"] == .number(1))
        #expect(demand.json["q"] == .string("720p"))
        #expect(demand.json["paths"] == .array([.string(recent.path)]))
        let kick = try #require(transport.sent(to: "/api/kick").first)
        #expect(kick.json["q"] == .string("720p"))
        #expect(kick.json["paths"] == .array([.string(saved.path)]))
    }

    @Test func theSameSourceCountsItsDemands() async throws {
        let transport = StubTransport(endless: .ok(ServerFixtures.playbackCooling))
        let source = Fixtures.source(transport)
        let recent = Fixtures.video(.back, category: "RecentClips", minute: "2026-11-08_20-01-00")
        for _ in 0..<2 {
            let plan = try await source.playbackPlan(for: recent, quality: .hd480)
            #expect(await Fixtures.upgrades(of: plan).last == .unavailable)
        }
        #expect(await waitUntil { transport.sent(to: "/api/live/demand").count == 2 })
        #expect(transport.sent(to: "/api/live/demand").map { $0.json["rev"] } == [.number(1), .number(2)])
    }

    /// The server's gate refuses a request without a valid cookie with 401 (`_gate`). With no password
    /// to log in again, nothing that follows would get through.
    @Test func aSessionThatCannotBeRestoredEndsTheWaiting() async throws {
        let transport = Self.routingTransport(sourceAnswers: [.ok(ServerFixtures.playbackPending), .status(401, "unauthorized")])
        let plan = try await Fixtures.source(transport).playbackPlan(for: Fixtures.video(), quality: .hd480)
        #expect(await Fixtures.upgrades(of: plan) == [.preparing, .unavailable])
    }

    /// The only 429 upstream answers is `POST /login` after too many wrong attempts (`fail_check`),
    /// which locks this phone out for the rest of the window: the waiting ends, after that one login.
    @Test func aPhoneLockedOutOfTheServerEndsTheWaitingAfterOneLogin() async throws {
        let transport = Self.routingTransport(sourceAnswers: [.ok(ServerFixtures.playbackPending), .status(401, "unauthorized")])
        transport.route("/login", steps: [.now(.status(429, ServerFixtures.lockedOutMessage))])
        let plan = try await Fixtures.source(transport, password: "pw").playbackPlan(for: Fixtures.video(), quality: .hd480)
        #expect(await Fixtures.upgrades(of: plan) == [.preparing, .unavailable])
        #expect(transport.sent(to: "/login").count == 1)
    }

    @Test func aLookThatFailsForOtherReasonsIsTriedAgain() async throws {
        let transport = Self.routingTransport(sourceAnswers: [.ok(ServerFixtures.playbackPending), .status(500, "busy"),
                                                                      .raises(URLError(.networkConnectionLost)), .ok(ServerFixtures.playbackReady)])
        let plan = try await Fixtures.source(transport).playbackPlan(for: Fixtures.video(), quality: .hd480)
        #expect(await Fixtures.upgrades(of: plan).count == 4)
        #expect(transport.sent(to: Self.sourcePath).count == 4)
    }

    // MARK: Export

    private static func handle(id: String = "2026-11-08_19-43-36-ex482913") -> ExportHandle {
        ExportHandle(id: id, eventID: "SentryClips/2026-11-08_19-43-36", file: "2026-11-08_19-43-36-front.mp4", camera: .front,
                     quality: .hd720, fileName: "2026-11-08_19-43-36_front.mp4")
    }

    @Test func anExportIsAskedForInTheServersSpelling() async throws {
        let transport = StubTransport([.ok(ServerFixtures.exportStarted)])
        let handle = try await Fixtures.source(transport).startExport(event: Fixtures.sentryEvent, video: Fixtures.video(), quality: .hd720)
        #expect(handle == Self.handle())
        let sent = try #require(transport.sent.first)
        #expect(sent.path == "/api/export/burn")
        #expect(sent.method == "POST")
        #expect(sent.header("Content-Type") == "application/json")
        #expect(sent.json["cat"] == .string("SentryClips"))
        #expect(sent.json["name"] == .string("2026-11-08_19-43-36"))
        #expect(sent.json["cams"] == .array([.string("front")]))
        #expect(sent.json["wm"] == .bool(true))
        #expect(sent.json["q"] == .string("720p"))
        #expect(sent.json["files"] == .array([.string("2026-11-08_19-43-36-front.mp4")]))
    }

    /// A refusal from the server and the failure it becomes.
struct RefusalCase: Sendable {
        let body: String
        let failure: ExportFailure
    }

    @Test(arguments: [
        RefusalCase(body: ServerFixtures.burnFontRefusal, failure: .watermarkUnavailable),
        RefusalCase(body: ServerFixtures.burnFFmpegRefusal, failure: .watermarkUnavailable),
        RefusalCase(body: ServerFixtures.burnEventMissing, failure: .server("事件不存在")),
        RefusalCase(body: ServerFixtures.burnNothingToExport, failure: .server("没有可导出的片段")),
        RefusalCase(body: ServerFixtures.burnBusy, failure: .server("已有导出/合成任务在进行, 请等它完成")),
        RefusalCase(body: ServerFixtures.burnLowMemory, failure: .server("设备可用内存不足(38MB), 稍后再试")),
    ])
    func aRefusedExportIsTheServersReasonOrTheFonts(_ refusal: RefusalCase) async throws {
        let transport = StubTransport([.status(400, refusal.body)])
        await #expect(throws: refusal.failure) {
            try await Fixtures.source(transport).startExport(event: Fixtures.sentryEvent, video: Fixtures.video(), quality: .hd480)
        }
    }

    @Test func anExportThatCannotEvenBeAskedIsANetworkFailure() async throws {
        let offline = StubTransport([.raises(URLError(.timedOut))])
        await #expect(throws: ExportFailure.network) {
            try await Fixtures.source(offline).startExport(event: Fixtures.sentryEvent, video: Fixtures.video(), quality: .hd480)
        }
        let gated = StubTransport([.unauthorized()])
        await #expect(throws: ExportFailure.network) {
            try await Fixtures.source(gated).startExport(event: Fixtures.sentryEvent, video: Fixtures.video(), quality: .hd480)
        }
    }

    @Test func aCancelledExportStaysCancelled() async throws {
        let transport = RoutingTransport()
        transport.route("/api/export/burn", .held(.ok(ServerFixtures.exportStarted)))
        let source = Fixtures.source(transport)
        let task = Task { try await source.startExport(event: Fixtures.sentryEvent, video: Fixtures.video(), quality: .hd480) }
        #expect(await waitUntil { transport.sent(to: "/api/export/burn").count == 1 })
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func aJobsProgressIsOneLook() async throws {
        let transport = StubTransport([.ok(ServerFixtures.stitchRunning(percent: 42)), .status(404, ServerFixtures.stitchGone)])
        let source = Fixtures.source(transport)
        let running = try await source.exportJob(Self.handle())
        #expect(running.state == .running)
        #expect(running.percent == 42)
        #expect(transport.sent.first?.path == "/api/stitch/status")
        #expect(transport.sent.first?.query == "id=2026-11-08_19-43-36-ex482913")
        let gone = try await source.exportJob(Self.handle())
        #expect(gone.state == .error)
    }

    @Test func theFinishedFileIsBroughtToThePhoneUnderItsOwnName() async throws {
        let transport = StubTransport([.ok("MP4", headers: ["Content-Type": "video/mp4", "Content-Length": "3"])])
        let progress = Box<[ExportProgress]>([])
        let file = try await Fixtures.source(transport).downloadExport(Self.handle()) { value in progress.update { $0.append(value) } }
        defer { try? FileManager.default.removeItem(at: Self.temporaryExports()) }
        #expect(file.lastPathComponent == "2026-11-08_19-43-36_front.mp4")
        #expect(file.deletingLastPathComponent().lastPathComponent == "WatchpostExports")
        #expect(try String(contentsOf: file, encoding: .utf8) == "MP4")
        #expect(progress.get() == [.downloading(received: 1, total: 3), .downloading(received: 3, total: 3)])
        let sent = try #require(transport.sent.first)
        #expect(sent.kind == .download)
        #expect(sent.path == "/api/export/burn/dl")
        #expect(sent.query == "id=2026-11-08_19-43-36-ex482913")
    }

    @Test func aFileThatIsGoneIsExpiredAndAnythingElseIsTheServersWords() async throws {
        let destination = Self.temporaryExports().appendingPathComponent("2026-11-08_19-43-36_front.mp4")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("HALF".utf8).write(to: destination)
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        let gone = StubTransport([.status(404, "gone")])
        await #expect(throws: ExportFailure.expired) { try await Fixtures.source(gone).downloadExport(Self.handle()) { _ in } }
        #expect(!FileManager.default.fileExists(atPath: destination.path), "A half copy is never left behind")
        try Data("HALF".utf8).write(to: destination)
        let refused = StubTransport([.status(503, ServerFixtures.qualityUnavailable)])
        await #expect(throws: ExportFailure.server("所选画质暂不可用")) { try await Fixtures.source(refused).downloadExport(Self.handle()) { _ in } }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let offline = StubTransport([.raises(URLError(.networkConnectionLost))])
        await #expect(throws: ExportFailure.network) { try await Fixtures.source(offline).downloadExport(Self.handle()) { _ in } }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: The whole export

    @Test func anExportThatIsReadyRightAwayReportsOnlyTheCopy() async throws {
        let transport = StubTransport([.ok(ServerFixtures.exportStarted), .ok(ServerFixtures.stitchDone),
                                       .ok("MP4", headers: ["Content-Length": "3"])])
        let progress = Box<[ExportProgress]>([])
        let file = try await Fixtures.source(transport).export(event: Fixtures.sentryEvent, video: Fixtures.video(), quality: .hd720) { value in
            progress.update { $0.append(value) }
        }
        defer { try? FileManager.default.removeItem(at: Self.temporaryExports()) }
        #expect(file.lastPathComponent == "2026-11-08_19-43-36_front.mp4")
        #expect(try String(contentsOf: file, encoding: .utf8) == "MP4")
        #expect(progress.get() == [.downloading(received: 1, total: 3), .downloading(received: 3, total: 3)])
        #expect(transport.sent.map(\.path) == ["/api/export/burn", "/api/stitch/status", "/api/export/burn/dl"])
    }

    @Test func anExportThatTakesAWhileReportsItsProgress() async throws {
        let transport = StubTransport([.ok(ServerFixtures.exportStarted), .ok(ServerFixtures.stitchRunning(percent: 42)),
                                       .ok(ServerFixtures.stitchDone), .ok("MP4", headers: ["Content-Length": "3"])])
        let progress = Box<[ExportProgress]>([])
        let file = try await Fixtures.source(transport).export(event: Fixtures.sentryEvent, video: Fixtures.video(), quality: .original) { value in
            progress.update { $0.append(value) }
        }
        defer { try? FileManager.default.removeItem(at: Self.temporaryExports()) }
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(progress.get() == [.generating(percent: 42),
                                  .downloading(received: 1, total: 3), .downloading(received: 3, total: 3)])
    }

    @Test(arguments: [
        RefusalCase(body: ServerFixtures.burnFontRefusal, failure: .watermarkUnavailable),
        RefusalCase(body: ServerFixtures.burnBusy, failure: .server("已有导出/合成任务在进行, 请等它完成")),
    ])
    func aRefusedExportStopsAtTheRefusal(_ refusal: RefusalCase) async throws {
        let transport = StubTransport([.status(400, refusal.body)])
        await #expect(throws: refusal.failure) {
            try await Fixtures.source(transport).export(event: Fixtures.sentryEvent, video: Fixtures.video(), quality: .hd480) { _ in }
        }
        #expect(transport.sent.map(\.path) == ["/api/export/burn"])
    }

    @Test func anExportWhoseFileVanishesIsExpired() async throws {
        let transport = StubTransport([.ok(ServerFixtures.exportStarted), .ok(ServerFixtures.stitchDone), .status(404, "gone")])
        await #expect(throws: ExportFailure.expired) {
            try await Fixtures.source(transport).export(event: Fixtures.sentryEvent, video: Fixtures.video(), quality: .hd480) { _ in }
        }
        #expect(transport.sent.map(\.path) == ["/api/export/burn", "/api/stitch/status", "/api/export/burn/dl"])
    }

    @Test func aJobThatFailsOnTheServerSaysWhy() async throws {
        let transport = StubTransport([.ok(ServerFixtures.exportStarted), .ok(ServerFixtures.stitchFailed)])
        await #expect(throws: ExportFailure.server("转码超时")) {
            try await Fixtures.source(transport).export(event: Fixtures.sentryEvent, video: Fixtures.video(), quality: .hd480) { _ in }
        }
    }

    // MARK: Names

    @Test func anExportIsNamedAfterTheEventItsCameraAndItsMinute() {
        let event = Fixtures.sentryEvent
        #expect(ServerClipSource.exportFileName(event: event, video: Fixtures.video()) == "2026-11-08_19-43-36_front.mp4")
        #expect(ServerClipSource.exportFileName(event: event, video: Fixtures.video(.leftPillar, minute: "2026-11-08_19-44-36"))
                == "2026-11-08_19-43-36_left_pillar_2026-11-08_19-44-36.mp4")
        #expect(ServerClipSource.exportFileName(event: event, video: ClipVideo(file: "clip", camera: .back, path: "/media/x/clip", duration: nil))
                == "2026-11-08_19-43-36_back_clip.mp4")
        let handle = ServerClipSource.handle(event: event, video: Fixtures.video(), quality: .hd360, id: "job-1")
        #expect(handle == ExportHandle(id: "job-1", eventID: "SentryClips/2026-11-08_19-43-36", file: "2026-11-08_19-43-36-front.mp4",
                                       camera: .front, quality: .hd360, fileName: "2026-11-08_19-43-36_front.mp4"))
    }
}
