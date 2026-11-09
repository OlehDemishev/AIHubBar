import SwiftUI

/// The «Справка» window's topics (docs/specs/SPEC-help.md): what each part of AI Hub Bar does, how to set it up, and where.
/// Texts that were already in the old help and are still true keep their wording, so their translations stay.
enum HelpTopic: String, CaseIterable, Identifiable, Sendable {
    case start, menuBar, panel, modules
    case limits, sessions, services
    case projects, calendar, reports
    case notch, layout, utilities
    case alerts, commandLine

    var id: String { rawValue }

    /// The sidebar sections, in order.
    static let groups: [(title: String, topics: [HelpTopic])] = [
        (String(localized: "Основы"), [.start, .menuBar, .panel, .modules]),
        ("AI", [.limits, .sessions, .services]),
        (String(localized: "Работа"), [.projects, .calendar, .reports]),
        ("Mac", [.notch, .layout, .utilities]),
        (String(localized: "Ещё"), [.alerts, .commandLine]),
    ]

    var title: String {
        switch self {
        case .start: String(localized: "Начало")
        case .menuBar: String(localized: "Строка меню")
        case .panel: String(localized: "Панель")
        case .modules: String(localized: "Модули и профили")
        case .limits: ModuleKind.limits.title
        case .sessions: ModuleKind.sessions.title
        case .services: String(localized: "Сервисы AI")
        case .projects: String(localized: "Проекты")
        case .calendar: String(localized: "Ближайшее и календарь")
        case .reports: ModuleKind.reports.title
        case .notch: ModuleKind.notch.title
        case .layout: ModuleKind.layout.title
        case .utilities: String(localized: "Утилиты Mac")
        case .alerts: String(localized: "Уведомления и Telegram")
        case .commandLine: String(localized: "Для скриптов")
        }
    }

    var symbol: String {
        switch self {
        case .start: "sparkles"
        case .menuBar: "menubar.rectangle"
        case .panel: "rectangle.stack"
        case .modules: "square.grid.2x2"
        case .limits: ModuleKind.limits.symbol
        case .sessions: ModuleKind.sessions.symbol
        case .services: "cpu"
        case .projects: "folder"
        case .calendar: "calendar"
        case .reports: ModuleKind.reports.symbol
        case .notch: ModuleKind.notch.symbol
        case .layout: ModuleKind.layout.symbol
        case .utilities: "wrench.and.screwdriver"
        case .alerts: "bell.badge"
        case .commandLine: "chevron.left.forwardslash.chevron.right"
        }
    }

    var tint: Color {
        switch self {
        case .start, .menuBar, .panel, .modules: .blue
        case .limits, .sessions, .services: ModuleGroup.ai.tint
        case .projects, .calendar, .reports: ModuleGroup.work.tint
        case .notch, .layout, .utilities: ModuleGroup.mac.tint
        case .alerts, .commandLine: .gray
        }
    }

    var isBeta: Bool { false }

    /// One or two sentences under the title.
    var summary: String {
        switch self {
        case .start: String(localized: "AI Hub Bar держит под рукой лимиты AI, сессии агентов и ваши проекты — в строке меню Mac, в один клик.")
        case .menuBar: String(localized: "Значок и числа рядом с часами: лимиты, ждущие ответа сессии, проблемы проектов — всё, что вы туда поставите.")
        case .panel: String(localized: "Панель открывается по клику на ✦: блоки модулей текущего профиля сверху вниз и поиск.")
        case .modules: String(localized: "Модуль — одна возможность AI Hub Bar. Профиль решает, какие модули видны в панели и в каком порядке.")
        case .limits: String(localized: "Сколько осталось от 5-часовой сессии и недели подписки Claude — и от лимитов других AI.")
        case .sessions: String(localized: "Все сессии Claude Code на этом Mac: что делают, кто ждёт ответа, фоновые задачи и очередь.")
        case .services: String(localized: "Агенты и модели, которые AI Hub Bar находит и запускает: Claude Code, Codex, Gemini, Copilot, Cursor и модели по API.")
        case .projects: String(localized: "Проекты профиля: git-репозитории или папки с работой — состояние, PR, этапы и команды для AI.")
        case .calendar: String(localized: "Дедлайны и публикации из карточек проектов и контент-плана — на неделю вперёд и в окне «Календарь».")
        case .reports: ModuleKind.reports.summary
        case .notch: ModuleKind.notch.summary
        case .layout: ModuleKind.layout.summary
        case .utilities: String(localized: "Ресурсы Mac, «Не спать», быстрые переключатели, история буфера, заметки и свои команды — каждое включается отдельно.")
        case .alerts: String(localized: "Что приходит уведомлением macOS и в Telegram, и как часто.")
        case .commandLine: String(localized: "AI Hub Bar отвечает и из Терминала — для скриптов и автоматизаций.")
        }
    }

