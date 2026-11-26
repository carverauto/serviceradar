//! Bounded full-resolution detection and ROI crop extraction for Vantage ML pipelines.
//!
//! Extracts padded bounding-box and polygon ROI regions directly from native-resolution
//! decoded [`RgbFrame`]s (never from `480x270` thumbnails), enforces `min_bbox_width_px`
//! on the *unpadded* native bounding box before padding, optionally downscales only if
//! the crop exceeds `max_dimension` (`<= 640px`), and encodes a standards-compliant
//! Baseline Sequential JFIF JPEG (`SOF0`) capped at `max_bytes` (`<= 96 KiB` for
//! inference, or `<= 32 KiB` via [`CropConfig::for_stored_preview`] for persisted
//! `camera_vantage_observations.crop_jpeg` previews).

use crate::error::MediaCoreError;
use crate::frame::RgbFrame;
use crate::thumbnail::{ThumbnailConfig, downscale_rgb_fit, encode_jpeg_thumbnail};
use base64::Engine as _;
use serde::{Deserialize, Serialize};

/// Default fractional context padding added on each side of a normalized detection box.
pub const DEFAULT_CROP_PADDING_RATIO: f32 = 0.15;
/// Default minimum unpadded native detection width in pixels (`min_bbox_width_px`).
pub const DEFAULT_MIN_BBOX_WIDTH_PX: u32 = 96;
/// Default maximum output dimension (width or height) in pixels.
pub const DEFAULT_MAX_CROP_DIMENSION: u32 = 640;
/// Hard upper bound on crop output dimension (`<= 640px`).
pub const HARD_MAX_CROP_DIMENSION: u32 = 640;
/// Default maximum Baseline JFIF JPEG payload size for inference crops (`96 KiB`).
pub const DEFAULT_MAX_CROP_BYTES: usize = 96 * 1024;
/// Hard upper bound on inference crop JPEG payload size (`96 KiB`).
pub const HARD_MAX_CROP_BYTES: usize = 96 * 1024;
/// Maximum persisted preview JPEG size (`32 KiB`) matching `camera_vantage_observations.crop_jpeg`.
pub const STORED_PREVIEW_MAX_BYTES: usize = 32 * 1024;

/// Configuration for full-resolution detection and ROI crop extraction.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CropConfig {
    /// Context padding fraction added to each edge (`0.15` = 15% of box width/height per side).
    pub padding_ratio: f32,
    /// Minimum unpadded detection width in native frame pixels (default `96`).
    pub min_bbox_width_px: u32,
    /// Minimum unpadded detection height in native frame pixels (default `1`).
    pub min_bbox_height_px: u32,
    /// Maximum width or height after bounded downscaling (default & hard cap `640`).
    pub max_dimension: u32,
    /// Initial JPEG quality in `1..=100` (default `85`).
    pub quality: u8,
    /// Minimum JPEG quality allowed while fitting `max_bytes` (default `35`).
    pub min_quality: u8,
    /// Maximum Baseline JFIF JPEG payload size in bytes (default & hard cap `96 KiB`).
    pub max_bytes: usize,
}

impl Default for CropConfig {
    fn default() -> Self {
        Self {
            padding_ratio: DEFAULT_CROP_PADDING_RATIO,
            min_bbox_width_px: DEFAULT_MIN_BBOX_WIDTH_PX,
            min_bbox_height_px: 1,
            max_dimension: DEFAULT_MAX_CROP_DIMENSION,
            quality: 85,
            min_quality: 35,
            max_bytes: DEFAULT_MAX_CROP_BYTES,
        }
    }
}

impl CropConfig {
    /// Returns a [`CropConfig`] capped at [`STORED_PREVIEW_MAX_BYTES`] (`32 KiB`) for
    /// optional persisted `VantageObservation.crop_jpeg` previews.
    pub fn for_stored_preview() -> Self {
        Self {
            max_dimension: DEFAULT_MAX_CROP_DIMENSION,
            quality: 75,
            min_quality: 30,
            max_bytes: STORED_PREVIEW_MAX_BYTES,
            ..Self::default()
        }
    }

    /// Validates all configuration invariants and hard bounds.
    pub fn validate(&self) -> Result<(), MediaCoreError> {
        if !self.padding_ratio.is_finite() || !(0.0..=2.0).contains(&self.padding_ratio) {
            return Err(MediaCoreError::invalid_configuration(format!(
                "crop padding_ratio {} must be finite and in 0.0..=2.0",
                self.padding_ratio
            )));
        }
        if self.max_dimension == 0 || self.max_dimension > HARD_MAX_CROP_DIMENSION {
            return Err(MediaCoreError::invalid_configuration(format!(
                "crop max_dimension {} must be in 1..={HARD_MAX_CROP_DIMENSION}",
                self.max_dimension
            )));
        }
        if self.max_bytes < 512 || self.max_bytes > HARD_MAX_CROP_BYTES {
            return Err(MediaCoreError::invalid_configuration(format!(
                "crop max_bytes {} must be in 512..={HARD_MAX_CROP_BYTES}",
                self.max_bytes
            )));
        }
        if self.quality == 0
            || self.quality > 100
            || self.min_quality == 0
            || self.min_quality > 100
        {
            return Err(MediaCoreError::invalid_configuration(
                "crop quality and min_quality must be in 1..=100",
            ));
        }
        if self.min_quality > self.quality {
            return Err(MediaCoreError::invalid_configuration(
                "crop min_quality cannot exceed quality",
            ));
        }
        Ok(())
    }

    /// Converts this crop configuration into a [`ThumbnailConfig`] for Baseline JFIF encoding.
    pub fn to_thumbnail_config(&self) -> ThumbnailConfig {
        ThumbnailConfig {
            max_width: self.max_dimension,
            max_height: self.max_dimension,
            quality: self.quality,
            min_quality: self.min_quality,
            max_bytes: self.max_bytes,
        }
    }
}

