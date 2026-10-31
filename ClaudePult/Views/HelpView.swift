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
        Section(title: String(localized: "Строка меню"), systemImage: "menubar.rectangle", items: [
            Item(name: "✦", detail: String(localized: "Клик — панель. Красная точка: у какого-то проекта состояние «красное». ✋ с числом: сколько сессий Claude ждут ответа.")),
            Item(name: String(localized: "Что показывать"), detail: String(localized: "Настройки → «Строка меню»: набор («Минимум», «Лимиты», «Всё», «Свой»), элементы и их порядок (лимиты числом, кольцом или полоской, отсчёт до сброса, прогноз, работающие сессии, фоновые задачи, очередь, место на диске, профиль), разделитель, мелкий текст, цвет. Сверху — живой предпросмотр.")),
            Item(name: "⌘R", detail: String(localized: "Обновить проекты в открытой панели.")),
            Item(name: "⌘,", detail: String(localized: "Настройки.")),
            Item(name: "⌘Q", detail: String(localized: "Выйти из AI Hub Bar.")),
            Item(name: String(localized: "Профили"), detail: String(localized: "Если включено больше одного профиля, вверху панели — переключатель. Профили настраиваются в Настройках → «Профили»; все настройки сохраняются в файл .claudepult (Основные → «Экспорт настроек…»), двойной клик по такому файлу — импорт.")),
        ]),
        Section(title: String(localized: "Лимиты подписки"), systemImage: "gauge.with.dots.needle.33percent", items: [
            Item(name: String(localized: "У значка"), detail: String(localized: "% 5-часовой сессии и недели — числом, кольцом или полоской (Настройки → «Строка меню»): зелёный до 50 %, оранжевый до 80 %, красный выше.")),
            Item(name: String(localized: "Блок «Лимиты»"), detail: String(localized: "Сессия с обратным отсчётом до сброса и прогнозом по темпу за 30 мин, неделя, недели по моделям, extra usage.")),
            Item(name: String(localized: "Расход по проектам"), detail: String(localized: "Оценка по журналам Claude Code: доли проектов и самая затратная сессия за сессию, сегодня, неделю.")),
            Item(name: String(localized: "Уведомления"), detail: String(localized: "Один раз на окно при 50/80/95 % (пороги — в Настройках) и когда лимит восстановился; по желанию ещё и в Telegram.")),
            Item(name: String(localized: "Виджет"), detail: String(localized: "«Лимиты Claude» для рабочего стола: правый клик по столу → «Изменить виджеты…» → AI Hub Bar. Маленький — кольцо сессии, средний — сессия и неделя.")),
            Item(name: String(localized: "Фон и лимит"), detail: String(localized: "Если сессия использована больше чем на 90 %, фоновая задача спрашивает: запустить сейчас или после сброса.")),
        ]),
        Section(title: String(localized: "Шаблоны"), systemImage: "square.stack.3d.up", items: [
            Item(name: String(localized: "Помощник"), detail: String(localized: "Настройки → «Профили» → «+» → «Помощник…»: профиль по шагам — шаблон, папка, этапы, метрики, календарь, сервис AI, команды, права, блоки панели, строка меню, название. Справа — как это будет выглядеть.")),
            Item(name: String(localized: "Добавить профиль"), detail: String(localized: "Настройки → «Профили» → «+»: «Разработчик (GitHub)», «Видео», «Тексты», «Ресёрч», «Соцсети», «Свой». Выберите папку — профиль готов, дальше всё правится в его настройках.")),
            Item(name: String(localized: "Разработчик (GitHub)"), detail: String(localized: "Встроенный сканер git: ветки, незакоммиченное, stash, PR и CI (если есть gh), шапка STATUS.md. Промты Claude — по правилам самого проекта (CLAUDE.md / AGENTS.md).")),
        ]),
        Section(title: String(localized: "Проекты-папки"), systemImage: "folder.badge.gearshape", items: [
            Item(name: String(localized: "Источник «папки»"), detail: String(localized: "Настройки → «Профили» → «Источник»: каждая папка внутри папки проектов — проект (ролик, статья, тема).")),
            Item(name: String(localized: "проект.md"), detail: String(localized: "Карточка проекта — обычный текст: «Этап: сценарий», «Дедлайн: 2026-11-05», «Публикация: 2026-11-05 18:00», «Формат: …», «Главный файл: сценарий.md», «Площадка: YouTube». Можно править руками.")),
            Item(name: String(localized: "Команды"), detail: String(localized: "В развёрнутом проекте: команды профиля и «Своя задача». Результат — всегда новый файл в папке проекта. Модель по API получает текст главного файла; Claude работает в фоне с правами профиля («только файлы» — без терминала и интернета); другие агенты открываются в Терминале, задача — в буфере обмена.")),
            Item(name: String(localized: "Сравнить"), detail: String(localized: "Включите «Сравнить», выберите 2–3 сервиса и команду: результаты лягут рядом («хуки (Claude).md», «хуки (OpenAI).md») и откроются в окне «Сравнение».")),
            Item(name: String(localized: "Этапы и метрики"), detail: String(localized: "Этапы профиля — через запятую; этап меняется кнопкой в развёрнутом проекте. Слова, хронометраж, время чтения и страницы считаются по главному файлу (.md, .txt, .rtf, .docx).")),
        ]),
        Section(title: String(localized: "Календарь"), systemImage: "calendar", items: [
            Item(name: String(localized: "Что в нём"), detail: String(localized: "Дедлайны и публикации из проект.md, записи контент-план.md — у профилей, где «Календарь» включён (Настройки → «Профили»).")),
            Item(name: String(localized: "Ближайшее"), detail: String(localized: "Блок в панели: 7 дней вперёд, просроченное красным; клик открывает проект или файл.")),
            Item(name: String(localized: "Окно «Календарь»"), detail: String(localized: "Месяц или неделя. Перетащите запись на другой день — дата перепишется в файле. Двойной клик по дню — новая запись.")),
            Item(name: String(localized: "Напоминания"), detail: String(localized: "Настройки → «Основные» → «Календарь»: за сколько напоминать и дублировать ли в Telegram.")),
        ]),
        Section(title: String(localized: "Сервисы AI"), systemImage: "cpu", items: [
            Item(name: String(localized: "Агенты"), detail: String(localized: "Codex CLI, Gemini CLI, Antigravity, Copilot CLI, Cursor CLI — AI Hub Bar находит установленные (Настройки → «Сервисы AI») и открывает их в Терминале в папке проекта: «Открыть в…» в блоке Claude у проекта. Вход у каждого свой.")),
            Item(name: String(localized: "Модели по API"), detail: String(localized: "Anthropic, OpenAI, Google, xAI, DeepSeek, Mistral и любой сервер, совместимый с OpenAI (Ollama, LM Studio, OpenRouter). Ключ — только в связке ключей macOS; «Проверить» не тратит токены.")),
            Item(name: String(localized: "Сервис профиля"), detail: String(localized: "Настройки → «Профили» → «Сервис по умолчанию»: им будут выполняться команды-шаблоны профиля.")),
        ]),
        Section(title: String(localized: "Сессии Claude Code"), systemImage: "bubble.left.and.text.bubble.right", items: [
            Item(name: String(localized: "Список"), detail: String(localized: "Все сессии на этом Маке — в Терминале, в приложении Claude, фоновые: проект, worktree, задача, длительность, состояние (работает, в фоне, ждёт ответа, готово, ошибка, завершена). Ждущие ответа подсвечены и приходят уведомлением.")),
            Item(name: String(localized: "Показать"), detail: String(localized: "Вывести вкладку Терминала с этой сессией; для сессий приложения Claude — открыть эту сессию в Claude, иначе — папку.")),
            Item(name: String(localized: "Журнал"), detail: String(localized: "Фоновая задача: что делает Claude, по шагам.")),
            Item(name: String(localized: "Остановить"), detail: String(localized: "Фоновая задача: остановить сейчас.")),
            Item(name: "Hooks", detail: String(localized: "Сессии видны, только если в Настройках установлены hooks (они дописываются в ~/.claude/settings.json, копия сохраняется рядом).")),
        ]),
        Section(title: String(localized: "Проекты"), systemImage: "folder", items: [
            Item(name: String(localized: "Строка"), detail: String(localized: "Точка состояния, ветка, незакоммиченные файлы, открытые PR (цвет — CI), когда была активность.")),
            Item(name: String(localized: "Раскрыть"), detail: String(localized: "Stage, Сейчас, Дальше, Нужно от вас из docs/STATUS.md, предупреждения, PR, worktree.")),
            Item(name: String(localized: "Следующий шаг"), detail: String(localized: "Claude берёт первый пункт Next и делает его по правилам ~/Projects/CLAUDE.md: ветка, проверки, PR, STATUS.")),
            Item(name: String(localized: "Своя задача…"), detail: String(localized: "Claude выполняет ваш текст по тем же правилам.")),
            Item(name: String(localized: "Завершить"), detail: String(localized: "Claude доводит текущую работу в папке: проверки, коммит, push, PR, STATUS — без нового кода.")),
            Item(name: String(localized: "Терминал / Фон"), detail: String(localized: "Где запускать: окно Терминала (можно отвечать Claude) или claude -p без окна (только разрешённые действия, лимит времени, итог — уведомлением и в Telegram). «Запомнить выбор» или профиль по умолчанию — в Настройках.")),
            Item(name: String(localized: "Занятая папка"), detail: String(localized: "Если в проекте уже работает Claude, новая задача идёт в отдельный worktree .claude/worktrees/cb-… на свежей ветке от origin/main.")),
            Item(name: String(localized: "Терминал · Finder · GitHub"), detail: String(localized: "Открыть папку проекта или репозиторий.")),
            Item(name: String(localized: "Удалить worktree"), detail: String(localized: "Только если в нём нет незакоммиченного и ветка запушена или влита.")),
        ]),
        Section(title: String(localized: "Команды"), systemImage: "terminal", items: [
            Item(name: String(localized: "Отчёт сейчас"), detail: String(localized: "Отчёт с AI-резюме за 24 ч в Telegram (1–3 мин).")),
            Item(name: String(localized: "Быстрая сводка"), detail: String(localized: "Сводка без AI за 24 ч в Telegram.")),
            Item(name: String(localized: "Последний отчёт"), detail: String(localized: "Открыть _daily-report/reports/latest.html.")),
            Item(name: String(localized: "Очистка: проверить"), detail: String(localized: "Показать, что удалит очистка сборок, ничего не трогая.")),
            Item(name: String(localized: "Очистка: выполнить"), detail: String(localized: "Удалить сборки и кэши, сбросить симуляторы (с подтверждением).")),
            Item(name: String(localized: "Диск"), detail: String(localized: "Свободное место; меньше 20 ГБ — оранжевым.")),
        ]),
        Section(title: String(localized: "Для скриптов"), systemImage: "chevron.left.forwardslash.chevron.right", items: [
            Item(name: String(localized: "--claude next|task|finish <папка>"), detail: String(localized: "Запустить команду Claude (--background — в фоне, --print — только показать).")),
            Item(name: "--command report|summary|cleanup-check|cleanup", detail: String(localized: "Общая команда.")),
            Item(name: "--sessions · --show-session <id>", detail: String(localized: "Список сессий; показать вкладку Терминала.")),
            Item(name: "--hooks status|install|uninstall", detail: String(localized: "Hooks сессий.")),
            Item(name: "--login-item status|on|off", detail: String(localized: "Автозапуск при входе.")),
            Item(name: "--background-settings", detail: String(localized: "Правила доступа фоновых задач.")),
            Item(name: "--usage · --token-usage", detail: String(localized: "Лимиты подписки; расход по проектам.")),
        ]),
    ]

    static let binary = "~/Applications/AI\\ Hub\\ Bar.app/Contents/MacOS/AIHubBar"
}

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Готовность", systemImage: "checklist").font(.headline)
                    ReadinessSection(collapsesWhenReady: true)
                }
                ForEach(HelpContent.sections) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(section.title, systemImage: section.systemImage)
                            .font(.headline)
                        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 6) {
                            ForEach(section.items) { item in
                                GridRow {
                                    Text(item.name)
                                        .fontWeight(.medium)
                                        .font(section.title == String(localized: "Для скриптов") ? .callout.monospaced() : .callout)
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
