//! «Ресурсы компьютера» (SPEC-profiles §4.1, SPEC-windows §4.10), the Mac's `SystemSampler` / `ResourceAlerts`:
//! processor, memory, the system disk, network, battery, graphics and the programs using the most processor, with
//! the same alerts. Counters come from `sysinfo` on every system; the battery from `GetSystemPowerStatus` (or
//! `/sys/class/power_supply`), a memory shortage from Windows' own low memory signal (or the share of free memory).

use serde::Serialize;
use std::collections::HashMap;
use std::time::{Duration, Instant};
use sysinfo::{Disks, Gpus, Networks, ProcessRefreshKind, ProcessesToUpdate, System};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Pressure {
    Normal,
    Warning,
    Critical,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Battery {
    pub percent: u8,
    pub charging: bool,
    pub on_ac: bool,
    /// Minutes to empty on battery; None while the system is still estimating.
    pub minutes_left: Option<u32>,
}

/// One reading. Nothing here needs a permission.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub cpu: f64,
    pub memory_used: u64,
    pub memory_total: u64,
    pub pressure: Pressure,
    pub disk_free: u64,
    pub disk_total: u64,
    /// Bytes per second over every interface but loopback.
    pub network_in: f64,
    pub network_out: f64,
    pub battery: Option<Battery>,
    /// Graphics load, when the system reports it.
    pub gpu: Option<f64>,
}