/// Bounded skip reason emitted when a detection/ROI is not eligible for inference.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum CropSkipReason {
    /// Unpadded native bbox was narrower or shorter than configured minimum pixels.
    #[serde(rename = "crop_below_min_dimension")]
    BelowMinDimension,
    /// Detection bounding box did not overlap any configured ROI polygon.
    #[serde(rename = "crop_outside_roi")]
    OutsideRoi,
}

impl CropSkipReason {
    /// Stable low-cardinality label value for Prometheus and telemetry counters.
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::BelowMinDimension => "crop_below_min_dimension",
            Self::OutsideRoi => "crop_outside_roi",
        }
    }
}

/// Encoded full-resolution (optionally bounded-downscaled) Baseline Sequential JFIF crop.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct EncodedCrop {
    pub width: u32,
    pub height: u32,
    pub source_bbox_width_px: u32,
    pub source_bbox_height_px: u32,
    pub padded_bbox_norm: [f32; 4],
    pub quality: u8,
    pub jpeg_bytes: Vec<u8>,
    pub sha256_hex: String,
}

impl EncodedCrop {
    /// Encodes the JPEG payload as standard base64 for VLM data URLs or `crop_jpeg_b64`.
    pub fn to_base64(&self) -> String {
        base64::engine::general_purpose::STANDARD.encode(&self.jpeg_bytes)
    }
}

/// Result of [`crop_detection_jpeg`] and related JPEG crop functions.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum CropOutcome {
    Encoded(EncodedCrop),
    Skipped {
        reason: CropSkipReason,
        bbox_width_px: u32,
        bbox_height_px: u32,
        min_bbox_width_px: u32,
    },
}

impl CropOutcome {
    pub fn encoded(&self) -> Option<&EncodedCrop> {
        match self {
            Self::Encoded(crop) => Some(crop),
            Self::Skipped { .. } => None,
        }
    }

    pub fn into_encoded(self) -> Option<EncodedCrop> {
        match self {
            Self::Encoded(crop) => Some(crop),
            Self::Skipped { .. } => None,
        }
    }

    pub fn skip_reason(&self) -> Option<CropSkipReason> {
        match self {
            Self::Encoded(_) => None,
            Self::Skipped { reason, .. } => Some(*reason),
        }
    }

    pub fn is_skipped(&self) -> bool {
        matches!(self, Self::Skipped { .. })
    }
}

/// Result of [`crop_detection_rgb`] and [`crop_roi_polygon_rgb`].
#[derive(Debug, Clone, PartialEq)]
pub enum RgbCropOutcome {
    Cropped {
        frame: RgbFrame,
        source_bbox_width_px: u32,
        source_bbox_height_px: u32,
        padded_bbox_norm: [f32; 4],
    },
    Skipped {
        reason: CropSkipReason,
        bbox_width_px: u32,
        bbox_height_px: u32,
        min_bbox_width_px: u32,
    },
}

/// Normalized `[x, y]` polygon region of interest in `[0.0, 1.0]` frame coordinates.
#[derive(Debug, Clone, PartialEq, Default, Serialize)]
#[serde(transparent)]
pub struct RoiPolygon(pub Vec<[f32; 2]>);

#[derive(Deserialize)]
#[serde(untagged)]
enum RoiPointRepr {
    Pair([f32; 2]),
    Object { x: f32, y: f32 },
}

impl RoiPointRepr {
    fn into_pair(self) -> [f32; 2] {
        match self {
            Self::Pair(pair) => pair,
            Self::Object { x, y } => [x, y],
        }
    }
}

#[derive(Deserialize)]
#[serde(untagged)]
enum RoiPolygonRepr {
    Sequence(Vec<RoiPointRepr>),
    Map { points: Vec<RoiPointRepr> },
}

impl<'de> Deserialize<'de> for RoiPolygon {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let repr = RoiPolygonRepr::deserialize(deserializer)?;
        let raw_points = match repr {
            RoiPolygonRepr::Sequence(pts) | RoiPolygonRepr::Map { points: pts } => pts,
        };
        Ok(Self(
            raw_points
                .into_iter()
                .map(RoiPointRepr::into_pair)
                .collect(),
        ))
    }
}

impl RoiPolygon {
    /// Creates a new [`RoiPolygon`] from normalized `[x, y]` vertices.
    pub fn new(vertices: Vec<[f32; 2]>) -> Self {
        Self(vertices)
    }

    /// Validates that the polygon has at least 3 finite vertices within `[0.0, 1.0]`
    /// and spans a non-zero bounding box.
    pub fn validate(&self) -> Result<(), MediaCoreError> {
        if self.0.len() < 3 {
            return Err(MediaCoreError::invalid_configuration(format!(
                "ROI polygon requires at least 3 vertices, got {}",
                self.0.len()
            )));
        }
        for (idx, &[x, y]) in self.0.iter().enumerate() {
            if !x.is_finite()
                || !y.is_finite()
                || !(0.0..=1.0).contains(&x)
                || !(0.0..=1.0).contains(&y)
            {
                return Err(MediaCoreError::invalid_configuration(format!(
                    "ROI polygon vertex {idx} ([{x}, {y}]) must be finite and in 0.0..=1.0"
                )));
            }
        }
        let bbox = self.bounding_bbox_unchecked();
        if bbox[2] <= bbox[0] || bbox[3] <= bbox[1] {
            return Err(MediaCoreError::invalid_configuration(
                "ROI polygon must span non-zero width and height",
            ));
        }
        Ok(())
    }

    fn bounding_bbox_unchecked(&self) -> [f32; 4] {
        let mut min_x = 1.0f32;
        let mut min_y = 1.0f32;
        let mut max_x = 0.0f32;
        let mut max_y = 0.0f32;
        for &[x, y] in &self.0 {
            min_x = min_x.min(x.clamp(0.0, 1.0));
            min_y = min_y.min(y.clamp(0.0, 1.0));
            max_x = max_x.max(x.clamp(0.0, 1.0));
            max_y = max_y.max(y.clamp(0.0, 1.0));
        }
        [min_x, min_y, max_x, max_y]
    }

