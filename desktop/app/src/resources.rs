//! Stage 6 «Ресурсы компьютера» (SPEC-windows §4.10, the Mac's `SystemMonitor` and `ResourcesView`): a reading every
//! 30 s in the background for the alerts and the tray's hint, and every 2 s while the panel asks; the programs using
//! the most processor every 5 s. Only while the module is on.

use crate::{save, strings, AppState};
use claudepult_core::i18n::Strings;
use claudepult_core::resources::{self, Alert, Alerts, ProcessUsage, Sampler, Snapshot};
use serde::Serialize;
use serde_json::Value;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Manager};
use tauri_plugin_notification::NotificationExt;

const KIND: &str = "resources";
/// The Mac's `ResourceMetric`, in its order.
const METRICS: [&str; 7] = ["cpu", "memory", "gpu", "disk", "network", "battery", "processes"];

#[derive(Default)]
struct State {
    sampler: Option<Sampler>,
    alerts: Alerts,
    snapshot: Option<Snapshot>,
    sampled: Option<Instant>,
    processes: Vec<ProcessUsage>,
    processes_at: Option<Instant>,
}

#[derive(Clone, Default)]
pub struct Resources(Arc<Mutex<State>>);

impl Resources {
    pub fn start(&self, app: AppHandle) {
        let this = self.clone();
        std::thread::spawn(move || loop {
            if on(&app) {
                let snapshot = this.read(Duration::ZERO);
                let (alerts, disk_below) = {
                    let settings = app.state::<AppState>().settings.lock().unwrap().clone();
                    (settings.resource_alerts, settings.resource_disk_below_gb)
                };
                if alerts {
                    let fired = this.0.lock().unwrap().alerts.evaluate(&snapshot, disk_below, Instant::now());
                    for alert in fired {
                        notify(&app, &alert);
                    }
                }
            } else {
                // Off: nothing is read and nothing kept.
                *this.0.lock().unwrap() = State::default();
            }
            app.state::<crate::limits::Limits>().update_tray(&app);
            std::thread::sleep(Duration::from_secs(30));
        });
    }

    /// A reading at most `fresh` old; the very first one is primed a second before, as on the Mac.
    fn read(&self, fresh: Duration) -> Snapshot {
        let mut state = self.0.lock().unwrap();
        if let (Some(snapshot), Some(at)) = (&state.snapshot, state.sampled) {
            if at.elapsed() < fresh {
                return snapshot.clone();
            }
        }
        let sampler = state.sampler.get_or_insert_with(Sampler::new);
        if !sampler.primed() {
            sampler.sample();
            std::thread::sleep(Duration::from_secs(1));
        }
        let snapshot = sampler.sample();
        state.snapshot = Some(snapshot.clone());
        state.sampled = Some(Instant::now());
        snapshot
    }

    fn processes(&self) -> Vec<ProcessUsage> {
        let mut state = self.0.lock().unwrap();
        if state.processes_at.is_none_or(|at| at.elapsed() >= Duration::from_secs(5)) {
            let sampler = state.sampler.get_or_insert_with(Sampler::new);
            let mut found = sampler.top_processes(5);
            if found.is_empty() {
                // The first call primes the processes' counters.
                std::thread::sleep(Duration::from_millis(500));
                found = state.sampler.as_mut().map(|s| s.top_processes(5)).unwrap_or_default();
            }
            state.processes = found;
            state.processes_at = Some(Instant::now());
        }
        state.processes.clone()
    }

    /// «Процессор 23 % · память 61 %» for the tray's hint, while the module is on.
    pub fn tray_line(&self, s: &Strings) -> Option<String> {
        let state = self.0.lock().unwrap();
        let snapshot = state.snapshot.as_ref()?;
        Some(s.format("Процессор %lld %% · память %lld %%", &[&(snapshot.cpu.round() as i64).to_string(), &(snapshot.memory_percent().round() as i64).to_string()]))
    }
}

