import Foundation
import Testing
@testable import AIHubBar

/// «Раскладка» pauses while another app holds Secure Input and names that app (`SecureInput`).
struct SecureInputTests {
    @Test func theAppThatHoldsSecureInputIsNamed() {
        let names: [pid_t: String] = [1128: "Claude"]
        #expect(SecureInput.of(isOn: false, session: [:], name: { names[$0] }) == nil, "off: no pause")
        #expect(SecureInput.of(isOn: false, session: nil, name: { names[$0] }) == nil)
        let held = SecureInput.of(isOn: true, session: ["kCGSSessionSecureInputPID": NSNumber(value: 1128)], name: { names[$0] })
        #expect(held == SecureInput(appName: "Claude"))
        #expect(held?.title.contains("Claude") == true && held?.hint.contains("Claude") == true)
        // The session names a holder even when the quick check missed it; an unknown process is still a pause.
        #expect(SecureInput.of(isOn: false, session: ["kCGSSessionSecureInputPID": NSNumber(value: 1128)], name: { names[$0] })?.appName == "Claude")
        let unknown = SecureInput.of(isOn: true, session: [:], name: { names[$0] })
        #expect(unknown == SecureInput(appName: nil) && unknown?.title.isEmpty == false)
        #expect(SecureInput.of(isOn: true, session: ["kCGSSessionSecureInputPID": NSNumber(value: 4242)], name: { names[$0] }) == SecureInput(appName: nil))
    }
}
