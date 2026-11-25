import Foundation
import Testing
@testable import WatchpostApp

/// `ExportModel`: the one export the sheet shows, from asking about the font to the file on the phone.
@MainActor
struct ExportModelTests {
    private func model(_ transport: any HTTPTransport, exports: OwnExports) -> ExportModel {
        ExportModel(source: Fixtures.source(transport, exports: exports), event: Fixtures.sentryEvent, video: Fixtures.video(),
                    quality: .hd720)
    }

    /// The server's answers for an export that is ready at once: font present, burn started, job done, file.
    private static var readyScript: [StubTransport.Reply] {
        [.ok(ServerFixtures.fontPresent), .ok(ServerFixtures.exportStarted), .ok(ServerFixtures.stitchDone),
         .ok("MP4", headers: ["Content-Length": "3"])]
    }

    // MARK: Opening

    @Test func openingAsksAboutTheFontAndThatIsAll() async throws {
        let own = OwnExports()
        defer { own.remove() }
        let transport = StubTransport([.ok(ServerFixtures.fontPresent)])
        let model = model(transport, exports: own)
        #expect(model.phase == .idle)
        #expect(model.canGenerate == false, "Nothing is known yet")
        await model.open()
        #expect(model.phase == .idle)
        #expect(model.watermark == .available)
        #expect(model.watermarkUnavailable == false)
        #expect(model.canGenerate)
        #expect(!model.isWorking)
        #expect(model.handle == nil)
        #expect(model.canResume == false)
        #expect(model.fileURL == nil)
        #expect(transport.sent.map(\.path) == ["/api/font"])
    }

    @Test func aMissingFontIsOfferedToGoWithout() async throws {
        let own = OwnExports()
        defer { own.remove() }
        let model = model(StubTransport([.ok(ServerFixtures.fontMissing)]), exports: own)
        await model.open()
        #expect(model.phase == .idle)
        #expect(model.watermark == .unavailable)
        #expect(model.watermarkUnavailable)
        #expect(!model.canGenerate)
    }

    @Test(arguments: [StubTransport.Reply.status(500, "busy"), .raises(URLError(.timedOut)), .ok("{}")])
    func aFontQuestionThatFailsIsANetworkFailure(_ reply: StubTransport.Reply) async throws {
        let own = OwnExports()
        defer { own.remove() }
        let model = model(StubTransport([reply]), exports: own)
        await model.open()
        #expect(model.phase == .failed(.network))
        #expect(model.watermark == nil)
        #expect(!model.canGenerate)
        #expect(!model.isWorking)
    }

    @Test func openingAsksAgainAfterAFailure() async throws {
        let own = OwnExports()
        defer { own.remove() }
        let model = model(StubTransport([.status(500, "busy"), .ok(ServerFixtures.fontPresent)]), exports: own)
        await model.open()
        #expect(model.phase == .failed(.network))
        await model.open()
        #expect(model.phase == .idle)
        #expect(model.watermark == .available)
    }

    @Test func stoppingWhileTheFontIsBeingAskedIsStillIdleWhenTheAnswerComes() async throws {
        let own = OwnExports()
        defer { own.remove() }
        let transport = RoutingTransport()
        transport.route("/api/font", steps: [.held(.ok(ServerFixtures.fontPresent))])
        let model = model(transport, exports: own)
        let opening = Task { await model.open() }
        #expect(await waitUntil { transport.sent(to: "/api/font").count == 1 })
        model.stopWaiting()
        #expect(model.phase == .idle)
        #expect(!model.isWorking)
        transport.releaseWaiting()
        await opening.value
        // The answer is kept: nothing was started, and the sheet is where it was.
        #expect(model.phase == .idle)
        #expect(model.watermark == .available)
        #expect(model.handle == nil)
    }

    // MARK: Generating

    @Test func generateMakesTheFileAndOffersIt() async throws {
        let own = OwnExports()
        defer { own.remove() }
        let transport = StubTransport(Self.readyScript)
        let model = model(transport, exports: own)
        await model.open()
        model.start()
        #expect(model.isWorking)
        #expect(await settle { model.phase.isReady })
        let file = try #require(model.fileURL)
        #expect(file.lastPathComponent == "2026-11-08_19-43-36_front.mp4")
        #expect(try String(contentsOf: file, encoding: .utf8) == "MP4")
        #expect(model.handle != nil)
        #expect(!model.isWorking)
        #expect(model.canGenerate, "The button is only held back while work is going on")
        #expect(!model.canResume, "Already fetched")
        #expect(transport.sent.map(\.path) == ["/api/font", "/api/export/burn", "/api/stitch/status", "/api/export/burn/dl"])
        // Opening again shows the same file without asking the server anything.
        await model.open()
        #expect(model.fileURL == file)
        #expect(transport.sent.count == 4)
    }

