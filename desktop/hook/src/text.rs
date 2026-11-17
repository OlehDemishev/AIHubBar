//! The person's words of a UserPromptSubmit without the wrappers the Claude app puts in front of them, as the Mac
//! hook's `SYSTEM_TEXT` and `APP_TEXT` (format 7). Written by hand: the Mac's pattern needs a backreference.

/// `<system-reminder>…</system-reminder>` (or to the end when it isn't closed) replaced by a space, everywhere.
pub fn without_system_text(text: &str) -> String {
    const OPEN: &str = "<system-reminder>";
    const CLOSE: &str = "</system-reminder>";
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(start) = rest.find(OPEN) {
        out.push_str(&rest[..start]);
        out.push(' ');
        let after = &rest[start + OPEN.len()..];
        rest = match after.find(CLOSE) {
            Some(end) => &after[end + CLOSE.len()..],
            None => "",
        };
    }
    out.push_str(rest);
    out
}

/// The tag name of an app wrapper at the start: lowercase words joined by `-` or `_`, at least two
/// (`artifact-view-context`, `ide_selection`), then whitespace with attributes or `>`. Returns (name, end of the tag).
fn app_tag(text: &str) -> Option<(&str, usize)> {
    let start = text.len() - text.trim_start().len();
    let body = text[start..].strip_prefix('<')?;
    let name_len = body.find(|c: char| !(c.is_ascii_lowercase() || c == '-' || c == '_')).unwrap_or(body.len());
    let name = &body[..name_len];
    let words: Vec<&str> = name.split(['-', '_']).collect();
    if words.len() < 2 || words.iter().any(|w| w.is_empty()) {
        return None;
    }
    let after = &body[name_len..];
    let close = if after.starts_with('>') {
        0
    } else if after.starts_with(char::is_whitespace) {
        after.find('>')?
    } else {
        return None;
    };
    Some((name, start + 1 + name_len + close + 1))
}

/// Starts with an app wrapper: such a saved title is that text alone and is replaced.
pub fn starts_with_app_text(text: &str) -> bool {
    app_tag(text).is_some()
}

/// Leading app wrappers removed, one after another; an unclosed one takes the rest.
pub fn without_app_text(text: &str) -> String {
    let mut rest = text;
    while let Some((name, tag_end)) = app_tag(rest) {
        let closing = format!("</{name}>");
        rest = match rest[tag_end..].find(&closing) {
            Some(end) => &rest[tag_end + end + closing.len()..],
            None => "",
        };
    }
    rest.to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wrappers() {
        assert_eq!(without_system_text("<system-reminder>a\nb</system-reminder>Почини"), " Почини");
        assert_eq!(without_system_text("x <system-reminder>never closed"), "x  ");
        let app = "<artifact-view-context id=\"1\">page</artifact-view-context>\n<ide_selection>code</ide_selection> Сделай";
        assert_eq!(without_app_text(app).trim(), "Сделай");
        assert_eq!(without_app_text("<b>bold</b> text"), "<b>bold</b> text", "one word is not an app tag");
        assert_eq!(without_app_text("<ide-selection>no end"), "");
        assert!(starts_with_app_text("  <ide-selection>x</ide-selection>"));
        assert!(!starts_with_app_text("<ide-selection/>"));
    }
}