    /// «Как начать»: numbered steps.
    var steps: [String] {
        switch self {
        case .start:
            [String(localized: "Нажмите ✦ в строке меню — откроется панель."),
             String(localized: "Создайте профиль: Настройки → «Профили» → «+» → «Помощник…»."),
             String(localized: "На странице «Модули» оставьте только нужное — остальное выключится вместе с фоновой работой."),
             String(localized: "В «Строке меню» соберите, что видно рядом со значком.")]
        case .menuBar:
            [String(localized: "Откройте Настройки → «Строка меню»."),
             String(localized: "Кликните элемент в «Порядке» — появятся его настройки: число, кольцо или полоска, порог."),
             String(localized: "Перетащите разделитель на элемент — он встанет сразу после него. Без мыши — «Левее» и «Правее».")]
        case .panel:
            [String(localized: "Откройте Настройки → «Панель»."),
             String(localized: "Перетащите блок на другой или нажмите ⌃ / ⌄."),
             String(localized: "Справа видно, как панель выглядит сейчас.")]
        case .modules:
            [String(localized: "Настройки → «Модули»: включите набор («Только AI», «Утилиты Mac», «Всё») или отдельные плитки."),
             String(localized: "Клик по плитке — страница модуля: выключатель, «Где показывать» и все его настройки.")]
        case .limits:
            [String(localized: "Пороги уведомлений — на странице «Лимиты AI»."),
             String(localized: "Другие AI подключаются в «Сервисы AI»: вход в их CLI или ключ API.")]
        case .sessions:
            [String(localized: "Включите отслеживание на странице «Сессии агентов»."),
             String(localized: "Отвечайте на запросы разрешений прямо из уведомления или строки сессии.")]
        case .services:
            [String(localized: "Настройки → «Сервисы AI»: зелёная точка — сервис найден или настроен.")]
        case .projects:
            [String(localized: "Настройки → «Профили» → профиль → «Источник»: папка с проектами.")]
        case .calendar:
            [String(localized: "Включите календарь в профиле — или кнопкой «Включить в профиле» на плитке «Ближайшее».")]
        case .notch:
            [String(localized: "Включите «Остров у чёлки» на странице «Модули».")]
        case .layout:
            [String(localized: "Включите «Раскладку» на странице «Модули».")]
        case .reports, .utilities, .alerts, .commandLine:
            []
        }
    }