impl Snapshot {
    pub fn memory_percent(&self) -> f64 {
        if self.memory_total == 0 { 0.0 } else { self.memory_used as f64 / self.memory_total as f64 * 100.0 }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ProcessUsage {
    pub name: String,
    /// Percent of one core, as `ps` and Task Manager's «Details» count it, summed over a program's processes.
    pub cpu: f64,
}

/// Reads the counters. The processor and network numbers are differences between two readings, so the first one
/// only primes them.
pub struct Sampler {
    system: System,
    networks: Option<Networks>,
    disks: Option<Disks>,
    gpus: Option<Gpus>,
    last: Option<Instant>,
    processes_primed: bool,
    memory: memory::Signal,
}

impl Default for Sampler {
    fn default() -> Self {
        Sampler::new()
    }
}

impl Sampler {
    pub fn new() -> Sampler {
        Sampler {
            system: System::new().unwrap_or_else(|_| panic!("sysinfo can't read this system")),
            networks: Networks::new_with_refreshed_list().ok(),
            disks: Disks::new_with_refreshed_list().ok(),
            gpus: Gpus::new_with_refreshed_list().ok(),
            last: None,
            processes_primed: false,
            memory: memory::Signal::new(),
        }
    }

    /// Whether a reading has primed the differences.
    pub fn primed(&self) -> bool {
        self.last.is_some()
    }

    pub fn sample(&mut self) -> Snapshot {
        let now = Instant::now();
        let seconds = self.last.map(|at| now.duration_since(at).as_secs_f64()).filter(|s| *s > 0.0);
        self.last = Some(now);
        self.system.refresh_cpu_usage();
        self.system.refresh_memory();
        let (network_in, network_out) = match self.networks.as_mut() {
            Some(networks) => {
                networks.refresh(true);
                let (down, up) = networks
                    .iter()
                    .filter(|(name, _)| !is_loopback(&name.to_string_lossy()))
                    .fold((0u64, 0u64), |(down, up), (_, data)| (down + data.received(), up + data.transmitted()));
                seconds.map_or((0.0, 0.0), |s| (down as f64 / s, up as f64 / s))
            }
            None => (0.0, 0.0),
        };
        let (disk_free, disk_total) = self.system_disk();
        let gpu = self.gpus.as_mut().and_then(|gpus| {
            gpus.refresh(false);
            gpus.iter().filter_map(|g| g.usage()).map(f64::from).reduce(f64::max)
        });
        let (used, total, available) = (self.system.used_memory(), self.system.total_memory(), self.system.available_memory());
        Snapshot {
            cpu: if seconds.is_some() { f64::from(self.system.global_cpu_usage()) } else { 0.0 },
            memory_used: used,
            memory_total: total,
            pressure: pressure(self.memory.low(), available, total),
            disk_free,
            disk_total,
            network_in,
            network_out,
            battery: battery::read(),
            gpu,
        }
    }

    /// The disk the system is on: `%SystemDrive%` on Windows, `/` elsewhere.
    fn system_disk(&mut self) -> (u64, u64) {
        let Some(disks) = self.disks.as_mut() else { return (0, 0) };
        disks.refresh(true);
        let root = if cfg!(windows) { format!("{}\\", std::env::var("SystemDrive").unwrap_or_else(|_| "C:".into())) } else { "/".into() };
        disks
            .iter()
            .find(|d| d.mount_point().to_string_lossy().eq_ignore_ascii_case(&root))
            .map(|d| (d.available_space(), d.total_space()))
            .unwrap_or((0, 0))
    }

    /// The programs using the most processor since the last call, a program's processes summed. The first call
    /// primes and returns nothing.
    pub fn top_processes(&mut self, limit: usize) -> Vec<ProcessUsage> {
        self.system.refresh_processes_specifics(ProcessesToUpdate::All, true, ProcessRefreshKind::nothing().with_cpu());
        if !std::mem::replace(&mut self.processes_primed, true) {
            return Vec::new();
        }
        let mut by_name: HashMap<String, f64> = HashMap::new();
        for process in self.system.processes().values() {
            let name = process.name().to_string_lossy();
            let name = name.strip_suffix(".exe").or_else(|| name.strip_suffix(".EXE")).unwrap_or(&name).to_owned();
            *by_name.entry(name).or_default() += f64::from(process.cpu_usage());
        }
        top(by_name, limit)
    }
}

fn is_loopback(name: &str) -> bool {
    let name = name.to_lowercase();
    name == "lo" || name.starts_with("lo0") || name.contains("loopback")
}

fn top(by_name: HashMap<String, f64>, limit: usize) -> Vec<ProcessUsage> {
    let mut list: Vec<ProcessUsage> = by_name.into_iter().filter(|(name, cpu)| *cpu > 0.0 && !name.is_empty() && name != "System Idle Process").map(|(name, cpu)| ProcessUsage { name, cpu }).collect();
    list.sort_by(|a, b| b.cpu.total_cmp(&a.cpu).then_with(|| a.name.cmp(&b.name)));
    list.truncate(limit);
    list
}

/// The system's own low memory signal when it has one (Windows); else less than 5 % free is critical. Over 90 %
/// used is «повышено».
pub fn pressure(system_low: Option<bool>, available: u64, total: u64) -> Pressure {
    let free = if total == 0 { 1.0 } else { available as f64 / total as f64 };
    match system_low {
        Some(true) => Pressure::Critical,
        None if free < 0.05 => Pressure::Critical,
        _ if free < 0.10 => Pressure::Warning,
        _ => Pressure::Normal,
    }
}

#[cfg(windows)]
mod memory {
    use windows_sys::Win32::Foundation::HANDLE;
    use windows_sys::Win32::System::Memory::{CreateMemoryResourceNotification, LowMemoryResourceNotification, QueryMemoryResourceNotification};

    /// Windows' «low memory» notification object, the same one the system itself raises.
    pub struct Signal(HANDLE);

    // A kernel object, usable from any thread.
    unsafe impl Send for Signal {}

    impl Signal {
        pub fn new() -> Signal {
            Signal(unsafe { CreateMemoryResourceNotification(LowMemoryResourceNotification) })
        }

        pub fn low(&self) -> Option<bool> {
            if self.0.is_null() {
                return None;
            }
            let mut state = 0;
            (unsafe { QueryMemoryResourceNotification(self.0, &mut state) } != 0).then_some(state != 0)
        }
    }
}

#[cfg(not(windows))]
mod memory {
    pub struct Signal;

    impl Signal {
        pub fn new() -> Signal {
            Signal
        }

        pub fn low(&self) -> Option<bool> {
            None
        }
    }
}

mod battery {
    use super::Battery;

    #[cfg(windows)]
    pub fn read() -> Option<Battery> {
        use windows_sys::Win32::System::Power::{GetSystemPowerStatus, SYSTEM_POWER_STATUS};
        let mut status = SYSTEM_POWER_STATUS::default();
        if unsafe { GetSystemPowerStatus(&mut status) } == 0 {
            return None;
        }
        super::battery_of(status.ACLineStatus, status.BatteryFlag, status.BatteryLifePercent, status.BatteryLifeTime)
    }

    /// Linux: the first `BAT*` in `/sys/class/power_supply`; the time left from energy and power when on battery.
    #[cfg(not(windows))]
    pub fn read() -> Option<Battery> {
        let dir = std::fs::read_dir("/sys/class/power_supply").ok()?.flatten().find(|e| e.file_name().to_string_lossy().starts_with("BAT"))?.path();
        let read = |name: &str| std::fs::read_to_string(dir.join(name)).ok().map(|s| s.trim().to_owned());
        let number = |name: &str| read(name).and_then(|s| s.parse::<f64>().ok());
        let percent = number("capacity")?.clamp(0.0, 100.0) as u8;
        let status = read("status").unwrap_or_default();
        let charging = status == "Charging";
        let on_ac = status != "Discharging";
        let minutes_left = (!on_ac)
            .then(|| Some((number("energy_now")?, number("power_now")?)))
            .flatten()
            .filter(|(_, power)| *power > 0.0)
            .map(|(energy, power)| (energy / power * 60.0) as u32);
        Some(Battery { percent, charging, on_ac, minutes_left })
    }
}

/// `SYSTEM_POWER_STATUS` read: flag 128 — no battery, 255 — unknown; 8 — charging; the time in seconds, −1 unknown.
pub fn battery_of(ac_line: u8, flag: u8, percent: u8, seconds: u32) -> Option<Battery> {
    if flag == 255 || flag & 128 != 0 || percent > 100 {
        return None;
    }
    let on_ac = ac_line == 1;
    Some(Battery { percent, charging: flag & 8 != 0, on_ac, minutes_left: (!on_ac && seconds != u32::MAX && seconds > 0).then_some(seconds / 60) })
}

// MARK: - Alerts

#[derive(Debug, Clone, PartialEq)]
pub enum Alert {
    Cpu,
    Memory,
    /// Bytes free.
    Disk(u64),
    Battery(u8),
}

/// When to notify (the Mac's `ResourceAlerts`): each alert once per event, again only after it cleared.
#[derive(Debug, Default)]
pub struct Alerts {
    cpu_high_since: Option<Instant>,
    fired: std::collections::HashSet<&'static str>,
}

pub const CPU_HIGH: f64 = 90.0;
pub const CPU_CLEAR: f64 = 70.0;
pub const CPU_SUSTAINED: Duration = Duration::from_secs(5 * 60);
pub const BATTERY_LOW: u8 = 15;
pub const BATTERY_CLEAR: u8 = 20;

impl Alerts {
    pub fn evaluate(&mut self, snapshot: &Snapshot, disk_below_gb: u64, now: Instant) -> Vec<Alert> {
        let mut alerts = Vec::new();
        let mut once = |key: &'static str, active: bool, cleared: bool, alert: Alert| {
            if active && self.fired.insert(key) {
                alerts.push(alert);
            } else if cleared {
                self.fired.remove(key);
            }
        };
        if snapshot.cpu >= CPU_HIGH {
            self.cpu_high_since.get_or_insert(now);
        } else if snapshot.cpu < CPU_CLEAR {
            self.cpu_high_since = None;
        }
        let sustained = self.cpu_high_since.is_some_and(|since| now.duration_since(since) >= CPU_SUSTAINED);
        once("cpu", sustained, self.cpu_high_since.is_none(), Alert::Cpu);
        once("memory", snapshot.pressure == Pressure::Critical, snapshot.pressure == Pressure::Normal, Alert::Memory);
        let limit = disk_below_gb * 1_000_000_000;
        once("disk", snapshot.disk_free > 0 && snapshot.disk_free < limit, snapshot.disk_free >= limit + 2_000_000_000, Alert::Disk(snapshot.disk_free));
        if let Some(battery) = &snapshot.battery {
            once("battery", !battery.on_ac && battery.percent < BATTERY_LOW, battery.on_ac || battery.percent >= BATTERY_CLEAR, Alert::Battery(battery.percent));
        }
        alerts
    }
}

/// The disk thresholds offered, GB.
pub const DISK_THRESHOLDS: [u64; 5] = [5, 10, 20, 50, 100];

#[cfg(test)]
mod tests {
    use super::*;

