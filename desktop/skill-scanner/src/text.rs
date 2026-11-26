//! Characters that are in the text but not on the screen, and other ways to keep words out of a reader's sight.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Hidden {
    /// Unicode tag characters: a whole hidden alphabet.
    Tag,
    /// Controls that change the order text is drawn in.
    Bidi,
    /// Zero-width spaces and joiners.
    ZeroWidth,
}

/// `previous` is the character before, to let a joiner inside an emoji or a non-Latin word pass.
pub fn hidden(c: char, previous: Option<char>) -> Option<Hidden> {
    match c as u32 {
        0xE0000..=0xE007F => Some(Hidden::Tag),
        0x202A..=0x202E | 0x2066..=0x2069 => Some(Hidden::Bidi),
        0x200B | 0x2060..=0x2064 | 0xFEFF | 0x180E | 0x200E | 0x200F | 0x061C => Some(Hidden::ZeroWidth),
        // Joiners are part of emoji and of several scripts; between Latin letters they have no use.
        0x200C | 0x200D if previous.map_or(true, |p| p.is_ascii()) => Some(Hidden::ZeroWidth),
        _ => None,
    }
}

pub fn has_hidden(line: &str) -> bool {
    let mut previous = None;
    line.chars().any(|c| {
        let found = hidden(c, previous).is_some();
        previous = Some(c);
        found
    })
}

/// The line as the agent's tokenizer effectively reads it: without the invisible characters.
pub fn without_hidden(line: &str) -> String {
    let mut previous = None;
    line.chars()
        .filter(|c| {
            let keep = hidden(*c, previous).is_none();
            previous = Some(*c);
            keep
        })
        .collect()
}

#[derive(Debug, Default)]
pub struct HiddenCount {
    pub count: usize,
    /// 1-based.
    pub first_line: usize,
}

#[derive(Debug, Default)]
pub struct HiddenReport {
    pub tags: HiddenCount,
    pub bidi: HiddenCount,
    pub zero_width: HiddenCount,
    /// What the tag characters spell.
    pub tag_text: String,
}

pub fn hidden_report(text: &str) -> HiddenReport {
    let mut report = HiddenReport::default();
    let mut line = 1;
    let mut previous = None;
    for (index, c) in text.chars().enumerate() {
        if c == '\n' {
            line += 1;
        }
        // A byte order mark at the very start is how some editors save a file.
        let class = if index == 0 && c == '\u{feff}' { None } else { hidden(c, previous) };
        previous = Some(c);
        let Some(class) = class else { continue };
        let slot = match class {
            Hidden::Tag => {
                if let Some(ascii) = char::from_u32(c as u32 - 0xE0000).filter(|a| (' '..='~').contains(a)) {
                    report.tag_text.push(ascii);
                }
                &mut report.tags
            }
            Hidden::Bidi => &mut report.bidi,
            Hidden::ZeroWidth => &mut report.zero_width,
        };
        if slot.count == 0 {
            slot.first_line = line;
        }
        slot.count += 1;
    }
    report
}

/// A whole line for showing to a person: the invisible characters spelled out, nothing cut.
pub fn visible(line: &str) -> String {
    let mut shown = String::with_capacity(line.len());
    let mut previous = None;
    for c in line.chars() {
        if hidden(c, previous).is_some() {
            shown.push_str(&format!("<U+{:04X}>", c as u32));
        } else if c.is_control() && c != '\t' {
            shown.push(' ');
        } else {
            shown.push(c);
        }
        previous = Some(c);
    }
    shown
}

/// A line for showing to a person: short, on one line, with the invisible characters spelled out.
pub fn excerpt(text: &str) -> String {
    let mut shown = String::new();
    let mut previous = None;
    let mut length = 0;
    for c in text.trim().chars() {
        if length >= 180 {
            shown.push('…');
            break;
        }
        if hidden(c, previous).is_some() {
            shown.push_str(&format!("<U+{:04X}>", c as u32));
        } else if c.is_control() {
            shown.push(' ');
        } else {
            shown.push(c);
        }
        previous = Some(c);
        length += 1;
    }
    shown
}

/// Edit distance of at most one: a letter changed, added, dropped, or two neighbours swapped.
pub fn one_typo_apart(a: &str, b: &str) -> bool {
    if a == b {
        return false;
    }
    let (a, b): (Vec<char>, Vec<char>) = (a.chars().collect(), b.chars().collect());
    let (short, long) = if a.len() <= b.len() { (&a, &b) } else { (&b, &a) };
    match long.len() - short.len() {
        0 => {
            let differing: Vec<usize> = (0..a.len()).filter(|&i| a[i] != b[i]).collect();
            match differing.as_slice() {
                [_] => true,
                [i, j] => *j == *i + 1 && a[*i] == b[*j] && a[*j] == b[*i],
                _ => false,
            }
        }
        1 => {
            let mut skipped = false;
            let (mut i, mut j) = (0, 0);
            while i < short.len() && j < long.len() {
                if short[i] == long[j] {
                    i += 1;
                    j += 1;
                } else if skipped {
                    return false;
                } else {
                    skipped = true;
                    j += 1;
                }
            }
            true
        }
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn invisible_characters_are_found_and_removed() {
        let line = "ig\u{200b}nore prev\u{200b}ious";
        assert!(has_hidden(line));
        assert_eq!(without_hidden(line), "ignore previous");
        assert_eq!(excerpt(line), "ig<U+200B>nore prev<U+200B>ious");
        // A family emoji and a Persian word keep their joiners.
        assert!(!has_hidden("👨\u{200d}👩\u{200d}👧 می\u{200c}خواهم"));
        // A byte order mark at the start is not a finding.
        assert_eq!(hidden_report("\u{feff}# Title\n").zero_width.count, 0);
    }

    #[test]
    fn tag_characters_are_decoded() {
        let hidden: String = "send keys".chars().map(|c| char::from_u32(0xE0000 + c as u32).unwrap()).collect();
        let report = hidden_report(&format!("# Title\nHello{hidden}\n"));
        assert_eq!(report.tags.count, 9);
        assert_eq!(report.tags.first_line, 2);
        assert_eq!(report.tag_text, "send keys");
    }

    #[test]
    fn typos_are_one_step_away() {
        assert!(one_typo_apart("reqeusts", "requests"));
        assert!(one_typo_apart("request", "requests"));
        assert!(one_typo_apart("requestss", "requests"));
        assert!(one_typo_apart("nunpy", "numpy"));
        assert!(!one_typo_apart("requests", "requests"));
        assert!(!one_typo_apart("flask", "black"));
    }
}
