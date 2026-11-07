# UI audit, 0.7.3 (2026-11-07)

What was looked at: the live panel on the Mac mini (light, glass, large text, spacious), all 28 Settings pages, the first-run assistant, usage history, quick prompt, cleanup output and island setup windows, plus a full read of the view code.

Not seen live: dark theme (see «Testing notes»), the panel with the system background, the island at a real notch, other languages, VoiceOver. Findings marked *code* come from reading the code; *live* means it was also seen on screen.

## P0: wrong action or lost data

Items 1–5 fixed in branch `fix/permission-safety`.

1. **Permission buttons change order.** The panel shows «Отклонить, Разрешить» (`SessionsView.swift:333`), the island «Разрешить, Отклонить» (`NotchIslandView.swift:410`). Same decision, opposite positions. White on green is about 2:1. *code*
2. **Rows move under the pointer.** Sessions sort by state, then `updatedAt` (`Session.swift:262`). With two sessions waiting, a newer request can put another session's «Разрешить» where the pointer is. *code*
3. **A new request in the open island has live buttons at once.** `showNext` returns early while the card is open (`NotchIsland.swift:252`), so the click guard is armed only in `open` (`:466`). The new row pushes the others down. *code*
4. **The command is cut in the middle next to «Разрешить».** Two lines, middle truncation, no tooltip (`SessionsView.swift:327`). *code*
5. **CLAUDE.md edits vanish.** Selecting another file replaces the draft with no prompt (`ClaudeConfigWindow.swift:111`); closing the window loses it too. *code*
6. **Instant delete and clear** with no confirmation: quick commands, prompts, clipboard history, service keys, menu bar reset (`QuickCommandsModule.swift:61`, `ClaudeSettings.swift:76`, `ClipboardModule.swift:53`, `ServicesSettings.swift:448`, `MenuBarSettings.swift:271`). Deleting a profile does ask. *code*

## P1: the panel

Items 7–12 fixed in branch `fix/panel-frame`; Esc (8) needs the Accessibility permission.

7. **The panel runs off the screen and cannot scroll.** With all blocks open the window was 1170 pt on a 1080 pt screen: the end of «Ресурсы Mac» and all of «Не спать» could not be reached. Only the project list scrolls; `maxListHeight` assumes 700 pt for everything else and uses `NSScreen.main` (`MenuPanelView.swift:42`). On the 13-inch Air this comes much sooner. Fix: one outer scroll capped by the panel's own screen, header and search pinned. *live*
8. **Esc does not close the panel.** Search takes focus on open, and `onExitCommand` calls `onCancel`, which the panel never passes (`PanelSearchView.swift:84`, `MenuPanelView.swift:64`). *live*
9. **Week days are one letter: П В С Ч П С В П.** Three letters repeat, so Monday and Friday read the same (`weekday(.narrow)`, `LimitsView.swift:403`). Use «Пн Вт Ср…». *live*
10. **Two figures for free space side by side:** «Свободно 1,57 ГБ» in «Команды», «свободно 2,94 ГБ» in «Ресурсы Mac». The first comes from the last report (`CommandsView.swift:63`), the second is live (`SystemMonitor.swift:102`). A disk warning also does not belong in «Команды». *live*
11. **Folded cards have different heights:** about 27, 29, 31 and 32 pt for «Сессии», «Проекты», «Команды», «Ресурсы». Paddings drifted to 8/4, 8/6 and 8/8 (`SessionsView.swift:83`, `:117`, `MenuPanelView.swift:409`, `:463`). This is the unevenness that is felt before it is noticed. *live*
12. **Titles are smaller than what they head.** At large text «Проекты» is clearly smaller than «Ambo» below it, so the hierarchy reads upside down. Summaries beside titles use three styles: grey count, bold «CPU 55 %», orange warning. *live*
13. **Names differ between panel and Settings:** «Лимиты» / «Лимиты AI», «Сессии» / «Сессии агентов», «Команды» / «Отчёты _daily-report», «CPU, RAM» / «Процессор, память». *live*
14. **«Сессии 4» above six rows.** The count means active ones, and the Settings preview says «работают: 3». *live*
15. **The expired-login button is unreachable** while a cached snapshot exists: dim rings and an orange error, no «Войти» (`LimitsView.swift:47`, `:65`). A failed refresh past reset keeps «сброс меньше чем через минуту» and the old coloured percent in the menu bar (`Usage.swift:202`). *code*
16. **Header and search sit on clear glass** with `.secondary` content; windows behind tint them (green blob in the capture) while the cards below are solid. Captions on cards are light grey. Only the island reads Increase Contrast. *live*
17. **Six unlabelled icons in the header.** The laptop and the file with a gear are hard to read, and quit is one click away next to help. *live, taste*
18. **Also:** a project picked in search expands below the fold, and a profile without Projects still lists them (`MenuPanelView.swift:152`, `:178`); queued launches show only inside «Лимиты» (`LimitsView.swift:97`); the four-button Claude row does not fit in Russian or German (`ClaudeActionsView.swift:29`); a profile with no shown modules is empty with no hint (`MenuPanelView.swift:82`); hover swaps duration for buttons and re-truncates the task (`SessionsView.swift:306`). *code*

## P1: Settings

Items 19–21 and 27–29 fixed in branch `fix/settings-rows`, 23, 24 and part of 26 in `fix/settings-texts`.

