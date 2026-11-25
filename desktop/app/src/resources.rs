//! Stage 6 «Ресурсы компьютера» (SPEC-windows §4.10, the Mac's `SystemMonitor` and `ResourcesView`): a reading every
//! 30 s in the background for the alerts and the tray's hint, and every 2 s while the panel asks; the programs using
//! the most processor every 5 s. Only while the module is on.

use crate::{save, strings, AppState};
use claudepult_core::i18n::Strings;
use claudepult_core::resources::{self, Alert, Alerts, ProcessUsage, Sampler, Snapshot};
use serde::Serialize;
use serde_json::Value;
use std::sync::mpsc::{Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Manager};
use tauri_plugin_notification::NotificationExt;

const KIND: &str = "resources";
/// The Mac's `ResourceMetric`, in its order.
const METRICS: [&str; 7] = ["cpu", "memory", "gpu", "disk", "network", "battery", "processes"];

/// What the sampling thread asks for. `sysinfo`'s graphics counters (a PDH query on Windows, NVIDIA's library on
/// Linux) may not move between threads, so one thread owns the sampler and the others ask it.
enum Ask {
    /// A reading at most this old.
    Read(Duration, Sender<Snapshot>),
    Processes(Sender<Vec<ProcessUsage>>),
    /// The module was switched off: drop everything.
    Reset,
}

/// The sampler's own thread.
#[derive(Default)]
struct Owner {
    sampler: Option<Sampler>,
    snapshot: Option<Snapshot>,
    sampled: Option<Instant>,
    processes: Vec<ProcessUsage>,
    processes_at: Option<Instant>,
}

impl Owner {
    fn run(asks: Receiver<Ask>, last: Arc<Mutex<Option<Snapshot>>>) {
        let mut owner = Owner::default();
        for ask in asks {
            match ask {
                Ask::Read(fresh, reply) => {
                    let snapshot = owner.read(fresh);
                    *last.lock().unwrap() = Some(snapshot.clone());
                    let _ = reply.send(snapshot);
                }
                Ask::Processes(reply) => {
                    let _ = reply.send(owner.processes());
                }
                Ask::Reset => {
                    owner = Owner::default();
                    *last.lock().unwrap() = None;
                }
            }
        }
    }

    /// The very first reading is primed a second before, as on the Mac.
    fn read(&mut self, fresh: Duration) -> Snapshot {
        if let (Some(snapshot), Some(at)) = (&self.snapshot, self.sampled) {
            if at.elapsed() < fresh {
                return snapshot.clone();
            }
        }
        let sampler = self.sampler.get_or_insert_with(Sampler::new);
        if !sampler.primed() {
            sampler.sample();
            std::thread::sleep(Duration::from_secs(1));
        }
        let snapshot = sampler.sample();
        self.snapshot = Some(snapshot.clone());
        self.sampled = Some(Instant::now());
        snapshot
    }

    fn processes(&mut self) -> Vec<ProcessUsage> {
        if self.processes_at.is_none_or(|at| at.elapsed() >= Duration::from_secs(5)) {
            let sampler = self.sampler.get_or_insert_with(Sampler::new);
            let mut found = sampler.top_processes(5);
            if found.is_empty() {
                // The first call primes the processes' counters.
                std::thread::sleep(Duration::from_millis(500));
                found = sampler.top_processes(5);
            }
            self.processes = found;
            self.processes_at = Some(Instant::now());
        }
        self.processes.clone()
    }
}

#[derive(Clone, Default)]
pub struct Resources {
    asks: Arc<Mutex<Option<Sender<Ask>>>>,
    /// The last reading, for the tray's hint.
    last: Arc<Mutex<Option<Snapshot>>>,
    alerts: Arc<Mutex<Alerts>>,
}

impl Resources {
    pub fn start(&self, app: AppHandle) {
        let (sender, receiver) = std::sync::mpsc::channel();
        *self.asks.lock().unwrap() = Some(sender);
        let last = self.last.clone();
        std::thread::spawn(move || Owner::run(receiver, last));
        let this = self.clone();
        std::thread::spawn(move || loop {
            if on(&app) {
                if let Some(snapshot) = this.read(Duration::ZERO) {
                    let (alerts, disk_below) = {
                        let settings = app.state::<AppState>().settings.lock().unwrap().clone();
                        (settings.resource_alerts, settings.resource_disk_below_gb)
                    };
                    if alerts {
                        let fired = this.alerts.lock().unwrap().evaluate(&snapshot, disk_below, Instant::now());
                        for alert in fired {
                            notify(&app, &alert);
                        }
                    }
                }
            } else if this.last.lock().unwrap().is_some() {
                // Off: nothing is read and nothing kept.
                this.ask(Ask::Reset);
                *this.alerts.lock().unwrap() = Alerts::default();
            }
            app.state::<crate::limits::Limits>().update_tray(&app);
            std::thread::sleep(Duration::from_secs(30));
        });
    }

    fn ask(&self, ask: Ask) {
        if let Some(asks) = self.asks.lock().unwrap().as_ref() {
            let _ = asks.send(ask);
        }
    }

    fn read(&self, fresh: Duration) -> Option<Snapshot> {
        let (reply, answer) = std::sync::mpsc::channel();
        self.ask(Ask::Read(fresh, reply));
        answer.recv().ok()
    }

    fn processes(&self) -> Vec<ProcessUsage> {
        let (reply, answer) = std::sync::mpsc::channel();
        self.ask(Ask::Processes(reply));
        answer.recv().unwrap_or_default()
    }

    /// «Процессор 23 % · память 61 %» for the tray's hint, while the module is on.
    pub fn tray_line(&self, s: &Strings) -> Option<String> {
        let last = self.last.lock().unwrap();
        let snapshot = last.as_ref()?;
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
        Alert::Swap(used) => (
            s.t("Подкачка сильно выросла"),
            s.format("Занято %@: памяти давно не хватает, и подкачка занимает место на диске. Закройте тяжёлые приложения или перезагрузите компьютер.", &[&s.format("%lld ГБ", &[&((used + (1 << 29)) >> 30).to_string()])]),
        ),
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
        tauri::async_runtime::spawn_blocking(move || (resources.read(Duration::from_millis(1500)), resources.processes())).await.unwrap_or_default()
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
