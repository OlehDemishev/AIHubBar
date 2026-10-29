import ServiceManagement
import Testing
@testable import ClaudePult

struct LoginItemStateTests {
    @Test(arguments: [
        (SMAppService.Status.enabled, LoginItemState.enabled),
        (.notRegistered, .disabled),
        (.notFound, .disabled),
        (.requiresApproval, .requiresApproval),
    ])
    func mapsServiceStatus(status: SMAppService.Status, expected: LoginItemState) {
        #expect(LoginItemState(status) == expected)
    }

    @Test func toggleIsOnWhileWaitingForApproval() {
        #expect(LoginItemState.enabled.isOn)
        #expect(LoginItemState.requiresApproval.isOn)
        #expect(!LoginItemState.disabled.isOn)
    }

    @Test func onlyApprovalStateHasMessage() {
        #expect(LoginItemState.enabled.message == nil)
        #expect(LoginItemState.disabled.message == nil)
        #expect(LoginItemState.requiresApproval.message != nil)
    }
}
