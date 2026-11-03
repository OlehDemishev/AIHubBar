import Foundation
import Testing
@testable import AIHubBar

/// docs/specs/SPEC-refactor.md §3: one definition per module, and the definitions agree with themselves — a place shown on
/// a module's page always has something behind it.
struct ModuleRegistryTests {
    @Test func everyModuleIsDefinedOnce() {
        #expect(ModuleDefinition.all.map(\.kind).sorted { $0.rawValue < $1.rawValue } == ModuleKind.allCases.sorted { $0.rawValue < $1.rawValue })
        for kind in ModuleKind.allCases {
            #expect(kind.definition.kind == kind)
            #expect(!kind.title.isEmpty && !kind.summary.isEmpty && !kind.tagline.isEmpty && !kind.symbol.isEmpty)
        }
    }

    /// The sidebar keeps the order it had before the registry.
    @Test func sidebarOrder() {
        #expect(ModuleGroup.ai.modules == [.limits, .sessions, .quickPrompt, .telegram])
        #expect(ModuleGroup.work.modules == [.upcoming, .projects, .reports, .quickCommands, .notes, .clipboard])
        #expect(ModuleGroup.mac.modules == [.resources, .keepAwake, .toggles, .layout, .notch])
    }

    @Test func placesHaveSomethingBehindThem() {
        for definition in ModuleDefinition.all {
            let places = Set(definition.places)
            let name = definition.kind.rawValue
            #expect(places.contains(.panel) == definition.isPanelBlock, "\(name): panel place ⇔ panel block")
            #expect(places.contains(.menuBar) == (!definition.menuBarKinds.isEmpty || definition.ownMenuBarItem), "\(name): menu bar")
            #expect(Set(definition.primaryMenuBarKinds).isSubset(of: definition.menuBarKinds), "\(name): primary elements are its own")
            #expect(places.contains(.island) == (definition.island != nil), "\(name): island")
            #expect(places.contains(.telegram) == (definition.telegram != nil), "\(name): Telegram")
            let owned = definition.notifications.filter { $0.module == definition.kind }
            #expect(places.contains(.notifications) == !owned.isEmpty, "\(name): notifications")
            if definition.bringIn != nil { #expect(definition.isBuiltIn, "\(name): only built-in modules are brought in") }
        }
    }

    /// Each menu bar element and each notification kind belongs to one module at most.
    @Test func ownershipIsUnique() {
        for kind in MenuBarElement.Kind.allCases {
            #expect(ModuleDefinition.all.filter { $0.menuBarKinds.contains(kind) }.count <= 1, "\(kind)")
        }
        #expect(MenuBarElement.Kind.icon.module == nil && MenuBarElement.Kind.disk.module == nil && MenuBarElement.Kind.mode.module == nil)
        #expect(MenuBarElement.Kind.cpu.module == .resources && MenuBarElement.Kind.forecast.module == .limits)
        #expect(NotificationKind.commands.module == nil, "command results belong to two modules")
        #expect(NotificationKind.of(.quickCommands) == [.commands] && NotificationKind.of(.reports) == [.commands])
        #expect(NotificationKind.context.module == .sessions && NotificationKind.calendar.module == .upcoming)
    }

    @Test func flagsAsBefore() {
        #expect(ModuleKind.allCases.filter(\.isBuiltIn) == [.limits, .sessions, .upcoming, .projects, .reports])
        #expect(ModuleKind.allCases.filter(\.isBeta) == [.layout])
        #expect(ModuleKind.allCases.filter { !$0.isPanelBlock } == [.notch, .layout, .quickPrompt, .telegram])
        #expect(ModuleKind.upcoming.definition.bringIn == .calendar && ModuleKind.projects.definition.bringIn == .profilePage)
    }
}
