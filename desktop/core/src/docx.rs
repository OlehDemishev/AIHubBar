//! The text of a Word file, for word counts and prompts (the Mac reads it with `NSAttributedString`). A `.docx` is a
//! zip archive; its text is the `<w:t>` runs of `word/document.xml`. Only what a word count needs: paragraphs, tabs
//! and line breaks become white space, everything else (styles, comments, headers) is left out.

use std::path::Path;

/// A Word file's visible text; None when it isn't a readable `.docx`.
pub fn text(path: &Path) -> Option<String> {
    let bytes = std::fs::read(path).ok()?;
    let xml = entry(&bytes, "word/document.xml")?;
    Some(xml_text(&String::from_utf8_lossy(&xml)))
}

fn u16_at(bytes: &[u8], at: usize) -> Option<usize> {
    bytes.get(at..at + 2).map(|b| u16::from_le_bytes([b[0], b[1]]) as usize)
}

fn u32_at(bytes: &[u8], at: usize) -> Option<usize> {
    bytes.get(at..at + 4).map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]) as usize)
}

/// One file of a zip archive, stored or deflated, found through the central directory.
fn entry(zip: &[u8], name: &str) -> Option<Vec<u8>> {
    const LIMIT: usize = 64 << 20;
    // The end of central directory record: 22 bytes plus a comment of up to 64 KB.
    let floor = zip.len().saturating_sub(22 + 0xFFFF);
    let end = (floor..=zip.len().checked_sub(22)?).rev().find(|&at| zip[at..at + 4] == [0x50, 0x4B, 0x05, 0x06])?;
    let count = u16_at(zip, end + 10)?;
    let mut at = u32_at(zip, end + 16)?;
    for _ in 0..count {
        if zip.get(at..at + 4)? != [0x50, 0x4B, 0x01, 0x02] {
            return None;
        }
        let method = u16_at(zip, at + 10)?;
        let size = u32_at(zip, at + 20)?;
        let (name_len, extra_len, comment_len) = (u16_at(zip, at + 28)?, u16_at(zip, at + 30)?, u16_at(zip, at + 32)?);
        let local = u32_at(zip, at + 42)?;
        if zip.get(at + 46..at + 46 + name_len)? == name.as_bytes() {
            if zip.get(local..local + 4)? != [0x50, 0x4B, 0x03, 0x04] {
                return None;
            }
            let start = local + 30 + u16_at(zip, local + 26)? + u16_at(zip, local + 28)?;
            let data = zip.get(start..start.checked_add(size)?)?;
            return match method {
                0 => Some(data.to_vec()),
                8 => miniz_oxide::inflate::decompress_to_vec_with_limit(data, LIMIT).ok(),
                _ => None,
            };
        }
        at += 46 + name_len + extra_len + comment_len;
    }
    None
}

/// The text of WordprocessingML: `<w:t>` contents, a line per paragraph, entities decoded.
fn xml_text(xml: &str) -> String {
    let mut out = String::new();
    let mut rest = xml;
    let mut in_text = false;
    while let Some(open) = rest.find('<') {
        if in_text {
            out.push_str(&decode(&rest[..open]));
        }
        let Some(close) = rest[open..].find('>') else { break };
        let tag = &rest[open + 1..open + close];
        let name = tag.trim_start_matches('/').split(|c: char| c.is_whitespace() || c == '/').next().unwrap_or_default();
        match name {
            "w:t" => in_text = !tag.starts_with('/') && !tag.ends_with('/'),
            "w:p" if tag.starts_with('/') => out.push('\n'),
            "w:tab" | "w:br" | "w:cr" => out.push(if name == "w:tab" { '\t' } else { '\n' }),
            _ => {}
        }
        rest = &rest[open + close + 1..];
    }
    out
}

