# AI Hub Bar: лимиты и расход других AI — техзадание (отложено)

Записано 2026-10-30 по итогам проверки. Олег пользуется только Claude, поэтому делать не сейчас: это для будущих пользователей, когда AI Hub Bar будет раздаваться. Перед началом — заново проверить форматы: почти всё ниже не задокументировано производителями и может поменяться.

На Маке Олега в момент проверки: Codex, Gemini CLI, Copilot, Cursor не установлены, ключей API в «Сервисах AI» нет. Значит, проверять вживую придётся на Маке, где эти сервисы есть.

---

## 1. Что умеет каждый сервис

| Сервис | Что можно показать | Откуда | Надёжность |
|---|---|---|---|
| Claude (подписка) | сессия 5 ч и неделя, %, сброс | уже есть (`UsageService`) | есть |
| Расход API из самого AI Hub Bar | токены и $ за день и месяц | уже есть (`api-spend.json`) | есть |
| Codex (подписка ChatGPT) | окна 5 ч и неделя: `used_percent`, `window_minutes`, сброс | см. §2.1 | средняя |
| OpenRouter | остаток кредитов, расход за день / неделю / месяц | `GET https://openrouter.ai/api/v1/key` с обычным ключом | высокая (официально) |
| GitHub Copilot | остаток премиум-запросов за месяц | `gh api /copilot_internal/user` | средняя (внутренний адрес) |
| Gemini CLI | остаток дневной квоты, % | см. §2.3 | низкая |
| OpenAI API | расход в $ по дням | `GET https://api.openai.com/v1/organization/costs` | высокая, но нужен админский ключ организации |
| Anthropic API | расход и использование | Admin API (`sk-ant-admin…`) | высокая, но нужен админский ключ |
| Cursor | расход за период, % тарифа | см. §2.5 | низкая |

## 2. Подробности

### 2.1 Codex
- **Лучший путь — через сам `codex`:** `codex app-server` по stdio (JSON-RPC): `initialize` с `clientInfo`, затем `account/rateLimits/read` с `params: {}`. Ответ: `rateLimits.primary` (5 ч) и `rateLimits.secondary` (неделя), у каждого `usedPercent` и `resetsAt`. Токены и вход не трогаем — их держит сам Codex.
- **Без сети, запасной:** последний `~/.codex/sessions/**/*.jsonl`, записи `event_msg` с `payload.type == "token_count"`: `rate_limits.primary` / `secondary` — `used_percent`, `window_minutes` (300 и 10080), сброс то `resets_at` (Unix), то `resets_in_seconds` — зависит от версии (`cli_version` в файле). `info` может быть `null`.
- **Живой адрес (не брать, если хватает первых двух):** `GET https://chatgpt.com/backend-api/wham/usage` с `Authorization: Bearer <tokens.access_token из ~/.codex/auth.json>` и `ChatGPT-Account-Id`. Требует читать чужой токен — хуже по приватности.

### 2.2 OpenRouter
- `GET /api/v1/key`, заголовок `Authorization: Bearer <ключ>`: `limit`, `limit_remaining`, `limit_reset`, `usage` (всего), дневные / недельные / месячные счётчики (UTC), отдельно BYOK. Новое поле `budgets` / `effective_budget` — лимиты организации. Старое `rate_limit` устарело.
- Ключ — в Связке ключей, как остальные (`APIKeyStore`, провайдер «compatible» уже умеет OpenRouter).

### 2.3 Gemini CLI
- Квота: внутренний API Google по входу из `~/.gemini/oauth_creds.json` (`access_token`, `refresh_token`, `expiry_date`): `POST https://cloudcode-pa.googleapis.com/v1internal/loadCodeAssist`, затем `…/retrieveUserQuota` → `remainingAmount`, `remainingFraction`. Нужен ID проекта Google Cloud. Время сброса и разбивка по моделям не описаны. Обновлять токен самим — значит трогать чужой вход: только с явного согласия.
- Запасной путь без сети: считать запросы за сегодня по журналам (`~/.gemini/tmp/**/chats/session-*.json`, путь менялся между версиями) и делить на дневной лимит тарифа: 1 000 (Google-аккаунт), 1 500 (AI Pro), 2 000 (AI Ultra / Enterprise), 250 (бесплатный ключ API, только Flash). Сброс — полночь по Тихоокеанскому времени.
- `/stats model` работает только в интерактивной сессии.

### 2.4 Copilot
- `gh api /copilot_internal/user` → `quota_snapshots.{chat, code, premium_interactions}`: `entitlement`, `remaining`, `unlimited`, `overage_count`. Сброс — раз в месяц по биллингу GitHub, поля со временем нет. Нужен установленный и залогиненный `gh`.

### 2.5 Cursor
- `POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage` с токеном из локальной базы Cursor (`~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`, таблица `cursorDiskKV`): `planUsage.totalSpend`, `limit` (центы), `totalPercentUsed`, `billingCycleStart` / `End`. Чужой токен и внутренний API — последним в очереди.

## 3. Как это встроить

- **Модуль «Лимиты AI» становится общим.** Кольца Claude сверху, ниже по строке на сервис: процент, время сброса, цвет по уровню. Сервис появляется сам, если найден на Маке (`codex`, `gh`, `~/.gemini`), или после ввода ключа (OpenRouter, админские ключи).
- **Общее для всех:** пороги уведомлений (как у Claude), элементы строки меню «<сервис> N %», строка в виджете, прогноз «хватит до сброса» там, где есть окно.
- **Приватность:** чужие токены не читаем без согласия; по возможности спрашиваем саму программу (`codex app-server`, `gh`). Ключи — только в Связке ключей.
- **Каждый источник — свой небольшой тип** с разбором ответа, проверенный тестами на реальных примерах ответа (сохранять обезличенные образцы в тестах).

## 4. Этапы

1. Каркас общего модуля, перенос Claude в него без видимых изменений.
2. Первая волна: Codex (через `codex app-server`, запасной — журналы), OpenRouter, Copilot.
3. Вторая волна: Gemini CLI (с согласием на чтение входа или по журналам), расход OpenAI и Anthropic по админским ключам, Cursor.

## 5. Источники (проверено 2026-10-30)

- [codex-ratelimit](https://github.com/xiangz19/codex-ratelimit), [схема файлов сессий Codex](https://lin-guanguo.github.io/llm-memory-research/agent-cli/codex-session-file-schema/)
- [OpenUsage: Codex, Gemini CLI, Copilot, Cursor](https://44a54478.openusage-docs.pages.dev/providers/codex/)
- [Трекинг квот Claude, Codex и Gemini одним скриптом](https://ianlpaterson.com/blog/tracking-claude-codex-gemini-quotas-from-one-script/)
- [OpenRouter: лимиты ключа](https://openrouter.ai/docs/api/reference/limits)
- [Gemini CLI: квоты и цены](https://geminicli.com/docs/resources/quota-and-pricing/)
- [Расход OpenAI через админский ключ](https://docs.vantage.sh/connecting_open_ai)
