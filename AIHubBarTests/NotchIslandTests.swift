import AppKit
import Foundation
import Testing
@testable import AIHubBar

/// The island's decisions (docs/specs/SPEC-notch.md), without its windows: above all, that a click or a key meant for
/// something else can't answer a permission request.
@MainActor
struct NotchIslandTests {
    private let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)
    private let notch = CGRect(x: 640, y: 924, width: 190, height: 32)

    private func island(fullScreen: Bool = false, _ configure: (inout NotchSettings) -> Void = { _ in }) -> (NotchIsland, Decisions) {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "notch-island-\(UUID().uuidString)")!)
        configure(&settings.notch)
        let island = NotchIsland(settings: settings)
        island.places = [NotchPlace(geometry: NotchGeometry(notch: notch, screen: screen), isFullScreen: fullScreen)]
        let decisions = Decisions()
        island.perform = { decisions.all.append($0) }
        return (island, decisions)
    }

    @MainActor final class Decisions {
        var all: [NotificationAction.Resolution] = []
    }

    private func request(_ id: String = "req1") -> NotchEvent {
        NotchEvent(id: "request-\(id)", kind: .request, title: "Ambo", body: "ls",
                   target: .approval(sessionID: "s-\(id)", requestID: id), arrived: .now)
    }

    private func banner(_ kind: NotchEventKind = .limits, id: String = "banner") -> NotchEvent {
        NotchEvent(id: id, kind: kind, title: "Лимит", body: "", target: .none, arrived: .now)
    }

    /// As it is after the time has passed and the pointer has moved.
    private func arm(_ island: NotchIsland) {
        var guardian = NotchClickGuard(shownAt: .now.addingTimeInterval(-NotchClickGuard.delay - 1), pointer: .zero)
        guardian.pointer(at: CGPoint(x: 100, y: 100))
        island.clickGuard = guardian
        island.updateArmed()
    }

    private func item(_ id: String, _ state: Session.State) throws -> SessionStore.Item {
        let session = try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: [
            "session_id": id, "cwd": "/p/\(id)", "updated_at": "2026-11-02T19:00:00+01:00",
        ]))
        return SessionStore.Item(session: session, state: state)
    }

    // MARK: Answering a request

    @Test func aFreshCardDoesntTakeClicks() {
        let (island, decisions) = island()
        let event = request()
        _ = island.queue.syncRequests([event])
        island.open(on: 0)
        #expect(!island.armed)
        island.answer(event, allow: true)
        #expect(decisions.all.isEmpty)
        #expect(island.requests.count == 1)
    }

    /// Time alone isn't enough: a pointer already resting there would click by accident.
    @Test func clicksNeedThePointerToMove() {
        let (island, _) = island()
        island.clickGuard = NotchClickGuard(shownAt: .now.addingTimeInterval(-10), pointer: .zero)
        island.updateArmed()
        #expect(!island.armed)
        arm(island)
        #expect(island.armed)
    }

    @Test func anArmedClickAnswersOnce() {
        let (island, decisions) = island()
        let event = request()
        _ = island.queue.syncRequests([event])
        arm(island)
        island.answer(event, allow: true)
        #expect(decisions.all == [.decide(requestID: "req1", allow: true)])
        #expect(island.queue.items.isEmpty)
    }

    @Test func aDenyIsADeny() {
        let (island, decisions) = island()
        let event = request()
        _ = island.queue.syncRequests([event])
        arm(island)
        island.answer(event, allow: false)
        #expect(decisions.all == [.decide(requestID: "req1", allow: false)])
    }

    /// The next request slides up under the pointer: a second click must not answer it unread.
    @Test func theNextRequestInTheCardWaitsAgain() {
        let (island, decisions) = island()
        let first = request("req1"), second = request("req2")
        _ = island.queue.syncRequests([first, second])
        island.open(on: 0)
        arm(island)
        island.answer(first, allow: true)
        #expect(!island.armed)
        island.answer(second, allow: true)
        #expect(decisions.all == [.decide(requestID: "req1", allow: true)])
        #expect(island.requests.map(\.id) == [second.id])
    }

    @Test func aBannerThatIsNoRequestAnswersNothing() {
        let (island, decisions) = island()
        arm(island)
        island.answer(banner(), allow: true)
        #expect(decisions.all.isEmpty)
    }

    // MARK: ⌃⌥Y / ⌃⌥N

    @Test func keysAreOffUnlessChosen() {
        let (island, decisions) = island { $0.hotKeys = false }
        _ = island.queue.syncRequests([request()])
        arm(island)
        island.answerByKey(allow: true)
        #expect(decisions.all.isEmpty)
    }

    @Test func keysWaitUntilTheRequestCanBeRead() {
        let (island, decisions) = island { $0.hotKeys = true }
        _ = island.queue.syncRequests([request()])
        island.clickGuard = NotchClickGuard(shownAt: .now, pointer: .zero)
        island.answerByKey(allow: true)
        #expect(decisions.all.isEmpty)

        // No pointer needed once the time has passed.
        island.clickGuard = NotchClickGuard(shownAt: .now.addingTimeInterval(-NotchClickGuard.delay - 1), pointer: .zero)
        island.answerByKey(allow: false)
        #expect(decisions.all == [.decide(requestID: "req1", allow: false)])
    }

    @Test func keysAnswerOnlyARequestOnScreen() {
        let (island, decisions) = island { $0.hotKeys = true }
        island.queue.push(banner())
        arm(island)
        island.answerByKey(allow: true)
        #expect(decisions.all.isEmpty)
    }

    @Test func keysAnswerTheCardsFirstRequest() {
        let (island, decisions) = island { $0.hotKeys = true }
        _ = island.queue.syncRequests([request("req1"), request("req2")])
        island.open(on: 0)
        arm(island)
        island.answerByKey(allow: true)
        #expect(decisions.all == [.decide(requestID: "req1", allow: true)])
    }

    // MARK: What comes in

    @Test func nothingShowsWithNoPlace() {
        let (island, _) = island()
        island.places = []
        #expect(!island.notification(id: "a", kind: .limits, title: "t", body: "", target: .none))
        #expect(island.queue.items.isEmpty)
    }

    @Test func aKindSwitchedOffStaysOut() {
        let (island, _) = island { $0.events = [.request] }
        _ = island.notification(id: "a", kind: .limits, title: "t", body: "", target: .none)
        #expect(island.queue.items.isEmpty)
    }

    /// Requests come from the open request files, so they last exactly as long as the request.
    @Test func aRequestsNotificationAddsNoBanner() {
        let (island, _) = island()
        _ = island.notification(id: "a", kind: .waiting, title: "t", body: "", target: .approval(sessionID: "s", requestID: "r"))
        #expect(island.queue.items.isEmpty)
    }

    @Test func overAFullScreenAppOnlyRequestsAndWaits() {
        let (island, _) = island(fullScreen: true)
        _ = island.notification(id: "a", kind: .limits, title: "t", body: "", target: .none)
        #expect(island.queue.items.isEmpty)
        _ = island.notification(id: "b", kind: .waiting, title: "t", body: "", target: .none)
        #expect(island.queue.items.map(\.id) == ["b"])
        #expect(island.banner(on: 0)?.id == "b")
    }

    /// No window can be visible here, so it never says «no system notification»: a request isn't lost.
    @Test func aHiddenIslandLeavesTheSystemNotification() {
        let (island, _) = island { $0.replaceNotifications = true }
        #expect(!island.notification(id: "a", kind: .waiting, title: "t", body: "", target: .none))
    }

    // MARK: A session that finished

    @Test func onlyAFinishedSessionGetsABanner() throws {
        let (island, _) = island { $0.liveActivity = false }
        // The first look: sessions that were done before don't count.
        island.noticeFinished([try item("old", .done), try item("s", .running)])
        #expect(island.queue.items.isEmpty)
        island.noticeFinished([try item("old", .done), try item("s", .done)])
        #expect(island.queue.items.map(\.id) == ["done-s"])
    }

    @Test func aFinishedSessionRespectsTheSwitches() throws {
        let (off, _) = island { $0.liveActivity = false; $0.events = [.request] }
        off.noticeFinished([try item("s", .running)])
        off.noticeFinished([try item("s", .done)])
        #expect(off.queue.items.isEmpty)

        let (full, _) = island(fullScreen: true) { $0.liveActivity = false }
        full.noticeFinished([try item("s", .running)])
        full.noticeFinished([try item("s", .done)])
        #expect(full.queue.items.isEmpty)
    }

    // MARK: A dropped file

    @Test func dropsTakeFilesOnly() throws {
        let (island, _) = island()
        let web = try #require(URL(string: "https://example.com"))
        #expect(!island.drop([web], on: 0))
        #expect(!island.drop([URL(fileURLWithPath: "/tmp/a.md")], on: 5))
        #expect(!island.isOpen)
        #expect(island.drop([web, URL(fileURLWithPath: "/tmp/a.md"), URL(fileURLWithPath: "/tmp/b.md")], on: 0))
        #expect(island.dropped?.lastPathComponent == "a.md")
        #expect(island.openIndex == 0)
    }

    @Test func dropsCanBeSwitchedOff() {
        let (island, _) = island { $0.fileDrop = false }
        #expect(!island.drop([URL(fileURLWithPath: "/tmp/a.md")], on: 0))
        #expect(!island.dragOver(CGPoint(x: notch.midX, y: notch.minY), on: 0))
        #expect(island.dropTarget == nil)
    }

    @Test func aDragLightsTheIslandOnlyOverTheZone() {
        let (island, _) = island()
        #expect(island.dragOver(CGPoint(x: notch.midX, y: notch.minY - 10), on: 0))
        #expect(island.dropTarget == 0)
        #expect(!island.dragOver(CGPoint(x: 10, y: 10), on: 0))
        #expect(island.dropTarget == nil)
        _ = island.dragOver(CGPoint(x: notch.midX, y: notch.minY - 10), on: 0)
        #expect(!island.dragOver(nil, on: 0))
        #expect(island.dropTarget == nil)
    }

    @Test func closingForgetsTheDroppedFile() {
        let (island, _) = island()
        _ = island.drop([URL(fileURLWithPath: "/tmp/a.md")], on: 0)
        island.close()
        #expect(island.dropped == nil)
        #expect(!island.isOpen)
    }

    @Test func aStartedCommandClosesTheCardWithABanner() {
        let (island, _) = island()
        island.open(on: 0)
        island.started("Корректура", file: "a.md")
        #expect(!island.isOpen)
        #expect(island.banner?.kind == .commands)
        #expect(island.banner?.body == "a.md")
    }

    // MARK: The card

    @Test func aScreenThatIsGoneOpensNothing() {
        let (island, _) = island()
        island.open(on: 3)
        #expect(!island.isOpen)
    }

    @Test func openingALinkRemovesABannerButNotARequest() {
        let (island, decisions) = island()
        let event = request(), other = banner()
        _ = island.queue.syncRequests([event])
        island.queue.push(other)
        island.openTarget(of: event)
        #expect(island.queue.items.contains { $0.id == event.id })
        island.openTarget(of: other)
        #expect(!island.queue.items.contains { $0.id == other.id })
        #expect(decisions.all.count == 2)
    }
}