    fn snapshot() -> Snapshot {
        Snapshot {
            cpu: 10.0,
            memory_used: 8 << 30,
            memory_total: 16 << 30,
            pressure: Pressure::Normal,
            disk_free: 100_000_000_000,
            disk_total: 500_000_000_000,
            network_in: 0.0,
            network_out: 0.0,
            battery: Some(Battery { percent: 80, charging: false, on_ac: false, minutes_left: Some(200) }),
            gpu: None,
        }
    }

    #[test]
    fn alerts_fire_once_per_event() {
        let start = Instant::now();
        let mut alerts = Alerts::default();
        let mut busy = snapshot();
        busy.cpu = 95.0;
        assert!(alerts.evaluate(&busy, 20, start).is_empty(), "not yet 5 minutes");
        assert_eq!(alerts.evaluate(&busy, 20, start + Duration::from_secs(301)), [Alert::Cpu]);
        assert!(alerts.evaluate(&busy, 20, start + Duration::from_secs(400)).is_empty(), "once");
        busy.cpu = 80.0;
        assert!(alerts.evaluate(&busy, 20, start + Duration::from_secs(500)).is_empty(), "80 % neither clears nor fires");
        busy.cpu = 50.0;
        alerts.evaluate(&busy, 20, start + Duration::from_secs(600));
        busy.cpu = 95.0;
        alerts.evaluate(&busy, 20, start + Duration::from_secs(700));
        assert_eq!(alerts.evaluate(&busy, 20, start + Duration::from_secs(1001)), [Alert::Cpu], "again after it cleared");

        let mut low = snapshot();
        low.disk_free = 15_000_000_000;
        low.pressure = Pressure::Critical;
        low.battery = Some(Battery { percent: 12, charging: false, on_ac: false, minutes_left: None });
        assert_eq!(alerts.evaluate(&low, 20, start), [Alert::Memory, Alert::Disk(15_000_000_000), Alert::Battery(12)]);
        low.disk_free = 21_000_000_000;
        low.pressure = Pressure::Warning;
        assert!(alerts.evaluate(&low, 20, start).is_empty(), "a little more space or memory clears nothing");
        low.disk_free = 23_000_000_000;
        low.pressure = Pressure::Normal;
        low.battery = Some(Battery { percent: 12, charging: true, on_ac: true, minutes_left: None });
        alerts.evaluate(&low, 20, start);
        low.disk_free = 15_000_000_000;
        assert_eq!(alerts.evaluate(&low, 20, start), [Alert::Disk(15_000_000_000)], "on the charger the battery stays quiet");
    }

