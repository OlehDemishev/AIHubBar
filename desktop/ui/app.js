// Shared by the panel and the settings window: texts in the interface language, calls into the Rust side.
// Texts are keyed by the Mac app's Russian source text (docs/SPEC-windows.md §2); `data-t` marks an element whose
// text is one such key, `data-t-title` its hover hint.

const invoke = window.__TAURI__.core.invoke;

let strings = {};

export function t(key, ...args) {
  let text = strings[key] || key;
  let next = 0;
  return text.replace(/%(?:(\d+)\$)?(@|lld|ld|d)/g, (_, position) => {
    const index = position ? Number(position) - 1 : next++;
    return args[index] ?? "";
  });
}

export async function loadTexts() {
  const ui = await invoke("ui_texts");
  strings = ui.strings;
  document.documentElement.lang = ui.lang;
  document.documentElement.dir = ui.rtl ? "rtl" : "ltr";
  for (const element of document.querySelectorAll("[data-t]")) element.textContent = t(element.dataset.t);
  for (const element of document.querySelectorAll("[data-t-title]")) element.title = t(element.dataset.tTitle);
  return ui;
}

export { invoke };