    /// Returns the axis-aligned normalized `[x1, y1, x2, y2]` bounding box of this polygon.
    pub fn bounding_bbox(&self) -> Result<[f32; 4], MediaCoreError> {
        self.validate()?;
        Ok(self.bounding_bbox_unchecked())
    }

    /// Ray-casting + boundary-segment point-in-polygon check in normalized coordinates.
    pub fn contains_point(&self, x: f32, y: f32) -> bool {
        if self.0.len() < 3 || !x.is_finite() || !y.is_finite() {
            return false;
        }
        let n = self.0.len();
        let mut inside = false;
        for i in 0..n {
            let [x1, y1] = self.0[i];
            let [x2, y2] = self.0[(i + 1) % n];
            if point_on_segment(x, y, x1, y1, x2, y2) {
                return true;
            }
            let intersects = (y1 > y) != (y2 > y)
                && (f64::from(x)
                    < f64::from(x1)
                        + (f64::from(y) - f64::from(y1)) * (f64::from(x2) - f64::from(x1))
                            / (f64::from(y2) - f64::from(y1)));
            if intersects {
                inside = !inside;
            }
        }
        inside
    }

    /// Returns `true` if the normalized bounding box center lies inside or on the polygon.
    pub fn contains_bbox_center(&self, bbox: [f32; 4]) -> bool {
        let cx = (bbox[0] + bbox[2]) * 0.5;
        let cy = (bbox[1] + bbox[3]) * 0.5;
        self.contains_point(cx, cy)
    }

    /// Returns `true` if the normalized bounding box overlaps this polygon.
    pub fn overlaps_bbox(&self, bbox: [f32; 4]) -> bool {
        if self.0.len() < 3 {
            return false;
        }
        let [bx1, by1, bx2, by2] = bbox;
        if !bx1.is_finite() || !by1.is_finite() || !bx2.is_finite() || !by2.is_finite() {
            return false;
        }
        let poly_bbox = self.bounding_bbox_unchecked();
        if bx2 <= poly_bbox[0] || bx1 >= poly_bbox[2] || by2 <= poly_bbox[1] || by1 >= poly_bbox[3]
        {
            return false;
        }

        // Check bbox center & corners inside polygon.
        if self.contains_bbox_center(bbox)
            || self.contains_point(bx1, by1)
            || self.contains_point(bx2, by1)
            || self.contains_point(bx2, by2)
            || self.contains_point(bx1, by2)
        {
            return true;
        }

        // Check any polygon vertex inside bbox.
        if self
            .0
            .iter()
            .any(|&[px, py]| px >= bx1 && px <= bx2 && py >= by1 && py <= by2)
        {
            return true;
        }

        // Check polygon edge intersections with bbox edges.
        let rect_edges = [
            ([bx1, by1], [bx2, by1]),
            ([bx2, by1], [bx2, by2]),
            ([bx2, by2], [bx1, by2]),
            ([bx1, by2], [bx1, by1]),
        ];
        let n = self.0.len();
        for i in 0..n {
            let p1 = self.0[i];
            let p2 = self.0[(i + 1) % n];
            for &(r1, r2) in &rect_edges {
                if segments_intersect(p1, p2, r1, r2) {
                    return true;
                }
            }
        }
        false
    }

    /// Masks pixels in `crop` whose centers fall outside this polygon to `fill_rgb`.
    pub fn mask_outside_rgb(
        &self,
        crop: &mut RgbFrame,
        crop_bbox_norm: [f32; 4],
        fill_rgb: [u8; 3],
    ) {
        let w = crop.width();
        let h = crop.height();
        if w == 0 || h == 0 {
            return;
        }
        let span_x = (crop_bbox_norm[2] - crop_bbox_norm[0]).max(0.0);
        let span_y = (crop_bbox_norm[3] - crop_bbox_norm[1]).max(0.0);
        for py in 0..h {
            let ny = crop_bbox_norm[1] + ((py as f32) + 0.5) / (h as f32) * span_y;
            for px in 0..w {
                let nx = crop_bbox_norm[0] + ((px as f32) + 0.5) / (w as f32) * span_x;
                if !self.contains_point(nx, ny) {
                    crop.set_pixel(px, py, fill_rgb);
                }
            }
        }
    }
}

fn point_on_segment(px: f32, py: f32, x1: f32, y1: f32, x2: f32, y2: f32) -> bool {
    const EPS: f64 = 1e-6;
    let cross = (f64::from(px) - f64::from(x1)) * (f64::from(y2) - f64::from(y1))
        - (f64::from(py) - f64::from(y1)) * (f64::from(x2) - f64::from(x1));
    if cross.abs() > EPS {
        return false;
    }
    let min_x = f64::from(x1.min(x2)) - EPS;
    let max_x = f64::from(x1.max(x2)) + EPS;
    let min_y = f64::from(y1.min(y2)) - EPS;
    let max_y = f64::from(y1.max(y2)) + EPS;
    let px = f64::from(px);
    let py = f64::from(py);
    px >= min_x && px <= max_x && py >= min_y && py <= max_y
}

fn segments_intersect(a1: [f32; 2], a2: [f32; 2], b1: [f32; 2], b2: [f32; 2]) -> bool {
    let orient = |p: [f32; 2], q: [f32; 2], r: [f32; 2]| -> f64 {
        (f64::from(q[0]) - f64::from(p[0])) * (f64::from(r[1]) - f64::from(p[1]))
            - (f64::from(q[1]) - f64::from(p[1])) * (f64::from(r[0]) - f64::from(p[0]))
    };
    let o1 = orient(a1, a2, b1);
    let o2 = orient(a1, a2, b2);
    let o3 = orient(b1, b2, a1);
    let o4 = orient(b1, b2, a2);

    if (o1 > 0.0 && o2 < 0.0 || o1 < 0.0 && o2 > 0.0)
        && (o3 > 0.0 && o4 < 0.0 || o3 < 0.0 && o4 > 0.0)
    {
        return true;
    }
    const EPS: f64 = 1e-9;
    (o1.abs() <= EPS && point_on_segment(b1[0], b1[1], a1[0], a1[1], a2[0], a2[1]))
        || (o2.abs() <= EPS && point_on_segment(b2[0], b2[1], a1[0], a1[1], a2[0], a2[1]))
        || (o3.abs() <= EPS && point_on_segment(a1[0], a1[1], b1[0], b1[1], b2[0], b2[1]))
        || (o4.abs() <= EPS && point_on_segment(a2[0], a2[1], b1[0], b1[1], b2[0], b2[1]))
}

