//! «Справка» (docs/specs/SPEC-help.md), the Mac's `HelpTopic`: what each part of AI Hub Bar does, how to begin and
//! where its settings are. Only what is true on Windows and Linux is here: a fact of the Mac's help is taken word
//! for word when it holds as it stands (its translations come with it), has a twin when it names the menu bar, ⌘ or
//! macOS, and is left out when the feature isn't here. The Mac's topics «Строка меню», «Отчёты», «Остров у чёлки»,
//! «Раскладка» and «Для скриптов» have nothing to say yet. No pictures: the Mac draws its own in SwiftUI.

use crate::i18n::Strings;
use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
pub struct Fact {
    pub name: String,
    pub detail: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct Section {
    pub title: String,
    pub facts: Vec<Fact>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Topic {
    /// The Mac's `HelpTopic` raw value.
    pub id: &'static str,
    /// The sidebar's section.
    pub group: String,
    pub title: String,
    pub glyph: &'static str,
    pub summary: String,
    /// «Как начать».
    pub steps: Vec<String>,
    pub sections: Vec<Section>,
    /// The page of Settings «Открыть в настройках» leads to.
    pub settings: Option<&'static str>,
}

fn fact(name: &str, detail: &str) -> Fact {
    Fact { name: name.to_owned(), detail: detail.to_owned() }
}

fn section(title: &str, facts: Vec<Fact>) -> Section {
    Section { title: title.to_owned(), facts }
}

/// The topics in the sidebar's order.
pub fn topics(s: &Strings) -> Vec<Topic> {
    let does = s.t("Что умеет");
    let basics = s.t("Основы");
    let work = s.t("Работа");
    let more = s.t("Ещё");
    let topic = |id, group: &str, title: &str, glyph, summary: &str, steps: Vec<&str>, sections, settings| Topic {
        id,
        group: group.to_owned(),
        title: title.to_owned(),
        glyph,
        summary: summary.to_owned(),
        steps: steps.into_iter().map(str::to_owned).collect(),
        sections,
        settings,
    };
    vec![
        topic(
            "start",
            basics,
            s.t("Начало"),
            "✦",
            s.t("AI Hub Bar держит под рукой лимиты AI, сессии агентов и ваши проекты — в трее, в один клик."),
            vec![
                s.t("Нажмите значок AI Hub Bar в трее — откроется панель."),
                s.t("На странице «Что показывать» оставьте только нужное — остальное выключится вместе с фоновой работой."),
            ],
            vec![section(
                does,
                vec![
                    fact(s.t("Обновления"), s.t("AI Hub Bar сам проверяет новые версии: Настройки → «Основные» → «Обновления».")),
                    fact(s.t("Что нового"), s.t("После обновления вверху панели один раз появляется карточка с тем, что изменилось; «Понятно» её убирает.")),
                ],
            )],
            Some("general"),
        ),
        topic(
            "panel",
            basics,
            s.t("Панель"),
            "▤",
            s.t("Панель открывается по клику на значок в трее: блоки модулей текущего профиля сверху вниз и поиск."),
            vec![s.t("Откройте Настройки → «Что показывать».")],
            vec![section(does, vec![fact(s.t("Поиск"), s.t("Поле сверху панели ищет проекты, сессии, команды и свои промпты. Открыть с клавиатуры — сочетание в «Клавишах»."))])],
            Some("show"),
        ),
        topic(
            "modules",
            basics,
            s.t("Модули и профили"),
            "▦",
            s.t("Модуль — одна возможность AI Hub Bar. Профиль решает, какие модули видны в панели и в каком порядке."),
            vec![s.t("Клик по названию модуля — его страница: выключатель и все его настройки.")],
            vec![],
            Some("show"),
        ),
        topic(
            "limits",
            "AI",
            s.t("Лимиты AI"),
            "◔",
            s.t("Сколько осталось от 5-часовой сессии и недели подписки Claude — и от лимитов других AI."),
            vec![s.t("Другие AI подключаются в «Сервисы AI»: вход в их CLI или ключ API.")],
            vec![section(
                does,
                vec![
                    fact(s.t("Неделя"), s.t("У недели видно, быстрее или медленнее ровного расхода вы тратите лимит: отметка на полосе и строка под ней.")),
                    fact(s.t("Расход по проектам"), s.t("Оценка по журналам Claude Code: доли проектов и самая затратная сессия за сессию, сегодня, неделю.")),
                    fact(s.t("История расхода"), s.t("«История расхода…» под расходом по проектам открывает окно: токены Claude Code по дням за последние недели.")),
                    fact(
                        s.t("Фон и лимит"),
                        s.t("Если сессия использована больше чем на 90 %, фоновая задача спрашивает: запустить сейчас или после сброса. «Ставить фоновые задачи на паузу» в Настройках → «Сервисы AI» останавливает идущие задачи у порога и продолжает их после сброса."),
                    ),
                ],
            )],
            Some("services"),
        ),
        topic(
            "sessions",
            "AI",
            s.t("Сессии агентов"),
            "☰",
            s.t("Все сессии Claude Code на этом компьютере: что делают, кто ждёт ответа, фоновые задачи и очередь."),
            vec![],
            vec![section(
                does,
                vec![
                    fact(s.t("Разрешения"), s.t("«Разрешить» и «Отклонить» — в строке сессии и, если включено, в Telegram. Работает ответ, который пришёл первым.")),
                    fact(
                        s.t("Быстрый запрос"),
                        s.t("Ctrl+Alt+P в любой программе: задача, проект (тот, что впереди, или прошлый) и агент — Ctrl+Enter, и она в фоне или в Терминале. Модуль «Быстрый запрос», клавиша — на его странице."),
                    ),
                    fact(s.t("Журнал"), s.t("Фоновая задача: что делает Claude, по шагам.")),
                    fact(s.t("Остановить"), s.t("Фоновая задача: первый клик спрашивает «Остановить?», второй останавливает.")),
                    fact(s.t("Недавно завершённые"), s.t("Сессии, которые недавно закончились, сложены под этой строкой — их можно продолжить.")),
                ],
            )],
            Some("services"),
        ),
        topic(
            "services",
            "AI",
            s.t("Сервисы AI"),
            "⚙",
            s.t("Агенты и модели, которые AI Hub Bar находит и запускает: Claude Code, Codex, Gemini, Copilot, Cursor и модели по API."),
            vec![],
            vec![section(does, vec![fact(s.t("Сервис профиля"), s.t("Настройки → «Профили» → «Сервис по умолчанию»: им будут выполняться команды-шаблоны профиля."))])],
            Some("services"),
        ),
        topic(
            "projects",
            work,
            s.t("Проекты"),
            "🗀",
            s.t("Проекты профиля: git-репозитории или папки с работой — состояние, PR, этапы и команды для AI."),
            vec![],
            vec![
                section(
                    s.t("Git-репозитории"),
                    vec![
                        fact(s.t("Строка"), s.t("Точка состояния, ветка, незакоммиченные файлы, открытые PR (цвет — CI), когда была активность.")),
                        fact(s.t("Своя задача…"), s.t("Claude выполняет ваш текст по тем же правилам.")),
                        fact(s.t("Завершить"), s.t("Claude доводит текущую работу в папке: проверки, коммит, push, PR, STATUS — без нового кода.")),
                        fact(s.t("Занятая папка"), s.t("Если в проекте уже работает Claude, новая задача идёт в отдельный worktree .claude/worktrees/cb-… на свежей ветке от origin/main.")),
                    ],
                ),
                section(
                    s.t("Проекты-папки"),
                    vec![
                        fact(
                            s.t("проект.md"),
                            s.t("Карточка проекта — обычный текст: «Этап: сценарий», «Дедлайн: 2026-11-05», «Публикация: 2026-11-05 18:00», «Формат: …», «Главный файл: сценарий.md», «Площадка: YouTube». Можно править руками."),
                        ),
                        fact(
                            s.t("Этапы и метрики"),
                            s.t("Этапы профиля — через запятую; этап меняется кнопкой в развёрнутом проекте. Слова, хронометраж, время чтения и страницы считаются по главному файлу (.md, .txt, .rtf, .docx)."),
                        ),
                    ],
                ),
            ],
            Some("modes"),
        ),
        topic(
            "calendar",
            work,
            s.t("Ближайшее и календарь"),
            "▣",
            s.t("Дедлайны и публикации из карточек проектов и контент-плана — на неделю вперёд и в окне «Календарь»."),
            vec![],
            vec![section(
                does,
                vec![
                    fact(s.t("Что в нём"), s.t("Дедлайны и публикации из проект.md, записи контент-план.md — у профилей, где «Календарь» включён (Настройки → «Профили»).")),
                    fact(s.t("Ближайшее"), s.t("Блок в панели: 7 дней вперёд, просроченное красным; клик открывает проект или файл.")),
                ],
            )],
            Some("modes"),
        ),
        topic(
            "utilities",
            more,
            s.t("Утилиты"),
            "⚒",
            s.t("Ресурсы компьютера, «Не спать», быстрые переключатели, история буфера, заметки и свои команды — каждое включается отдельно."),
            vec![],
            // Each module's own words from «Что показывать».
            vec![section(
                does,
                vec![
                    fact(s.t("Ресурсы компьютера"), s.t("Процессор, память, диск, сеть, батарея и самые прожорливые приложения; уведомления о нагрузке, памяти, месте и заряде.")),
                    fact(s.t("Не спать"), s.t("Компьютер не засыпает, пока работает Claude, на время, при подключённом питании или мониторе, пока открыты выбранные приложения.")),
                    fact(s.t("Быстрые переключатели"), s.t("Тёмная тема, значки на рабочем столе, блокировка и выключение экрана, корзина — в один клик.")),
                    fact(s.t("История буфера"), s.t("Последние копирования: поиск, закрепление, снова в буфер одним кликом. Пароли из менеджеров паролей не запоминаются.")),
                    fact(s.t("Заметки"), s.t("Заметки в Markdown прямо в панели: вкладки, обычные файлы .md в папке, которую откроет любой редактор.")),
                    fact(s.t("Быстрые команды"), s.t("Свои кнопки: скрипт в фоне или в Терминале, ссылка, файл, папка или программа.")),
                ],
            )],
            Some("show"),
        ),
        topic(
            "alerts",
            more,
            s.t("Уведомления и Telegram"),
            "🔔",
            s.t("Что приходит уведомлением системы и в Telegram."),
            vec![],
            vec![section(
                does,
                vec![
                    fact(
                        "Telegram",
                        s.t("Свой бот: токен из @BotFather, без сервера AI Hub Bar между вами. Настройки → «Основные» → «Telegram»: «Привязать чат», затем «Start» в чате. Меню в самом боте: /menu — лимиты и сессии."),
                    ),
                    fact(
                        s.t("Ответы из Telegram"),
                        s.t("Запросы разрешений приходят в тот же бот с кнопками ✅ и ❌: включите «Запросы разрешений в этот бот» на странице «Telegram»."),
                    ),
                ],
            )],
            Some("telegram"),
        ),
    ]
}

impl Topic {
    /// The search finds a topic by its title, summary, steps and facts, in any case.
    pub fn matches(&self, query: &str) -> bool {
        let query = query.trim().to_lowercase();
        if query.is_empty() {
            return true;
        }
        let facts = self.sections.iter().flat_map(|s| s.facts.iter().flat_map(|f| [&f.name, &f.detail]));
        [&self.title, &self.summary].into_iter().chain(&self.steps).chain(facts).any(|text| text.to_lowercase().contains(&query))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_topics_are_about_this_system() {
        let topics = topics(&Strings::default());
        let ids: Vec<_> = topics.iter().map(|t| t.id).collect();
        assert_eq!(ids, ["start", "panel", "modules", "limits", "sessions", "services", "projects", "calendar", "utilities", "alerts"]);
        let groups: Vec<_> = topics.iter().map(|t| t.group.as_str()).collect();
        assert_eq!(groups, ["Основы", "Основы", "Основы", "AI", "AI", "AI", "Работа", "Работа", "Ещё", "Ещё"], "the Mac's sections, without «Mac»");
        for topic in &topics {
            assert!(!topic.title.is_empty() && topic.summary.ends_with('.'), "{}", topic.id);
            let texts = [&topic.summary].into_iter().chain(&topic.steps).chain(topic.sections.iter().flat_map(|s| s.facts.iter().map(|f| &f.detail)));
            for text in texts {
                for word in ["Mac", "macOS", "⌘", "⌃", "⌥", "строке меню", "строку меню", "остров", "Finder", "связке ключей"] {
                    assert!(!text.contains(word), "{}: «{word}» in «{text}»", topic.id);
                }
            }
            assert!(topic.sections.iter().all(|s| !s.facts.is_empty()), "{}: no empty section", topic.id);
        }
    }

    #[test]
    fn the_search_reads_everything_on_a_page() {
        let topics = topics(&Strings::default());
        let found = |query: &str| topics.iter().filter(|t| t.matches(query)).map(|t| t.id).collect::<Vec<_>>();
        assert_eq!(found("  "), topics.iter().map(|t| t.id).collect::<Vec<_>>(), "nothing typed: every topic");
        assert_eq!(found("WORKTREE"), ["projects"], "a fact's text, in any case");
        assert_eq!(found("календарь"), ["calendar"], "a title and a summary");
        assert_eq!(found("ctrl+alt+p"), ["sessions"]);
        assert!(found("telegram").contains(&"alerts") && found("трее").contains(&"start"));
        assert!(found("нет такого слова").is_empty());
    }
}
