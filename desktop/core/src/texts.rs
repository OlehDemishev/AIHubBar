//! Limits in words, with the Mac app's texts (`UsageText`, `UsageStore` alerts, `UsageError`): the keys are the
//! Russian source texts of the String Catalog, so every language comes from there.

use crate::i18n::Strings;
use crate::usage::{Alert, UsageError, UsageForecast, UsageSnapshot, UsageWindow};
use chrono::{DateTime, Local, Utc};

/// «42 %».
pub fn percent(value: f64) -> String {
    format!("{} %", value.round() as i64)
}

/// «через 2 ч 14 мин», «через 35 мин», «меньше чем через минуту».
pub fn countdown(s: &Strings, to: DateTime<Utc>, now: DateTime<Utc>) -> String {
    let minutes = (to - now).num_minutes().max(0);
    if minutes < 1 {
        return s.t("меньше чем через минуту").to_owned();
    }
    if minutes < 60 {
        return s.format("через %lld мин", &[&minutes.to_string()]);
    }
    let (hours, rest) = (minutes / 60, minutes % 60);
    if hours < 24 {
        return if rest == 0 {
            s.format("через %lld ч", &[&hours.to_string()])
        } else {
            s.format("через %lld ч %lld мин", &[&hours.to_string(), &rest.to_string()])
        };
    }
    s.format("через %lld дн %lld ч", &[&(hours / 24).to_string(), &(hours % 24).to_string()])
}

/// «сброс через 2 ч 14 мин» within a day, else «сброс Чт 09:00».
pub fn reset_text(s: &Strings, resets_at: Option<DateTime<Utc>>, now: DateTime<Utc>) -> Option<String> {
    let resets = resets_at?;
    let when = if (resets - now).num_hours() < 24 {
        countdown(s, resets, now)
    } else {
        resets.with_timezone(&Local).format("%a %H:%M").to_string()
    };
    Some(s.format("сброс %@", &[&when]))
}

/// The window's name, as the Mac app has it.
pub fn window_title(s: &Strings, window: &UsageWindow) -> String {
    match window.key.as_str() {
        "five_hour" => s.t("Сессия (5 ч)").to_owned(),
        "seven_day" => s.t("Неделя").to_owned(),
        "seven_day_opus" => s.t("Неделя · Opus").to_owned(),
        "seven_day_sonnet" => s.t("Неделя · Sonnet").to_owned(),
        key => {
            let model = window.model.clone().unwrap_or_else(|| {
                key.trim_start_matches("seven_day_")
                    .split('_')
                    .map(|word| {
                        let mut chars = word.chars();
                        chars.next().map(|c| c.to_uppercase().chain(chars).collect::<String>()).unwrap_or_default()
                    })
                    .collect::<Vec<_>>()
                    .join(" ")
            });
            s.format("Неделя · %@", &[&model])
        }
    }
}

/// The tray icon's hint, like the Mac menu bar: «Сессия (5 ч) 42 % · сброс через 2 ч 14 мин · Неделя 31 %».
pub fn tray_tooltip(s: &Strings, snapshot: Option<&UsageSnapshot>, error: Option<&UsageError>, now: DateTime<Utc>) -> String {
    let mut parts = vec![crate::APP_NAME.to_owned()];
    if let Some(snapshot) = snapshot {
        if let Some(session) = snapshot.session() {
            let mut text = format!("{} {}", window_title(s, session), percent(session.utilization));
            if let Some(reset) = reset_text(s, session.resets_at, now) {
                text += &format!(" · {reset}");
            }
            parts.push(text);
        }
        if let Some(week) = snapshot.week() {
            parts.push(format!("{} {}", window_title(s, week), percent(week.utilization)));
        }
    }
    if let Some(error) = error {
        parts.push(error_text(s, error));
    }
    parts.join("\n")
}

pub fn forecast_text(s: &Strings, forecast: &UsageForecast) -> Option<String> {
    match forecast {
        UsageForecast::RunsOutAt(date) => {
            Some(s.format("при текущем темпе хватит до ~%@", &[&date.with_timezone(&Local).format("%H:%M").to_string()]))
        }
        UsageForecast::LastsUntilReset => Some(s.t("до сброса хватит").to_owned()),
        UsageForecast::Unknown => None,
    }
}

