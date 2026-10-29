import SwiftUI

/// Everything ClaudePult can do, for the «Помощь» window (docs/SPEC.md §2.7).
enum HelpContent {
    struct Item: Identifiable {
        var name: String
        var detail: String
        var id: String { name }
    }

    struct Section: Identifiable {
        var title: String
        var systemImage: String
        var items: [Item]
        var id: String { title }
    }

    static let sections: [Section] = [
        Section(title: "Строка меню", systemImage: "menubar.rectangle", items: [
            Item(name: "✦", detail: "Клик — панель. Красная точка: у какого-то проекта состояние «красное». Число рядом: сколько сессий Claude ждут ответа."),
            Item(name: "⌘R", detail: "Обновить проекты в открытой панели."),
            Item(name: "⌘,", detail: "Настройки."),
            Item(name: "⌘Q", detail: "Выйти из ClaudePult."),
        ]),
        Section(title: "Лимиты подписки", systemImage: "gauge.with.dots.needle.33percent", items: [
            Item(name: "У значка", detail: "% 5-часовой сессии (или сессии и недели, или кольцо — в Настройках): зелёный до 50 %, оранжевый до 80 %, красный выше."),
            Item(name: "Блок «Лимиты»", detail: "Сессия с обратным отсчётом до сброса и прогнозом по темпу за 30 мин, неделя, недели по моделям, extra usage."),
            Item(name: "Расход по проектам", detail: "Оценка по журналам Claude Code: доли проектов и самая затратная сессия за сессию, сегодня, неделю."),
            Item(name: "Уведомления", detail: "Один раз на окно при 50/80/95 % (пороги — в Настройках) и когда лимит восстановился; по желанию ещё и в Telegram."),
            Item(name: "Фон и лимит", detail: "Если сессия использована больше чем на 90 %, фоновая задача спрашивает: запустить сейчас или после сброса."),
        ]),
        Section(title: "Сессии Claude Code", systemImage: "bubble.left.and.text.bubble.right", items: [
            Item(name: "Список", detail: "Все сессии на этом Маке — в Терминале, в приложении Claude, фоновые: проект, worktree, задача, длительность, состояние (работает, в фоне, ждёт ответа, готово, ошибка, завершена). Ждущие ответа подсвечены и приходят уведомлением."),
            Item(name: "Показать", detail: "Вывести вкладку Терминала с этой сессией; для сессий приложения Claude — открыть Claude, иначе — папку."),
            Item(name: "Журнал", detail: "Фоновая задача: что делает Claude, по шагам."),
            Item(name: "Остановить", detail: "Фоновая задача: остановить сейчас."),
            Item(name: "Hooks", detail: "Сессии видны, только если в Настройках установлены hooks (они дописываются в ~/.claude/settings.json, копия сохраняется рядом)."),
        ]),
        Section(title: "Проекты", systemImage: "folder", items: [
            Item(name: "Строка", detail: "Точка состояния, ветка, незакоммиченные файлы, открытые PR (цвет — CI), когда была активность."),
            Item(name: "Раскрыть", detail: "Stage, Сейчас, Дальше, Нужно от Олега из docs/STATUS.md, предупреждения, PR, worktree."),
            Item(name: "Следующий шаг", detail: "Claude берёт первый пункт Next и делает его по правилам ~/Projects/CLAUDE.md: ветка, проверки, PR, STATUS."),
            Item(name: "Своя задача…", detail: "Claude выполняет ваш текст по тем же правилам."),
            Item(name: "Завершить", detail: "Claude доводит текущую работу в папке: проверки, коммит, push, PR, STATUS — без нового кода."),
            Item(name: "Терминал / Фон", detail: "Где запускать: окно Терминала (можно отвечать Claude) или claude -p без окна (только разрешённые действия, лимит времени, итог — уведомлением и в Telegram). «Запомнить выбор» или режим по умолчанию — в Настройках."),
            Item(name: "Занятая папка", detail: "Если в проекте уже работает Claude, новая задача идёт в отдельный worktree .claude/worktrees/cb-… на свежей ветке от origin/main."),
            Item(name: "Терминал · Finder · GitHub", detail: "Открыть папку проекта или репозиторий."),
            Item(name: "Удалить worktree", detail: "Только если в нём нет незакоммиченного и ветка запушена или влита."),
        ]),
        Section(title: "Команды", systemImage: "terminal", items: [
            Item(name: "Отчёт сейчас", detail: "Отчёт с AI-резюме за 24 ч в Telegram (1–3 мин)."),
            Item(name: "Быстрая сводка", detail: "Сводка без AI за 24 ч в Telegram."),
            Item(name: "Последний отчёт", detail: "Открыть _daily-report/reports/latest.html."),
            Item(name: "Очистка: проверить", detail: "Показать, что удалит очистка сборок, ничего не трогая."),
            Item(name: "Очистка: выполнить", detail: "Удалить сборки и кэши, сбросить симуляторы (с подтверждением)."),
            Item(name: "Диск", detail: "Свободное место; меньше 20 ГБ — оранжевым."),
        ]),
        Section(title: "Для скриптов", systemImage: "chevron.left.forwardslash.chevron.right", items: [
            Item(name: "--claude next|task|finish <папка>", detail: "Запустить команду Claude (--background — в фоне, --print — только показать)."),
            Item(name: "--command report|summary|cleanup-check|cleanup", detail: "Общая команда."),
            Item(name: "--sessions · --show-session <id>", detail: "Список сессий; показать вкладку Терминала."),
            Item(name: "--hooks status|install|uninstall", detail: "Hooks сессий."),
            Item(name: "--login-item status|on|off", detail: "Автозапуск при входе."),
            Item(name: "--background-settings", detail: "Правила доступа фоновых задач."),
            Item(name: "--usage · --token-usage", detail: "Лимиты подписки; расход по проектам."),
        ]),
    ]

    static let binary = "~/Applications/ClaudePult.app/Contents/MacOS/ClaudePult"
}

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(HelpContent.sections) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(section.title, systemImage: section.systemImage)
                            .font(.headline)
                        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 6) {
                            ForEach(section.items) { item in
                                GridRow {
                                    Text(item.name)
                                        .fontWeight(.medium)
                                        .font(section.title == "Для скриптов" ? .callout.monospaced() : .callout)
                                        .frame(width: 200, alignment: .leading)
                                    Text(item.detail)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                Text("Команды для скриптов вызываются так: \(HelpContent.binary) --sessions")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 620, minHeight: 480)
    }
}
