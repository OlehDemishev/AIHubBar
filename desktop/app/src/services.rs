//! Stage 5 «Сервисы AI» in Settings (the Mac's `AIServiceStore` and its settings page, models by API only): a key per
//! provider in Credential Manager, «Проверить» that lists the models and picks one, the compatible server's name and
//! address, and the month's API spend. Agents other than Claude Code come later.

use crate::{save, strings, AppState};
use claudepult_core::agents::{self, Found};
use claudepult_core::ai::{self, Check, Service, PROVIDERS};
use claudepult_core::{keys, paths};
use tauri_plugin_clipboard_manager::ClipboardExt;
use serde::Serialize;
use std::collections::HashMap;
use std::sync::Mutex;
use tauri::{AppHandle, Manager};

/// The last «Проверить» of each provider, for its status and model list (the Mac keeps them in memory too).
#[derive(Default)]
pub struct Checks(Mutex<HashMap<&'static str, Check>>);

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderRow {
    id: &'static str,
    title: String,
    key_page: Option<&'static str>,
    key_required: bool,
    has_key: bool,
    /// The chosen model, and the list from the last check to choose from.
    model: Option<String>,
    models: Vec<String>,
    status: Option<String>,
    ok: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ServicesView {
    /// Credential Manager is there (Windows); elsewhere only servers without a key work.
    keys_available: bool,
    providers: Vec<ProviderRow>,
    compatible_name: String,
    compatible_url: String,
    /// «API за месяц: 1 240 токенов · $0.12», when anything was spent.
    spend: Option<String>,
}

pub fn spend_path() -> std::path::PathBuf {
    paths::data_dir().join("api-spend.json")
}

fn view(app: &AppHandle) -> ServicesView {
    let texts = strings(app);
    let services = app.state::<AppState>().settings.lock().unwrap().services();
    let checks = app.state::<Checks>().0.lock().unwrap().clone();
    let providers = PROVIDERS
        .iter()
        .map(|provider| {
            let check = checks.get(provider.id);
            ProviderRow {
                id: provider.id,
                title: if provider.id == "compatible" { texts.t("Совместимый с OpenAI").to_owned() } else { provider.title.to_owned() },
                key_page: provider.key_page,
                key_required: ai::key_required(provider.id),
                has_key: keys::read(provider.id).is_some(),
                model: ai::model(&services, provider.id),
                models: match check {
                    Some(Check::Ok(models)) => models.clone(),
                    _ => Vec::new(),
                },
                status: check.map(|c| c.text(&texts)),
                ok: matches!(check, Some(Check::Ok(_))),
            }
        })
        .collect();
    let month = chrono::Local::now().date_naive().with_day(1).and_then(|d| d.and_hms_opt(0, 0, 0)).and_then(|d| d.and_local_timezone(chrono::Local).single());
    let spend = month.and_then(|start| {
        let (tokens, cost) = ai::spend_since(&ai::load_spend(&spend_path()), start.with_timezone(&chrono::Utc), &services);
        (tokens > 0).then(|| {
            let line = format!("{tokens}{}", texts.t(" токенов"));
            texts.format("API за месяц: %@", &[&cost.map(|c| format!("{line} · ${c:.2}")).unwrap_or(line)])
        })
    });
    ServicesView {
        keys_available: keys::available(),
        providers,
        compatible_name: ai::compatible_name(&services),
        compatible_url: ai::base_url(&services, ai::provider("compatible").expect("listed")),
        spend,
    }
}

use chrono::Datelike;

#[tauri::command]
pub fn services_view(app: AppHandle) -> ServicesView {
    view(&app)
}

/// Lists the models — costs no tokens — and picks one when none (or a vanished one) is chosen.
fn run_check(app: &AppHandle, id: &str) {
    let Some(provider) = ai::provider(id) else { return };
    let services = app.state::<AppState>().settings.lock().unwrap().services();
    let result = ai::check(provider, &ai::base_url(&services, provider), keys::read(id).as_deref(), &strings(app));
    eprintln!("API check {id}: {}", result.text(&strings(app)));
    if let Check::Ok(models) = &result {
        let chosen = ai::model(&services, id);
        if chosen.as_ref().is_none_or(|m| !models.contains(m)) {
            if let Some(best) = ai::preferred_model(models, provider).or_else(|| models.first().cloned()) {
                save(app, |settings| ai::set_model(settings.services_mut(), id, &best));
            }
        }
    }
    app.state::<Checks>().0.lock().unwrap().insert(provider.id, result);
}

#[tauri::command]
pub async fn check_api(app: AppHandle, provider: String) -> ServicesView {
    let handle = app.clone();
    let _ = tauri::async_runtime::spawn_blocking(move || run_check(&handle, &provider)).await;
    view(&app)
}

/// «Сохранить»: into Credential Manager, then checked at once.
#[tauri::command]
pub async fn save_api_key(app: AppHandle, provider: String, key: String) -> Result<ServicesView, String> {
    let id = ai::provider(&provider).ok_or("unknown provider")?.id;
    keys::save(id, &key).map_err(|e| e.to_string())?;
    eprintln!("API key saved: {id}");
    app.state::<Checks>().0.lock().unwrap().remove(id);
    Ok(check_api(app, provider).await)
}

#[tauri::command]
pub fn delete_api_key(app: AppHandle, provider: String) -> Result<ServicesView, String> {
    let id = ai::provider(&provider).ok_or("unknown provider")?.id;
    keys::delete(id).map_err(|e| e.to_string())?;
    eprintln!("API key deleted: {id}");
    app.state::<Checks>().0.lock().unwrap().remove(id);
    Ok(view(&app))
}

#[tauri::command]
pub fn set_api_model(app: AppHandle, provider: String, model: String) -> ServicesView {
    if let Some(provider) = ai::provider(&provider) {
        save(&app, |settings| ai::set_model(settings.services_mut(), provider.id, &model));
    }
    view(&app)
}

/// The compatible server's name and address; its last check no longer holds.
#[tauri::command]
pub fn set_compatible_server(app: AppHandle, name: String, url: String) -> ServicesView {
    save(&app, |settings| ai::set_compatible(settings.services_mut(), &name, &url));
    app.state::<Checks>().0.lock().unwrap().remove("compatible");
    view(&app)
}

// MARK: - Agents

/// The installed agents, found at start and again from Settings (finding them runs each one's `--version`).
#[derive(Default)]
pub struct Agents(Mutex<Option<Vec<Found>>>);

impl Agents {
    pub fn start(app: &AppHandle) {
        let app = app.clone();
        std::thread::spawn(move || {
            let found = agents::scan();
            eprintln!("agents: {}", found.iter().map(|f| f.id).collect::<Vec<_>>().join(", "));
            *app.state::<Agents>().0.lock().unwrap() = Some(found);
        });
    }

    /// What was found so far; empty until the first scan ends.
    pub fn found(&self) -> Vec<Found> {
        self.0.lock().unwrap().clone().unwrap_or_default()
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentRow {
    id: &'static str,
    title: &'static str,
    installed: bool,
    version: Option<String>,
    path: Option<String>,
    /// How to install it here, or how it signs in once it is.
    install: &'static str,
    login: String,
}

/// Settings → «Агенты»: what is installed, its version, how to install or sign in. `refresh` looks again.
#[tauri::command]
pub async fn agents_view(app: AppHandle, refresh: bool) -> Vec<AgentRow> {
    if refresh || app.state::<Agents>().0.lock().unwrap().is_none() {
        let found = tauri::async_runtime::spawn_blocking(agents::scan).await.unwrap_or_default();
        *app.state::<Agents>().0.lock().unwrap() = Some(found);
    }
    let found = app.state::<Agents>().found();
    let texts = strings(&app);
    agents::KINDS
        .iter()
        .map(|kind| {
            let here = found.iter().find(|f| f.id == kind.id);
            AgentRow {
                id: kind.id,
                title: kind.title,
                installed: here.is_some(),
                version: here.and_then(|f| f.version.clone()),
                path: here.map(|f| f.path.to_string_lossy().into_owned()),
                install: kind.install(),
                login: texts.format("Вход: %@", &[kind.login]),
            }
        })
        .collect()
}

/// «Скопировать: …» next to an agent that isn't installed: its install command.
#[tauri::command]
pub fn copy_install_command(app: AppHandle, agent: String) -> Result<(), String> {
    let kind = agents::kind(&agent).ok_or("unknown agent")?;
    app.clipboard().write_text(kind.install()).map_err(|e| e.to_string())
}

/// Who can run a command now: Claude Code, the installed agents (in a terminal), a provider with a key, and the
/// compatible server once a model is chosen.
pub fn available(app: &AppHandle) -> Vec<Service> {
    let services = app.state::<AppState>().settings.lock().unwrap().services();
    let mut list = vec![Service::ClaudeCode];
    list.extend(app.state::<Agents>().found().into_iter().map(|f| Service::Agent(f.id.to_owned())));
    for provider in PROVIDERS.iter() {
        let ready = if ai::key_required(provider.id) { keys::read(provider.id).is_some() } else { ai::model(&services, provider.id).is_some() };
        if ready {
            list.push(Service::Api(provider));
        }
    }
    list
}

/// «Где взять ключ»: the provider's own page, from the list above only.
#[tauri::command]
pub fn open_key_page(provider: String) -> Result<(), String> {
    let page = ai::provider(&provider).and_then(|p| p.key_page).ok_or("no page")?;
    crate::projects::open_with_system(page.as_ref())
}
