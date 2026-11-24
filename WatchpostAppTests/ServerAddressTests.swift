import Foundation
import Testing
@testable import WatchpostApp

struct ServerAddressTests {
    /// What was typed and the base URL it becomes.
struct AddressCase: Sendable {
        let typed: String
        let url: String
    }

    // MARK: normalize

    @Test(arguments: [
        AddressCase(typed: "192.168.1.50", url: "http://192.168.1.50/"),
        AddressCase(typed: "192.168.1.50:8080", url: "http://192.168.1.50:8080/"),
        AddressCase(typed: "http://box.local", url: "http://box.local/"),
        AddressCase(typed: "https://cam.example.com:8443", url: "https://cam.example.com:8443/"),
        AddressCase(typed: "https://example.com/", url: "https://example.com/"),
        AddressCase(typed: "HTTP://BOX.LOCAL", url: "http://box.local/"),
        AddressCase(typed: "Https://Example.COM", url: "https://example.com/"),
        AddressCase(typed: "https://example.com/sentry/", url: "https://example.com/"),
        AddressCase(typed: "http://box.local:8080/api/events?x=1", url: "http://box.local:8080/"),
        AddressCase(typed: "http://192.168.1.50:8080/#token", url: "http://192.168.1.50:8080/"),
        AddressCase(typed: "  http://box.local:8080/ \n", url: "http://box.local:8080/"),
    ])
    func anAddressBecomesABaseURL(_ address: AddressCase) throws {
        #expect(try ServerAddress.normalize(address.typed).absoluteString == address.url)
    }

    @Test func anIPv6LiteralIsAnAddress() throws {
        let url = try ServerAddress.normalize("http://[fe80::1]:8080")
        #expect(url.absoluteString == "http://[fe80::1]:8080/")
        #expect(url.port == 8080)
        #expect(ServerAddress.isLocal(url))
    }

    @Test(arguments: ["", "   ", "\n\t"])
    func anEmptyAddressSaysSo(_ typed: String) {
        #expect(throws: ServerAddressProblem.empty) { try ServerAddress.normalize(typed) }
    }

    @Test(arguments: [
        "ftp://box.local", "javascript:alert(1)", "mailto:a@b.c", "http://", "http:///api/ver",
        "user:pass@box.local", "http://user@192.168.1.50:8080", "http://[fe80::1",
    ])
    func whatIsNotAnAddressSaysSo(_ typed: String) {
        #expect(throws: ServerAddressProblem.notAnAddress) { try ServerAddress.normalize(typed) }
    }

    @Test func theConnectFormAsksTheSameQuestion() {
        #expect(ServerAddress.problem("192.168.1.50:8080") == nil)
        #expect(ServerAddress.problem(" https://cam.example.com ") == nil)
        #expect(ServerAddress.problem("") != nil)
        #expect(ServerAddress.problem("ftp://box.local") == .notAnAddress)
        #expect(ServerAddress.problem("http://") == .notAnAddress)
    }

    // MARK: isLocal

    private static func local(_ host: String) throws -> Bool {
        ServerAddress.isLocal(try #require(URL(string: "http://\(host):8080/")))
    }

    @Test(arguments: ["10.0.0.5", "192.168.1.50", "172.16.0.1", "172.31.255.254", "169.254.10.1", "127.0.0.1",
                       "100.64.0.1", "100.127.255.254"])
    func privateAndLinkLocalAddressesAreLocal(_ host: String) throws {
        #expect(try Self.local(host))
    }

    @Test(arguments: ["8.8.8.8", "172.15.0.1", "172.32.0.1", "192.169.0.1", "100.63.255.255", "100.128.0.1", "203.0.113.9"])
    func publicAddressesAreNotLocal(_ host: String) throws {
        #expect(try !Self.local(host))
    }

    @Test(arguments: ["localhost", "box.localhost", "box.local", "box.lan", "box.home", "box.home.arpa", "box.internal",
                       "box.localdomain"])
    func namesFromTheHomeNetworkAreLocal(_ host: String) throws {
        #expect(try Self.local(host))
    }

    @Test(arguments: ["example.com", "box.example.com", "notlocalhost", "box.locale", "box.localhosts"])
    func namesFromTheInternetAreNotLocal(_ host: String) throws {
        #expect(try !Self.local(host))
    }

    @Test(arguments: ["[::1]", "[fe80::1]", "[FC00::1]", "[fd12:3456::1]"])
    func localIPv6AddressesAreLocal(_ host: String) throws {
        #expect(try Self.local(host))
    }

    @Test(arguments: ["[2001:db8::1]", "[2606:4700::1111]"])
    func publicIPv6AddressesAreNotLocal(_ host: String) throws {
        #expect(try !Self.local(host))
    }
}
