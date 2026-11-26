//! AI Hub Bar for Windows and Linux (docs/specs/SPEC-windows.md §9): stage 1 «Каркас» — the tray icon, the panel at it,
//! the settings window, 13 languages, one running copy, start at sign-in and `claudepult --app-command`;
//! stage 2 «Лимиты» in `limits.rs`; stage 3 «Сессии» in `sessions.rs` and the `claudepult-hook` program; stage 4
//! «Проекты» in `projects.rs`; stage 5 «Профили» in `profiles.rs`.

// No console window behind the app in a release build on Windows.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod assistant;
mod batch;
mod calendar;
mod changes;
mod claude_config;
mod clipboard;
mod commands;
mod accounts;
mod help;
mod pair_compare;
mod crash;
mod history;
mod skills;
mod versions;
mod local_servers;
mod hub;
mod keep_awake;
mod notes;
mod search;
mod limits;
mod profiles;
mod resources;
mod projects;
mod queue;
mod quick_prompt;
mod quick_commands;
mod command_hot_keys;
mod runs;
mod services;
mod sessions;
mod telegram;
mod toggles;
mod updates;

use claudepult_core::i18n::{self, Strings};
use claudepult_core::ipc::{self, Reply, Request};
use claudepult_core::settings::Settings;
use claudepult_core::{paths, APP_NAME};
use serde::Serialize;
use std::sync::Mutex;
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager, RunEvent, WebviewUrl, WebviewWindowBuilder, WindowEvent};
use tauri_plugin_autostart::{MacosLauncher, ManagerExt};
use limits::Limits;
use projects::Projects;
use runs::Runs;
use sessions::Sessions;
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
    Strings::of(language(app), strings_json(language(app)))
}

