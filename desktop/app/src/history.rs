//! «История расхода» (the Mac's `UsageHistoryWindow`): Claude Code's tokens by day for the last weeks, from its
//! journals, kept in `usage-days.json` — the Mac's file and format — with the day's highest limits, a CSV export and
//! what the tokens would cost through the API at the person's own price against the plan's.

use std::path::PathBuf;
use std::sync::Mutex;

use chrono::{Duration, Utc};
use claudepult_core::token_usage::{self, UsageDay};
use claudepult_core::{ai, paths};
use serde::Serialize;
use tauri::{AppHandle, Manager};
use tauri_plugin_dialog::DialogExt;

#[derive(Default)]
pub struct History {
    scanner: Mutex<token_usage::Scanner>,
}

fn days_file() -> PathBuf {
    paths::data_dir().join("usage-days.json")
}

fn load() -> Vec<UsageDay> {
    std::fs::read_to_string(days_file()).ok().and_then(|text| serde_json::from_str(&text).ok()).unwrap_or_default()
}

fn save(days: &[UsageDay]) {
    if let Err(error) = std::fs::write(days_file(), serde_json::to_string(days).unwrap_or_else(|_| "[]".to_owned())) {
        eprintln!("usage days not saved: {error}");
    }
}

/// The limits as they stand now, for the day's highest figures (called on every reading of the limits).
pub fn note(session: Option<f64>, week: Option<f64>) {
    save(&token_usage::noting(&load(), session, week, Utc::now()));
}

/// Left once the first, long read is done (the days file itself appears earlier, with the first reading of the limits).
fn backfilled_file() -> PathBuf {
    paths::data_dir().join("usage-days-backfilled")
}

