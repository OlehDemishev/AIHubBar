//! AI Hub Bar for Windows and Linux (docs/SPEC-windows.md §9): stage 1 «Каркас» — the tray icon, the panel at it,
//! the settings window, 13 languages, one running copy, start at sign-in and `claudepult --app-command`;
//! stage 2 «Лимиты» in `limits.rs`.

// No console window behind the app in a release build on Windows.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod limits;

use claudepult_core::i18n::{self, Strings};
use claudepult_core::ipc::{self, Reply, Request};
use claudepult_core::settings::Settings;
use claudepult_core::{paths, APP_NAME};
use serde::Serialize;
use std::sync::Mutex;
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Manager, RunEvent, WebviewUrl, WebviewWindowBuilder, WindowEvent};
use tauri_plugin_autostart::{MacosLauncher, ManagerExt};
use limits::Limits;
use tauri_plugin_positioner::{Position, WindowExt};

const TRAY_ID: &str = "main";

struct AppState {
    settings: Mutex<Settings>,
}

/// The texts of one language, written by `scripts/strings.py` from the Mac app's String Catalog.
fn strings_json(code: &str) -> &'static str {
    match code {
        "en" => include_str!("../../ui/i18n/en.json"),
        "es" => include_str!("../../ui/i18n/es.json"),
        "pt-BR" => include_str!("../../ui/i18n/pt-BR.json"),
        "fr" => include_str!("../../ui/i18n/fr.json"),
        "de" => include_str!("../../ui/i18n/de.json"),
        "ja" => include_str!("../../ui/i18n/ja.json"),
        "id" => include_str!("../../ui/i18n/id.json"),
        "ko" => include_str!("../../ui/i18n/ko.json"),
        "it" => include_str!("../../ui/i18n/it.json"),
        "ar" => include_str!("../../ui/i18n/ar.json"),
        "pl" => include_str!("../../ui/i18n/pl.json"),
        "uk" => include_str!("../../ui/i18n/uk.json"),
        // Russian is the source: its keys are its texts.
        _ => "{}",
    }
}

fn language(app: &AppHandle) -> &'static str {
    let state = app.state::<AppState>();
    let chosen = state.settings.lock().unwrap().language.clone();
    i18n::resolve(chosen.as_deref())
}

fn strings(app: &AppHandle) -> Strings {
    Strings::from_json(strings_json(language(app)))
}

fn save(app: &AppHandle, change: impl FnOnce(&mut Settings)) {
    let state = app.state::<AppState>();
    let mut settings = state.settings.lock().unwrap();
    change(&mut settings);
    if let Err(error) = settings.save(&paths::settings_file()) {
        eprintln!("settings not saved: {error}");
    }
}

// MARK: - Windows

/// Where the tray icons are when the panel opens without a click on ours (`claudepult --app-command panel`, a
/// second launch): bottom right on Windows, top right on Linux and macOS.
fn corner() -> Position {
    if cfg!(target_os = "windows") { Position::BottomRight } else { Position::TopRight }
}

fn show_panel(app: &AppHandle) {
    let Some(panel) = app.get_webview_window("panel") else { return };
    // At the icon — TrayCenter flips to whichever side has room — once a click has told where it is.
    if panel.move_window(Position::TrayCenter).is_err() {
        let _ = panel.move_window(corner());
    }
    let _ = panel.show();
    let _ = panel.set_focus();
}

fn toggle_panel(app: &AppHandle) {
    let Some(panel) = app.get_webview_window("panel") else { return };
    if panel.is_visible().unwrap_or(false) {
        let _ = panel.hide();
    } else {
        show_panel(app);
    }
}

fn open_settings_window(app: &AppHandle) {
    if let Some(panel) = app.get_webview_window("panel") {
        let _ = panel.hide();
    }
    if let Some(window) = app.get_webview_window("settings") {
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
        return;
    }
    let title = format!("{APP_NAME} — {}", strings(app).t("Настройки…").trim_end_matches('…'));
    let _ = WebviewWindowBuilder::new(app, "settings", WebviewUrl::App("settings.html".into()))
        .title(title)
        .inner_size(560.0, 420.0)
        .min_inner_size(480.0, 360.0)
        .center()
        .build();
}

fn build_panel(app: &AppHandle) -> tauri::Result<()> {
    let panel = WebviewWindowBuilder::new(app, "panel", WebviewUrl::App("panel.html".into()))
        .title(APP_NAME)
        .inner_size(360.0, 420.0)
        .resizable(false)
        .decorations(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .visible(false)
        .build()?;
    // Like the Mac popover: it goes away when something else is clicked.
    let handle = panel.clone();
    panel.on_window_event(move |event| {
        if let WindowEvent::Focused(false) = event {
            let _ = handle.hide();
        }
    });
    Ok(())
}

// MARK: - Tray

fn tray_menu(app: &AppHandle) -> tauri::Result<Menu<tauri::Wry>> {
    let texts = strings(app);
    Menu::with_items(app, &[
        &MenuItem::with_id(app, "panel", texts.t("Открыть панель"), true, None::<&str>)?,
        &MenuItem::with_id(app, "settings", texts.t("Настройки…"), true, None::<&str>)?,
        &PredefinedMenuItem::separator(app)?,
        &MenuItem::with_id(app, "quit", texts.t("Выйти из AI Hub Bar"), true, None::<&str>)?,
    ])
}

fn build_tray(app: &AppHandle) -> tauri::Result<()> {
    let mut tray = TrayIconBuilder::with_id(TRAY_ID)
        .tooltip(APP_NAME)
        .menu(&tray_menu(app)?)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| {
            run_command(app, event.id().as_ref());
        })
        .on_tray_icon_event(|tray, event| {
            tauri_plugin_positioner::on_tray_event(tray.app_handle(), &event);
            if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = event {
                toggle_panel(tray.app_handle());
            }
        });
    if let Some(icon) = app.default_window_icon() {
        tray = tray.icon(icon.clone());
    }
    tray.build(app)?;
    Ok(())
}