    @Test(arguments: [ServerFixtures.burnFontRefusal, ServerFixtures.burnFFmpegRefusal])
    func aBurningTheServerCannotDoIsShownAsTheFonts(_ body: String) async throws {
        let own = OwnExports()
        defer { own.remove() }
        let model = model(StubTransport([.ok(ServerFixtures.fontPresent), .status(400, body)]), exports: own)
        await model.open()
        model.start()
        #expect(await settle { model.phase.isFailed })
        #expect(model.phase == .failed(.watermarkUnavailable))
        #expect(model.watermarkUnavailable)
        #expect(model.handle == nil, "Nothing to pick up again")
        #expect(!model.canResume)
    }

    @Test func anyOtherRefusalIsTheServersWords() async throws {
        let own = OwnExports()
        defer { own.remove() }
        let model = model(StubTransport([.ok(ServerFixtures.fontPresent), .status(400, ServerFixtures.burnBusy)]), exports: own)
        await model.open()
        model.start()
        #expect(await settle { model.phase == .failed(.server("已有导出/合成任务在进行, 请等它完成")) })
        #expect(!model.watermarkUnavailable)
        #expect(model.handle == nil)
    }

    @Test func aFileThatVanishesBeforeTheCopyIsExpired() async throws {
        let own = OwnExports()
        defer { own.remove() }
        let model = model(StubTransport([.ok(ServerFixtures.fontPresent), .ok(ServerFixtures.exportStarted),
                                             .ok(ServerFixtures.stitchDone), .status(404, "gone")]), exports: own)
        await model.open()
        model.start()
        #expect(await settle { model.phase == .failed(.expired) })
        #expect(model.handle == nil, "Asking again would only find it gone")
        #expect(!model.canResume)
    }

    @Test func aStatusThatSaysTheJobIsGoneIsAFailureThatKeepsTheHandle() async throws {
        let own = OwnExports()
        defer { own.remove() }
        let model = model(StubTransport([.ok(ServerFixtures.fontPresent), .ok(ServerFixtures.exportStarted),
                                             .status(404, ServerFixtures.stitchGone)]), exports: own)
        await model.open()
        model.start()
        #expect(await settle { model.phase.isFailed })
        // Only an expired file or a missing font makes the model forget the job; this is neither.
        guard case .failed(let failure) = model.phase else { return }
        #expect(failure != .expired && failure != .watermarkUnavailable && failure != .network)
        #expect(model.handle != nil)
        #expect(model.canResume)
    }

    @Test func aNetworkFailureIsNamed() async throws {
        let own = OwnExports()
        defer { own.remove() }
        let model = model(StubTransport([.ok(ServerFixtures.fontPresent), .raises(URLError(.networkConnectionLost))]), exports: own)
        await model.open()
        model.start()
        #expect(await settle { model.phase == .failed(.network) })
    }

    @Test func theProgressIsSeenWhileTheServerWorks() async throws {
        let own = OwnExports()
        defer { own.remove() }
        let transport = StubTransport([.ok(ServerFixtures.fontPresent), .ok(ServerFixtures.exportStarted),
                                       .ok(ServerFixtures.stitchRunning(percent: 42)), .ok(ServerFixtures.stitchDone),
                                       .ok("MP4", headers: ["Content-Length": "3"])])
        let model = model(transport, exports: own)
        await model.open()
        model.start()
        #expect(await settle { model.phase == .generating(percent: 42) })
        #expect(model.isWorking)
        #expect(!model.canGenerate)
        // The job is on the server and not fetched: waiting could be picked up again if it were stopped.
        // What keeps a second tap from starting another job is that `start()` refuses while work is going on.
        #expect(model.canResume, "The job exists and has not been fetched")
        // A start while the work is going on changes nothing.
        model.start()
        #expect(await settle { model.phase.isReady })
        #expect(transport.sent(to: "/api/export/burn").count == 1)
    }

    @Test func aSecondTapWhileTheJobIsBeingAskedForStartsNothing() async throws {
        let own = OwnExports()
        defer { own.remove() }
        let transport = RoutingTransport()
        transport.route("/api/font", endless: .ok(ServerFixtures.fontPresent))
        transport.route("/api/export/burn", steps: [.held(.ok(ServerFixtures.exportStarted))])
        transport.route("/api/stitch/status", endless: .ok(ServerFixtures.stitchDone))
        transport.route("/api/export/burn/dl", endless: .ok("MP4", headers: ["Content-Length": "3"]))
        let model = model(transport, exports: own)
        await model.open()
        model.start()
        // Expected: the work counts as started from the first tap, so the button gives way at once.
        #expect(model.isWorking)
        #expect(!model.canGenerate)
        #expect(await waitUntil { transport.sent(to: "/api/export/burn").count == 1 })
        model.start()
        transport.releaseWaiting()
        #expect(await settle { model.phase.isReady })
        #expect(transport.sent(to: "/api/export/burn").count == 1)
    }

