//! The tray icon drawn on the fly (docs/specs/SPEC-windows.md §4.1): Windows shows only a small square icon, so instead of
//! the Mac's menu bar text there is a drawing of the main service's first two limits (Claude's session and week), each
//! coloured by its level, in the style the person chose, and a dot in the corner: orange while a session waits for the
//! person, red while a project needs attention (the Mac's menu bar alert). Pure pixels (RGBA), so it is tested anywhere and handed to Tauri as is.

use crate::usage::UsageLevel;

pub const GREEN: [u8; 3] = [0x34, 0xC7, 0x59];
pub const ORANGE: [u8; 3] = [0xFF, 0x95, 0x00];
pub const RED: [u8; 3] = [0xFF, 0x3B, 0x30];
const TRACK: [u8; 4] = [0x8E, 0x8E, 0x93, 0x90];

pub fn level_color(level: UsageLevel) -> [u8; 3] {
    match level {
        UsageLevel::Low => GREEN,
        UsageLevel::Medium => ORANGE,
        UsageLevel::High => RED,
    }
}

/// How the two limits are drawn (Settings → «Сервисы AI» → «Значок в трее»). Without a second limit every style
/// draws the first one alone.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Style {
    /// One ring of the first limit: the icon of the first versions.
    Ring,
    /// The second limit as a smaller ring inside the first one's.
    Rings,
    /// Two columns filling from the bottom.
    Columns,
    /// Two rows filling from the left.
    Rows,
    /// The first limit as a number, the second as a row under it.
    Number,
    /// The first limit as a ring, the second as a pie inside it.
    Pie,
    /// Two arcs, left and right, filling from the bottom.
    Arcs,
}

impl Style {
    pub const ALL: [Style; 7] = [Style::Columns, Style::Number, Style::Rows, Style::Rings, Style::Pie, Style::Arcs, Style::Ring];
    /// The one that still reads at 16 px.
    pub const DEFAULT: Style = Style::Columns;

    pub fn id(self) -> &'static str {
        match self {
            Style::Ring => "ring",
            Style::Rings => "rings",
            Style::Columns => "columns",
            Style::Rows => "rows",
            Style::Number => "number",
            Style::Pie => "pie",
            Style::Arcs => "arcs",
        }
    }

    pub fn parse(id: &str) -> Option<Style> {
        Style::ALL.into_iter().find(|style| style.id() == id)
    }

    /// The saved style; an empty or unknown one is the default.
    pub fn saved(id: &str) -> Style {
        Style::parse(id).unwrap_or(Style::DEFAULT)
    }
}

/// What a point of the icon is: nothing, the grey track or a limit's colour.
#[derive(Clone, Copy)]
enum Paint {
    Empty,
    Track,
    Fill([u8; 3]),
}

fn fraction(percent: f64) -> f64 {
    (percent / 100.0).clamp(0.0, 1.0)
}

fn color(percent: f64) -> [u8; 3] {
    level_color(UsageLevel::of(percent))
}

fn filled(used: bool, percent: f64) -> Paint {
    if used { Paint::Fill(color(percent)) } else { Paint::Track }
}

/// Angle from twelve o'clock, clockwise, 0…1; and the distance from the middle. `u`, `v` are 0…1 across the icon.
fn polar(u: f64, v: f64) -> (f64, f64) {
    let (dx, dy) = (u - 0.5, v - 0.5);
    ((dx.atan2(-dy) / std::f64::consts::TAU).rem_euclid(1.0), dx.hypot(dy))
}

/// A ring between two radii filling clockwise from the top.
fn ring_paint(u: f64, v: f64, inner: f64, outer: f64, percent: f64) -> Paint {
    let (angle, distance) = polar(u, v);
    if distance < inner || distance > outer { Paint::Empty } else { filled(angle <= fraction(percent), percent) }
}

/// Inside a rectangle with rounded corners.
fn rounded(u: f64, v: f64, x0: f64, y0: f64, x1: f64, y1: f64, radius: f64) -> bool {
    if u < x0 || u > x1 || v < y0 || v > y1 {
        return false;
    }
    let cx = u.clamp(x0 + radius, x1 - radius);
    let cy = v.clamp(y0 + radius, y1 - radius);
    (u - cx).hypot(v - cy) <= radius
}

