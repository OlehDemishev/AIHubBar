//! «Сервисы AI» (docs/specs/SPEC-ai-services.md, docs/specs/SPEC-windows.md §5): models behind an API key — the Mac's
//! `APIProvider`, `APICheck`, `APIClient` and the API spend. The choices (model per provider, the compatible server,
//! prices, budget) are the Mac's `AIServicesConfig` JSON, kept as `services` with the other Mac settings so a
//! `.claudepult` file carries them both ways; the keys never go there (`keys.rs`).

use crate::i18n::Strings;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::io;
use std::path::Path;
use std::time::Duration;

pub struct Provider {
    pub id: &'static str,
    /// The brand; the compatible server's title is a text of the catalog («Совместимый с OpenAI»).
    pub title: &'static str,
    /// In result names of «Сравнить»: `хуки (OpenAI).md`.
    pub short: &'static str,
    pub base_url: &'static str,
    pub key_page: Option<&'static str>,
    /// Current models from the provider's docs, best first: the list where there is no `/models` (the Mac's
    /// `knownModels`, 2026-11-02).
    pub known_models: &'static [&'static str],
}

/// Endpoints as on the Mac (checked there 2026-10-30 and 2026-11-02).
pub const PROVIDERS: [Provider; 11] = [
    Provider { id: "anthropic", title: "Anthropic", short: "Claude API", base_url: "https://api.anthropic.com/v1", key_page: Some("https://console.anthropic.com/settings/keys"), known_models: &[] },
    Provider { id: "openai", title: "OpenAI", short: "OpenAI", base_url: "https://api.openai.com/v1", key_page: Some("https://platform.openai.com/api-keys"), known_models: &[] },
    Provider { id: "google", title: "Google Gemini", short: "Gemini", base_url: "https://generativelanguage.googleapis.com/v1beta/openai", key_page: Some("https://aistudio.google.com/apikey"), known_models: &[] },
    Provider { id: "xai", title: "xAI Grok", short: "Grok", base_url: "https://api.x.ai/v1", key_page: Some("https://console.x.ai"), known_models: &[] },
    Provider { id: "deepseek", title: "DeepSeek", short: "DeepSeek", base_url: "https://api.deepseek.com", key_page: Some("https://platform.deepseek.com/api_keys"), known_models: &[] },
    Provider { id: "mistral", title: "Mistral", short: "Mistral", base_url: "https://api.mistral.ai/v1", key_page: Some("https://console.mistral.ai/api-keys"), known_models: &[] },
    Provider { id: "qwen", title: "Alibaba Qwen", short: "Qwen", base_url: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1", key_page: Some("https://modelstudio.console.alibabacloud.com/model/settings/api-key"), known_models: &["qwen3.8-max", "qwen3.7-plus", "qwen3.8-flash"] },
    Provider { id: "kimi", title: "Moonshot Kimi", short: "Kimi", base_url: "https://api.moonshot.ai/v1", key_page: Some("https://platform.kimi.ai/console/api-keys"), known_models: &["kimi-k3.1-pro", "kimi-k3", "kimi-k3.1-pro-highspeed"] },
    Provider { id: "glm", title: "Z.ai GLM", short: "GLM", base_url: "https://api.z.ai/api/paas/v4", key_page: Some("https://z.ai/manage-apikey/apikey-list"), known_models: &["glm-5.3", "glm-5.3-flashx", "glm-5.3-flash"] },
    Provider { id: "minimax", title: "MiniMax", short: "MiniMax", base_url: "https://api.minimax.io/v1", key_page: Some("https://platform.minimax.io/user-center/basic-information/interface-key"), known_models: &["MiniMax-M3", "MiniMax-M3.1-Flash"] },
    Provider { id: "compatible", title: "", short: "Local", base_url: "http://localhost:11434/v1", key_page: None, known_models: &[] },
];

pub fn provider(id: &str) -> Option<&'static Provider> {
    PROVIDERS.iter().find(|p| p.id == id)
}

