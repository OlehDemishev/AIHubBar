// What the relay says itself: to strangers, about pairing and about which Mac answers. Russian and Ukrainian speakers
// get Russian, everyone else English; the Macs' own screens come in the app's language.

const TEXTS = {
  en: {
    welcome: "This is the AI Hub Bar bot: a menu for your Mac in Telegram — limits, sessions, reports. Install AI Hub Bar ({site}), then press “Connect Telegram” in it.",
    badCode: "This link has expired. Press “Connect Telegram” in AI Hub Bar again.",
    noMac: "No Mac answers this chat right now. On the Mac: Settings → Modules → Telegram → “This Mac answers the bot”.",
    asleep: "💤 {mac} is offline — it will answer when it wakes up (commands older than 30 minutes are skipped).",
    macs: "Macs of this chat — the one marked ✅ answers:",
    description: "A menu for your Mac in Telegram: Claude limits, sessions, background tasks, reports, build cleanup. Works with the AI Hub Bar app.",
    short: "Your Mac's AI work in Telegram — with AI Hub Bar.",
    commands: [
      { command: "menu", description: "Home: limits, sessions, background tasks" },
      { command: "report", description: "AI report since the morning (or /report 3)" },
      { command: "status", description: "Quick summary without AI" },
      { command: "clean", description: "Build cleanup (/clean check — only show)" },
      { command: "macs", description: "Which Mac answers" },
      { command: "help", description: "Bot commands" },
    ],
  },
  ru: {
    welcome: "Это бот AI Hub Bar: меню вашего Мака в Telegram — лимиты, сессии, отчёты. Установите AI Hub Bar ({site}) и нажмите в нём «Подключить Telegram».",
    badCode: "Ссылка устарела. Нажмите «Подключить Telegram» в AI Hub Bar ещё раз.",
    noMac: "Сейчас этому чату не отвечает ни один Мак. На Маке: Настройки → Модули → Telegram → «Этот Мак отвечает боту».",
    asleep: "💤 {mac} не на связи — ответит, когда проснётся (команды старше 30 минут пропускаются).",
    macs: "Маки этого чата — отвечает отмеченный ✅:",
    description: "Меню вашего Мака в Telegram: лимиты Claude, сессии, фоновые задачи, отчёты, очистка сборок. Работает с приложением AI Hub Bar.",
    short: "AI-работа вашего Мака в Telegram — с AI Hub Bar.",
    commands: [
      { command: "menu", description: "Главная: лимиты, сессии, фоновые задачи" },
      { command: "report", description: "Отчёт с AI с утра до сейчас (или /report 3)" },
      { command: "status", description: "Быстрая сводка без AI" },
      { command: "clean", description: "Очистка сборок (/clean check — только показать)" },
      { command: "macs", description: "Какой Мак отвечает" },
      { command: "help", description: "Команды бота" },
    ],
  },
};

export function language(code) {
  return ["ru", "uk", "be"].includes(String(code || "").slice(0, 2)) ? "ru" : "en";
}

export function text(code, key, values = {}) {
  const value = TEXTS[language(code)][key];
  return typeof value === "string" ? value.replace(/\{(\w+)\}/g, (_, name) => values[name] ?? "") : value;
}