fn decode(text: &str) -> String {
    if !text.contains('&') {
        return text.to_owned();
    }
    let mut out = String::new();
    let mut rest = text;
    while let Some(amp) = rest.find('&') {
        out.push_str(&rest[..amp]);
        let tail = &rest[amp + 1..];
        let Some(semi) = tail.find(';').filter(|&n| n <= 10) else {
            out.push('&');
            rest = tail;
            continue;
        };
        let entity = &tail[..semi];
        let decoded = match entity {
            "amp" => Some('&'),
            "lt" => Some('<'),
            "gt" => Some('>'),
            "quot" => Some('"'),
            "apos" => Some('\''),
            _ => entity
                .strip_prefix("#x")
                .map(|hex| u32::from_str_radix(hex, 16))
                .or_else(|| entity.strip_prefix('#').map(str::parse::<u32>))
                .and_then(Result::ok)
                .and_then(char::from_u32),
        };
        match decoded {
            Some(c) => {
                out.push(c);
                rest = &tail[semi + 1..];
            }
            None => {
                out.push('&');
                rest = tail;
            }
        }
    }
    out.push_str(rest);
    out
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// A zip archive as Word writes one: local headers, the central directory, its end record. CRCs aren't read.
    pub(crate) fn zip_of(files: &[(&str, &[u8], bool)]) -> Vec<u8> {
        let (mut zip, mut central) = (Vec::new(), Vec::new());
        for (name, data, deflate) in files {
            let body = if *deflate { miniz_oxide::deflate::compress_to_vec(data, 6) } else { data.to_vec() };
            let method: u16 = if *deflate { 8 } else { 0 };
            let offset = zip.len() as u32;
            zip.extend([0x50, 0x4B, 0x03, 0x04, 20, 0, 0, 0]);
            zip.extend(method.to_le_bytes());
            zip.extend([0; 8]);
            zip.extend((body.len() as u32).to_le_bytes());
            zip.extend((data.len() as u32).to_le_bytes());
            zip.extend((name.len() as u16).to_le_bytes());
            zip.extend([0, 0]);
            zip.extend(name.as_bytes());
            zip.extend(&body);
            central.extend([0x50, 0x4B, 0x01, 0x02, 20, 0, 20, 0, 0, 0]);
            central.extend(method.to_le_bytes());
            central.extend([0; 8]);
            central.extend((body.len() as u32).to_le_bytes());
            central.extend((data.len() as u32).to_le_bytes());
            central.extend((name.len() as u16).to_le_bytes());
            central.extend([0; 12]);
            central.extend(offset.to_le_bytes());
            central.extend(name.as_bytes());
        }
        let start = zip.len() as u32;
        zip.extend(&central);
        zip.extend([0x50, 0x4B, 0x05, 0x06, 0, 0, 0, 0]);
        zip.extend((files.len() as u16).to_le_bytes());
        zip.extend((files.len() as u16).to_le_bytes());
        zip.extend((central.len() as u32).to_le_bytes());
        zip.extend(start.to_le_bytes());
        zip.extend([0, 0]);
        zip
    }

    pub(crate) const DOCUMENT: &str = r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
<w:p><w:pPr><w:pStyle w:val="Title"/></w:pPr><w:r><w:t>Сценарий</w:t></w:r></w:p>
<w:p><w:r><w:t xml:space="preserve">Привет, </w:t></w:r><w:r><w:rPr><w:b/></w:rPr><w:t>мир</w:t></w:r><w:r><w:tab/><w:t>Tom &amp; Jerry &#x2014; &#8470;1</w:t></w:r></w:p>
<w:p/><w:sectPr/></w:body></w:document>"#;

    #[test]
    fn word_files() {
        assert_eq!(xml_text(DOCUMENT), "Сценарий\nПривет, мир\tTom & Jerry — №1\n");
        assert_eq!(decode("a &bogus; b & c"), "a &bogus; b & c");
        for deflate in [false, true] {
            let zip = zip_of(&[("[Content_Types].xml", b"<Types/>", deflate), ("word/document.xml", DOCUMENT.as_bytes(), deflate)]);
            assert_eq!(entry(&zip, "word/document.xml").as_deref(), Some(DOCUMENT.as_bytes()));
            assert_eq!(entry(&zip, "word/missing.xml"), None);
        }
        assert_eq!(entry(b"not a zip at all, just text that is long enough", "word/document.xml"), None);
        assert_eq!(entry(&[], "x"), None);
    }
}