pub fn error_text(s: &Strings, error: &UsageError) -> String {
    match error {
        UsageError::NoCredentials => s.t("Войдите в Claude Code: claude → /login").to_owned(),
        UsageError::Expired => s
            .t("Вход Claude Code устарел — обновится при следующем запуске claude в Терминале (если нет: claude → /login)")
            .to_owned(),
        UsageError::Http(code @ (401 | 403)) => s.format("Сессия Claude Code истекла (HTTP %lld): claude → /login", &[&code.to_string()]),
        UsageError::Http(code) => s.format("Лимиты недоступны (HTTP %lld)", &[&code.to_string()]),
        UsageError::RateLimited(_) => s.t("Сервер лимитов просит запрашивать реже").to_owned(),
        UsageError::Network(detail) => s.format("Лимиты недоступны: нет связи (%lld)", &[detail]),
        UsageError::BadResponse => s.t("Лимиты недоступны: ответ в неизвестном формате").to_owned(),
    }
}

/// A notification's title and text for an alert, as on the Mac.
pub fn alert_text(s: &Strings, alert: &Alert, snapshot: &UsageSnapshot, now: DateTime<Utc>) -> (String, String) {
    let title_of = |key: &str| {
        snapshot.windows.iter().find(|w| w.key == key).map(|w| window_title(s, w)).unwrap_or_else(|| key.to_owned())
    };
    match alert {
        Alert::Crossed { window_key, threshold, utilization, resets_at } => {
            let title = s.format("Лимит Claude: %@ — %@", &[&title_of(window_key).to_lowercase(), &percent(*utilization)]);
            let mut body = s.format("Порог %lld %%", &[&threshold.to_string()]);
            if let Some(resets) = resets_at {
                body += &s.format(", сброс %@", &[&countdown(s, *resets, now)]);
            }
            (title, body)
        }
        Alert::Restored { window_key } => {
            (s.t("Лимит Claude восстановлен").to_owned(), s.format("%@ снова доступна", &[&title_of(window_key)]))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration;

    fn ru() -> Strings {
        Strings::default()
    }

    #[test]
    fn countdowns() {
        let now = Utc::now();
        let s = ru();
        assert_eq!(countdown(&s, now + Duration::seconds(30), now), "меньше чем через минуту");
        assert_eq!(countdown(&s, now + Duration::minutes(35), now), "через 35 мин");
        assert_eq!(countdown(&s, now + Duration::minutes(120), now), "через 2 ч");
        assert_eq!(countdown(&s, now + Duration::minutes(134), now), "через 2 ч 14 мин");
        assert_eq!(countdown(&s, now + Duration::hours(50), now), "через 2 дн 2 ч");
        let en = Strings::from_json(r#"{"через %lld ч %lld мин": "in %lld h %lld min"}"#);
        assert_eq!(countdown(&en, now + Duration::minutes(134), now), "in 2 h 14 min");
    }

    #[test]
    fn tooltip_and_alerts() {
        let now: DateTime<Utc> = "2026-11-02T18:00:00Z".parse().unwrap();
        let snapshot = UsageSnapshot::decode(
            r#"{"five_hour": {"utilization": 42.4, "resets_at": "2026-11-02T20:14:00Z"}, "seven_day": {"utilization": 31}}"#,
            now,
        )
        .unwrap();
        let s = ru();
        assert_eq!(
            tray_tooltip(&s, Some(&snapshot), None, now),
            "AI Hub Bar\nСессия (5 ч) 42 % · сброс через 2 ч 14 мин\nНеделя 31 %"
        );
        assert_eq!(tray_tooltip(&s, None, Some(&UsageError::NoCredentials), now), "AI Hub Bar\nВойдите в Claude Code: claude → /login");
        let (title, body) = alert_text(
            &s,
            &Alert::Crossed { window_key: "five_hour".into(), threshold: 80, utilization: 81.0, resets_at: Some(now + Duration::minutes(35)) },
            &snapshot,
            now,
        );
        assert_eq!(title, "Лимит Claude: сессия (5 ч) — 81 %");
        assert_eq!(body, "Порог 80 %, сброс через 35 мин");
        assert_eq!(error_text(&s, &UsageError::Http(401)), "Сессия Claude Code истекла (HTTP 401): claude → /login");
        let other = UsageWindow { key: "seven_day_sonnet_5".into(), utilization: 1.0, resets_at: None, model: None };
        assert_eq!(window_title(&s, &other), "Неделя · Sonnet 5");
    }
}