/// The settings file; one from before profiles becomes the first profile. A first start has none: the assistant
/// opens (`setup`).
fn load_settings() -> Settings {
    let mut settings = Settings::load(&paths::settings_file());
    if settings.migrate_profile(i18n::resolve(settings.language.as_deref())) {
        eprintln!("profiles: «{}» made", settings.current().map(|p| p.name.as_str()).unwrap_or_default());
        if let Err(error) = settings.save(&paths::settings_file()) {
            eprintln!("settings not saved: {error}");
        }
    }
    settings
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

/// The corner is the screen's, and on Windows the taskbar lies there: the panel's lowest buttons were under it and
/// took no clicks. Moves the panel back inside the monitor's work area.
fn keep_off_the_taskbar(panel: &tauri::WebviewWindow) {
    let (Ok(Some(monitor)), Ok(at), Ok(size)) = (panel.current_monitor(), panel.outer_position(), panel.outer_size()) else { return };
    let area = monitor.work_area();
    let (x, y) = fit_into(
        (at.x, at.y),
        (size.width as i32, size.height as i32),
        (area.position.x, area.position.y),
        (area.size.width as i32, area.size.height as i32),
    );
    if (x, y) != (at.x, at.y) {
        let _ = panel.set_position(tauri::PhysicalPosition::new(x, y));
    }
}

/// A window's top left corner moved so that the window lies inside the area (its top left kept when it can't fit).
fn fit_into(at: (i32, i32), size: (i32, i32), area_at: (i32, i32), area_size: (i32, i32)) -> (i32, i32) {
    let fit = |at: i32, size: i32, from: i32, length: i32| at.min(from + length - size).max(from);
    (fit(at.0, size.0, area_at.0, area_size.0), fit(at.1, size.1, area_at.1, area_size.1))
}

fn show_panel(app: &AppHandle) {
    let Some(panel) = app.get_webview_window("panel") else { return };
    // At the icon — TrayCenter flips to whichever side has room — once a click has told where it is.
    if panel.move_window(Position::TrayCenter).is_err() {
        let _ = panel.move_window(corner());
        keep_off_the_taskbar(&panel);
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

/// The page Settings should open on, for a window that is not built yet: its page asks for it once loaded.
static SETTINGS_PAGE: Mutex<Option<String>> = Mutex::new(None);

fn open_settings_window(app: &AppHandle) {
    open_settings_page(app, None);
}

/// Settings on one of its pages («services», «general», «module.quickPrompt»…); `None` leaves the page it has, and a
/// new window comes up on the one looked at last.
pub(crate) fn open_settings_page(app: &AppHandle, page: Option<&str>) {
    if let Some(panel) = app.get_webview_window("panel") {
        let _ = panel.hide();
    }
    if let Some(window) = app.get_webview_window("settings") {
        if let Some(page) = page {
            let _ = window.emit("settings-page", page);
        }
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
        return;
    }
    *SETTINGS_PAGE.lock().unwrap() = page.map(str::to_owned);
    let title = format!("{APP_NAME} — {}", strings(app).t("Настройки…").trim_end_matches('…'));
    let app = app.clone();
    off_main_thread(move || {
        // The Mac's proportions (940 × 700, at least 820 × 560), smaller: a sidebar and a page beside it.
        let _ = WebviewWindowBuilder::new(&app, "settings", WebviewUrl::App("settings.html".into()))
            .title(title)
            .inner_size(860.0, 640.0)
            .min_inner_size(680.0, 480.0)
            .center()
            .build();
    });
}

#[tauri::command]
fn take_settings_page() -> Option<String> {
    SETTINGS_PAGE.lock().unwrap().take()
}

/// Where every window but the panel is built. Commands, the tray menu and the hot key run on the main thread, and
/// on Windows a window built there comes up white: WebView2 waits for the very thread that waits for it.
pub(crate) fn off_main_thread(build: impl FnOnce() + Send + 'static) {
    std::thread::spawn(build);
}

const PANEL_HEIGHT: f64 = 600.0;

fn build_panel(app: &AppHandle) -> tauri::Result<()> {
    let panel = WebviewWindowBuilder::new(app, "panel", WebviewUrl::App("panel.html".into()))
        .title(APP_NAME)
        .inner_size(380.0, PANEL_HEIGHT)
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
        &MenuItem::with_id(app, "skills", skills::menu_title(app), true, None::<&str>)?,
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
        "quick-prompt" => quick_prompt::show(app),
        "search" => search::show(app),
        "help" => help::show(app),
        "skills" => skills::show(app),
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
    /// «Размер текста»: every page is scaled by this.
    text_scale: f64,
    /// «Плотность строк»: the panel's spacing is multiplied by this.
    density: f64,
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
        chosen: settings.language.clone(),
        languages: i18n::LANGUAGES.iter().map(|code| LanguageItem { code, name: i18n::native_name(code) }).collect(),
        // Windows 11 hides new tray icons under «^».
        show_tray_hint: cfg!(target_os = "windows") && !settings.tray_hint_seen,
        text_scale: settings.text_size().1,
        density: settings.panel_density().1,
    }
}

/// «Что нового»: the lines of the card, or none when it is not to be shown.
#[tauri::command]
fn whats_new_view(app: AppHandle) -> Vec<String> {
    let settings = app.state::<AppState>().settings.lock().unwrap().clone();
    if claudepult_core::whats_new::should_show(settings.whats_new_seen.as_deref(), !settings.profiles.is_empty()) {
        claudepult_core::whats_new::items(&strings(&app))
    } else {
        Vec::new()
    }
}

/// «Понятно» or «Открыть настройки»: the card is not shown again until a version with news.
#[tauri::command]
fn whats_new_seen(app: AppHandle) {
    save(&app, |settings| settings.whats_new_seen = Some(claudepult_core::whats_new::VERSION.to_owned()));
}

#[derive(Serialize)]
struct Choice {
    id: &'static str,
    title: String,
}

#[derive(Serialize)]
struct AppearanceView {
    theme: &'static str,
    themes: Vec<Choice>,
    text_size: &'static str,
    text_sizes: Vec<Choice>,
    width: &'static str,
    widths: Vec<Choice>,
    density: &'static str,
    densities: Vec<Choice>,
    limits_style: &'static str,
    limits_styles: Vec<Choice>,
}

/// The theme of every window: the system's, or the chosen one.
fn apply_theme(app: &AppHandle) {
    let theme = match app.state::<AppState>().settings.lock().unwrap().theme() {
        "light" => Some(tauri::Theme::Light),
        "dark" => Some(tauri::Theme::Dark),
        _ => None,
    };
    app.set_theme(theme);
}

#[tauri::command]
fn appearance_view(app: AppHandle) -> AppearanceView {
    let texts = strings(&app);
    let settings = app.state::<AppState>().settings.lock().unwrap().clone();
    let choice = |id: &'static str, title: &str| Choice { id, title: title.to_owned() };
    AppearanceView {
        theme: settings.theme(),
        themes: vec![choice("system", texts.t("Как в системе")), choice("light", texts.t("Светлая")), choice("dark", texts.t("Тёмная"))],
        text_size: settings.text_size().0,
        text_sizes: vec![choice("small", texts.t("Мелкий")), choice("normal", texts.t("Обычный")), choice("large", texts.t("Крупный")), choice("extraLarge", texts.t("Очень крупный"))],
        width: settings.panel_width().0,
        widths: vec![choice("narrow", texts.t("Узкая")), choice("normal", texts.t("Обычная")), choice("wide", texts.t("Широкая"))],
        density: settings.panel_density().0,
        limits_style: settings.limits_style(),
        limits_styles: vec![choice("bars", texts.t("Полосы")), choice("rings", texts.t("Кольца"))],
        densities: vec![choice("compact", texts.t("Плотно")), choice("normal", texts.t("Обычно")), choice("spacious", texts.t("Просторно"))],
    }
}

/// The panel as wide as «Ширина» says, wider with a larger text.
fn size_panel(app: &AppHandle) {
    let settings = app.state::<AppState>().settings.lock().unwrap().clone();
    if let Some(panel) = app.get_webview_window("panel") {
        let _ = panel.set_size(tauri::LogicalSize::new((settings.panel_width().1 * settings.text_size().1).round(), PANEL_HEIGHT));
    }
}

/// «Тема», «Размер текста», «Ширина» and «Плотность строк»: every window follows at once.
#[tauri::command]
fn set_appearance(app: AppHandle, theme: String, text_size: String, width: String, density: String, limits_style: String) -> AppearanceView {
    save(&app, |settings| {
        settings.set_appearance(&theme, &text_size);
        settings.set_panel_shape(&width, &density);
        settings.set_limits_style(&limits_style);
    });
    let _ = app.emit("limits-changed", ());
    apply_theme(&app);
    size_panel(&app);
    if let Some(panel) = app.get_webview_window("panel") {
        let density = app.state::<AppState>().settings.lock().unwrap().panel_density().1;
        let _ = panel.eval(format!("document.documentElement.style.setProperty('--density', {density})"));
    }
    let scale = app.state::<AppState>().settings.lock().unwrap().text_size().1;
    for window in app.webview_windows().values() {
        let _ = window.eval(format!("document.documentElement.style.zoom = {scale}"));
    }
    appearance_view(app)
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
    app.state::<Projects>().ask(false);
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct LaunchSettings {
    /// `terminal`, `background`, or None — ask.
    mode: Option<String>,
    time_limit_minutes: u32,
}

#[tauri::command]
fn launch_settings(app: AppHandle) -> LaunchSettings {
    let settings = app.state::<AppState>().settings.lock().unwrap().clone();
    LaunchSettings { mode: settings.launch_mode(), time_limit_minutes: settings.background_time_limit_minutes }
}

#[tauri::command]
fn set_launch_settings(app: AppHandle, mode: Option<String>, time_limit_minutes: u32) {
    save(&app, |settings| {
        settings.set_launch_mode(mode);
        settings.background_time_limit_minutes = time_limit_minutes.clamp(5, 24 * 60);
    });
}

#[tauri::command]
fn pull_request_alerts(app: AppHandle) -> bool {
    app.state::<AppState>().settings.lock().unwrap().pull_request_alerts
}

#[tauri::command]
fn set_pull_request_alerts(app: AppHandle, enabled: bool) {
    save(&app, |settings| settings.pull_request_alerts = enabled);
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
fn open_settings(app: AppHandle, page: Option<String>) {
    open_settings_page(&app, page.as_deref());
}

#[tauri::command]
fn hide_panel(app: AppHandle) {
    if let Some(panel) = app.get_webview_window("panel") {
        let _ = panel.hide();
    }
}

#[tauri::command]
fn quit(app: AppHandle) {
    app.state::<keep_awake::KeepAwake>().release();
    app.exit(0);
}

fn main() {
    // A panic of the app leaves a report the next start offers to send (the Mac's crash report).
    claudepult_core::crash::install(crash::dir(), env!("CARGO_PKG_VERSION"));
    // A first start: nothing saved yet, so the assistant makes the first profile (the Mac's empty start).
    let first_start = !paths::settings_file().exists();
    let app = tauri::Builder::default()
        // First: a second launch only brings the panel forward in the copy that runs.
        .plugin(tauri_plugin_single_instance::init(|app, args, cwd| {
            // A second launch: a `.claudepult` opened with a double click goes to the import, anything else shows the panel.
            let args = args.into_iter().map(|a| if std::path::Path::new(&a).is_relative() { std::path::Path::new(&cwd).join(&a).to_string_lossy().into_owned() } else { a });
            match profiles::import_argument(args.skip(1)) {
                Some(file) => profiles::open_import_file(app, &file),
                None => show_panel(app),
            }
        }))
        .plugin(tauri_plugin_autostart::init(MacosLauncher::LaunchAgent, None))
        .plugin(tauri_plugin_positioner::init())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(quick_prompt::plugin())
        .manage(Limits::new())
        .manage(Sessions::default())
        .manage(Projects::default())
        .manage(Runs::default())
        .manage(commands::Jobs::default())
        .manage(services::Checks::default())
        .manage(services::Agents::default())
        .manage(calendar::Calendar::default())
        .manage(keep_awake::KeepAwake::default())
        .manage(resources::Resources::default())
        .manage(quick_commands::QuickCommands::default())
        .manage(toggles::Toggles::default())
        .manage(clipboard::Clipboard::default())
        .manage(search::SearchKey::default())
        .manage(claude_config::ClaudeConfig::default())
        .manage(queue::Queue::default())
        .manage(batch::Batches::default())
        .manage(changes::ChangesStore::default())
        .manage(hub::Hub::default())
        .manage(accounts::Accounts::default())
        .manage(versions::Keeper::default())
        .manage(pair_compare::PairCompare::default())
        .manage(updates::Updates::default())
        .manage(history::History::default())
        .manage(telegram::Telegram::default())
        .manage(quick_prompt::QuickPrompt::default())
        .manage(command_hot_keys::CommandHotKeys::default())
        .manage(AppState { settings: Mutex::new(load_settings()) })
        .invoke_handler(tauri::generate_handler![
            batch::batch_start,
            batch::batch_cancel,
            batch::batch_dismiss,
            ui_texts, set_language, dismiss_tray_hint, autostart_enabled, set_autostart, open_settings, take_settings_page, hide_panel, quit,
            limits::limits_view, limits::spend_view, limits::limit_thresholds, limits::set_limit_thresholds, limits::renew_claude_login, limits::set_renew_claude_login, limits::open_status_page, limits::refresh_limits,
            sessions::sessions_view, sessions::decide_request, sessions::resume_session, sessions::hooks_state, sessions::install_hooks,
            sessions::uninstall_hooks, sessions::agent_hooks_state, sessions::install_agent_hooks, sessions::uninstall_agent_hooks,
            projects::projects_view, projects::refresh_projects, projects::projects_panel_opened, projects::open_project,
            projects::open_link, projects::launch_claude, projects::set_project_stage, projects::create_project_card,
            projects::create_folder_project, projects::open_project_file, commands::run_folder_command,
            commands::clear_finished_jobs, commands::compare_folder_command, services::services_view, services::set_api_budget, services::set_api_price, services::check_api,
            services::save_api_key, services::delete_api_key, services::set_api_model, services::set_compatible_server, services::open_key_page,
            services::agents_view, services::copy_install_command, projects::open_agent, calendar::upcoming_view,
            calendar::open_upcoming, calendar::reminder_hours, calendar::set_reminder_hours, calendar::set_profile_calendar,
            calendar::open_calendar, calendar::calendar_view, calendar::export_calendar, local_servers::project_servers, local_servers::open_local_server, local_servers::stop_local_server, calendar::reread_calendar, calendar::move_calendar_entry,
            calendar::add_calendar_date, assistant::open_assistant, assistant::assistant_start, assistant::assistant_look,
            assistant::assistant_choose_folder, assistant::assistant_apply_folder, assistant::assistant_finish,
            runs::stop_run, runs::run_log, projects::worktree_removal, launch_settings, set_launch_settings,
            telegram::telegram_view, telegram::telegram_save_token, telegram::telegram_remove_token, telegram::telegram_bind,
            telegram::telegram_cancel_binding, telegram::telegram_set_chat, telegram::telegram_test, telegram::set_telegram_event,
            telegram::set_telegram_answers, telegram::set_telegram_requests,
            claude_config::open_claude_config, claude_config::claude_config_view, claude_config::claude_config_edit, claude_config::claude_config_save,
            claude_config::claude_config_open, claude_config::set_mcp_server, claude_config::set_agent_skill, claude_config::set_claude_plugin,
            changes::open_changed, projects::launch_both, runs::hand_over_run, runs::review_run, queue::resume_run_now, queue::run_guard, queue::set_run_guard, queue::queue_launch, queue::queued_view, queue::cancel_queued, queue::night_hour, queue::set_night_hour,
            pair_compare::open_pair_compare, pair_compare::pair_view, pair_compare::pair_file_diff, pair_compare::pair_between_diff,
            pair_compare::pair_action, pair_compare::pair_open_folder, help::open_help, help::help_view, crash::crash_reports_asked, crash::set_crash_reports_asked, versions::open_versions, versions::versions_view, versions::version_compare, versions::version_restore,
            versions::version_questions, versions::version_open_file, versions::versions_settings, versions::set_versions_settings, versions::clear_versions, versions::open_versions_folder, help::open_feedback, accounts::claude_accounts, accounts::add_claude_account, accounts::rename_claude_account,
            accounts::remove_claude_account, accounts::sign_in_claude_account, accounts::refresh_claude_accounts, skills::open_skills, skills::skills_texts, skills::skills_refresh, skills::skills_search, skills::skills_card, skills::skills_preview, skills::skills_show_folder, skills::skills_add_folder, skills::skills_forget, skills::skills_plan_install, skills::skills_install, skills::skills_remove, skills::skills_set_enabled, skills::skills_journal, skills::skills_restore, skills::skills_updates, skills::skills_plan_update, skills::skills_update, history::open_history, history::day_summary_settings, history::set_day_summary, history::send_day_summary, history::history_view, history::set_plan_price, history::export_history,
            updates::updates_view, updates::set_updates_daily, updates::check_updates, updates::install_update,
            pull_request_alerts, set_pull_request_alerts, profiles::projects_folder, profiles::choose_projects_folder,
            profiles::reset_projects_folder, profiles::profiles_view, profiles::select_profile, profiles::add_profile, profiles::profile_templates,
            profiles::rename_profile, profiles::delete_profile, profiles::profile_details, profiles::set_profile_field,
            profiles::export_settings, profiles::export_profile,
            keep_awake::keep_awake_view, keep_awake::keep_awake_hold, keep_awake::keep_awake_release, keep_awake::modules_view,
            keep_awake::set_module, keep_awake::set_keep_awake_rules, keep_awake::choose_keep_awake_apps,
            resources::resources_view, resources::open_task_manager, resources::resource_settings, resources::set_resource_alerts,
            quick_commands::quick_commands_view, quick_commands::run_quick_command, quick_commands::quick_commands_library,
            quick_commands::set_quick_commands, quick_commands::new_quick_command, clipboard::clipboard_view, clipboard::clipboard_copy, clipboard::clipboard_pin, clipboard::clipboard_remove, clipboard::clipboard_clear,
            clipboard::clipboard_settings, clipboard::add_clipboard_excluded, clipboard::remove_clipboard_excluded, clipboard::set_clipboard_options, appearance_view, set_appearance, whats_new_view, whats_new_seen, search::search_key_view, search::set_search_hot_key, search::panel_search, search::saved_prompts_view, search::set_saved_prompts, search::add_saved_prompt, search::prompt_projects,
            search::fill_saved_prompt, notes::notes_view, notes::notes_select, notes::notes_create, notes::notes_save, notes::notes_trash, notes::notes_open,
            notes::notes_settings, notes::choose_notes_folder, notes::open_notes_folder, toggles::toggles_view, toggles::perform_toggle,
            toggles::quick_toggle_settings, toggles::set_quick_toggles, hub::hub_view, hub::refresh_hub, hub::hub_settings,
            hub::set_hub_enabled, hub::save_hub_key, hub::delete_hub_key, hub::set_gemini_options, hub::open_hub_key_page,
            hub::main_service, hub::set_main_service, limits::tray_styles, limits::set_tray_style, quick_prompt::quick_prompt_start, quick_prompt::quick_prompt_send,
            quick_prompt::quick_prompt_settings, quick_prompt::set_quick_prompt_hot_key, quick_prompt::open_quick_prompt,
            quick_prompt::close_quick_prompt, command_hot_keys::hot_key_from_press, command_hot_keys::set_hot_key_recording,
            profiles::choose_import, profiles::import_view, profiles::apply_import, profiles::cancel_import
        ])
        .setup(move |app| {
            // Only the tray icon, no Dock icon, when trying it out on a Mac.
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);
            let handle = app.handle().clone();
            build_panel(&handle)?;
            size_panel(&handle);
            build_tray(&handle)?;
            handle.state::<Limits>().start(handle.clone());
            handle.state::<Sessions>().start(handle.clone());
            handle.state::<Projects>().start(handle.clone());
            handle.state::<Runs>().start(handle.clone());
            handle.state::<queue::Queue>().start(handle.clone());
            handle.state::<batch::Batches>().start(handle.clone());
            services::Agents::start(&handle);
            handle.state::<calendar::Calendar>().start(handle.clone());
            apply_theme(&handle);
            handle.state::<keep_awake::KeepAwake>().start(handle.clone());
            handle.state::<clipboard::Clipboard>().start(handle.clone());
            handle.state::<resources::Resources>().start(handle.clone());
            handle.state::<hub::Hub>().start(handle.clone());
            history::start_day_summary(handle.clone());
            skills::start_update_watch(handle.clone());
            versions::Keeper::start(handle.clone());
            let for_crash = handle.clone();
            std::thread::spawn(move || crash::check_at_start(&for_crash));
            handle.state::<accounts::Accounts>().start(handle.clone());
            command_hot_keys::sync(&handle);
            updates::watch(handle.clone());
            telegram::start(handle.clone());
            // Started by a double click on a `.claudepult` file.
            if let Some(file) = profiles::import_argument(std::env::args().skip(1)) {
                profiles::open_import_file(&handle, &file);
            }
            if first_start {
                // A new person has nothing to compare with.
                save(&handle, |settings| settings.whats_new_seen = Some(claudepult_core::whats_new::VERSION.to_owned()));
            }
            if first_start && handle.state::<AppState>().settings.lock().unwrap().profiles.is_empty() {
                eprintln!("first start: the assistant opens");
                assistant::open_assistant(handle.clone());
            }
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

    app.run(|app, event| {
        // Closing the settings window must not quit: the app lives in the tray until «Выйти».
        match event {
            RunEvent::ExitRequested { api, code: None, .. } => api.prevent_exit(),
            RunEvent::Exit => {
                sessions::stop();
                app.state::<keep_awake::KeepAwake>().release();
            }
            _ => {}
        }
    });
}

#[cfg(test)]
mod tests {
    use super::fit_into;

    #[test]
    fn the_panel_stays_above_the_taskbar() {
        // 1920×1080 with a 60 px taskbar at the bottom: the screen's corner puts 60 px of the panel under it.
        assert_eq!(fit_into((1445, 330), (475, 750), (0, 0), (1920, 1020)), (1445, 270));
        // Inside already: left where it is.
        assert_eq!(fit_into((1200, 200), (475, 750), (0, 0), (1920, 1020)), (1200, 200));
        // A taskbar on the left or the top, and a second monitor to the left of the first.
        assert_eq!(fit_into((0, 0), (475, 750), (60, 40), (1860, 1040)), (60, 40));
        assert_eq!(fit_into((-500, 400), (475, 750), (-1920, 0), (1920, 1020)), (-500, 270));
        // Taller than the area: the top stays in sight.
        assert_eq!(fit_into((100, 300), (475, 1200), (0, 0), (1920, 1020)), (100, 0));
    }
}