/// A column filling from the bottom.
fn column(u: f64, v: f64, x0: f64, x1: f64, percent: f64) -> Paint {
    let (y0, y1) = (0.04, 0.96);
    if !rounded(u, v, x0, y0, x1, y1, 0.1) { Paint::Empty } else { filled(v >= y1 - (y1 - y0) * fraction(percent), percent) }
}

/// A row filling from the left.
fn row(u: f64, v: f64, y0: f64, y1: f64, percent: f64) -> Paint {
    let (x0, x1) = (0.02, 0.98);
    if !rounded(u, v, x0, y0, x1, y1, ((y1 - y0) / 2.0).min(0.1)) { Paint::Empty } else { filled(u <= x0 + (x1 - x0) * fraction(percent), percent) }
}

/// Digits three cells wide and five high, a row per number, the left cell in the high bit.
const DIGITS: [[u8; 5]; 10] = [
    [0b111, 0b101, 0b101, 0b101, 0b111],
    [0b010, 0b110, 0b010, 0b010, 0b111],
    [0b111, 0b001, 0b111, 0b100, 0b111],
    [0b111, 0b001, 0b111, 0b001, 0b111],
    [0b101, 0b101, 0b111, 0b001, 0b001],
    [0b111, 0b100, 0b111, 0b001, 0b111],
    [0b111, 0b100, 0b111, 0b101, 0b111],
    [0b111, 0b001, 0b001, 0b001, 0b001],
    [0b111, 0b101, 0b111, 0b101, 0b111],
    [0b111, 0b101, 0b111, 0b001, 0b111],
];

/// The cells of a whole percent, five rows of `columns` cells: «62» is seven cells wide. «100» gets a «1» one cell
/// wide, or three digits would not fit the icon.
fn number_cells(percent: f64) -> (usize, Vec<bool>) {
    let value = percent.round().clamp(0.0, 100.0) as usize;
    let mut glyphs: Vec<(usize, [u8; 5])> = Vec::new();
    if value == 100 {
        glyphs.push((1, [1; 5]));
        glyphs.push((3, DIGITS[0]));
        glyphs.push((3, DIGITS[0]));
    } else {
        if value >= 10 {
            glyphs.push((3, DIGITS[value / 10]));
        }
        glyphs.push((3, DIGITS[value % 10]));
    }
    let columns = glyphs.iter().map(|(width, _)| width).sum::<usize>() + glyphs.len() - 1;
    let mut cells = vec![false; columns * 5];
    let mut left = 0;
    for (width, rows) in glyphs {
        for (y, bits) in rows.iter().enumerate() {
            for x in 0..width {
                cells[y * columns + left + x] = bits >> (width - 1 - x) & 1 == 1;
            }
        }
        left += width + 1;
    }
    (columns, cells)
}

/// Where the number's cells go, in pixels: (left, top, cell). Whole pixels when a cell is two or more, so the
/// digits stay sharp; Windows halves a 32 px icon for a 16 px tray.
fn number_frame(size: u32, columns: usize, top: f64, bottom: f64) -> (f64, f64, f64) {
    let n = size as f64;
    let (width, height) = (n * 0.96, n * (bottom - top));
    let mut cell = (width / columns as f64).min(height / 5.0);
    let sharp = cell >= 2.0;
    if sharp {
        cell = cell.floor();
    }
    let left = (n - cell * columns as f64) / 2.0;
    let y = n * top + (height - cell * 5.0) / 2.0;
    if sharp { (left.floor(), y.floor(), cell) } else { (left, y, cell) }
}