    #[test]
    fn readings_explained() {
        assert_eq!(pressure(Some(true), 8, 16), Pressure::Critical);
        assert_eq!(pressure(Some(false), 1, 100), Pressure::Warning, "Windows says it's not low yet");
        assert_eq!(pressure(None, 4, 100), Pressure::Critical);
        assert_eq!(pressure(None, 50, 100), Pressure::Normal);
        assert_eq!(battery_of(0, 0, 76, 7200), Some(Battery { percent: 76, charging: false, on_ac: false, minutes_left: Some(120) }));
        assert_eq!(battery_of(1, 8, 40, u32::MAX), Some(Battery { percent: 40, charging: true, on_ac: true, minutes_left: None }));
        assert_eq!(battery_of(1, 128, 255, u32::MAX), None, "no battery");
        assert_eq!(battery_of(0, 255, 50, 0), None, "unknown");
        let top = top(HashMap::from([("chrome".into(), 30.0), ("Code".into(), 45.5), ("idle".into(), 0.0), ("System Idle Process".into(), 700.0)]), 5);
        assert_eq!(top.iter().map(|p| p.name.as_str()).collect::<Vec<_>>(), ["Code", "chrome"]);
        assert!(is_loopback("lo") && is_loopback("lo0") && is_loopback("Loopback Pseudo-Interface 1") && !is_loopback("Ethernet"));
        assert_eq!(snapshot().memory_percent(), 50.0);
    }

    #[test]
    fn this_computer() {
        let mut sampler = Sampler::new();
        let first = sampler.sample();
        assert!(first.memory_total > 0 && first.memory_used <= first.memory_total);
        assert_eq!(first.cpu, 0.0, "the first reading only primes");
        assert!(sampler.top_processes(5).is_empty(), "the first call primes too");
        std::thread::sleep(sysinfo::MINIMUM_CPU_UPDATE_INTERVAL.max(Duration::from_millis(300)));
        let second = sampler.sample();
        assert!((0.0..=100.0).contains(&second.cpu));
        assert!(second.disk_total > 0 && second.disk_free <= second.disk_total, "the system disk is found");
        let _ = sampler.top_processes(5);
    }
}