fn validate_frame_and_bbox(
    frame: &RgbFrame,
    bbox_norm: [f32; 4],
) -> Result<[f32; 4], MediaCoreError> {
    if frame.width() == 0 || frame.height() == 0 {
        return Err(MediaCoreError::invalid_frame(
            "cannot crop from an empty frame",
        ));
    }
    let [x1, y1, x2, y2] = bbox_norm;
    if !x1.is_finite() || !y1.is_finite() || !x2.is_finite() || !y2.is_finite() {
        return Err(MediaCoreError::invalid_frame(format!(
            "crop bbox contains non-finite coordinate: {bbox_norm:?}"
        )));
    }
    let cx1 = x1.clamp(0.0, 1.0);
    let cy1 = y1.clamp(0.0, 1.0);
    let cx2 = x2.clamp(0.0, 1.0);
    let cy2 = y2.clamp(0.0, 1.0);
    if cx2 <= cx1 || cy2 <= cy1 {
        return Err(MediaCoreError::invalid_frame(format!(
            "crop bbox must have positive width and height, got {bbox_norm:?}"
        )));
    }
    Ok([cx1, cy1, cx2, cy2])
}

/// Expands a normalized `[x1, y1, x2, y2]` bounding box by `padding_ratio` on all sides,
/// clamping the result into `[0.0, 1.0]`.
pub fn expand_bbox_padded(
    bbox_norm: [f32; 4],
    padding_ratio: f32,
) -> Result<[f32; 4], MediaCoreError> {
    if !padding_ratio.is_finite() || !(0.0..=2.0).contains(&padding_ratio) {
        return Err(MediaCoreError::invalid_configuration(format!(
            "crop padding_ratio {padding_ratio} must be finite and in 0.0..=2.0"
        )));
    }
    let [x1, y1, x2, y2] = bbox_norm;
    if !x1.is_finite() || !y1.is_finite() || !x2.is_finite() || !y2.is_finite() {
        return Err(MediaCoreError::invalid_frame(format!(
            "crop bbox contains non-finite coordinate: {bbox_norm:?}"
        )));
    }
    let cx1 = x1.clamp(0.0, 1.0);
    let cy1 = y1.clamp(0.0, 1.0);
    let cx2 = x2.clamp(0.0, 1.0);
    let cy2 = y2.clamp(0.0, 1.0);
    if cx2 <= cx1 || cy2 <= cy1 {
        return Err(MediaCoreError::invalid_frame(format!(
            "crop bbox must have positive width and height, got {bbox_norm:?}"
        )));
    }
    let dx = f64::from(cx2 - cx1) * f64::from(padding_ratio);
    let dy = f64::from(cy2 - cy1) * f64::from(padding_ratio);
    Ok([
        ((f64::from(cx1) - dx).clamp(0.0, 1.0)) as f32,
        ((f64::from(cy1) - dy).clamp(0.0, 1.0)) as f32,
        ((f64::from(cx2) + dx).clamp(0.0, 1.0)) as f32,
        ((f64::from(cy2) + dy).clamp(0.0, 1.0)) as f32,
    ])
}

fn measure_unpadded_px(frame: &RgbFrame, clamped_bbox: [f32; 4]) -> (u32, u32) {
    let w_px = ((clamped_bbox[2] - clamped_bbox[0]) * (frame.width() as f32)).round() as u32;
    let h_px = ((clamped_bbox[3] - clamped_bbox[1]) * (frame.height() as f32)).round() as u32;
    (w_px, h_px)
}

/// Extracts a padded full-resolution RGB crop from `frame`, gating on the *unpadded*
/// native bbox dimensions (`min_bbox_width_px`, `min_bbox_height_px`) before padding
/// and bounded downscaling (`<= config.max_dimension`).
pub fn crop_detection_rgb(
    frame: &RgbFrame,
    bbox_norm: [f32; 4],
    config: &CropConfig,
) -> Result<RgbCropOutcome, MediaCoreError> {
    config.validate()?;
    let clamped = validate_frame_and_bbox(frame, bbox_norm)?;
    let (bbox_w_px, bbox_h_px) = measure_unpadded_px(frame, clamped);

    if bbox_w_px < config.min_bbox_width_px || bbox_h_px < config.min_bbox_height_px {
        return Ok(RgbCropOutcome::Skipped {
            reason: CropSkipReason::BelowMinDimension,
            bbox_width_px: bbox_w_px,
            bbox_height_px: bbox_h_px,
            min_bbox_width_px: config.min_bbox_width_px,
        });
    }

    let padded_bbox_norm = expand_bbox_padded(clamped, config.padding_ratio)?;
    let native = frame.crop_normalized(padded_bbox_norm);
    let fitted = downscale_rgb_fit(&native, config.max_dimension, config.max_dimension);

    Ok(RgbCropOutcome::Cropped {
        frame: fitted,
        source_bbox_width_px: bbox_w_px,
        source_bbox_height_px: bbox_h_px,
        padded_bbox_norm,
    })
}

