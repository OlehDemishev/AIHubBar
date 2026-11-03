import Foundation
import Testing
@testable import AIHubBar

struct AppLogTests {
    struct Failure: Error {}

    @Test func attemptReportsWhetherTheWriteWorked() {
        var ran = false
        #expect(AppLog.attempt("test write") { ran = true })
        #expect(ran)
        #expect(!AppLog.attempt("test write") { throw Failure() })
    }
}
