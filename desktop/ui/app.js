// Shared by the panel and the settings window: texts in the interface language, calls into the Rust side.
// Texts are keyed by the Mac app's Russian source text (docs/specs/SPEC-windows.md §2); `data-t` marks an element whose
// text is one such key, `data-t-title` its hover hint, `data-t-placeholder` an input's placeholder.

const invoke = window.__TAURI__.core.invoke;

let strings = {};

export function t(key, ...args) {
  let text = strings[key] || key;
  let next = 0;
  // `%%` is a percent sign, as in the Mac's catalog.
  return text.replace(/%%|%(?:(\d+)\$)?(@|lld|ld|d)/g, (match, position) => {
    if (match === "%%") return "%";
    const index = position ? Number(position) - 1 : next++;
    return args[index] ?? "";
  });
}

export async function loadTexts() {
  const ui = await invoke("ui_texts");
  strings = ui.strings;
  document.documentElement.lang = ui.lang;
  document.documentElement.dir = ui.rtl ? "rtl" : "ltr";
  // «Размер текста»: the whole page, as the Mac scales its panel's fonts.
  document.documentElement.style.zoom = ui.textScale ?? 1;
  // «Плотность строк»: the panel's own spacing reads it; other windows have none of those rules.
  document.documentElement.style.setProperty("--density", ui.density ?? 1);
  for (const element of document.querySelectorAll("[data-t]")) element.textContent = t(element.dataset.t);
  for (const element of document.querySelectorAll("[data-t-title]")) element.title = t(element.dataset.tTitle);
  for (const element of document.querySelectorAll("[data-t-placeholder]")) element.placeholder = t(element.dataset.tPlaceholder);
  return ui;
}

export { invoke };