    /// What the topic explains, in groups.
    var sections: [HelpSection] {
        switch self {
        case .start:
            [HelpSection(facts: [
                HelpFact("⌘R", String(localized: "Обновить проекты в открытой панели.")),
                HelpFact("⌘,", String(localized: "Настройки.")),
                HelpFact("⌘Q", String(localized: "Выйти из AI Hub Bar.")),
                HelpFact(String(localized: "Профили"), String(localized: "Если включено больше одного профиля, вверху панели — переключатель. Профили настраиваются в Настройках → «Профили»; все настройки сохраняются в файл .claudepult (Основные → «Экспорт настроек…»), двойной клик по такому файлу — импорт."), symbol: "square.stack.3d.up"),
            ])]
        case .menuBar:
            [HelpSection(facts: [
                HelpFact("✦", String(localized: "Клик — панель. Красная точка: у какого-то проекта состояние «красное». ✋ с числом: сколько сессий Claude ждут ответа.")),
                HelpFact(String(localized: "У значка"), String(localized: "% 5-часовой сессии и недели — числом, кольцом или полоской (Настройки → «Строка меню»): зелёный до 50 %, оранжевый до 80 %, красный выше."), symbol: "gauge.with.dots.needle.33percent"),
                HelpFact(String(localized: "Разделители"), String(localized: "Пробел, широкий пробел, «·», «|», тонкая линия, «/», «›» и «Новая группа» — сколько угодно раз. Видны, только когда с обеих сторон есть что показать."), symbol: "poweron"),
                HelpFact(String(localized: "Капсулы по группам"), String(localized: "Элементы между «Новыми группами» рисуются на общей скруглённой подложке."), symbol: "capsule"),
                HelpFact(String(localized: "У каждого профиля своя"), String(localized: "Переключили профиль — сменилась и строка меню."), symbol: "square.stack.3d.up"),
            ])]
        case .panel:
            [HelpSection(facts: [
                HelpFact(String(localized: "Поиск"), String(localized: "Поле сверху панели ищет проекты, сессии, команды и свои промпты. Открыть с клавиатуры — сочетание в «Основных»."), symbol: "magnifyingglass"),
                HelpFact(String(localized: "Свернуть блок"), String(localized: "Клик по заголовку блока сворачивает его; панель это запоминает."), symbol: "chevron.down"),
                HelpFact(String(localized: "Внешний вид"), String(localized: "Тема, стеклянный фон, размер текста, ширина и плотность — Настройки → «Внешний вид»."), symbol: "paintbrush"),
            ])]
        case .modules:
            [HelpSection(facts: [
                HelpFact(String(localized: "Выключатель"), String(localized: "Выключенный модуль не работает в фоне, не виден в панели и строке меню и не присылает уведомлений. Его настройки и место в профилях сохраняются."), symbol: "switch.2"),
                HelpFact(String(localized: "Где показывать"), String(localized: "Чипы на странице модуля: панель, строка меню, остров, уведомления, Telegram."), symbol: "rectangle.3.group"),
             ]),
             HelpSection(title: String(localized: "Профили"), facts: [
                HelpFact(String(localized: "Помощник"), String(localized: "Настройки → «Профили» → «+» → «Помощник…»: профиль по шагам — шаблон, папка, этапы, метрики, календарь, сервис AI, команды, права, блоки панели, строка меню, название. Справа — как это будет выглядеть."), symbol: "wand.and.stars"),
                HelpFact(String(localized: "Добавить профиль"), String(localized: "Настройки → «Профили» → «+»: «Разработчик (GitHub)», «Видео», «Тексты», «Ресёрч», «Соцсети», «Свой». Выберите папку — профиль готов, дальше всё правится в его настройках."), symbol: "plus.circle"),
             ])]
        case .limits:
            [HelpSection(facts: [
                HelpFact(String(localized: "Блок «Лимиты»"), String(localized: "Сессия с обратным отсчётом до сброса и прогнозом по темпу за 30 мин, неделя, недели по моделям, extra usage."), symbol: "gauge.with.dots.needle.33percent"),
                HelpFact(String(localized: "Другие AI"), String(localized: "Codex, Copilot, Gemini, Cursor и расход по API — такими же карточками, как Claude."), symbol: "sparkles"),
                HelpFact(String(localized: "Расход по проектам"), String(localized: "Оценка по журналам Claude Code: доли проектов и самая затратная сессия за сессию, сегодня, неделю."), symbol: "chart.pie"),
                HelpFact(String(localized: "Уведомления"), String(localized: "Один раз на окно при 50/80/95 % (пороги — в Настройках) и когда лимит восстановился; по желанию ещё и в Telegram."), symbol: "bell"),
                HelpFact(String(localized: "Виджет"), String(localized: "«Лимиты Claude» для рабочего стола: правый клик по столу → «Изменить виджеты…» → AI Hub Bar. Маленький — кольцо сессии, средний — сессия и неделя."), symbol: "widget.small"),
                HelpFact(String(localized: "Фон и лимит"), String(localized: "Если сессия использована больше чем на 90 %, фоновая задача спрашивает: запустить сейчас или после сброса."), symbol: "moon.zzz"),
            ])]
        case .sessions:
            [HelpSection(facts: [
                HelpFact(String(localized: "Список"), String(localized: "Все сессии на этом Mac — в Терминале, в приложении Claude, фоновые: проект, worktree, задача, длительность, состояние (работает, в фоне, ждёт ответа, готово, ошибка, завершена). Ждущие ответа подсвечены и приходят уведомлением."), symbol: "list.bullet"),
                HelpFact(String(localized: "Разрешения"), String(localized: "«Разрешить» и «Отклонить» — в уведомлении, в строке сессии, в острове и, если включено, в Telegram. Работает ответ, который пришёл первым."), symbol: "hand.raised"),
                HelpFact(String(localized: "Показать"), String(localized: "Вывести вкладку Терминала с этой сессией; для сессий приложения Claude — открыть эту сессию в Claude, иначе — папку."), symbol: "macwindow"),
                HelpFact(String(localized: "Терминал / Фон"), String(localized: "Где запускать: окно Терминала (можно отвечать Claude) или claude -p без окна (только разрешённые действия, лимит времени, итог — уведомлением и в Telegram). «Запомнить выбор» или профиль по умолчанию — в Настройках."), symbol: "terminal"),
                HelpFact(ModuleKind.quickPrompt.title, String(localized: "⌃⌥P в любом приложении: задача, проект (тот, что впереди, или прошлый) и агент — ⌘↩, и она в фоне или в Терминале. Модуль «Быстрый запрос», клавиша — на его странице."), symbol: ModuleKind.quickPrompt.symbol),
                HelpFact(String(localized: "Журнал"), String(localized: "Фоновая задача: что делает Claude, по шагам."), symbol: "doc.text"),
                HelpFact(String(localized: "Остановить"), String(localized: "Фоновая задача: остановить сейчас."), symbol: "stop.circle"),
                HelpFact(String(localized: "Отслеживание сессий"), String(localized: "Сессии видны, только если отслеживание включено: небольшой скрипт дописывается в ~/.claude/settings.json, копия сохраняется рядом."), symbol: "link"),
                HelpFact(String(localized: "Codex и Copilot"), String(localized: "Их сессии тоже показывают «работает / ждёт / готово», если на их странице в «Сервисах AI» установлен hook AI Hub Bar. Codex запускает новый hook только после проверки: в codex введите /hooks и доверьте его. Без hook — только недавние беседы, без состояния."), symbol: "person.2"),
            ])]
        case .services:
            [HelpSection(facts: [
                HelpFact(String(localized: "Агенты"), String(localized: "Codex CLI, Gemini CLI, Antigravity, Copilot CLI, Cursor CLI — AI Hub Bar находит установленные (Настройки → «Сервисы AI») и открывает их в Терминале в папке проекта: «Открыть в…» в блоке Claude у проекта. Вход у каждого свой."), symbol: "terminal"),
                HelpFact(String(localized: "Модели по API"), String(localized: "Anthropic, OpenAI, Google, xAI, DeepSeek, Mistral и любой сервер, совместимый с OpenAI (Ollama, LM Studio, OpenRouter). Ключ — только в связке ключей macOS; «Проверить» не тратит токены."), symbol: "key"),
                HelpFact(String(localized: "Сервис профиля"), String(localized: "Настройки → «Профили» → «Сервис по умолчанию»: им будут выполняться команды-шаблоны профиля."), symbol: "square.stack.3d.up"),
            ])]
        case .projects:
            [HelpSection(title: String(localized: "Git-репозитории"), facts: [
                HelpFact(String(localized: "Строка"), String(localized: "Точка состояния, ветка, незакоммиченные файлы, открытые PR (цвет — CI), когда была активность."), symbol: "circle.fill"),
                HelpFact(String(localized: "Следующий шаг"), String(localized: "Claude берёт первый пункт Next и делает его по правилам ~/Projects/CLAUDE.md: ветка, проверки, PR, STATUS."), symbol: "forward"),
                HelpFact(String(localized: "Своя задача…"), String(localized: "Claude выполняет ваш текст по тем же правилам."), symbol: "text.bubble"),
                HelpFact(String(localized: "Завершить"), String(localized: "Claude доводит текущую работу в папке: проверки, коммит, push, PR, STATUS — без нового кода."), symbol: "checkmark.circle"),
                HelpFact(String(localized: "Занятая папка"), String(localized: "Если в проекте уже работает Claude, новая задача идёт в отдельный worktree .claude/worktrees/cb-… на свежей ветке от origin/main."), symbol: "arrow.triangle.branch"),
                HelpFact(String(localized: "Терминал · Finder · GitHub"), String(localized: "Открыть папку проекта или репозиторий."), symbol: "arrow.up.forward.app"),
             ]),
             HelpSection(title: String(localized: "Проекты-папки"), facts: [
                HelpFact(String(localized: "Источник «папки»"), String(localized: "Настройки → «Профили» → «Источник»: каждая папка внутри папки проектов — проект (ролик, статья, тема)."), symbol: "folder.badge.gearshape"),
                HelpFact(String(localized: "проект.md"), String(localized: "Карточка проекта — обычный текст: «Этап: сценарий», «Дедлайн: 2026-11-05», «Публикация: 2026-11-05 18:00», «Формат: …», «Главный файл: сценарий.md», «Площадка: YouTube». Можно править руками."), symbol: "doc.plaintext"),
                HelpFact(String(localized: "Команды"), String(localized: "В развёрнутом проекте: команды профиля и «Своя задача». Результат — всегда новый файл в папке проекта. Модель по API получает текст главного файла; Claude работает в фоне с правами профиля («только файлы» — без терминала и интернета); другие агенты открываются в Терминале, задача — в буфере обмена."), symbol: "bolt"),
                HelpFact(String(localized: "Сравнить"), String(localized: "Включите «Сравнить», выберите 2–3 сервиса и команду: результаты лягут рядом («хуки (Claude).md», «хуки (OpenAI).md») и откроются в окне «Сравнение»."), symbol: "square.split.2x1"),
                HelpFact(String(localized: "Этапы и метрики"), String(localized: "Этапы профиля — через запятую; этап меняется кнопкой в развёрнутом проекте. Слова, хронометраж, время чтения и страницы считаются по главному файлу (.md, .txt, .rtf, .docx)."), symbol: "chart.bar"),
             ])]
        case .calendar:
            [HelpSection(facts: [
                HelpFact(String(localized: "Что в нём"), String(localized: "Дедлайны и публикации из проект.md, записи контент-план.md — у профилей, где «Календарь» включён (Настройки → «Профили»)."), symbol: "calendar"),
                HelpFact(String(localized: "Ближайшее"), String(localized: "Блок в панели: 7 дней вперёд, просроченное красным; клик открывает проект или файл."), symbol: "calendar.day.timeline.left"),
                HelpFact(String(localized: "Окно «Календарь»"), String(localized: "Месяц или неделя. Перетащите запись на другой день — дата перепишется в файле. Двойной клик по дню — новая запись."), symbol: "calendar.badge.plus"),
                HelpFact(String(localized: "Напоминания"), String(localized: "На странице модуля «Ближайшее»: за сколько напоминать и дублировать ли в Telegram."), symbol: "alarm"),
            ])]
        case .reports:
            [HelpSection(facts: [
                HelpFact(String(localized: "Отчёт сейчас"), String(localized: "Отчёт с AI-резюме за 24 ч в Telegram (1–3 мин)."), symbol: "doc.text.magnifyingglass"),
                HelpFact(String(localized: "Быстрая сводка"), String(localized: "Сводка без AI за 24 ч в Telegram."), symbol: "bolt"),
                HelpFact(String(localized: "Последний отчёт"), String(localized: "Открыть _daily-report/reports/latest.html."), symbol: "safari"),
                HelpFact(String(localized: "Очистка: проверить"), String(localized: "Показать, что удалит очистка сборок, ничего не трогая."), symbol: "eye"),
                HelpFact(String(localized: "Очистка: выполнить"), String(localized: "Удалить сборки и кэши, сбросить симуляторы (с подтверждением)."), symbol: "trash"),
            ])]
        case .notch:
            [HelpSection(facts: [
                HelpFact(String(localized: "Ушки"), String(localized: "Слева и справа от чёлки — лимит и сессии, когда сводка «только в острове»; что именно, выбирается на странице модуля."), symbol: "capsule.tophalf.filled"),
                HelpFact(String(localized: "Карточка"), String(localized: "Наведите курсор на чёлку — откроется карточка с лимитами и тем, что делает Claude."), symbol: "rectangle.portrait.topthird.inset.filled"),
                HelpFact(String(localized: "Запросы"), String(localized: "Запрос разрешения появляется в острове с «Разрешить» и «Отклонить»; ⌃⌥Y / ⌃⌥N — с клавиатуры, если включено."), symbol: "hand.raised"),
                HelpFact(String(localized: "Файл на остров"), String(localized: "Перетащите файл на остров — откроются AI-команды профиля для него."), symbol: "doc.badge.arrow.up"),
                HelpFact(String(localized: "Без чёлки"), String(localized: "На экранах без чёлки — пилюля сверху по центру."), symbol: "display"),
            ])]
        case .layout:
            [HelpSection(facts: [
                HelpFact(String(localized: "Само"), String(localized: "Слово в чужой раскладке исправляется после пробела, и раскладка переключается."), symbol: "wand.and.stars"),
                HelpFact(String(localized: "Двойной Shift"), String(localized: "Переводит последнее слово или отменяет неверное исправление — и запоминает слово."), symbol: "shift"),
                HelpFact("⌥⇧", String(localized: "Переводит выделенный текст."), symbol: "option"),
                HelpFact(String(localized: "Направления"), String(localized: "В меню языка в строке меню можно выбрать, с какой раскладки на какую исправлять само, например только EN → RU."), symbol: "arrow.left.arrow.right"),
                HelpFact(String(localized: "Исключения"), String(localized: "Слова из словаря исключений не исправляются сами, а ⌥⇧ оставляет их как есть."), symbol: "text.badge.xmark"),
                HelpFact(String(localized: "Доступ"), String(localized: "Нужен «Универсальный доступ»: модуль сам попросит и покажет, где его включить."), symbol: "lock.shield"),
            ])]
        case .utilities:
            [HelpSection(facts: [ModuleKind.resources, .keepAwake, .toggles, .clipboard, .notes, .quickCommands].map {
                HelpFact($0.title, $0.summary, symbol: $0.symbol)
            })]
        case .alerts:
            [HelpSection(facts: [
                HelpFact(String(localized: "Как часто"), String(localized: "У каждого модуля на странице — «Как часто уведомлять»: каждый раз, не чаще раза в 15 мин, в час, в день или не присылать."), symbol: "clock"),
                HelpFact("Telegram", String(localized: "Бот — модуль «Telegram»: токен, чат и меню в самом боте (/menu — лимиты, сессии, отчёты, очистка). Что дублировать — чипом «Telegram» на странице модуля."), symbol: "paperplane"),
                HelpFact(String(localized: "Ответы из Telegram"), String(localized: "Запросы разрешений Claude можно принимать и отклонять кнопками в Telegram — отдельный бот, страница «Сессии агентов»."), symbol: "hand.tap"),
                HelpFact(String(localized: "Клик по уведомлению"), String(localized: "Ведёт к сессии, PR, журналу или отчёту."), symbol: "cursorarrow.click"),
            ])]
        case .commandLine:
            [HelpSection(facts: [
                HelpFact(String(localized: "--claude next|task|finish <папка>"), String(localized: "Запустить команду Claude (--background — в фоне, --print — только показать).")),
                HelpFact("--command report|summary|cleanup-check|cleanup", String(localized: "Общая команда.")),
                HelpFact("--sessions · --show-session <id>", String(localized: "Список сессий; показать вкладку Терминала.")),
                HelpFact("--hooks status|install|uninstall", String(localized: "Hooks сессий.")),
                HelpFact("--login-item status|on|off", String(localized: "Автозапуск при входе.")),
                HelpFact("--background-settings", String(localized: "Правила доступа фоновых задач.")),
                HelpFact("--usage · --token-usage", String(localized: "Лимиты подписки; расход по проектам.")),
            ], monospaced: true)]
        }
    }