/// Reads what is new in the journals into the days. The first time three months back, then the last week.
fn refresh(app: &AppHandle) -> Vec<UsageDay> {
    let now = Utc::now();
    let first = !backfilled_file().exists();
    let reach = if first { 92 } else { 8 };
    let records = app.state::<History>().scanner.lock().unwrap().scan(&paths::claude_dir().join("projects"), reach, now - Duration::days(reach), now);
    let days = token_usage::merging(&load(), &records, now);
    save(&days);
    if first {
        let _ = std::fs::write(backfilled_file(), "");
    }
    days
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DayBar {
    /// `yyyy-MM-dd`.
    day: String,
    tokens: u64,
    /// «1,2 млн».
    text: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TodayLine {
    text: String,
    heading: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryView {
    /// «Сегодня»: the limits, today's spend by project, today's background runs, the other services.
    today: Vec<TodayLine>,
    days: Vec<DayBar>,
    total: String,
    /// Over the days with any use.
    average: String,
    busiest: Option<String>,
    /// Dollars at the person's Anthropic price; None when no price is set.
    cost: Option<f64>,
    plan_price: f64,
    verdict: Option<String>,
    /// The plan pays off.
    verdict_good: bool,
}

fn view(app: &AppHandle, days: &[UsageDay], period: i64) -> HistoryView {
    let texts = crate::strings(app);
    let (price, plan) = {
        let state = app.state::<crate::AppState>();
        let settings = state.settings.lock().unwrap();
        (ai::price(&settings.services(), "anthropic"), settings.claude_plan_price)
    };
    let shown = token_usage::recent(days, period, Utc::now());
    let used: Vec<&UsageDay> = shown.iter().filter(|day| day.tokens() > 0).collect();
    let total: u64 = used.iter().map(|day| day.tokens()).sum();
    let cost = price.map(|price| used.iter().map(|day| day.cost(price)).sum::<f64>());
    let ratio = cost.and_then(|cost| token_usage::plan_ratio(cost, period, plan));
    let today_key = token_usage::day_key(Utc::now());
    let (session_percent, week_percent, breakdown) = app.state::<crate::limits::Limits>().today(&crate::profiles::projects_root(app), &texts);
    let midnight = chrono::Local::now().date_naive().and_hms_opt(0, 0, 0).and_then(|t| t.and_local_timezone(chrono::Local).earliest()).map(|t| t.with_timezone(&Utc));
    let runs = app
        .state::<crate::runs::Runs>()
        .list()
        .iter()
        .filter(|run| midnight.is_some_and(|start| run.started_at >= start))
        .map(|run| {
            let outcome = if run.is_running() { None } else { Some(run.state == claudepult_core::runs::RunState::Succeeded) };
            (outcome, crate::runs::project_label(run), claudepult_core::launch::one_line(&run.task))
        })
        .collect();
    let others = app
        .state::<crate::hub::Hub>()
        .telegram_services(&texts)
        .into_iter()
        .filter_map(|service| {
            let limits: Vec<String> = service.windows.iter().filter_map(|w| w.percent.map(|p| format!("{} {} %", w.title, p.round() as i64))).collect();
            (!limits.is_empty()).then(|| format!("{} — {}", service.title, limits.join(", ")))
        })
        .collect();
    let input = token_usage::DayInput {
        session_percent,
        week_percent,
        breakdown,
        runs,
        others,
        cost: price.and_then(|price| days.iter().find(|day| day.day == today_key).map(|day| day.cost(price))),
        hits: crate::limits::hits_today(),
    };
    HistoryView {
        today: token_usage::day_lines(&input, &texts).into_iter().map(|(text, heading)| TodayLine { text, heading }).collect(),
        days: shown.iter().map(|day| DayBar { day: day.day.clone(), tokens: day.tokens(), text: token_usage::tokens_text(day.tokens(), &texts) }).collect(),
        total: token_usage::tokens_text(total, &texts),
        average: token_usage::tokens_text(if used.is_empty() { 0 } else { total / used.len() as u64 }, &texts),
        busiest: used.iter().max_by_key(|day| day.tokens()).map(|day| day.day.clone()),
        cost,
        plan_price: plan,
        verdict: ratio.map(|ratio| token_usage::plan_verdict(ratio, &texts)),
        verdict_good: ratio.is_some_and(|ratio| ratio >= 1.0),
    }
}

fn period_of(period: i64) -> i64 {
    if [7, 30, 90].contains(&period) { period } else { 30 }
}

/// The window's numbers; the journals are read first, off the window's thread.
#[tauri::command]
pub async fn history_view(app: AppHandle, period: i64) -> Result<HistoryView, String> {
    let reader = app.clone();
    let days = tauri::async_runtime::spawn_blocking(move || refresh(&reader)).await.map_err(|e| e.to_string())?;
    Ok(view(&app, &days, period_of(period)))
}

/// «Подписка, $ в месяц».
#[tauri::command]
pub fn set_plan_price(app: AppHandle, price: f64, period: i64) -> HistoryView {
    let price = if price.is_finite() && price > 0.0 { price.min(100_000.0) } else { 0.0 };
    crate::save(&app, |settings| settings.claude_plan_price = price);
    view(&app, &load(), period_of(period))
}

/// «Экспорт CSV…»: the shown days into a file the person chooses. Some(error text) when writing failed.
#[tauri::command]
pub async fn export_history(app: AppHandle, period: i64) -> Option<String> {
    let days = token_usage::recent(&load(), period_of(period), Utc::now());
    let mut dialog = app.dialog().file().add_filter("CSV", &["csv"]).set_file_name("AI Hub Bar usage.csv");
    if let Some(window) = app.get_webview_window("history") {
        dialog = dialog.set_parent(&window);
    }
    let mut path = tauri::async_runtime::spawn_blocking(move || dialog.blocking_save_file()).await.ok()??.into_path().ok()?;
    if path.extension().is_none() {
        path.set_extension("csv");
    }
    match std::fs::write(&path, token_usage::csv(&days)) {
        Ok(()) => {
            eprintln!("usage history exported");
            None
        }
        Err(error) => Some(error.to_string()),
    }
}

/// Opens (or brings forward) the window.
#[tauri::command]
pub fn open_history(app: AppHandle) {
    if let Some(panel) = app.get_webview_window("panel") {
        let _ = panel.hide();
    }
    if let Some(window) = app.get_webview_window("history") {
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
        return;
    }
    let title = format!("{} — {}", claudepult_core::APP_NAME, crate::strings(&app).t("История расхода"));
    crate::off_main_thread(move || {
        let _ = tauri::WebviewWindowBuilder::new(&app, "history", tauri::WebviewUrl::App("history.html".into())).title(title).inner_size(720.0, 520.0).min_inner_size(620.0, 420.0).center().build();
    });
}
