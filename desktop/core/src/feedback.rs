//! «Предложить идею» / «Сообщить о проблеме» (the Mac's `Feedback`): the repository's issue forms
//! (.github/ISSUE_TEMPLATE) with the version and the system already filled in. Nothing is sent by the app itself —
//! the person sees the whole form on GitHub first. The crash report the Mac offers after a crash is not here: there
//! is no report of the system's to read.

pub const REPOSITORY: &str = "https://github.com/OlehDemishev/AIHubBar";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Template {
    Bug,
    Idea,
}

impl Template {
    pub fn parse(name: &str) -> Option<Template> {
        match name {
            "bug" => Some(Template::Bug),
            "idea" => Some(Template::Idea),
            _ => None,
        }
    }

    fn file(self) -> &'static str {
        match self {
            Template::Bug => "bug_report.yml",
            Template::Idea => "feature_request.yml",
        }
    }
}

/// A query value: everything but letters, digits and `-._~` as %XX of its UTF-8 bytes.
fn encoded(text: &str) -> String {
    text.bytes().map(|b| if b.is_ascii_alphanumeric() || b"-._~".contains(&b) { (b as char).to_string() } else { format!("%{b:02X}") }).collect()
}

/// GitHub fills an issue form's fields from query items named by the fields' ids.
pub fn issue_url(template: Template, fields: &[(&str, &str)]) -> String {
    let items = std::iter::once(("template", template.file())).chain(fields.iter().copied());
    let query = items.map(|(name, value)| format!("{name}={}", encoded(value))).collect::<Vec<_>>().join("&");
    format!("{REPOSITORY}/issues/new?{query}")
}

/// «Windows 11 Home (26100), x86_64» — what the bug form's system field gets. The form names that field `macos`.
pub fn system_line(os: Option<&str>, arch: &str) -> String {
    let os = os.map(str::trim).filter(|os| !os.is_empty()).unwrap_or(std::env::consts::OS);
    format!("{os}, {arch}")
}

pub fn system() -> String {
    system_line(sysinfo::System::long_os_version().ok().as_deref(), &sysinfo::System::cpu_arch())
}

/// The form a button opens: an idea as it is, a problem with the version and the system.
pub fn url(template: Template, version: &str) -> String {
    match template {
        Template::Idea => issue_url(template, &[]),
        Template::Bug => issue_url(template, &[("version", version), ("macos", &system())]),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_forms_links() {
        assert_eq!(issue_url(Template::Idea, &[]), "https://github.com/OlehDemishev/AIHubBar/issues/new?template=feature_request.yml");
        assert_eq!(
            issue_url(Template::Bug, &[("version", "0.1.9"), ("macos", "Windows 11 Home (26100), x86_64")]),
            "https://github.com/OlehDemishev/AIHubBar/issues/new?template=bug_report.yml&version=0.1.9&macos=Windows%2011%20Home%20%2826100%29%2C%20x86_64"
        );
        // A system named in another alphabet, and the characters a query can't hold.
        assert_eq!(encoded("Ö&=#+ я"), "%C3%96%26%3D%23%2B%20%D1%8F");
        assert_eq!((Template::parse("bug"), Template::parse("idea"), Template::parse("x")), (Some(Template::Bug), Some(Template::Idea), None));
    }

    #[test]
    fn the_system_in_a_line() {
        assert_eq!(system_line(Some("Windows 11 Home (26100) "), "x86_64"), "Windows 11 Home (26100), x86_64");
        assert_eq!(system_line(None, "arm64"), format!("{}, arm64", std::env::consts::OS));
        let here = system();
        assert!(here.contains(", ") && here.len() > 6, "{here}");
        assert!(url(Template::Bug, "0.1.9").contains("&version=0.1.9&macos="));
    }
}