19. **Row labels do not line up.** `IconRow` uses a plain `Label` (`SettingsControls.swift:30`), so the text starts where each symbol ends: 581, 583, 586 px down one card on «Внешний вид», and rows without an icon start further left («Название» and «Значок», «Источник» and «Папка проектов»). One label style with a fixed icon column fixes every page. *live*
20. **Multi-line prompts are right-aligned, and two prompts in one list have different layouts** («Текст» above the field in one, beside it in the other). A grouped `Form` right-aligns `TextField` (`ClaudeSettings.swift:73`, `:81`). The same on «Быстрые команды», where placeholders act as labels. *live*
21. **The sidebar hides what is selected.** About 22 rows plus headers do not fit 700 pt, it opens scrolled, and the first five pages are out of view; a selected row can sit under the search field. Deep links never scroll to it (`SettingsView.swift:27`). «Сервисы AI» reads as an empty heading until hovered. *live*
22. **The «Остров» chip is ticked while nothing shows,** because the default is `summary = .menuBar` since 0.7.3 (`ModulePage.swift:136`, `NotchSettings.swift:68`). In «только в острове» the menu bar preview still shows numbers (`MenuBarSettings.swift:75`). Help, the illustration and the module text still promise limits beside the notch. With both ears empty and island-only summary, a person has neither (`NotchIsland.swift:200`). *code*
23. **Stale routes:** «вкладка «Профили»», «Модули → Лимиты», and footnotes on «Панель» sending people to «Профили» for what moved to «Панель» (`AppearanceSettings.swift:35`, `ModulePage.swift:266`, `PanelBuilder.swift:68`, `ServicesSettings.swift:139`, `NotchSetupView.swift:16`). *live*
24. **One thing, several names:** «Отслеживание сессий» / «Hook AI Hub Bar», «Выключить отслеживание» / «Снять hook», a footnote pointing to «Обновить hooks» while the button says «Обновить отслеживание» (`SessionsModule.swift:76`, `ServicesSettings.swift:234`). Mac and Мак are mixed. *live*
25. **Telegram is switched in up to three places:** the chip, a row on the module page, a row on the Telegram page. Check they are one state and keep one. The same for «Где показывать → Строка меню» and «Язык в строке меню» on «Раскладка». The «Уведомления» chip stays ticked with alerts off (`ModulePage.swift:182`). *live, partly code*
26. **Internal words for everyone:** «_daily-report», «report.py», «бота ежедневного отчёта», `.claudepult`, «ClaudePult Notes», and the owner's project «Cantero» as the sample (`AppearanceSettings.swift:68`, `StatusWidget.swift:27`). *live*
27. **Truncation in Russian at the default width:** «Только раскла…» on «Модули», «Ресурсы…» on «Панель» with room to spare, the block list in «Профили». Chip rows do not wrap at the minimum width (`ModulePage.swift:87`, `PanelBuilder.swift:113`). *live*
28. **Search finds pages, not settings.** «язык», «экспорт», «MCP», «аккаунт» give a blank sidebar with no message (`SettingsPane.swift:102`). *code*
29. **Pages jump.** The header grows from one to three lines, so everything below moves between pages; long subtitles («Раскладка», «Быстрый запрос») are instructions. Sections repeat the page title («Быстрый запрос», «Заметки», «Раскладка», «Остров у чёлки»). The «Не чаще…» footnote about sessions and PR appears on «Ресурсы Mac». *live*
30. **Also:** tiles and order chips cannot be reached by keyboard (`ModuleCatalog.swift:137`, `MenuBarOrderViews.swift:79`); failed export and «Войти» reach only the log (`ProfilesSettings.swift:381`, `ClaudeSettings.swift:152`); excluded clipboard apps are only a count (`ClipboardModule.swift:48`); «Указать цену…» opens a page without a price field (`UsageHistoryWindow.swift:70`). *code*

## P2: island and windows

31. **The invisible zone beside the notch still opens the card** in the default mode with no ears, also over full-screen apps (`NotchGeometry.swift:47`, `NotchIsland.swift:434`). The pill's rest frame has zero height, so its card never opens (`NotchGeometry.swift:42`). *code; check on the Air*
32. **The island card does not scroll** and is capped at 440 pt; several requests lose their buttons (`NotchGeometry.swift:24`). *code*
33. **«Ничего» in one ear does not free the menus** while the other ear has content (`NotchIslandView.swift:26`). *code*
34. **↑ ↓ do nothing in the ⌃⌥C search window** (`PanelSearchView.swift:236`). *code*
35. **«Очистка сборок» is a dead end:** a large empty window with «Очистка ещё не запускалась» and no action. *live*
36. **Previews do not look like the panel.** Settings and the assistant draw limits as bars, the panel as rings; percent is «34%» in some places, «34 %» in others. *live*
37. **Widgets:** a stale percent with «сброс через 0 мин» when the app is off, «Нет данных» with only the week limit, real project names in the gallery (`UsageWidget.swift:124`, `:134`, `StatusWidget.swift:27`). *code*
38. **Small:** CSV ignores the chosen period (`UsageHistoryWindow.swift:108`); the period control is inset from the content below it; the calendar's «ещё» count is wrong above 20 entries (`CalendarWindow.swift:179`); window titles with and without «— AI Hub Bar». *live, partly code*

## Order of work

1. P0 1–5: one order for the buttons, stable rows, guard on every new request, full command text, ask before losing edits.
2. Panel frame: 7, 8, 9, 10, 11.
3. One settings row: 19, 20, then 21.
4. The 0.7.3 island wording and state: 22, 31, 33.
5. One text pass in 12 languages: 13, 23, 24, 26.

## Testing notes

- `@AppStorage` keys follow `defaults write` in the running app, so `settingsPage` switches Settings pages with no mouse, and `screencapture -l <id>` takes them behind other windows.
- `AppSettings` values (`panelTheme`, `panelBackground`) do not; they need the Settings control or a relaunch, so the dark captures of this audit are not valid and dark theme stays unchecked.
