import Foundation
import Observation

/// One export: a single camera and a single minute, with the watermark, made
/// by the source and brought to the phone for the system share sheet.
///
/// The job is kept when the person stops waiting: the server has no way to
/// cancel, so the sheet can pick the same job up again while it still exists.
@MainActor
@Observable
final class ExportModel {
    enum Phase: Equatable {
        /// Nothing asked yet.
        case idle
        /// Asking whether the watermark can be made right now.
        case checking
        case generating(percent: Int?)
        case downloading(received: Int64, total: Int64?)
        /// The file is on the phone, ready for the system share sheet.
        case ready(URL)
        case failed(ExportFailure)
        /// Waiting was stopped. The server may still be making the file.
        case stoppedWaiting
    }

    let source: any ClipSource
    let event: RecordedEvent
    let video: ClipVideo
    let quality: Quality

    private(set) var phase: Phase = .idle
    /// Nil until the source answered; `.unavailable` means the server has no font for the watermark.
    private(set) var watermark: WatermarkAvailability?
    private(set) var handle: ExportHandle?
    private var fetchedFile: URL?
    private var task: Task<Void, Never>?

    init(source: any ClipSource, event: RecordedEvent, video: ClipVideo, quality: Quality) {
        self.source = source
        self.event = event
        self.video = video
        self.quality = quality
    }

    /// The file the share sheet offers.
    var fileURL: URL? {
        if case .ready(let url) = phase { return url }
        return nil
    }

    /// Whether "Generate" can start something: the watermark is possible and nothing is running.
    var canGenerate: Bool {
        watermark == .available && !isWorking
    }

    var isWorking: Bool {
        switch phase {
        case .checking, .generating, .downloading: true
        case .idle, .ready, .failed, .stoppedWaiting: false
        }
    }

    /// The job is still on the server and has not been fetched: waiting can continue.
    var canResume: Bool { handle != nil && fetchedFile == nil }

    /// The failure with a file the person can act on: the server cannot add a watermark.
    var watermarkUnavailable: Bool {
        if case .failed(.watermarkUnavailable) = phase { return true }
        return watermark == .unavailable
    }

    // MARK: Opening the sheet

    func open() async {
        if let fetchedFile {
            phase = .ready(fetchedFile)
            return
        }
        if let handle {
            // A job from before: look at it rather than start a second one.
            if let status = try? await source.exportJob(handle), status.state != .error {
                run(resuming: handle)
                return
            }
            self.handle = nil
        }
        phase = .checking
        do {
            let availability = try await source.watermarkAvailability()
            guard !Task.isCancelled else { return }
            watermark = availability
            phase = .idle
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(.network)
        }
    }

    func start() {
        guard !isWorking else { return }
        if let handle, canResume, watermark != .unavailable {
            run(resuming: handle)
        } else {
            run(resuming: nil)
        }
    }

    func retry() { start() }

    /// Stops waiting. The server is not told: it has no way to cancel a job.
    func stopWaiting() {
        guard isWorking else { return }
        task?.cancel()
        task = nil
        phase = handle != nil ? .stoppedWaiting : .idle
    }

    /// Forgets the job, so the next start makes a new one.
    func discardJob() {
        task?.cancel()
        task = nil
        handle = nil
        phase = .idle
    }

    // MARK: The work

    private func run(resuming existing: ExportHandle?) {
        let source = source
        let event = event
        let video = video
        let quality = quality
        // Seen as started at once, before the server answers: a second tap must not start another job.
        phase = .generating(percent: nil)
        // The task keeps the model alive until the job is over, so the sheet can be closed and reopened meanwhile.
        task = Task {
            do {
                let handle: ExportHandle
                if let existing {
                    handle = existing
                } else {
                    handle = try await source.startExport(event: event, video: video, quality: quality)
                }
                self.handle = handle
                var running = true
                while running {
                    try Task.checkCancellation()
                    let status = try await source.exportJob(handle)
                    switch status.state {
                    case .done:
                        running = false
                    case .error:
                        throw ExportFailure.server(status.message ?? "")
                    case .running, .unknown:
                        self.apply(.generating(percent: status.percent))
                        try await Task.sleep(for: .seconds(1))
                    }
                }
                let file = try await source.downloadExport(handle) { progress in
                    Task { @MainActor in self.apply(progress) }
                }
                fetchedFile = file
                phase = .ready(file)
                task = nil
            } catch is CancellationError {
                // Whoever cancelled has already set the phase.
            } catch {
                let failure = (error as? ExportFailure) ?? .network
                // A job that is gone, or a server that cannot do it, is not worth asking about again.
                if failure == .expired || failure == .watermarkUnavailable { handle = nil }
                phase = .failed(failure)
                task = nil
            }
        }
    }

    private func apply(_ progress: ExportProgress) {
        guard isWorking else { return }
        switch progress {
        case .generating(let percent): phase = .generating(percent: percent)
        case .downloading(let received, let total): phase = .downloading(received: received, total: total)
        }
    }
}