/// Local servers (Ollama, LM Studio) work without a key.
pub fn key_required(id: &str) -> bool {
    id != "compatible"
}

// MARK: - Services

/// Who runs a command (the Mac's `AIService`, stored by id): `claude-code`, `agent:codex`, `api:openai`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Service {
    ClaudeCode,
    Agent(String),
    Api(&'static Provider),
}

impl PartialEq for Provider {
    fn eq(&self, other: &Self) -> bool {
        self.id == other.id
    }
}
impl Eq for Provider {}
impl std::fmt::Debug for Provider {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.id)
    }
}

impl Service {
    pub fn parse(id: &str) -> Option<Service> {
        if id == "claude-code" {
            return Some(Service::ClaudeCode);
        }
        match id.split_once(':')? {
            ("agent", "claude") => Some(Service::ClaudeCode),
            ("agent", kind) if !kind.is_empty() => Some(Service::Agent(kind.to_owned())),
            ("api", provider_id) => provider(provider_id).map(Service::Api),
            _ => None,
        }
    }

    pub fn id(&self) -> String {
        match self {
            Service::ClaudeCode => "claude-code".into(),
            Service::Agent(kind) => format!("agent:{kind}"),
            Service::Api(provider) => format!("api:{}", provider.id),
        }
    }

    /// In lists and job rows: «Claude», «OpenAI», the compatible server's own name.
    pub fn short_name(&self, services: &Value) -> String {
        match self {
            Service::ClaudeCode => "Claude".into(),
            Service::Agent(kind) => kind.clone(),
            Service::Api(provider) if provider.id == "compatible" => Some(compatible_name(services)).filter(|n| !n.is_empty()).unwrap_or_else(|| "Local".into()),
            Service::Api(provider) => provider.short.into(),
        }
    }
}

// MARK: - The Mac's `AIServicesConfig` JSON

/// The model chosen for a provider.
pub fn model(services: &Value, provider: &str) -> Option<String> {
    services["models"][provider].as_str().filter(|m| !m.is_empty()).map(str::to_owned)
}

pub fn set_model(services: &mut Value, provider: &str, model: &str) {
    object(services, "models").insert(provider.into(), json!(model));
}

pub fn compatible_name(services: &Value) -> String {
    services["compatibleName"].as_str().unwrap_or_default().to_owned()
}

pub fn base_url(services: &Value, provider: &Provider) -> String {
    if provider.id == "compatible" {
        services["compatibleBaseURL"].as_str().filter(|u| !u.trim().is_empty()).unwrap_or(provider.base_url).to_owned()
    } else {
        provider.base_url.to_owned()
    }
}

/// The compatible server's name and address as typed.
pub fn set_compatible(services: &mut Value, name: &str, url: &str) {
    if !services.is_object() {
        *services = json!({});
    }
    services["compatibleName"] = json!(name.trim());
    services["compatibleBaseURL"] = json!(url.trim());
}

/// Dollars per million tokens, input and output, as entered on the Mac.
pub fn price(services: &Value, provider: &str) -> Option<(f64, f64)> {
    let price = &services["prices"][provider];
    Some((price["input"].as_f64()?, price["output"].as_f64()?))
}

fn object<'a>(services: &'a mut Value, key: &str) -> &'a mut Map<String, Value> {
    if !services.is_object() {
        *services = json!({});
    }
    if !services[key].is_object() {
        services[key] = json!({});
    }
    services[key].as_object_mut().expect("just made an object")
}

// MARK: - «Проверить»

#[derive(Debug, Clone, PartialEq)]
pub enum Check {
    Ok(Vec<String>),
    BadKey,
    NoKey,
    Failed(String),
}

impl Check {
    pub fn text(&self, s: &Strings) -> String {
        match self {
            Check::Ok(models) if models.is_empty() => s.t("Работает").to_owned(),
            Check::Ok(models) => s.format("Работает · моделей: %lld", &[&models.len().to_string()]),
            Check::BadKey => s.t("Ключ не подошёл").to_owned(),
            Check::NoKey => s.t("Нет ключа").to_owned(),
            Check::Failed(reason) => reason.clone(),
        }
    }