    /// Where its settings are.
    var settings: SettingsPane? {
        switch self {
        case .start: .general
        case .menuBar: .menuBar
        case .panel: .panel
        case .modules: .modules
        case .limits: .module(.limits)
        case .sessions: .module(.sessions)
        case .services: .service(.claude)
        case .projects: .modes
        case .calendar: .module(.upcoming)
        case .reports: .module(.reports)
        case .notch: .module(.notch)
        case .layout: .module(.layout)
        case .utilities: .modules
        case .alerts: .general
        case .commandLine: nil
        }
    }

    /// The search finds a topic by its title, summary, steps and facts.
    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        let words = [title, summary] + steps + sections.flatMap { $0.facts.flatMap { [$0.name, $0.detail] } }
        return words.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    static let binary = "~/Applications/AI\\ Hub\\ Bar.app/Contents/MacOS/AIHubBar"
}

struct HelpSection: Identifiable {
    var title: String?
    var facts: [HelpFact]
    var monospaced = false
    var id: String { title ?? facts.first?.name ?? "" }
}

struct HelpFact: Identifiable {
    var name: String
    var detail: String
    var symbol: String?
    var id: String { name }

    init(_ name: String, _ detail: String, symbol: String? = nil) {
        self.name = name
        self.detail = detail
        self.symbol = symbol
    }
}

