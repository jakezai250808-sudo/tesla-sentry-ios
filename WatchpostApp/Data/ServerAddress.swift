import Foundation

// The address of a person's own server, as typed on the connect screen.

enum ServerAddress {
    /// Turns what someone typed into the base URL requests go to.
    ///
    /// Accepted: `192.168.1.50`, `192.168.1.50:8080`, `http://box.local`, `https://example.com/`.
    /// Without a scheme it is `http://`, since these are boxes on a home network.
    /// Anything after the host (a path, a query) is dropped: the server lives at the root.
    static func normalize(_ text: String) throws(ServerAddressProblem) -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .empty }
        var candidate = trimmed
        if !candidate.contains("://") {
            candidate = "http://" + candidate
        }
        guard let parts = URLComponents(string: candidate),
              let scheme = parts.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = parts.host?.lowercased(),
              !host.isEmpty,
              parts.user == nil,
              parts.password == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true
        else { throw .notAnAddress }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = parts.port
        components.path = "/"
        guard let url = components.url else { throw .notAnAddress }
        return url
    }

    /// The problem to show under the field, before anything is sent; nil when the text is a usable address.
    static func problem(_ text: String) -> ServerAddressProblem? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }
        do {
            _ = try normalize(text)
            return nil
        } catch {
            // `normalize` only throws `notAnAddress` here: the empty text was answered above.
            return .notAnAddress
        }
    }

    /// True for addresses that only make sense on the person's own network.
    /// Reaching those needs the local-network permission on iOS.
    static func isLocal(_ url: URL) -> Bool {
        guard let host = (url.ipv6Host ?? url.host)?.lowercased() else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local")
            || host.hasSuffix(".lan") || host.hasSuffix(".home") || host.hasSuffix(".home.arpa")
            || host.hasSuffix(".internal") || host.hasSuffix(".localdomain") {
            return true
        }
        if isPrivateIPv4(host) { return true }
        if host.contains(":") { return isLinkLocalIPv6(host) }
        return false
    }

    private static func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        // Loopback, link-local, and the three private ranges.
        if octets[0] == 127 || octets[0] == 10 || (octets[0] == 169 && octets[1] == 254) { return true }
        if octets[0] == 192 && octets[1] == 168 { return true }
        if octets[0] == 172 && (16...31).contains(octets[1]) { return true }
        if octets[0] == 100 && (64...127).contains(octets[1]) { return true } // carrier-grade NAT
        return false
    }

    private static func isLinkLocalIPv6(_ host: String) -> Bool {
        let lower = host.lowercased()
        if lower == "::1" || lower == "::" { return true }
        if lower.hasPrefix("fe8") || lower.hasPrefix("fe9") || lower.hasPrefix("fea") || lower.hasPrefix("feb") { return true }
        if lower.hasPrefix("fc") || lower.hasPrefix("fd") { return true }
        // An IPv4-mapped address, ::ffff:a.b.c.d
        if lower.hasPrefix("::ffff:") {
            let v4 = String(lower.dropFirst(7))
            if let hex = UInt32(v4, radix: 16) {
                return isPrivateIPv4("\(hex >> 24 & 255).\(hex >> 16 & 255).\(hex >> 8 & 255).\(hex & 255)")
            }
            return isPrivateIPv4(v4)
        }
        return false
    }
}
