import Foundation
import Observation

/// The servers the person saved, and what belongs to each of them. Records
/// (address, quality choice, version) sit in defaults; the password and the
/// session cookie sit in the keychain, each keyed by the server's id.
@MainActor
@Observable
final class ServerStore {
    private(set) var records: [ServerRecord] = []
    /// The server the app was on when it last closed, if it is still saved.
    var lastServerID: UUID? {
        get { defaults.string(forKey: Self.lastKey).flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: Self.lastKey) }
    }

    private let defaults: UserDefaults
    private let secrets: SecretStore
    private static let recordsKey = "watchpost.servers"
    private static let lastKey = "watchpost.lastServer"

    init(defaults: UserDefaults = .standard, secrets: SecretStore = SecretStore()) {
        self.defaults = defaults
        self.secrets = secrets
        if let data = defaults.data(forKey: Self.recordsKey),
           let saved = try? JSONDecoder().decode([ServerRecord].self, from: data) {
            records = saved
        }
    }

    func record(id: UUID) -> ServerRecord? {
        records.first { $0.id == id }
    }

    /// Adds a server, or replaces the one with the same id.
    func save(_ record: ServerRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        persist()
    }

    func update(_ id: UUID, _ change: (inout ServerRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        var record = records[index]
        change(&record)
        records[index] = record
        persist()
    }

    /// Forgets the server and everything stored for it. Nothing on the server itself changes.
    func remove(_ id: UUID) {
        records.removeAll { $0.id == id }
        persist()
        if lastServerID == id { lastServerID = nil }
        try? secrets.remove(Self.passwordKey(id))
        try? secrets.remove(Self.sessionKey(id))
    }

    // MARK: Secrets

    func password(for id: UUID) -> String? {
        try? secrets.value(for: Self.passwordKey(id))
    }

    func setPassword(_ password: String?, for id: UUID) {
        try? secrets.set(password?.isEmpty == true ? nil : password, for: Self.passwordKey(id))
    }

    func token(for id: UUID) -> SessionToken? {
        guard let text = try? secrets.value(for: Self.sessionKey(id)),
              let data = text.data(using: .utf8),
              let token = try? JSONDecoder().decode(SessionToken.self, from: data) else { return nil }
        return token
    }

    func setToken(_ token: SessionToken?, for id: UUID) {
        guard let token, let data = try? JSONEncoder().encode(token) else {
            try? secrets.remove(Self.sessionKey(id))
            return
        }
        try? secrets.set(String(decoding: data, as: UTF8.self), for: Self.sessionKey(id))
    }

    func touch(_ id: UUID) {
        update(id) { $0.lastUsedAt = Date() }
    }

    func setQuality(_ quality: Quality, for id: UUID) {
        update(id) { $0.preferredQuality = quality }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Self.recordsKey)
    }

    private static func passwordKey(_ id: UUID) -> String { "server.\(id.uuidString).password" }
    private static func sessionKey(_ id: UUID) -> String { "server.\(id.uuidString).session" }
}