fn on(app: &AppHandle) -> bool {
    app.state::<AppState>().settings.lock().unwrap().module_on(KIND)
}

fn notify(app: &AppHandle, alert: &Alert) {
    let s = strings(app);
    let (title, body) = match alert {
        Alert::Cpu => (s.t("Процессор загружен"), s.t("Больше 90 % уже 5 минут. Кто нагружает — в панели, блок «Ресурсы компьютера».").to_owned()),
        Alert::Memory => (s.t("Памяти не хватает"), s.t("Система сообщает о критической нехватке памяти. Закройте лишние приложения.").to_owned()),
        Alert::Disk(free) => (s.t("Мало места на диске"), s.format("Свободно %@.", &[&s.format("%lld ГБ", &[&(free / 1_000_000_000).to_string()])])),
        Alert::Battery(percent) => (s.t("Батарея садится"), s.format("Осталось %lld %%. Подключите зарядку.", &[&percent.to_string()])),
    };
    eprintln!("resources alert: {alert:?}");
    let _ = app.notification().builder().title(title).body(body).show();
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResourcesView {
    /// The module is on and the current profile shows it.
    shown: bool,
    snapshot: Option<Snapshot>,
    processes: Vec<ProcessUsage>,
    /// The current profile's choice of rows (the Mac's `ProfileModule.metrics`); all when it made none.
    metrics: Vec<&'static str>,
    /// «Открыть Диспетчер задач»: Windows only.
    task_manager: bool,
}

/// The panel asks every 2 s while it is open.
#[tauri::command]
pub async fn resources_view(app: AppHandle) -> ResourcesView {
    let settings = app.state::<AppState>().settings.lock().unwrap().clone();
    let shown = settings.shows_module(KIND);
    let chosen: Option<Vec<String>> = settings
        .current()
        .and_then(|p| p.other.get("modules")?.as_array()?.iter().find(|m| m["kind"] == KIND)?.get("metrics")?.as_array().cloned())
        .map(|list| list.iter().filter_map(Value::as_str).map(str::to_owned).collect());
    let metrics = METRICS.into_iter().filter(|m| chosen.as_ref().is_none_or(|list| list.iter().any(|c| c == m))).collect();
    let resources = app.state::<Resources>().inner().clone();
    let (snapshot, processes) = if shown {
        tauri::async_runtime::spawn_blocking(move || (Some(resources.read(Duration::from_millis(1500))), resources.processes())).await.unwrap_or_default()
    } else {
        (None, Vec::new())
    };
    ResourcesView { shown, snapshot, processes, metrics, task_manager: cfg!(windows) }
}

#[tauri::command]
pub fn open_task_manager() -> Result<(), String> {
    if !cfg!(windows) {
        return Err("Windows only".into());
    }
    std::process::Command::new("taskmgr.exe").spawn().map(|_| ()).map_err(|e| e.to_string())
}

// MARK: - Settings → «Модули»

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResourceSettings {
    on: bool,
    alerts: bool,
    disk_below_gb: u64,
    thresholds: [u64; 5],
}

#[tauri::command]
pub fn resource_settings(app: AppHandle) -> ResourceSettings {
    let settings = app.state::<AppState>().settings.lock().unwrap().clone();
    ResourceSettings { on: settings.module_on(KIND), alerts: settings.resource_alerts, disk_below_gb: settings.resource_disk_below_gb, thresholds: resources::DISK_THRESHOLDS }
}

#[tauri::command]
pub fn set_resource_alerts(app: AppHandle, alerts: bool, disk_below_gb: u64) -> ResourceSettings {
    save(&app, |settings| {
        settings.resource_alerts = alerts;
        if resources::DISK_THRESHOLDS.contains(&disk_below_gb) {
            settings.resource_disk_below_gb = disk_below_gb;
        }
    });
    resource_settings(app)
}
