//! HSV sub-crop color classification and visual attribute extraction.
//!
//! Splits detected subject crops into upper-body (torso) and lower-body (legs/skirt/lower hull)
//! regions in HSV space so natural-language queries like `"person in red"` or
//! `"person wearing red shirt and blue pants"` can leverage structured fast-path attributes
//! alongside multimodal embeddings.

use crate::frame::RgbFrame;
use serde::{Deserialize, Serialize};

/// Canonical coarse color palette used for structured visual attribute indexing and filtering.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ColorName {
    Red,
    Blue,
    Black,
    White,
    Gray,
    Green,
    Yellow,
    Orange,
    Brown,
    Purple,
}

impl ColorName {
    pub const ALL: [Self; 10] = [
        Self::Red,
        Self::Blue,
        Self::Black,
        Self::White,
        Self::Gray,
        Self::Green,
        Self::Yellow,
        Self::Orange,
        Self::Brown,
        Self::Purple,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Red => "red",
            Self::Blue => "blue",
            Self::Black => "black",
            Self::White => "white",
            Self::Gray => "gray",
            Self::Green => "green",
            Self::Yellow => "yellow",
            Self::Orange => "orange",
            Self::Brown => "brown",
            Self::Purple => "purple",
        }
    }

    fn slot_index(self) -> usize {
        match self {
            Self::Red => 0,
            Self::Blue => 1,
            Self::Black => 2,
            Self::White => 3,
            Self::Gray => 4,
            Self::Green => 5,
            Self::Yellow => 6,
            Self::Orange => 7,
            Self::Brown => 8,
            Self::Purple => 9,
        }
    }
}