/// `size`×`size` RGBA of the two limits in `style`: grey tracks, the used parts in their levels' colours, and a dot of
/// `dot`'s colour top right. Edges are smoothed by covering each pixel with 4×4 samples.
pub fn draw(style: Style, size: u32, first: f64, second: Option<f64>, dot: Option<[u8; 3]>) -> Vec<u8> {
    let n = size as f64;
    let number = (style == Style::Number).then(|| {
        let (columns, cells) = number_cells(first);
        let (top, bottom) = if second.is_some() { (0.04, 0.72) } else { (0.1, 0.9) };
        Number { columns, cells, frame: number_frame(size, columns, top, bottom) }
    });
    let paint = |px: f64, py: f64| -> Paint {
        let (u, v) = (px / n, py / n);
        let Some(second) = second else {
            return match style {
                Style::Columns => column(u, v, 0.26, 0.74, first),
                Style::Rows => row(u, v, 0.3, 0.7, first),
                Style::Number => number_paint(&number, px, py, first),
                _ => ring_paint(u, v, 0.24, 0.44, first),
            };
        };
        match style {
            Style::Ring => ring_paint(u, v, 0.24, 0.44, first),
            Style::Rings => match ring_paint(u, v, 0.33, 0.49, first) {
                Paint::Empty => ring_paint(u, v, 0.09, 0.25, second),
                outer => outer,
            },
            Style::Pie => match ring_paint(u, v, 0.33, 0.49, first) {
                Paint::Empty => ring_paint(u, v, 0.0, 0.23, second),
                outer => outer,
            },
            Style::Columns => match column(u, v, 0.08, 0.44, first) {
                Paint::Empty => column(u, v, 0.56, 0.92, second),
                left => left,
            },
            Style::Rows => match row(u, v, 0.12, 0.44, first) {
                Paint::Empty => row(u, v, 0.56, 0.88, second),
                top => top,
            },
            Style::Number => match number_paint(&number, px, py, first) {
                Paint::Empty => row(u, v, 0.8, 0.98, second),
                digits => digits,
            },
            Style::Arcs => {
                let (angle, distance) = polar(u, v);
                // A gap at the top and at the bottom keeps the two arcs apart.
                let gap = 14.0 / 360.0;
                let span = 0.5 - 2.0 * gap;
                if !(0.27..=0.47).contains(&distance) {
                    Paint::Empty
                } else if angle > 0.5 + gap && angle < 1.0 - gap {
                    filled(angle - (0.5 + gap) <= span * fraction(first), first)
                } else if angle > gap && angle < 0.5 - gap {
                    filled(0.5 - gap - angle <= span * fraction(second), second)
                } else {
                    Paint::Empty
                }
            }
        }
    };
    // Over the number the dot is smaller and further into the corner, so it takes a corner of the last digit, not half of it.
    let (dot_center, dot_radius) = if style == Style::Number { ((n * 0.86, n * 0.14), n * 0.13) } else { ((n * 0.8, n * 0.2), n * 0.17) };
    let track_alpha = TRACK[3] as f64 / 255.0;
    let mut pixels = vec![0u8; (size * size * 4) as usize];
    for y in 0..size {
        for x in 0..size {
            // Colour sums weighted by coverage, and the coverage itself.
            let (mut sum, mut alpha) = ([0.0f64; 3], 0.0f64);
            for sy in 0..4 {
                for sx in 0..4 {
                    let px = x as f64 + (sx as f64 + 0.5) / 4.0;
                    let py = y as f64 + (sy as f64 + 0.5) / 4.0;
                    let (rgb, weight) = match dot {
                        Some(dot) if (px - dot_center.0).hypot(py - dot_center.1) <= dot_radius => (dot, 1.0),
                        _ => match paint(px, py) {
                            Paint::Empty => continue,
                            Paint::Track => ([TRACK[0], TRACK[1], TRACK[2]], track_alpha),
                            Paint::Fill(rgb) => (rgb, 1.0),
                        },
                    };
                    for channel in 0..3 {
                        sum[channel] += rgb[channel] as f64 * weight / 16.0;
                    }
                    alpha += weight / 16.0;
                }
            }
            let alpha = alpha.min(1.0);
            let index = ((y * size + x) * 4) as usize;
            if alpha > 0.0 {
                for channel in 0..3 {
                    pixels[index + channel] = (sum[channel] / alpha).round().min(255.0) as u8;
                }
                pixels[index + 3] = (alpha * 255.0).round() as u8;
            }
        }
    }
    pixels
}