/// The tray menu, the panel's buttons and `claudepult --app-command` all end here.
fn run_command(app: &AppHandle, name: &str) -> bool {
    match name {
        "panel" => show_panel(app),
        "settings" => open_settings_window(app),
        "quit" => app.exit(0),
        _ => return false,
    }
    true
}

// MARK: - Commands for the windows

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct UiTexts {
    lang: &'static str,
    rtl: bool,
    strings: serde_json::Value,
    version: &'static str,
    chosen: Option<String>,
    languages: Vec<LanguageItem>,
    show_tray_hint: bool,
}

#[derive(Serialize)]
struct LanguageItem {
    code: &'static str,
    name: &'static str,
}

#[tauri::command]
fn ui_texts(app: AppHandle) -> UiTexts {
    let lang = language(&app);
    let settings = app.state::<AppState>().settings.lock().unwrap().clone();
    UiTexts {
        lang,
        rtl: i18n::is_rtl(lang),
        strings: serde_json::from_str(strings_json(lang)).unwrap_or_default(),
        version: env!("CARGO_PKG_VERSION"),
        chosen: settings.language,
        languages: i18n::LANGUAGES.iter().map(|code| LanguageItem { code, name: i18n::native_name(code) }).collect(),
        // Windows 11 hides new tray icons under «^».
        show_tray_hint: cfg!(target_os = "windows") && !settings.tray_hint_seen,
    }
}

#[tauri::command]
fn set_language(app: AppHandle, code: Option<String>) {
    save(&app, |settings| settings.language = code.filter(|code| i18n::supported(code).is_some()));
    // Everything follows at once: the tray menu and both windows.
    if let (Some(tray), Ok(menu)) = (app.tray_by_id(TRAY_ID), tray_menu(&app)) {
        let _ = tray.set_menu(Some(menu));
    }
    for window in app.webview_windows().values() {
        let _ = window.eval("location.reload()");
    }
    app.state::<Limits>().update_tray(&app);
}

#[tauri::command]
fn dismiss_tray_hint(app: AppHandle) {
    save(&app, |settings| settings.tray_hint_seen = true);
}

#[tauri::command]
fn autostart_enabled(app: AppHandle) -> bool {
    app.autolaunch().is_enabled().unwrap_or(false)
}

/// Returns what it is now, which differs from what was asked when the system refused.
#[tauri::command]
fn set_autostart(app: AppHandle, enabled: bool) -> bool {
    let launcher = app.autolaunch();
    let result = if enabled { launcher.enable() } else { launcher.disable() };
    if let Err(error) = result {
        eprintln!("autostart: {error}");
    }
    launcher.is_enabled().unwrap_or(false)
}

#[tauri::command]
fn open_settings(app: AppHandle) {
    open_settings_window(&app);
}

#[tauri::command]
fn hide_panel(app: AppHandle) {
    if let Some(panel) = app.get_webview_window("panel") {
        let _ = panel.hide();
    }
}

#[tauri::command]
fn quit(app: AppHandle) {
    app.exit(0);
}

fn main() {
    let app = tauri::Builder::default()
        // First: a second launch only brings the panel forward in the copy that runs.
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| show_panel(app)))
        .plugin(tauri_plugin_autostart::init(MacosLauncher::LaunchAgent, None))
        .plugin(tauri_plugin_positioner::init())
        .plugin(tauri_plugin_notification::init())
        .manage(Limits::new())
        .manage(AppState { settings: Mutex::new(Settings::load(&paths::settings_file())) })
        .invoke_handler(tauri::generate_handler![
            ui_texts, set_language, dismiss_tray_hint, autostart_enabled, set_autostart, open_settings, hide_panel, quit,
            limits::limits_view, limits::refresh_limits
        ])
        .setup(|app| {
            // Only the tray icon, no Dock icon, when trying it out on a Mac.
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);
            let handle = app.handle().clone();
            build_panel(&handle)?;
            build_tray(&handle)?;
            handle.state::<Limits>().start(handle.clone());
            let for_ipc = handle.clone();
            if let Err(error) = ipc::serve(move |request| match request {
                Request::AppCommand(name) => {
                    let app = for_ipc.clone();
                    let known = claudepult_core::ipc::APP_COMMANDS.contains(&name.as_str());
                    if known {
                        let _ = for_ipc.run_on_main_thread(move || {
                            run_command(&app, &name);
                        });
                        Reply::Ok
                    } else {
                        Reply::Unknown
                    }
                }
            }) {
                eprintln!("claudepult link not started: {error}");
            }
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("AI Hub Bar could not start");

    app.run(|_app, event| {
        // Closing the settings window must not quit: the app lives in the tray until «Выйти».
        if let RunEvent::ExitRequested { api, code: None, .. } = event {
            api.prevent_exit();
        }
    });
}
