import Foundation
import Testing
@testable import AIHubBar

/// «Локальные серверы»: reading `lsof` and matching a server to its project.
struct LocalServersTests {
    @Test func listenersFromLsof() {
        let output = """
        p812
        cnode
        f23
        n*:3000
        f24
        n[::1]:3000
        f31
        n127.0.0.1:9229
        p90
        crapportd
        f8
        n*:49152
        p77
        cbroken
        nno-port
        """
        #expect(LocalServers.parseListeners(output) == [
            .init(pid: 812, command: "node", port: 3000), .init(pid: 812, command: "node", port: 9229),
            .init(pid: 90, command: "rapportd", port: 49152),
        ])
        #expect(LocalServers.parseListeners("").isEmpty)
    }

    @Test func foldersFromLsof() {
        let output = "p812\nfcwd\nn/Users/o/Projects/Ambo/web\np90\nfcwd\nn/\np5\n"
        #expect(LocalServers.parseDirectories(output) == [812: "/Users/o/Projects/Ambo/web", 90: "/"])
    }

    @Test func aServerBelongsToTheProjectItRunsIn() {
        let web = LocalServer(pid: 1, command: "node", port: 3000, folder: "/P/Ambo/web")
        let root = LocalServer(pid: 2, command: "python3", port: 8000, folder: "/P/Ambo")
        let sibling = LocalServer(pid: 3, command: "node", port: 5173, folder: "/P/Ambo-site")
        let system = LocalServer(pid: 4, command: "rapportd", port: 49152, folder: "/")
        #expect(LocalServers.servers([web, root, sibling, system], in: "/P/Ambo") == [web, root])
        #expect(LocalServers.servers([web, root, sibling, system], in: "/P/Ambo/") == [web, root])
        #expect(web.url?.absoluteString == "http://localhost:3000")
        #expect(web.id == "1:3000")
    }
}