    /// 400 and 403 come back for a bad key too (Google, xAI), with the key named in the message.
    pub fn from(status: u16, body: &str, s: &Strings) -> Check {
        match status {
            200..=299 => parse_models(body).map(Check::Ok).unwrap_or_else(|| Check::Failed(s.t("Ответ в неизвестном формате").to_owned())),
            401 => Check::BadKey,
            400 | 403 => {
                let text = body.chars().take(2000).collect::<String>().to_lowercase();
                if text.contains("key") || text.contains("auth") { Check::BadKey } else { Check::Failed(s.format("Ошибка HTTP %lld", &[&status.to_string()])) }
            }
            429 => Check::Failed(s.t("Слишком много запросов (HTTP 429)").to_owned()),
            _ => Check::Failed(s.format("Ошибка HTTP %lld", &[&status.to_string()])),
        }
    }

    /// The provider's own rules: Z.ai has no `/models` but checks the key first, so its 404 means the key was taken;
    /// a provider with known models gets them when its list is in another shape.
    pub fn for_provider(provider: &Provider, status: u16, body: &str, s: &Strings) -> Check {
        let result = Check::from(status, body, s);
        let known = || provider.known_models.iter().map(|m| (*m).to_owned()).collect();
        if provider.known_models.is_empty() {
            return result;
        }
        match result {
            _ if provider.id == "glm" && status == 404 => Check::Ok(known()),
            Check::Failed(_) if (200..300).contains(&status) => Check::Ok(known()),
            other => other,
        }
    }
}

/// `{"data": [{"id": …}]}`, or a bare array; Google's ids may come as `models/…`. Sorted, without repeats.
pub fn parse_models(body: &str) -> Option<Vec<String>> {
    let value: Value = serde_json::from_str(body).ok()?;
    let items = value.get("data").and_then(Value::as_array).or(value.as_array())?;
    let mut ids: Vec<String> = items
        .iter()
        .filter_map(|item| item.get("id").and_then(Value::as_str))
        .map(|id| id.strip_prefix("models/").unwrap_or(id).to_owned())
        .collect();
    ids.sort();
    ids.dedup();
    Some(ids)
}

/// A sensible default from a list: a known one, else the first that isn't an embedding / audio / image model.
pub fn preferred_model(models: &[String], provider: &Provider) -> Option<String> {
    if let Some(known) = provider.known_models.iter().find(|m| models.iter().any(|x| x == *m)) {
        return Some((*known).to_owned());
    }
    const SKIP: [&str; 10] = ["embed", "tts", "whisper", "audio", "image", "dall-e", "moderation", "transcribe", "realtime", "search"];
    models.iter().find(|m| !SKIP.iter().any(|s| m.to_lowercase().contains(s))).cloned()
}

fn agent(timeout: Duration) -> ureq::Agent {
    ureq::Agent::config_builder().http_status_as_error(false).timeout_global(Some(timeout)).build().into()
}

fn trimmed_base(base: &str) -> Option<String> {
    let base = base.trim().trim_end_matches('/');
    (base.starts_with("http://") || base.starts_with("https://")).then(|| base.to_owned())
}

/// Lists the models: costs no tokens, so it is also the key check.
pub fn check(provider: &Provider, base: &str, key: Option<&str>, s: &Strings) -> Check {
    if key_required(provider.id) && key.is_none() {
        return Check::NoKey;
    }
    let Some(base) = trimmed_base(base) else { return Check::Failed(s.t("Неверный адрес сервера").to_owned()) };
    let mut request = agent(Duration::from_secs(20)).get(&format!("{base}/models")).header("Accept", "application/json").header("User-Agent", "AIHubBar");
    if let Some(key) = key.filter(|k| !k.is_empty()) {
        request = if provider.id == "anthropic" {
            request.header("x-api-key", key).header("anthropic-version", "2023-06-01")
        } else {
            request.header("Authorization", &format!("Bearer {key}"))
        };
    }
    match request.call() {
        Ok(mut response) => {
            let status = response.status().as_u16();
            let body = response.body_mut().read_to_string().unwrap_or_default();
            Check::for_provider(provider, status, &body, s)
        }
        Err(_) if provider.id == "compatible" => Check::Failed(s.t("Сервер не отвечает — запущен ли он?").to_owned()),
        Err(_) => Check::Failed(s.t("Нет связи").to_owned()),
    }
}