/// The number's cells and where they are in the icon: (left, top, cell) in pixels.
struct Number {
    columns: usize,
    cells: Vec<bool>,
    frame: (f64, f64, f64),
}

fn number_paint(number: &Option<Number>, px: f64, py: f64, percent: f64) -> Paint {
    let Some(Number { columns, cells, frame: (left, top, cell) }) = number else { return Paint::Empty };
    let (x, y) = ((px - left) / cell, (py - top) / cell);
    if x < 0.0 || y < 0.0 || x >= *columns as f64 || y >= 5.0 {
        return Paint::Empty;
    }
    if cells[y as usize * columns + x as usize] { Paint::Fill(color(percent)) } else { Paint::Empty }
}

/// One ring of a single limit.
pub fn ring(size: u32, percent: f64, dot: Option<[u8; 3]>) -> Vec<u8> {
    draw(Style::Ring, size, percent, None, dot)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pixel(pixels: &[u8], size: u32, x: u32, y: u32) -> [u8; 4] {
        let i = ((y * size + x) * 4) as usize;
        [pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3]]
    }

    #[test]
    fn ring_fills_clockwise_from_the_top() {
        let size = 32;
        let quarter = ring(size, 25.0, None);
        assert_eq!(quarter.len(), (size * size * 4) as usize);
        // On the ring, right of twelve o'clock (used) and left of it (not yet).
        let right = pixel(&quarter, size, 22, 6);
        let left = pixel(&quarter, size, 9, 6);
        assert_eq!(&right[..3], &GREEN, "25 % is green and starts at the top, going right");
        assert_ne!(&left[..3], &GREEN);
        assert!(left[3] > 0, "the rest of the ring is the grey track");
        assert_eq!(pixel(&quarter, size, 16, 16)[3], 0, "the middle stays empty");
        assert_eq!(pixel(&quarter, size, 0, 0)[3], 0, "so do the corners");
    }

    #[test]
    fn colour_and_dot() {
        let size = 32;
        let high = ring(size, 90.0, Some(ORANGE));
        assert_eq!(&pixel(&high, size, 9, 20)[..3], &RED, "90 % fills most of the ring in red");
        assert_eq!(pixel(&high, size, 26, 6), [ORANGE[0], ORANGE[1], ORANGE[2], 255], "the dot top right");
        let calm = ring(size, 90.0, None);
        assert_ne!(pixel(&calm, size, 26, 6)[..3], ORANGE);
        let red = ring(size, 10.0, Some(RED));
        assert_eq!(pixel(&red, size, 26, 6), [RED[0], RED[1], RED[2], 255], "a project's alert is red");
    }

    #[test]
    fn styles_are_saved_by_id() {
        for style in Style::ALL {
            assert_eq!(Style::parse(style.id()), Some(style));
        }
        assert_eq!(Style::saved(""), Style::DEFAULT);
        assert_eq!(Style::saved("hologram"), Style::DEFAULT);
        assert_eq!(Style::saved("number"), Style::Number);
    }

    #[test]
    fn columns_fill_from_the_bottom_each_in_its_colour() {
        let size = 32;
        let icon = draw(Style::Columns, size, 62.0, Some(31.0), None);
        assert_eq!(&pixel(&icon, size, 8, 26)[..3], &ORANGE, "the first limit is the left column");
        assert_eq!(&pixel(&icon, size, 23, 26)[..3], &GREEN, "the second is the right one");
        assert_eq!(&pixel(&icon, size, 8, 16)[..3], &ORANGE, "62 % reaches above the middle");
        assert_ne!(&pixel(&icon, size, 23, 16)[..3], &GREEN, "31 % doesn't");
        assert!(pixel(&icon, size, 23, 16)[3] > 0, "the track is there");
        assert_eq!(pixel(&icon, size, 16, 16)[3], 0, "a gap between the columns");
    }

    #[test]
    fn rows_fill_from_the_left() {
        let size = 32;
        let icon = draw(Style::Rows, size, 90.0, Some(20.0), None);
        assert_eq!(&pixel(&icon, size, 20, 9)[..3], &RED, "the first limit on top");
        assert_eq!(&pixel(&icon, size, 4, 23)[..3], &GREEN, "the second under it");
        assert_ne!(&pixel(&icon, size, 20, 23)[..3], &GREEN);
        assert_eq!(pixel(&icon, size, 16, 16)[3], 0);
    }

    #[test]
    fn rings_and_pie_keep_the_second_limit_inside() {
        let size = 32;
        for style in [Style::Rings, Style::Pie] {
            let icon = draw(style, size, 90.0, Some(40.0), None);
            assert_eq!(&pixel(&icon, size, 29, 16)[..3], &RED, "{style:?}: the outer ring is the first limit");
            assert_eq!(&pixel(&icon, size, 20, 13)[..3], &GREEN, "{style:?}: the second limit inside");
            assert_ne!(&pixel(&icon, size, 11, 13)[..3], &GREEN, "{style:?}: 40 % stops before the left half");
        }
        assert_eq!(pixel(&draw(Style::Rings, size, 90.0, Some(40.0), None), size, 16, 16)[3], 0, "a ring is hollow");
        assert!(pixel(&draw(Style::Pie, size, 90.0, Some(40.0), None), size, 15, 18)[3] > 0, "a pie isn't");
    }

    #[test]
    fn arcs_fill_from_the_bottom_on_both_sides() {
        let size = 32;
        let icon = draw(Style::Arcs, size, 62.0, Some(31.0), None);
        assert_eq!(&pixel(&icon, size, 5, 22)[..3], &ORANGE, "left, low: the first limit");
        assert_eq!(&pixel(&icon, size, 26, 22)[..3], &GREEN, "right, low: the second");
        assert_ne!(&pixel(&icon, size, 26, 9)[..3], &GREEN, "31 % doesn't reach the top");
        assert_eq!(pixel(&icon, size, 16, 2)[3], 0, "the gap at the top");
    }

    #[test]
    fn number_is_sharp_and_fits() {
        let size = 32;
        let icon = draw(Style::Number, size, 62.0, Some(31.0), None);
        // «62» is 7 cells of 4 px from x = 2, y = 2: the «6» has its top bar and nothing right of its second row.
        assert_eq!(pixel(&icon, size, 3, 3), [ORANGE[0], ORANGE[1], ORANGE[2], 255]);
        assert_eq!(pixel(&icon, size, 11, 7)[3], 0);
        assert_eq!(pixel(&icon, size, 15, 10)[3], 0, "a cell between the digits");
        assert_eq!(&pixel(&icon, size, 4, 28)[..3], &GREEN, "the second limit is the row under the number");
        // «100» still fits: nothing is painted in the first or last pixel column of the digits' rows.
        let full = draw(Style::Number, size, 100.0, Some(31.0), None);
        assert!((0..22).all(|y| pixel(&full, size, 0, y)[3] == 0 && pixel(&full, size, 31, y)[3] == 0));
        assert!((0..size).any(|x| pixel(&full, size, x, 12)[..3] == RED));
        assert_eq!(number_cells(7.0).0, 3);
        assert_eq!(number_cells(100.0).0, 9);
    }

    #[test]
    fn one_limit_alone_and_the_dot_in_every_style() {
        let size = 32;
        for style in Style::ALL {
            let alone = draw(style, size, 62.0, None, Some(RED));
            assert_eq!(alone.len(), (size * size * 4) as usize);
            assert!(alone.chunks(4).any(|p| p[..3] == ORANGE && p[3] == 255), "{style:?} draws the first limit alone");
            assert!(!alone.chunks(4).any(|p| p[..3] == GREEN), "{style:?} draws no second limit");
            assert_eq!(pixel(&alone, size, 27, 4), [RED[0], RED[1], RED[2], 255], "{style:?}: the dot top right");
        }
        let number = draw(Style::Number, size, 62.0, Some(31.0), Some(RED));
        assert_eq!(&pixel(&number, size, 21, 4)[..3], &ORANGE, "the dot leaves the last digit's top bar readable");
        assert_eq!(draw(Style::Rings, size, 62.0, None, None), ring(size, 62.0, None), "without a second limit the rings are the old ring");
    }
}
