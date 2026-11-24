import Foundation

// The server side of the app's model: what is remembered per server, and the
// small answers the server gives to status and playback questions.

/// Stream quality. Everything but the original is transcoded by the server on
/// request, so it may not exist yet the moment it is asked for.
enum Quality: String, CaseIterable, Codable, Sendable, Hashable {
    case original = "orig"
    case hd720 = "720p"
    case hd480 = "480p"
    case hd360 = "360p"

    /// The first choice for a new server.
    static let standard = Quality.hd480

    /// Menu order.
    static let menuOrder: [Quality] = [.original, .hd720, .hd480, .hd360]

    var isTranscoded: Bool { self != .original }

    var title: String {
        switch self {
        case .original: String(localized: "Original", comment: "Quality: the untouched recording")
        case .hd720: "720p"
        case .hd480: "480p"
        case .hd360: "360p"
        }
    }
}

/// A server the person saved. The password and session are kept apart, in the
/// secret store, keyed by `id`.
struct ServerRecord: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    /// Base URL, e.g. `http://192.168.1.50:8080`.
    var address: URL
    var addedAt: Date
    var preferredQuality: Quality
    var lastUsedAt: Date
    /// What the server answered to `/api/ver` when it last connected.
    var serverVersion: String?

    init(id: UUID = UUID(), address: URL, addedAt: Date = Date(), preferredQuality: Quality = .standard, lastUsedAt: Date = Date(), serverVersion: String? = nil) {
        self.id = id
        self.address = address
        self.addedAt = addedAt
        self.preferredQuality = preferredQuality
        self.lastUsedAt = lastUsedAt
        self.serverVersion = serverVersion
    }

    /// `host` or `host:port`, as shown on the connect screen.
    var hostLabel: String {
        var text = address.ipv6Host ?? address.host ?? address.absoluteString
        if let port = address.port {
            let defaultPort = address.scheme?.lowercased() == "https" ? 443 : 80
            if port != defaultPort { text += ":\(port)" }
        }
        return text
    }
}

extension URL {
    /// The host without the brackets IPv6 URLs put around it.
    var ipv6Host: String? {
        guard let host else { return nil }
        return host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : nil
    }
}

/// The server's signed session cookie (`tsf_sess`). It stays valid until
/// `expiresAt` unless the server's admin password is changed.
struct SessionToken: Codable, Hashable, Sendable {
    var value: String
    var expiresAt: Date?

    func isValid(now: Date = Date()) -> Bool {
        guard let expiresAt else { return true }
        // Leave a minute so a request never goes out with a token that lapses on the way.
        return expiresAt.timeIntervalSince(now) > 60
    }
}

enum PlaybackSourceState: String, Codable, Sendable, Hashable {
    case ready
    /// Transcoding now.
    case pending
    /// Waiting because the server is too busy or too warm to transcode.
    case cooling
    /// The server cannot transcode (no ffmpeg).
    case failed
    case missing
}

enum ExportJobState: String, Codable, Sendable, Hashable {
    case running
    case done
    case error
    case unknown
}

/// One answer of `/api/stitch/status`.
struct ExportJobStatus: Hashable, Codable, Sendable {
    var state: ExportJobState
    var percent: Int?
    var message: String?
    var sizeBytes: Int64?
}

/// `/api/live`: whether the sync from the car is alive, and how full things are.
/// Every field is optional; a missing one is shown as unknown, never as zero.
struct SyncStatus: Hashable, Codable, Sendable {
    var syncRunning: Bool?
    var pendingFiles: Int?
    /// Seconds since the server last logged a finished sync.
    var lastSyncAgo: TimeInterval?
    var ffmpegAvailable: Bool?
    /// The archive (the box's own copies of the clips) against its configured limit. Same unit, same filesystem.
    var archiveUsedBytes: Int64?
    var archiveLimitBytes: Int64?
    /// The virtual USB stick the car writes to: space used inside the image, and the image's nominal size.
    var usbUsedBytes: Int64?
    var usbCapacityBytes: Int64?
    /// The whole disk the archive lives on.
    var diskUsedBytes: Int64?
    var diskCapacityBytes: Int64?
    var measuredAt: Date?

    static let unknown = SyncStatus()

    var archiveFraction: Double? {
        guard let archiveUsedBytes, let archiveLimitBytes, archiveLimitBytes > 0 else { return nil }
        return min(max(Double(archiveUsedBytes) / Double(archiveLimitBytes), 0), 1)
    }

    var usbFraction: Double? {
        guard let usbUsedBytes, let usbCapacityBytes, usbCapacityBytes > 0 else { return nil }
        return min(max(Double(usbUsedBytes) / Double(usbCapacityBytes), 0), 1)
    }

    var diskFraction: Double? {
        guard let diskUsedBytes, let diskCapacityBytes, diskCapacityBytes > 0 else { return nil }
        return min(max(Double(diskUsedBytes) / Double(diskCapacityBytes), 0), 1)
    }

    var isArchiveNearlyFull: Bool { (archiveFraction ?? 0) > 0.85 }
}

/// A failed talk with the server.
enum UpstreamError: Error, Hashable, Sendable {
    /// `URLError`, by domain and code.
    case network(domain: String, code: Int)
    case badResponse
    case http(status: Int, message: String?)
    case unauthorized
    case lockedOut
    case incompatible
}

enum ServerAddressProblem: Error, Hashable, Sendable {
    case empty
    /// Not an http(s) address with a host.
    case notAnAddress
}

/// Why connecting failed, in the terms the connect screen shows.
enum ConnectFailure: Error, Hashable, Sendable {
    case invalidAddress(ServerAddressProblem)
    /// The address is on the local network and could not be reached: often the
    /// local-network permission, so the screen offers to open Settings.
    case localNetworkUnreachable
    case unreachable
    case certificateRejected
    case credentialsRejected
    case lockedOut
    case incompatibleServer
    case server(status: Int)
    case cancelled
}