// MARK: - A request to a model

#[derive(Debug, Clone, PartialEq)]
pub struct Reply {
    pub text: String,
    pub input_tokens: u64,
    pub output_tokens: u64,
}

/// The endpoint and body: Anthropic's Messages, OpenAI-style chat completions for the others.
pub fn chat_request(provider: &Provider, base: &str, model: &str, prompt: &str) -> Option<(String, Value)> {
    let base = trimmed_base(base)?;
    let anthropic = provider.id == "anthropic";
    let mut body = json!({"model": model, "messages": [{"role": "user", "content": prompt}]});
    if anthropic {
        body["max_tokens"] = json!(16_000);
    }
    Some((format!("{base}{}", if anthropic { "/messages" } else { "/chat/completions" }), body))
}

/// Anthropic: `content[].text` and `usage.input_tokens / output_tokens`; others: `choices[0].message.content` and
/// `usage.prompt_tokens / completion_tokens`.
pub fn parse_reply(body: &str, provider: &Provider) -> Option<Reply> {
    let value: Value = serde_json::from_str(body).ok()?;
    let usage = |key: &str| value["usage"][key].as_u64().unwrap_or(0);
    if provider.id == "anthropic" {
        let parts: Vec<&str> = value["content"].as_array()?.iter().filter(|p| p["type"] == "text").filter_map(|p| p["text"].as_str()).collect();
        return (!parts.is_empty()).then(|| Reply { text: parts.join("\n"), input_tokens: usage("input_tokens"), output_tokens: usage("output_tokens") });
    }
    let text = value["choices"][0]["message"]["content"].as_str()?;
    Some(Reply { text: text.to_owned(), input_tokens: usage("prompt_tokens"), output_tokens: usage("completion_tokens") })
}

/// The server's own words for an error, short.
pub fn error_message(body: &str) -> String {
    let value: Value = serde_json::from_str(body).unwrap_or_default();
    let message = value["error"]["message"].as_str().or(value["detail"].as_str()).or(value["error"].as_str()).unwrap_or_default();
    message.chars().take(200).collect()
}

/// One request; the error in the interface language, as the Mac's `APIClient.APIError` words it.
pub fn complete(provider: &Provider, services: &Value, key: Option<&str>, prompt: &str, s: &Strings) -> Result<(Reply, String), String> {
    if key_required(provider.id) && key.is_none() {
        return Err(s.t("Нет ключа API — Настройки → «Сервисы AI»").to_owned());
    }
    let model = model(services, provider.id).ok_or_else(|| s.t("Не выбрана модель — Настройки → «Сервисы AI» → «Проверить»").to_owned())?;
    let (url, body) = chat_request(provider, &base_url(services, provider), &model, prompt).ok_or_else(|| s.t("Неверный адрес сервера").to_owned())?;
    let mut request = agent(Duration::from_secs(300)).post(&url).header("Content-Type", "application/json").header("User-Agent", "AIHubBar");
    if let Some(key) = key.filter(|k| !k.is_empty()) {
        request = if provider.id == "anthropic" { request.header("x-api-key", key) } else { request.header("Authorization", &format!("Bearer {key}")) };
    }
    if provider.id == "anthropic" {
        request = request.header("anthropic-version", "2023-06-01");
    }
    let mut response = request.send(body.to_string()).map_err(|e| s.format("Нет связи: %@", &[&e.to_string()]))?;
    let status = response.status().as_u16();
    let text = response.body_mut().read_to_string().unwrap_or_default();
    if !(200..300).contains(&status) {
        if Check::from(status, &text, s) == Check::BadKey {
            return Err(s.t("Ключ не подошёл").to_owned());
        }
        let message = error_message(&text);
        let head = s.format("Ошибка HTTP %lld", &[&status.to_string()]);
        return Err(if message.is_empty() { head } else { format!("{head}: {message}") });
    }
    match parse_reply(&text, provider) {
        Some(reply) if !reply.text.trim().is_empty() => Ok((reply, model)),
        _ => Err(s.t("Модель вернула пустой ответ").to_owned()),
    }
}

