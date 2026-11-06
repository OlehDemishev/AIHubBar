import Foundation
import Testing
@testable import AIHubBar

struct ServiceStatusTests {
    func page(_ indicator: String, _ description: String) -> Data {
        Data(#"{"page":{"id":"x"},"status":{"indicator":"\#(indicator)","description":"\#(description)"}}"#.utf8)
    }

    @Test func readsThePage() {
        #expect(ServiceStatus.problem(in: page("none", "All Systems Operational")) == nil)
        #expect(ServiceStatus.problem(in: page("major", "Partial System Outage")) == "Partial System Outage")
        #expect(ServiceStatus.problem(in: Data("<html>".utf8)) == nil, "an unreadable answer says nothing")
    }

    @Test func onlySomeErrorsAskIt() {
        #expect(UsageError.http(503).mayBeOutage && UsageError.network(-1009).mayBeOutage && UsageError.badResponse.mayBeOutage)
        #expect(!UsageError.http(401).mayBeOutage && !UsageError.noCredentials.mayBeOutage && !UsageError.keychainDenied.mayBeOutage)
    }
}