/// Extracts a padded full-resolution crop from `frame`, downscales only if exceeding
/// `config.max_dimension`, and encodes a Baseline Sequential JFIF JPEG (`SOF0`) within
/// `config.max_bytes`.
pub fn crop_detection_jpeg(
    frame: &RgbFrame,
    bbox_norm: [f32; 4],
    config: &CropConfig,
) -> Result<CropOutcome, MediaCoreError> {
    match crop_detection_rgb(frame, bbox_norm, config)? {
        RgbCropOutcome::Skipped {
            reason,
            bbox_width_px,
            bbox_height_px,
            min_bbox_width_px,
        } => Ok(CropOutcome::Skipped {
            reason,
            bbox_width_px,
            bbox_height_px,
            min_bbox_width_px,
        }),
        RgbCropOutcome::Cropped {
            frame: cropped,
            source_bbox_width_px,
            source_bbox_height_px,
            padded_bbox_norm,
        } => {
            let thumb_cfg = config.to_thumbnail_config();
            let encoded = encode_jpeg_thumbnail(&cropped, &thumb_cfg)?;
            Ok(CropOutcome::Encoded(EncodedCrop {
                width: encoded.width,
                height: encoded.height,
                source_bbox_width_px,
                source_bbox_height_px,
                padded_bbox_norm,
                quality: encoded.quality,
                jpeg_bytes: encoded.jpeg_bytes,
                sha256_hex: encoded.sha256_hex,
            }))
        }
    }
}

/// Filters a detection against `rois` (when non-empty, skipping with
/// [`CropSkipReason::OutsideRoi`] if it overlaps none) and extracts a bounded Baseline JFIF crop.
pub fn crop_detection_in_rois_jpeg(
    frame: &RgbFrame,
    bbox_norm: [f32; 4],
    rois: &[RoiPolygon],
    config: &CropConfig,
) -> Result<CropOutcome, MediaCoreError> {
    config.validate()?;
    let clamped = validate_frame_and_bbox(frame, bbox_norm)?;
    for roi in rois {
        roi.validate()?;
    }

    if !rois.is_empty() && !rois.iter().any(|roi| roi.overlaps_bbox(clamped)) {
        let (bbox_width_px, bbox_height_px) = measure_unpadded_px(frame, clamped);
        return Ok(CropOutcome::Skipped {
            reason: CropSkipReason::OutsideRoi,
            bbox_width_px,
            bbox_height_px,
            min_bbox_width_px: config.min_bbox_width_px,
        });
    }

    crop_detection_jpeg(frame, clamped, config)
}

/// Extracts an RGB crop around an [`RoiPolygon`]'s bounding box, optionally masking pixels
/// outside the polygon before bounded downscaling.
pub fn crop_roi_polygon_rgb(
    frame: &RgbFrame,
    polygon: &RoiPolygon,
    config: &CropConfig,
    mask_outside: bool,
) -> Result<RgbCropOutcome, MediaCoreError> {
    config.validate()?;
    if frame.width() == 0 || frame.height() == 0 {
        return Err(MediaCoreError::invalid_frame(
            "cannot crop ROI polygon from an empty frame",
        ));
    }
    let bbox_norm = polygon.bounding_bbox()?;
    let (bbox_w_px, bbox_h_px) = measure_unpadded_px(frame, bbox_norm);
    if bbox_w_px < config.min_bbox_width_px || bbox_h_px < config.min_bbox_height_px {
        return Ok(RgbCropOutcome::Skipped {
            reason: CropSkipReason::BelowMinDimension,
            bbox_width_px: bbox_w_px,
            bbox_height_px: bbox_h_px,
            min_bbox_width_px: config.min_bbox_width_px,
        });
    }

    let padded_bbox_norm = expand_bbox_padded(bbox_norm, config.padding_ratio)?;
    let mut native = frame.crop_normalized(padded_bbox_norm);
    if mask_outside {
        polygon.mask_outside_rgb(&mut native, padded_bbox_norm, [0, 0, 0]);
    }
    let fitted = downscale_rgb_fit(&native, config.max_dimension, config.max_dimension);

    Ok(RgbCropOutcome::Cropped {
        frame: fitted,
        source_bbox_width_px: bbox_w_px,
        source_bbox_height_px: bbox_h_px,
        padded_bbox_norm,
    })
}

/// Extracts and encodes a Baseline Sequential JFIF JPEG around an [`RoiPolygon`],
/// optionally masking pixels outside the polygon before downscaling and encoding.
pub fn crop_roi_polygon_jpeg(
    frame: &RgbFrame,
    polygon: &RoiPolygon,
    config: &CropConfig,
    mask_outside: bool,
) -> Result<CropOutcome, MediaCoreError> {
    match crop_roi_polygon_rgb(frame, polygon, config, mask_outside)? {
        RgbCropOutcome::Skipped {
            reason,
            bbox_width_px,
            bbox_height_px,
            min_bbox_width_px,
        } => Ok(CropOutcome::Skipped {
            reason,
            bbox_width_px,
            bbox_height_px,
            min_bbox_width_px,
        }),
        RgbCropOutcome::Cropped {
            frame: cropped,
            source_bbox_width_px,
            source_bbox_height_px,
            padded_bbox_norm,
        } => {
            let thumb_cfg = config.to_thumbnail_config();
            let encoded = encode_jpeg_thumbnail(&cropped, &thumb_cfg)?;
            Ok(CropOutcome::Encoded(EncodedCrop {
                width: encoded.width,
                height: encoded.height,
                source_bbox_width_px,
                source_bbox_height_px,
                padded_bbox_norm,
                quality: encoded.quality,
                jpeg_bytes: encoded.jpeg_bytes,
                sha256_hex: encoded.sha256_hex,
            }))
        }
    }
}