// MARK: - Spend (`api-spend.json`, the Mac's `SpendRecord` list)

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SpendRecord {
    #[serde(with = "crate::runs::iso")]
    pub date: DateTime<Utc>,
    pub provider: String,
    pub model: String,
    pub input_tokens: u64,
    pub output_tokens: u64,
}

pub fn load_spend(path: &Path) -> Vec<SpendRecord> {
    std::fs::read_to_string(path).ok().and_then(|text| serde_json::from_str::<Vec<Value>>(&text).ok()).unwrap_or_default().into_iter().filter_map(|v| serde_json::from_value(v).ok()).collect()
}

/// Adds one request and drops what is older than 400 days, as the Mac does.
pub fn record_spend(path: &Path, record: SpendRecord) -> io::Result<()> {
    let mut records = load_spend(path);
    let year_ago = record.date - chrono::Duration::days(400);
    records.push(record);
    records.retain(|r| r.date >= year_ago);
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, serde_json::to_string(&records).map_err(io::Error::other)?)?;
    std::fs::rename(tmp, path)
}

/// Tokens since a date, and dollars where a price was entered for the provider.
pub fn spend_since(records: &[SpendRecord], since: DateTime<Utc>, services: &Value) -> (u64, Option<f64>) {
    let mut tokens = 0;
    let mut cost = None;
    for record in records.iter().filter(|r| r.date >= since) {
        tokens += record.input_tokens + record.output_tokens;
        if let Some((input, output)) = price(services, &record.provider) {
            *cost.get_or_insert(0.0) += record.input_tokens as f64 / 1e6 * input + record.output_tokens as f64 / 1e6 * output;
        }
    }
    (tokens, cost)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s() -> Strings {
        Strings::from_json("{}")
    }

    #[test]
    fn services_by_id() {
        assert_eq!(Service::parse("claude-code"), Some(Service::ClaudeCode));
        assert_eq!(Service::parse("api:openai").map(|s| s.id()), Some("api:openai".into()));
        assert_eq!(Service::parse("agent:codex"), Some(Service::Agent("codex".into())));
        assert_eq!(Service::parse("api:nope"), None);
        assert_eq!(Service::parse("junk"), None);
        let config = json!({"compatibleName": "Ollama"});
        assert_eq!(Service::parse("api:compatible").unwrap().short_name(&config), "Ollama");
        assert_eq!(Service::parse("api:compatible").unwrap().short_name(&json!({})), "Local");
        assert_eq!(Service::parse("api:anthropic").unwrap().short_name(&config), "Claude API");
    }

    #[test]
    fn the_macs_config() {
        let mut config = json!({"models": {"openai": "gpt-6"}, "compatibleBaseURL": " ", "prices": {"openai": {"input": 2.0, "output": 8.0}}, "monthlyBudget": 20});
        assert_eq!(model(&config, "openai").as_deref(), Some("gpt-6"));
        assert_eq!(base_url(&config, provider("compatible").unwrap()), "http://localhost:11434/v1", "blank is the default");
        set_model(&mut config, "glm", "glm-5.3");
        set_compatible(&mut config, " LM Studio ", "http://localhost:1234/v1/");
        assert_eq!(config["models"], json!({"openai": "gpt-6", "glm": "glm-5.3"}));
        assert_eq!(config["monthlyBudget"], 20, "what this version doesn't touch stays");
        assert_eq!(base_url(&config, provider("compatible").unwrap()), "http://localhost:1234/v1/");
        let mut empty = Value::Null;
        set_model(&mut empty, "openai", "x");
        assert_eq!(empty, json!({"models": {"openai": "x"}}));
    }

    #[test]
    fn checks() {
        let s = s();
        assert_eq!(Check::from(200, r#"{"data": [{"id": "models/gemini-3"}, {"id": "a"}, {"id": "a"}]}"#, &s), Check::Ok(vec!["a".into(), "gemini-3".into()]));
        assert_eq!(Check::from(200, r#"[{"id": "m"}]"#, &s), Check::Ok(vec!["m".into()]));
        assert_eq!(Check::from(401, "", &s), Check::BadKey);
        assert_eq!(Check::from(400, r#"{"error": "API key not valid"}"#, &s), Check::BadKey);
        assert_eq!(Check::from(403, "forbidden region", &s), Check::Failed("Ошибка HTTP 403".into()));
        assert_eq!(Check::from(200, "<html>", &s), Check::Failed("Ответ в неизвестном формате".into()));
        let glm = provider("glm").unwrap();
        assert_eq!(Check::for_provider(glm, 404, "", &s), Check::Ok(glm.known_models.iter().map(|m| (*m).to_owned()).collect()));
        assert_eq!(Check::for_provider(provider("openai").unwrap(), 404, "", &s), Check::Failed("Ошибка HTTP 404".into()));
        assert_eq!(Check::Ok(vec!["a".into(), "b".into()]).text(&s), "Работает · моделей: 2");
        assert_eq!(check(provider("openai").unwrap(), "https://x", None, &s), Check::NoKey);
        assert_eq!(check(provider("compatible").unwrap(), "ftp://x", None, &s), Check::Failed("Неверный адрес сервера".into()));
    }

    #[test]
    fn preferred() {
        let models: Vec<String> = ["text-embedding-3", "gpt-6", "whisper-1"].map(String::from).to_vec();
        assert_eq!(preferred_model(&models, provider("openai").unwrap()).as_deref(), Some("gpt-6"));
        let qwen: Vec<String> = ["qwen-old", "qwen3.7-plus"].map(String::from).to_vec();
        assert_eq!(preferred_model(&qwen, provider("qwen").unwrap()).as_deref(), Some("qwen3.7-plus"));
    }

    #[test]
    fn requests_and_replies() {
        let anthropic = provider("anthropic").unwrap();
        let (url, body) = chat_request(anthropic, "https://api.anthropic.com/v1/", "claude-x", "hi").unwrap();
        assert_eq!(url, "https://api.anthropic.com/v1/messages");
        assert_eq!(body["max_tokens"], 16_000);
        let (url, body) = chat_request(provider("openai").unwrap(), "https://api.openai.com/v1", "gpt", "hi").unwrap();
        assert_eq!(url, "https://api.openai.com/v1/chat/completions");
        assert!(body.get("max_tokens").is_none() && body["messages"][0]["content"] == "hi");
        assert!(chat_request(anthropic, "localhost", "m", "p").is_none());
        let reply = parse_reply(r#"{"content": [{"type": "text", "text": "a"}, {"type": "tool_use"}, {"type": "text", "text": "b"}], "usage": {"input_tokens": 10, "output_tokens": 5}}"#, anthropic).unwrap();
        assert_eq!((reply.text.as_str(), reply.input_tokens, reply.output_tokens), ("a\nb", 10, 5));
        let reply = parse_reply(r#"{"choices": [{"message": {"content": "ok"}}], "usage": {"prompt_tokens": 3, "completion_tokens": 4}}"#, provider("glm").unwrap()).unwrap();
        assert_eq!((reply.input_tokens, reply.output_tokens), (3, 4));
        assert_eq!(parse_reply(r#"{"content": []}"#, anthropic), None);
        assert_eq!(error_message(r#"{"error": {"message": "model not found"}}"#), "model not found");
        assert_eq!(error_message(r#"{"detail": "nope"}"#), "nope");
        let s = s();
        assert_eq!(complete(provider("openai").unwrap(), &json!({}), None, "p", &s).unwrap_err(), "Нет ключа API — Настройки → «Сервисы AI»");
        assert_eq!(complete(provider("openai").unwrap(), &json!({}), Some("k"), "p", &s).unwrap_err(), "Не выбрана модель — Настройки → «Сервисы AI» → «Проверить»");
    }

    /// A local OpenAI-style server, as Ollama or LM Studio would answer: «Проверить» and a request go over real HTTP.
    #[test]
    fn a_local_server() {
        use std::io::{BufRead, BufReader, Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = std::thread::spawn(move || {
            let mut seen = Vec::new();
            for stream in listener.incoming().take(2) {
                let mut stream = stream.unwrap();
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                let mut length = 0;
                loop {
                    let mut header = String::new();
                    reader.read_line(&mut header).unwrap();
                    if header.trim().is_empty() {
                        break;
                    }
                    if let Some(value) = header.to_lowercase().strip_prefix("content-length:") {
                        length = value.trim().parse().unwrap();
                    }
                }
                let mut body = vec![0; length];
                reader.read_exact(&mut body).unwrap();
                seen.push((line.clone(), String::from_utf8(body).unwrap()));
                let reply = if line.starts_with("GET /v1/models") {
                    r#"{"data": [{"id": "nomic-embed"}, {"id": "llama4"}]}"#
                } else {
                    r#"{"choices": [{"message": {"content": "Готово"}}], "usage": {"prompt_tokens": 12, "completion_tokens": 3}}"#
                };
                write!(stream, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{reply}", reply.len()).unwrap();
            }
            seen
        });
        let s = s();
        let compatible = provider("compatible").unwrap();
        let mut services = json!({});
        set_compatible(&mut services, "Ollama", &format!("http://127.0.0.1:{port}/v1"));
        let checked = check(compatible, &base_url(&services, compatible), None, &s);
        assert_eq!(checked, Check::Ok(vec!["llama4".into(), "nomic-embed".into()]));
        let Check::Ok(models) = checked else { unreachable!() };
        set_model(&mut services, "compatible", &preferred_model(&models, compatible).unwrap());
        let (reply, model) = complete(compatible, &services, None, "Привет", &s).unwrap();
        assert_eq!((reply.text.as_str(), reply.input_tokens, model.as_str()), ("Готово", 12, "llama4"));
        let seen = server.join().unwrap();
        assert!(seen[1].0.starts_with("POST /v1/chat/completions"));
        assert_eq!(serde_json::from_str::<Value>(&seen[1].1).unwrap(), json!({"model": "llama4", "messages": [{"role": "user", "content": "Привет"}]}));
    }

    #[test]
    fn spend_file() {
        let dir = std::env::temp_dir().join(format!("claudepult-spend-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let path = dir.join("api-spend.json");
        let now: DateTime<Utc> = "2026-11-18T12:00:00Z".parse().unwrap();
        let old = SpendRecord { date: now - chrono::Duration::days(500), provider: "openai".into(), model: "gpt".into(), input_tokens: 1, output_tokens: 1 };
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(&path, serde_json::to_string(&[&old]).unwrap()).unwrap();
        record_spend(&path, SpendRecord { date: now, provider: "openai".into(), model: "gpt".into(), input_tokens: 1_000_000, output_tokens: 500_000 }).unwrap();
        record_spend(&path, SpendRecord { date: now, provider: "glm".into(), model: "glm".into(), input_tokens: 10, output_tokens: 0 }).unwrap();
        let records = load_spend(&path);
        assert_eq!(records.len(), 2, "older than 400 days dropped");
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(text.contains("\"inputTokens\":1000000") && text.contains("\"date\":\"2026-11-18T12:00:00Z\""), "the Mac's shape");
        let prices = json!({"prices": {"openai": {"input": 2.0, "output": 8.0}}});
        assert_eq!(spend_since(&records, now - chrono::Duration::days(1), &prices), (1_500_010, Some(6.0)));
        assert_eq!(spend_since(&records, now, &json!({})).1, None, "no price, no dollars");
        std::fs::remove_dir_all(dir).unwrap();
    }
}
