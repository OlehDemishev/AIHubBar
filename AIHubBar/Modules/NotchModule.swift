import AppKit
import SwiftUI

// «Остров у чёлки» (docs/specs/SPEC-refactor.md §3): what the module is, its Settings sections and its «Панель сейчас» line.

extension ModuleDefinition {
    static let notch = ModuleDefinition(
        kind: .notch,
        group: .mac,
        symbol: "laptopcomputer",
        title: String(localized: "Остров у чёлки"),
        summary: String(localized: "Чёрный остров вокруг чёлки MacBook: запросы, события и по наведению карточка с лимитами и тем, что делает Claude."),
        tagline: String(localized: "Запросы и лимиты у чёлки"),
        isPanelBlock: false,
        places: [],
        keywords: [String(localized: "Скрыть остров"), String(localized: "Слева от чёлки"), String(localized: "Справа от чёлки")]
    )
}

extension ModuleUI {
    static let notch = ModuleUI(
        settings: { AnyView(NotchSection()) },
        sketch: nil
    )
}

/// «Остров у чёлки» (SPEC-notch §6): what the ears show and how the card opens.
struct NotchSection: View {
    @Environment(AppSettings.self) private var settings

    static var earsHint: String { String(localized: "Ушки видны на экране с чёлкой и со сводкой «только в острове».") }

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle("Скрыть остров", systemImage: "eye.slash", isOn: $settings.notch.hidden)
            Picker("Сводка — лимиты и сессии", systemImage: "rectangle.split.2x1", selection: $settings.notch.summary) {
                ForEach(NotchSummary.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Где показывать", systemImage: "display", selection: $settings.notch.screen) {
                ForEach(NotchScreen.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Пилюля на экранах без чёлки", systemImage: "capsule", isOn: Binding(
                get: { settings.notch.showsPill(macHasNotch: NotchGeometry.macHasNotch) },
                set: { settings.notch.pill = $0 }
            ))
        } footer: {
            Footnote(text: String(localized: "«Только в острове»: в строке меню остаются значок и красная точка проектов, лимиты и сессии — в ушках у чёлки. Пилюля — чёрный остров под строкой меню по центру, только для событий и запросов: у неё нет ушек, поэтому сводка тогда остаётся в строке меню. Скрытый остров ничего не показывает, уведомления приходят как обычно."))
        }
        Section {
            Group {
                Picker("Слева от чёлки", systemImage: "arrow.left.to.line", selection: $settings.notch.leftEar) {
                    ForEach(NotchEar.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Справа от чёлки", systemImage: "arrow.right.to.line", selection: $settings.notch.rightEar) {
                    ForEach(NotchEar.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            .disabled(settings.notch.summary == .menuBar)
            .help(Self.earsHint)
            Toggle("Открывать карточку при наведении", systemImage: "cursorarrow.motionlines", isOn: $settings.notch.openOnHover)
            Toggle("Файл на остров — AI-команды", systemImage: "doc.badge.arrow.up", isOn: $settings.notch.fileDrop)
                .help("Перетащите файл или папку на чёлку: команды профиля и «Своя задача» для него, результат — новым файлом рядом.")
            Toggle("Ход работы Claude в ушке сессий", systemImage: "list.bullet.clipboard", isOn: $settings.notch.liveActivity)
                .help("Кольцо и «3/7» по списку задач Claude, шаги в карточке, итог в «Готово». Без списка — минуты с начала ответа.")
            Toggle("Горячие клавиши ⌃⌥Y / ⌃⌥N для запросов", systemImage: "keyboard", isOn: $settings.notch.hotKeys)
                .onChange(of: settings.notch.hotKeys) { GlobalHotKey.registerIsland(settings.notch.hotKeys) }
                .help("Разрешить или отклонить запрос, который сейчас в острове. Клавишей легко разрешить, не прочитав команду.")
        } header: {
            Text("Ушки и карточка")
        } footer: {
            Footnote(text: NotchGeometry.macHasNotch
                ? String(localized: "Без наведения карточка открывается кликом по чёлке. В покое остров пропускает клики к строке меню.")
                : String(localized: "На этом Маке сейчас нет экрана с чёлкой: остров появится, когда она будет (например, на встроенном экране MacBook)."))
        }
        Section {
            ForEach(NotchEventKind.allCases, id: \.self) { kind in
                Toggle(isOn: Binding(
                    get: { settings.notch.events.contains(kind) },
                    set: { on in
                        settings.notch.events = NotchEventKind.allCases.filter { $0 == kind ? on : settings.notch.events.contains($0) }
                    }
                )) {
                    Label(kind.title, systemImage: kind.symbol)
                }
            }
            Toggle("Запросы и ожидание — только в острове", systemImage: "bell.slash", isOn: $settings.notch.replaceNotifications)
        } header: {
            Text("События в острове")
        } footer: {
            Footnote(text: String(localized: "Событие ненадолго раскрывает остров; запрос разрешения держится, пока на него не ответят. «Только в острове»: пока остров виден, уведомление о запросе или ожидании не приходит; если острова не видно (экран спит, Мак заблокирован, полноэкранное приложение), уведомление придёт как обычно. Telegram — без изменений."))
        }
    }
}