impl core::fmt::Display for ColorName {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Structured visual attributes extracted from a detected subject crop.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct VisualAttributes {
    /// Dominant colors across the full crop (ordered by prevalence, up to 2).
    pub dominant_colors: Vec<ColorName>,
    /// Dominant colors in the upper-body sub-crop (`y in [0.0, 0.50]`).
    pub upper_body_colors: Vec<ColorName>,
    /// Dominant colors in the lower-body sub-crop (`y in [0.50, 1.0]`).
    pub lower_body_colors: Vec<ColorName>,
    /// Crop width / height aspect ratio.
    pub aspect_ratio: f32,
    /// Normalized bounding-box area fraction (`0.0..=1.0`).
    pub area_fraction: f32,
    /// Mean BT.601 luma (`0.0..=1.0`) of the crop.
    pub mean_luma: f32,
}

impl VisualAttributes {
    /// Returns string names for `dominant_colors` (convenience for legacy string APIs).
    pub fn dominant_color_names(&self) -> Vec<String> {
        self.dominant_colors
            .iter()
            .map(|c| c.as_str().to_string())
            .collect()
    }
}

/// Converts an RGB8 triplet into `(hue_deg [0, 360), saturation [0, 1], value [0, 1])`.
pub fn rgb_to_hsv([r, g, b]: [u8; 3]) -> (f32, f32, f32) {
    let rf = f32::from(r) / 255.0;
    let gf = f32::from(g) / 255.0;
    let bf = f32::from(b) / 255.0;
    let max_c = rf.max(gf).max(bf);
    let min_c = rf.min(gf).min(bf);
    let delta = max_c - min_c;
    let sat = if max_c <= 1e-5 { 0.0 } else { delta / max_c };

    if delta <= 1e-5 {
        return (0.0, sat, max_c);
    }

    let mut hue = if (max_c - rf).abs() < 1e-5 {
        60.0 * (((gf - bf) / delta) % 6.0)
    } else if (max_c - gf).abs() < 1e-5 {
        60.0 * (((bf - rf) / delta) + 2.0)
    } else {
        60.0 * (((rf - gf) / delta) + 4.0)
    };
    if hue < 0.0 {
        hue += 360.0;
    }
    (hue, sat, max_c)
}

/// Maps an HSV triplet `(hue_deg, saturation, value)` to a canonical [`ColorName`].
pub fn classify_hsv_color(hue: f32, sat: f32, val: f32) -> ColorName {
    if val < 0.16 {
        return ColorName::Black;
    }
    if sat < 0.16 {
        if val >= 0.82 {
            return ColorName::White;
        }
        return ColorName::Gray;
    }

    let h = hue.rem_euclid(360.0);
    if !(16.0..335.0).contains(&h) {
        ColorName::Red
    } else if h < 42.0 {
        if val < 0.68 {
            ColorName::Brown
        } else {
            ColorName::Orange
        }
    } else if h < 72.0 {
        ColorName::Yellow
    } else if h < 168.0 {
        ColorName::Green
    } else if h < 258.0 {
        ColorName::Blue
    } else {
        ColorName::Purple
    }
}

/// Classifies up to 2 dominant colors in an RGB crop, optionally excluding pixels close to
/// a border-estimated background RGB color.
pub fn classify_crop_colors(crop: &RgbFrame, exclude_bg: Option<[u8; 3]>) -> Vec<ColorName> {
    let mut counts = [0u32; 10];
    let mut sampled = 0u32;

    for y in 0..crop.height() {
        for x in 0..crop.width() {
            let rgb = crop.pixel_at(x, y);
            if let Some(bg) = exclude_bg
                && !is_foreground_pixel(rgb, bg)
            {
                continue;
            }
            let (h, s, v) = rgb_to_hsv(rgb);
            let color = classify_hsv_color(h, s, v);
            counts[color.slot_index()] += 1;
            sampled += 1;
        }
    }

    if sampled == 0 {
        return Vec::new();
    }

    let mut indexed: Vec<(usize, u32)> = counts
        .into_iter()
        .enumerate()
        .filter(|&(_, c)| (c as f32) / (sampled as f32) >= 0.18)
        .collect();
    indexed.sort_by_key(|a| core::cmp::Reverse(a.1));
    indexed
        .into_iter()
        .take(2)
        .map(|(idx, _)| ColorName::ALL[idx])
        .collect()
}

/// Extracts full, upper-body, and lower-body HSV color attributes plus geometric stats
/// for a normalized bounding box `[x1, y1, x2, y2]` within `frame`.
pub fn extract_visual_attributes(
    frame: &RgbFrame,
    bbox_norm: [f32; 4],
    exclude_bg: Option<[u8; 3]>,
) -> VisualAttributes {
    let crop = frame.crop_normalized(bbox_norm);
    let dominant_colors = classify_crop_colors(&crop, exclude_bg);
    let upper_crop = crop.crop_normalized([0.0, 0.0, 1.0, 0.5]);
    let lower_crop = crop.crop_normalized([0.0, 0.5, 1.0, 1.0]);
    let upper_body_colors = classify_crop_colors(&upper_crop, exclude_bg);
    let lower_body_colors = classify_crop_colors(&lower_crop, exclude_bg);

    let bw = (bbox_norm[2] - bbox_norm[0]).max(1e-6);
    let bh = (bbox_norm[3] - bbox_norm[1]).max(1e-6);
    let aspect_ratio = (crop.width() as f32) / (crop.height().max(1) as f32);
    let area_fraction = (bw * bh).clamp(0.0, 1.0);

    let mut luma_sum = 0u64;
    let total_px = (crop.width() as u64) * (crop.height() as u64);
    for px in crop.pixels().as_chunks::<3>().0 {
        let y =
            (77u64 * u64::from(px[0]) + 150u64 * u64::from(px[1]) + 29u64 * u64::from(px[2]) + 128)
                >> 8;
        luma_sum += y;
    }
    let mean_luma = if total_px > 0 {
        ((luma_sum as f32) / ((total_px as f32) * 255.0)).clamp(0.0, 1.0)
    } else {
        0.0
    };

    VisualAttributes {
        dominant_colors,
        upper_body_colors,
        lower_body_colors,
        aspect_ratio,
        area_fraction,
        mean_luma,
    }
}

fn is_foreground_pixel(rgb: [u8; 3], bg: [u8; 3]) -> bool {
    let dist = (i16::from(rgb[0]) - i16::from(bg[0])).unsigned_abs()
        + (i16::from(rgb[1]) - i16::from(bg[1])).unsigned_abs()
        + (i16::from(rgb[2]) - i16::from(bg[2])).unsigned_abs();
    dist >= 48
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_red_upper_and_blue_lower_person_crop() {
        let mut frame = RgbFrame::solid(200, 200, [180, 180, 180]);
        // Person bbox [0.25, 0.20, 0.55, 0.80] => x: 50..110, y: 40..160
        // Upper half (y: 40..100) bright red; lower half (y: 100..160) bright blue.
        frame.fill_rect(50, 40, 110, 100, [220, 25, 25]);
        frame.fill_rect(50, 100, 110, 160, [25, 60, 225]);

        let attrs =
            extract_visual_attributes(&frame, [0.25, 0.20, 0.55, 0.80], Some([180, 180, 180]));
        assert_eq!(attrs.upper_body_colors, vec![ColorName::Red]);
        assert_eq!(attrs.lower_body_colors, vec![ColorName::Blue]);
        assert!(attrs.dominant_colors.contains(&ColorName::Red));
        assert!(attrs.dominant_colors.contains(&ColorName::Blue));
        assert!(attrs.aspect_ratio < 1.0);
        assert!((attrs.area_fraction - 0.18).abs() < 0.01);
    }

    #[test]
    fn classifies_all_ten_canonical_colors() {
        let cases: [([u8; 3], ColorName); 10] = [
            ([230, 20, 20], ColorName::Red),
            ([20, 70, 230], ColorName::Blue),
            ([10, 10, 10], ColorName::Black),
            ([245, 245, 245], ColorName::White),
            ([128, 128, 128], ColorName::Gray),
            ([25, 200, 40], ColorName::Green),
            ([240, 230, 30], ColorName::Yellow),
            ([240, 130, 20], ColorName::Orange),
            ([120, 70, 30], ColorName::Brown),
            ([160, 35, 210], ColorName::Purple),
        ];
        for (rgb, expected) in cases {
            let (h, s, v) = rgb_to_hsv(rgb);
            assert_eq!(
                classify_hsv_color(h, s, v),
                expected,
                "RGB {rgb:?} -> HSV ({h:.1}, {s:.2}, {v:.2})"
            );
        }
    }
}