    // MARK: Stopping and picking up

    /// A server whose job is seen running (the first look says so, and the sheet waits a second before
    /// looking again), and done on the look after that. `afterwards` is what the looks after the first say.
    private func runningJobTransport(afterwards: StubTransport.Reply = .ok(ServerFixtures.stitchDone)) -> RoutingTransport {
        let transport = RoutingTransport()
        transport.route("/api/font", endless: .ok(ServerFixtures.fontPresent))
        transport.route("/api/export/burn", endless: .ok(ServerFixtures.exportStarted))
        transport.route("/api/stitch/status", steps: [.now(.ok(ServerFixtures.stitchRunning(percent: 42))), .now(afterwards)])
        transport.route("/api/export/burn/dl", endless: .ok("MP4", headers: ["Content-Length": "3"]))
        return transport
    }

    /// Opens and starts, and waits until the sheet shows the server at work.
    private func started(_ model: ExportModel) async {
        await model.open()
        model.start()
        #expect(await settle { model.phase == .generating(percent: 42) })
    }

    @Test func stoppingKeepsTheJobAndStartPicksItUp() async throws {
        let own = OwnExports()
        defer { own.remove() }
        let transport = runningJobTransport()
        let model = model(transport, exports: own)
        await started(model)
        model.stopWaiting()
        #expect(model.phase == .stoppedWaiting)
        #expect(!model.isWorking)
        #expect(model.handle != nil)
        #expect(model.canResume)
        #expect(model.fileURL == nil)
        // The server is not told: there is no way to cancel a job. Nothing more is asked until the person says so.
        try await Task.sleep(for: .milliseconds(1100))
        #expect(model.phase == .stoppedWaiting)
        #expect(transport.sent(to: "/api/stitch/status").count == 1)
        #expect(transport.sent(to: "/api/export/burn/dl").isEmpty)
        // Picking it up looks at the same job again, and does not start a new one.
        model.start()
        #expect(await settle { model.phase.isReady })
        #expect(transport.sent(to: "/api/export/burn").count == 1)
        #expect(transport.sent(to: "/api/stitch/status").count == 2)
        #expect(transport.sent(to: "/api/export/burn/dl").count == 1)
    }

    @Test func reopeningALeftJobLooksAtItAndCarriesOn() async throws {
        let own = OwnExports()
        defer { own.remove() }
        let transport = runningJobTransport()
        let model = model(transport, exports: own)
        await started(model)
        model.stopWaiting()
        #expect(model.phase == .stoppedWaiting)
        // The sheet opened again: the job is asked about first, and the font is not asked about again.
        await model.open()
        #expect(await settle { model.phase.isReady })
        #expect(transport.sent(to: "/api/export/burn").count == 1)
        #expect(transport.sent(to: "/api/font").count == 1)
        #expect(transport.sent(to: "/api/export/burn/dl").count == 1)
    }

    @Test func reopeningALeftJobThatFailedAsksAboutTheFontInstead() async throws {
        let own = OwnExports()
        defer { own.remove() }
        let transport = runningJobTransport()
        let model = model(transport, exports: own)
        await started(model)
        model.stopWaiting()
        #expect(model.phase == .stoppedWaiting)
        transport.route("/api/stitch/status", endless: .status(404, ServerFixtures.stitchGone))
        await model.open()
        #expect(await settle { model.phase == .idle })
        #expect(model.handle == nil, "That job is over: the next start makes a new one")
        #expect(!model.canResume)
        #expect(model.watermark == .available)
        #expect(model.canGenerate)
        #expect(transport.sent(to: "/api/font").count == 2)
        #expect(transport.sent(to: "/api/export/burn/dl").isEmpty)
    }

    @Test func discardingTheJobStartsANewOneNextTime() async throws {
        let own = OwnExports()
        defer { own.remove() }
        let transport = runningJobTransport()
        let model = model(transport, exports: own)
        await started(model)
        model.stopWaiting()
        model.discardJob()
        #expect(model.phase == .idle)
        #expect(model.handle == nil)
        #expect(!model.canResume)
        #expect(model.canGenerate)
        model.start()
        #expect(await settle { model.phase.isReady })
        #expect(transport.sent(to: "/api/export/burn").count == 2)
        #expect(transport.sent(to: "/api/stitch/status").count == 2, "The new job's first look")
        #expect(transport.sent(to: "/api/export/burn/dl").count == 1)
    }

    @Test func stoppingBeforeAnythingWasStartedIsJustIdle() async throws {
        let own = OwnExports()
        defer { own.remove() }
        let model = model(StubTransport([.ok(ServerFixtures.fontPresent)]), exports: own)
        model.stopWaiting()
        #expect(model.phase == .idle)
        model.discardJob()
        #expect(model.phase == .idle)
        model.stopWaiting()
        #expect(model.phase == .idle)
    }
}

private extension ExportModel.Phase {
    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
