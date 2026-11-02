//! The tray icon drawn on the fly (docs/SPEC-windows.md §4.1): Windows shows only a small square icon, so instead of
//! the Mac's menu bar text there is a ring of the session limit, coloured by level, and a dot in the corner when
//! something waits for the person. Pure pixels (RGBA), so it is tested anywhere and handed to Tauri as is.

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

/// `size`×`size` RGBA: a grey track, the used part from twelve o'clock clockwise in the level's colour, and an
/// orange dot top right when `attention`. Edges are smoothed by covering each pixel with 4×4 samples.
pub fn ring(size: u32, percent: f64, attention: bool) -> Vec<u8> {
    let color = level_color(UsageLevel::of(percent));
    let fraction = (percent / 100.0).clamp(0.0, 1.0);
    let n = size as f64;
    let center = n / 2.0;
    let outer = n / 2.0 - n * 0.06;
    let inner = outer - n * 0.2;
    let dot_center = (n * 0.8, n * 0.2);
    let dot_radius = n * 0.17;
    let mut pixels = vec![0u8; (size * size * 4) as usize];
    for y in 0..size {
        for x in 0..size {
            let (mut track, mut used, mut dot) = (0.0, 0.0, 0.0);
            for sy in 0..4 {
                for sx in 0..4 {
                    let px = x as f64 + (sx as f64 + 0.5) / 4.0;
                    let py = y as f64 + (sy as f64 + 0.5) / 4.0;
                    if attention && (px - dot_center.0).hypot(py - dot_center.1) <= dot_radius {
                        dot += 1.0;
                        continue;
                    }
                    let distance = (px - center).hypot(py - center);
                    if distance < inner || distance > outer {
                        continue;
                    }
                    // Angle from twelve o'clock, clockwise, 0…1.
                    let angle = ((px - center).atan2(-(py - center)) / std::f64::consts::TAU).rem_euclid(1.0);
                    if angle <= fraction { used += 1.0 } else { track += 1.0 }
                }
            }
            let (track, used, dot) = (track / 16.0, used / 16.0, dot / 16.0);
            let alpha = (track * TRACK[3] as f64 / 255.0 + used + dot).min(1.0);
            let index = ((y * size + x) * 4) as usize;
            if alpha > 0.0 {
                for channel in 0..3 {
                    let value = track * (TRACK[3] as f64 / 255.0) * TRACK[channel] as f64
                        + used * color[channel] as f64
                        + dot * ORANGE[channel] as f64;
                    pixels[index + channel] = (value / alpha).round().min(255.0) as u8;
                }
                pixels[index + 3] = (alpha * 255.0).round() as u8;
            }
        }
    }
    pixels
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
        let quarter = ring(size, 25.0, false);
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
        let high = ring(size, 90.0, true);
        assert_eq!(&pixel(&high, size, 9, 20)[..3], &RED, "90 % fills most of the ring in red");
        assert_eq!(pixel(&high, size, 26, 6), [ORANGE[0], ORANGE[1], ORANGE[2], 255], "the dot top right");
        let calm = ring(size, 90.0, false);
        assert_ne!(pixel(&calm, size, 26, 6)[..3], ORANGE);
    }
}