/// Extracts and encodes a Baseline Sequential JFIF JPEG covering the union of one or more
/// [`RoiPolygon`]s, optionally masking pixels outside every polygon before downscaling.
pub fn crop_roi_polygons_jpeg(
    frame: &RgbFrame,
    polygons: &[RoiPolygon],
    config: &CropConfig,
    mask_outside: bool,
) -> Result<CropOutcome, MediaCoreError> {
    if polygons.is_empty() {
        return Err(MediaCoreError::invalid_configuration(
            "crop_roi_polygons_jpeg requires at least one ROI polygon",
        ));
    }
    if polygons.len() == 1 {
        return crop_roi_polygon_jpeg(frame, &polygons[0], config, mask_outside);
    }

    config.validate()?;
    if frame.width() == 0 || frame.height() == 0 {
        return Err(MediaCoreError::invalid_frame(
            "cannot crop ROI polygons from an empty frame",
        ));
    }

    let mut union_bbox = [1.0f32, 1.0f32, 0.0f32, 0.0f32];
    for poly in polygons {
        let bbox = poly.bounding_bbox()?;
        union_bbox[0] = union_bbox[0].min(bbox[0]);
        union_bbox[1] = union_bbox[1].min(bbox[1]);
        union_bbox[2] = union_bbox[2].max(bbox[2]);
        union_bbox[3] = union_bbox[3].max(bbox[3]);
    }

    let (bbox_w_px, bbox_h_px) = measure_unpadded_px(frame, union_bbox);
    if bbox_w_px < config.min_bbox_width_px || bbox_h_px < config.min_bbox_height_px {
        return Ok(CropOutcome::Skipped {
            reason: CropSkipReason::BelowMinDimension,
            bbox_width_px: bbox_w_px,
            bbox_height_px: bbox_h_px,
            min_bbox_width_px: config.min_bbox_width_px,
        });
    }

    let padded_bbox_norm = expand_bbox_padded(union_bbox, config.padding_ratio)?;
    let mut native = frame.crop_normalized(padded_bbox_norm);
    if mask_outside {
        let w = native.width();
        let h = native.height();
        if w > 0 && h > 0 {
            let span_x = (padded_bbox_norm[2] - padded_bbox_norm[0]).max(0.0);
            let span_y = (padded_bbox_norm[3] - padded_bbox_norm[1]).max(0.0);
            for py in 0..h {
                let ny = padded_bbox_norm[1] + ((py as f32) + 0.5) / (h as f32) * span_y;
                for px in 0..w {
                    let nx = padded_bbox_norm[0] + ((px as f32) + 0.5) / (w as f32) * span_x;
                    if !polygons.iter().any(|p| p.contains_point(nx, ny)) {
                        native.set_pixel(px, py, [0, 0, 0]);
                    }
                }
            }
        }
    }
    let fitted = downscale_rgb_fit(&native, config.max_dimension, config.max_dimension);
    let thumb_cfg = config.to_thumbnail_config();
    let encoded = encode_jpeg_thumbnail(&fitted, &thumb_cfg)?;
    Ok(CropOutcome::Encoded(EncodedCrop {
        width: encoded.width,
        height: encoded.height,
        source_bbox_width_px: bbox_w_px,
        source_bbox_height_px: bbox_h_px,
        padded_bbox_norm,
        quality: encoded.quality,
        jpeg_bytes: encoded.jpeg_bytes,
        sha256_hex: encoded.sha256_hex,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use sha2::{Digest, Sha256};

    #[derive(Debug, Clone, PartialEq, Eq)]
    struct ParsedJfifInfo {
        has_app0_jfif: bool,
        has_sof0: bool,
        has_progressive_sof2: bool,
        has_dqt: bool,
        has_dht: bool,
        has_sos: bool,
        width: u16,
        height: u16,
    }

    fn parse_jfif_markers(jpeg: &[u8]) -> Result<ParsedJfifInfo, String> {
        if jpeg.len() < 4 || jpeg[0] != 0xFF || jpeg[1] != 0xD8 {
            return Err("missing JPEG SOI".to_string());
        }
        if jpeg[jpeg.len() - 2] != 0xFF || jpeg[jpeg.len() - 1] != 0xD9 {
            return Err("missing JPEG EOI".to_string());
        }

        let mut info = ParsedJfifInfo {
            has_app0_jfif: false,
            has_sof0: false,
            has_progressive_sof2: false,
            has_dqt: false,
            has_dht: false,
            has_sos: false,
            width: 0,
            height: 0,
        };

        let mut i = 2usize;
        while i + 3 < jpeg.len() {
            if jpeg[i] != 0xFF {
                return Err(format!("expected marker prefix 0xFF at offset {i}"));
            }
            let marker = jpeg[i + 1];
            if marker == 0xD9 {
                break;
            }
            let seg_len = u16::from_be_bytes([jpeg[i + 2], jpeg[i + 3]]) as usize;
            if seg_len < 2 || i + 2 + seg_len > jpeg.len() {
                return Err(format!(
                    "invalid segment length {seg_len} for marker 0x{marker:02X}"
                ));
            }
            let body = &jpeg[i + 4..i + 2 + seg_len];
            match marker {
                0xE0 => {
                    if body.starts_with(b"JFIF\0") {
                        info.has_app0_jfif = true;
                    }
                }
                0xDB => info.has_dqt = true,
                0xC4 => info.has_dht = true,
                0xC0 => {
                    if body.len() < 5 {
                        return Err("truncated SOF0".to_string());
                    }
                    info.has_sof0 = true;
                    info.height = u16::from_be_bytes([body[1], body[2]]);
                    info.width = u16::from_be_bytes([body[3], body[4]]);
                }
                0xC2 => {
                    info.has_progressive_sof2 = true;
                }
                0xDA => {
                    info.has_sos = true;
                    break;
                }
                _ => {}
            }
            i += 2 + seg_len;
        }
        Ok(info)
    }

    fn synthetic_1080p_alpr_frame() -> RgbFrame {
        let mut frame = RgbFrame::solid(1920, 1080, [30, 35, 45]);
        // Vehicle body in [0.30, 0.45, 0.55, 0.80] -> (576..1056, 486..864)
        frame.fill_rect(576, 486, 1056, 864, [210, 215, 225]);
        // Synthetic high-contrast plate bar inside vehicle
        frame.fill_rect(730, 690, 900, 750, [245, 245, 245]);
        for stripe in (742..890).step_by(18) {
            frame.fill_rect(stripe, 702, stripe + 8, 738, [20, 20, 25]);
        }
        frame
    }

    #[test]
    fn native_1080p_detection_crop_slices_full_res_and_encodes_baseline_jfif_within_96kib() {
        let frame = synthetic_1080p_alpr_frame();
        let cfg = CropConfig {
            padding_ratio: 0.15,
            min_bbox_width_px: 96,
            min_bbox_height_px: 1,
            max_dimension: 640,
            quality: 85,
            min_quality: 35,
            max_bytes: 96 * 1024,
        };

        let outcome = crop_detection_jpeg(&frame, [0.30, 0.45, 0.55, 0.80], &cfg)
            .expect("1080p detection crop should succeed");
        let encoded = outcome
            .encoded()
            .expect("crop should be encoded, not skipped");

        // Unpadded bbox: (0.55 - 0.30) * 1920 = 480 px, (0.80 - 0.45) * 1080 = 378 px.
        assert_eq!(encoded.source_bbox_width_px, 480);
        assert_eq!(encoded.source_bbox_height_px, 378);
        // Padded bbox: ~624x492 native pixels (<= 640px, no downscale).
        assert!((624..=625).contains(&encoded.width));
        assert!((492..=493).contains(&encoded.height));
        assert!(encoded.jpeg_bytes.len() <= 96 * 1024);

        let expected_sha = hex::encode(Sha256::digest(&encoded.jpeg_bytes));
        assert_eq!(encoded.sha256_hex, expected_sha);

        let jfif = parse_jfif_markers(&encoded.jpeg_bytes).expect("valid JFIF markers");
        assert!(jfif.has_app0_jfif);
        assert!(jfif.has_sof0, "must emit Baseline Sequential SOF0");
        assert!(!jfif.has_progressive_sof2, "must not emit progressive SOF2");
        assert!(jfif.has_dqt && jfif.has_dht && jfif.has_sos);
        assert_eq!(u32::from(jfif.width), encoded.width);
        assert_eq!(u32::from(jfif.height), encoded.height);
    }

    #[test]
    fn oversized_crop_downscales_to_640px_and_preview_config_caps_at_32kib() {
        let mut frame = RgbFrame::solid(1920, 1080, [40, 45, 50]);
        // High-frequency synthetic checkerboard inside a large bbox [0.10, 0.10, 0.70, 0.90].
        for y in 108..972u32 {
            for x in 192..1344u32 {
                let c = if ((x / 4) + (y / 4)) % 2 == 0 {
                    240
                } else {
                    15
                };
                frame.set_pixel(x, y, [c, c.wrapping_sub(30), 255 - c]);
            }
        }

        let inf_cfg = CropConfig::default();
        let inf = crop_detection_jpeg(&frame, [0.10, 0.10, 0.70, 0.90], &inf_cfg)
            .expect("oversized crop should succeed")
            .into_encoded()
            .expect("should encode");
        assert!(inf.width.max(inf.height) <= 640);
        assert!(inf.jpeg_bytes.len() <= 96 * 1024);

        let preview_cfg = CropConfig::for_stored_preview();
        let preview = crop_detection_jpeg(&frame, [0.10, 0.10, 0.70, 0.90], &preview_cfg)
            .expect("preview crop should succeed")
            .into_encoded()
            .expect("should encode preview");
        assert!(preview.width.max(preview.height) <= 640);
        assert!(
            preview.jpeg_bytes.len() <= STORED_PREVIEW_MAX_BYTES,
            "preview length {} exceeded 32 KiB",
            preview.jpeg_bytes.len()
        );
        let jfif = parse_jfif_markers(&preview.jpeg_bytes).expect("valid preview JFIF");
        assert!(jfif.has_sof0);
    }

    #[test]
    fn rejects_undersized_unpadded_bbox_even_when_padding_would_exceed_min_width() {
        let frame = synthetic_1080p_alpr_frame();
        let cfg = CropConfig {
            padding_ratio: 0.15,
            min_bbox_width_px: 96,
            ..CropConfig::default()
        };
        // 0.045 * 1920 = 86.4 -> 86 px unpadded (< 96), whereas padded width is ~112 px (> 96).
        let outcome = crop_detection_jpeg(&frame, [0.48, 0.50, 0.525, 0.58], &cfg)
            .expect("below-min skip is a clean policy outcome, not Err");

        assert_eq!(
            outcome,
            CropOutcome::Skipped {
                reason: CropSkipReason::BelowMinDimension,
                bbox_width_px: 86,
                bbox_height_px: 86,
                min_bbox_width_px: 96,
            }
        );
        assert_eq!(
            outcome.skip_reason().map(CropSkipReason::as_str),
            Some("crop_below_min_dimension")
        );
    }

    #[test]
    fn border_clamping_and_invalid_inputs_behave_deterministically() {
        let padded = expand_bbox_padded([0.0, 0.0, 0.15, 0.20], 0.15).expect("valid border bbox");
        assert!((padded[0] - 0.0).abs() < 1e-6);
        assert!((padded[1] - 0.0).abs() < 1e-6);
        assert!((padded[2] - 0.1725).abs() < 1e-5);
        assert!((padded[3] - 0.23).abs() < 1e-5);

        let frame = RgbFrame::solid(640, 480, [10, 20, 30]);
        let bad_dim_cfg = CropConfig {
            max_dimension: 641,
            ..CropConfig::default()
        };
        assert_eq!(
            crop_detection_jpeg(&frame, [0.1, 0.1, 0.5, 0.5], &bad_dim_cfg)
                .unwrap_err()
                .kind(),
            &crate::error::MediaCoreErrorKind::InvalidConfiguration(
                "crop max_dimension 641 must be in 1..=640".to_string()
            )
        );

        let bad_bytes_cfg = CropConfig {
            max_bytes: HARD_MAX_CROP_BYTES + 1,
            ..CropConfig::default()
        };
        assert!(matches!(
            crop_detection_jpeg(&frame, [0.1, 0.1, 0.5, 0.5], &bad_bytes_cfg)
                .unwrap_err()
                .kind(),
            crate::error::MediaCoreErrorKind::InvalidConfiguration(_)
        ));

        let bad_pad_cfg = CropConfig {
            padding_ratio: -0.1,
            ..CropConfig::default()
        };
        assert!(matches!(
            crop_detection_jpeg(&frame, [0.1, 0.1, 0.5, 0.5], &bad_pad_cfg)
                .unwrap_err()
                .kind(),
            crate::error::MediaCoreErrorKind::InvalidConfiguration(_)
        ));

        assert!(matches!(
            crop_detection_jpeg(&frame, [0.5, 0.1, 0.2, 0.5], &CropConfig::default())
                .unwrap_err()
                .kind(),
            crate::error::MediaCoreErrorKind::InvalidFrame(_)
        ));
        assert!(matches!(
            crop_detection_jpeg(&frame, [f32::NAN, 0.1, 0.5, 0.5], &CropConfig::default())
                .unwrap_err()
                .kind(),
            crate::error::MediaCoreErrorKind::InvalidFrame(_)
        ));
    }

    #[test]
    fn roi_polygon_filtering_and_masking_enforce_gate_boundaries() {
        let mut frame = RgbFrame::solid(1000, 1000, [200, 50, 50]);
        frame.fill_rect(350, 400, 650, 750, [30, 210, 90]);

        let gate_roi =
            RoiPolygon::new(vec![[0.20, 0.30], [0.80, 0.30], [0.90, 0.90], [0.10, 0.90]]);
        let cfg = CropConfig {
            padding_ratio: 0.0,
            min_bbox_width_px: 96,
            ..CropConfig::default()
        };

        // Detection inside gate trapezoid encodes cleanly.
        let inside = crop_detection_in_rois_jpeg(
            &frame,
            [0.35, 0.40, 0.65, 0.75],
            std::slice::from_ref(&gate_roi),
            &cfg,
        )
        .expect("inside ROI should succeed");
        assert!(inside.encoded().is_some());

        // Detection outside trapezoid skips with `crop_outside_roi`.
        let outside = crop_detection_in_rois_jpeg(
            &frame,
            [0.01, 0.01, 0.15, 0.20],
            std::slice::from_ref(&gate_roi),
            &cfg,
        )
        .expect("outside ROI should skip cleanly");
        assert_eq!(outside.skip_reason(), Some(CropSkipReason::OutsideRoi));
        assert_eq!(
            outside.skip_reason().map(CropSkipReason::as_str),
            Some("crop_outside_roi")
        );

        // Masked polygon crop zeroes top-left / top-right corners outside the trapezoid.
        let rgb_outcome = crop_roi_polygon_rgb(&frame, &gate_roi, &cfg, true)
            .expect("ROI polygon RGB crop should succeed");
        let RgbCropOutcome::Cropped { frame: masked, .. } = rgb_outcome else {
            panic!("expected cropped ROI polygon frame");
        };
        assert_eq!(masked.pixel_at(0, 0), [0, 0, 0]);
        assert_eq!(masked.pixel_at(masked.width() - 1, 0), [0, 0, 0]);
        // Center pixel lies inside green inner rectangle.
        let center = masked.pixel_at(masked.width() / 2, masked.height() / 2);
        assert!(
            center[1] > 150,
            "expected green interior pixel, got {center:?}"
        );

        let jpeg_outcome = crop_roi_polygon_jpeg(&frame, &gate_roi, &cfg, true)
            .expect("ROI polygon JPEG crop should succeed");
        let encoded = jpeg_outcome.encoded().expect("encoded ROI JPEG");
        assert!(encoded.jpeg_bytes.len() <= 96 * 1024);
        assert!(
            parse_jfif_markers(&encoded.jpeg_bytes)
                .expect("valid JFIF")
                .has_sof0
        );
    }

    #[test]
    fn roi_polygon_deserializes_sequence_and_elixir_map_formats_and_round_trips() {
        let expected = RoiPolygon::new(vec![[0.2, 0.4], [0.7, 0.4], [0.7, 0.9], [0.2, 0.9]]);

        let seq_poly: RoiPolygon = serde_json::from_value(serde_json::json!([
            [0.2, 0.4],
            [0.7, 0.4],
            [0.7, 0.9],
            [0.2, 0.9]
        ]))
        .expect("sequence format should deserialize");
        assert_eq!(seq_poly, expected);

        let points_pair_poly: RoiPolygon = serde_json::from_value(serde_json::json!({
            "points": [[0.2, 0.4], [0.7, 0.4], [0.7, 0.9], [0.2, 0.9]]
        }))
        .expect("M1 map-of-points-pairs format should deserialize");
        assert_eq!(points_pair_poly, expected);

        let points_obj_poly: RoiPolygon = serde_json::from_value(serde_json::json!({
            "points": [
                {"x": 0.2, "y": 0.4},
                {"x": 0.7, "y": 0.4},
                {"x": 0.7, "y": 0.9},
                {"x": 0.2, "y": 0.9}
            ]
        }))
        .expect("M1 map-of-xy-objects format should deserialize");
        assert_eq!(points_obj_poly, expected);

        let serialized = serde_json::to_value(&expected).expect("serialize RoiPolygon");
        let round_trip: RoiPolygon =
            serde_json::from_value(serialized).expect("round-trip deserialize");
        assert_eq!(round_trip, expected);
    }

    #[test]
    fn thin_aspect_ratio_noisy_crop_fits_tight_max_bytes() {
        let mut seed: u32 = 0xCAFE_BABE;
        let mut pixels = Vec::with_capacity(640 * 30 * 3);
        for _ in 0..(640 * 30) {
            seed = seed.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            pixels.push(((seed >> 24) & 0xFF) as u8);
            pixels.push(((seed >> 16) & 0xFF) as u8);
            pixels.push(((seed >> 8) & 0xFF) as u8);
        }
        let strip = RgbFrame::from_rgb8(640, 30, pixels).unwrap();
        let cfg = CropConfig {
            padding_ratio: 0.0,
            min_bbox_width_px: 10,
            max_bytes: 4096,
            ..CropConfig::for_stored_preview()
        };
        let encoded = crop_detection_jpeg(&strip, [0.0, 0.0, 1.0, 1.0], &cfg)
            .expect("thin noisy crop should downscale and fit")
            .into_encoded()
            .expect("encoded thin crop");
        assert!(encoded.jpeg_bytes.len() <= 4096);
        assert!(encoded.width < 640);
        let jfif = parse_jfif_markers(&encoded.jpeg_bytes).expect("valid JFIF");
        assert!(jfif.has_sof0);
    }
}