/// The help as data for the site (docs/specs/SPEC-help.md §4), in the language this process runs in.
struct HelpExport: Encodable {
    struct Topic: Encodable {
        var id, group, title, summary: String
        var beta: Bool
        var steps: [String]
        var sections: [Section]
    }

    struct Section: Encodable {
        var title: String
        var monospaced: Bool
        var facts: [Fact]
    }

    struct Fact: Encodable {
        var name, detail: String
    }

    var language: String
    var labels: [String: String]
    var topics: [Topic]

    static func make() -> HelpExport {
        let topics = HelpTopic.groups.flatMap { group in
            group.topics.map { topic in
                Topic(id: topic.rawValue, group: group.title, title: topic.title, summary: topic.summary, beta: topic.isBeta,
                      steps: topic.steps,
                      sections: topic.sections.map { section in
                          Section(title: section.title ?? String(localized: "Что умеет"), monospaced: section.monospaced,
                                  facts: section.facts.map { Fact(name: $0.name, detail: $0.detail) })
                      })
            }
        }
        let labels = [
            "help": String(localized: "Справка"),
            "start": String(localized: "Как начать"),
            "search": String(localized: "Поиск по справке"),
            "replay": String(localized: "Показать ещё раз"),
            "beta": String(localized: "бета"),
            "scripts": String(localized: "Команды для скриптов вызываются так: \(HelpTopic.binary) --sessions"),
        ]
        return HelpExport(language: Bundle.main.preferredLocalizations.first ?? "ru", labels: labels, topics: topics)
    }
}
