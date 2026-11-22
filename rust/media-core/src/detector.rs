//! Apache-2.0 YOLOX object detector interface, anchor-free grid decoder, letterbox
//! geometry, class-aware NMS, and deterministic synthetic detector for unit testing.

use crate::error::MediaCoreError;
use crate::frame::RgbFrame;
use serde::{Deserialize, Serialize};

/// Canonical surveillance object categories (UniFi-friendly + COCO mapped).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ObjectCategory {
    Person,
    Vehicle,
    Bicycle,
    Animal,
    Package,
    Motion,
}

impl ObjectCategory {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Person => "person",
            Self::Vehicle => "vehicle",
            Self::Bicycle => "bicycle",
            Self::Animal => "animal",
            Self::Package => "package",
            Self::Motion => "motion",
        }
    }

    pub fn class_id(self) -> u32 {
        match self {
            Self::Person => 0,
            Self::Vehicle => 1,
            Self::Bicycle => 2,
            Self::Animal => 3,
            Self::Package => 4,
            Self::Motion => 5,
        }
    }
}

impl core::fmt::Display for ObjectCategory {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Maps a standard 80-class COCO index to a canonical [`ObjectCategory`].
pub fn coco_class_to_category(class_id: usize) -> Option<ObjectCategory> {
    match class_id {
        0 => Some(ObjectCategory::Person),              // person
        1 => Some(ObjectCategory::Bicycle),             // bicycle
        2 | 3 | 5 | 7 => Some(ObjectCategory::Vehicle), // car, motorcycle, bus, truck
        14 | 15 | 16 | 17 | 18 | 19 | 21 => Some(ObjectCategory::Animal), // bird..bear
        24 | 26 | 28 => Some(ObjectCategory::Package),  // backpack, handbag, suitcase
        _ => None,
    }
}

/// Maps a COCO class name to a canonical [`ObjectCategory`].
pub fn coco_name_to_category(name: &str) -> Option<ObjectCategory> {
    match name.trim().to_ascii_lowercase().as_str() {
        "person" => Some(ObjectCategory::Person),
        "car" | "truck" | "bus" | "motorcycle" | "vehicle" => Some(ObjectCategory::Vehicle),
        "bicycle" | "bike" => Some(ObjectCategory::Bicycle),
        "dog" | "cat" | "bird" | "horse" | "sheep" | "cow" | "bear" | "animal" => {
            Some(ObjectCategory::Animal)
        }
        "backpack" | "suitcase" | "handbag" | "package" | "parcel" => Some(ObjectCategory::Package),
        "motion" => Some(ObjectCategory::Motion),
        _ => None,
    }
}

/// Canonical object detection emitted by any [`ObjectDetector`].
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Detection {
    /// Raw or canonical class identifier (e.g. COCO class id or `ObjectCategory::class_id()`).
    pub class_id: u32,
    /// Canonical surveillance category label.
    pub label: ObjectCategory,
    /// Detection confidence in `[0.0, 1.0]`.
    pub confidence: f32,
    /// Normalized `[x1, y1, x2, y2]` bounding box in `[0.0, 1.0]`.
    pub bbox: [f32; 4],
}

impl Detection {
    pub fn new(class_id: u32, label: ObjectCategory, confidence: f32, bbox: [f32; 4]) -> Self {
        Self {
            class_id,
            label,
            confidence: confidence.clamp(0.0, 1.0),
            bbox: clamp_unit_bbox(bbox),
        }
    }

    pub fn area(&self) -> f32 {
        (self.bbox[2] - self.bbox[0]).max(0.0) * (self.bbox[3] - self.bbox[1]).max(0.0)
    }
}

/// Pluggable object detector contract (implemented by Candle/ONNX YOLOX or synthetic backends).
pub trait ObjectDetector: Send + Sync {
    /// Stable model identifier (e.g. `"yolox-s"` or `"synthetic-blob-v1"`).
    fn model_id(&self) -> &str;

    /// Detects objects in `frame` with confidence `>= min_confidence`.
    fn detect(
        &self,
        frame: &RgbFrame,
        min_confidence: f32,
    ) -> Result<Vec<Detection>, MediaCoreError>;
}

/// Configuration for Apache-2.0 YOLOX anchor-free post-processing.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct YoloxConfig {
    /// Square model input width/height (e.g. `640` for YOLOX-s/m/l, `416` for YOLOX-tiny/nano).
    pub input_width: u32,
    pub input_height: u32,
    /// FPN feature strides (standard YOLOX uses `[8, 16, 32]`).
    pub strides: Vec<u32>,
    /// Number of object classes per grid cell (standard COCO = `80`).
    pub num_classes: usize,
    /// Class-aware NMS IoU threshold (default `0.45`).
    pub nms_iou_threshold: f32,
    /// Maximum detections kept after NMS (default `32`).
    pub max_detections: usize,
    /// Whether `obj_conf` and class scores in the raw tensor are raw logits requiring sigmoid
    /// (`true` for raw Candle/PyTorch head outputs; `false` for ONNX exports with baked sigmoid).
    pub apply_sigmoid: bool,
}

impl Default for YoloxConfig {
    fn default() -> Self {
        Self::yolox_s()
    }
}

impl YoloxConfig {
    /// Standard Apache-2.0 YOLOX-s (`640x640`, strides `[8, 16, 32]`, 80 COCO classes).
    pub fn yolox_s() -> Self {
        Self {
            input_width: 640,
            input_height: 640,
            strides: vec![8, 16, 32],
            num_classes: 80,
            nms_iou_threshold: 0.45,
            max_detections: 32,
            apply_sigmoid: false,
        }
    }

    /// Total number of anchor-free grid cells across all configured FPN strides.
    pub fn total_grid_cells(&self) -> Result<usize, MediaCoreError> {
        if self.input_width == 0 || self.input_height == 0 || self.strides.is_empty() {
            return Err(MediaCoreError::invalid_configuration(
                "YOLOX input dimensions and strides must be non-empty",
            ));
        }
        let mut total = 0usize;
        for &stride in &self.strides {
            if stride == 0
                || !self.input_width.is_multiple_of(stride)
                || !self.input_height.is_multiple_of(stride)
            {
                return Err(MediaCoreError::invalid_configuration(format!(
                    "YOLOX input {}x{} is not divisible by stride {stride}",
                    self.input_width, self.input_height
                )));
            }
            let gw = (self.input_width / stride) as usize;
            let gh = (self.input_height / stride) as usize;
            total = total.saturating_add(gw.saturating_mul(gh));
        }
        Ok(total)
    }
}

/// Aspect-preserving letterbox resize transform used by YOLOX preprocessing and box unscaling.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LetterboxTransform {
    pub src_width: u32,
    pub src_height: u32,
    pub dst_width: u32,
    pub dst_height: u32,
    pub scale: f32,
    pub pad_x: f32,
    pub pad_y: f32,
}

impl LetterboxTransform {
    /// Computes top-left (or centered) letterbox scaling parameters from `src` to `dst`.
    ///
    /// Uses centered padding (`pad_x`, `pad_y`) matching standard YOLOX/ONNX preprocessing.
    pub fn compute(
        src_width: u32,
        src_height: u32,
        dst_width: u32,
        dst_height: u32,
    ) -> Result<Self, MediaCoreError> {
        if src_width == 0 || src_height == 0 || dst_width == 0 || dst_height == 0 {
            return Err(MediaCoreError::invalid_frame(
                "letterbox dimensions must be non-zero",
            ));
        }
        let scale_x = (dst_width as f32) / (src_width as f32);
        let scale_y = (dst_height as f32) / (src_height as f32);
        let scale = scale_x.min(scale_y);
        let scaled_w = (src_width as f32) * scale;
        let scaled_h = (src_height as f32) * scale;
        let pad_x = ((dst_width as f32) - scaled_w) * 0.5;
        let pad_y = ((dst_height as f32) - scaled_h) * 0.5;
        Ok(Self {
            src_width,
            src_height,
            dst_width,
            dst_height,
            scale,
            pad_x,
            pad_y,
        })
    }

    /// Maps a `[x1, y1, x2, y2]` box in letterboxed model-input pixels back to normalized
    /// `[0.0, 1.0]` coordinates in the original source frame.
    pub fn unscale_xyxy_to_norm(&self, box_px: [f32; 4]) -> [f32; 4] {
        let inv_scale = 1.0 / self.scale.max(1e-6);
        let x1 = ((box_px[0] - self.pad_x) * inv_scale) / (self.src_width as f32);
        let y1 = ((box_px[1] - self.pad_y) * inv_scale) / (self.src_height as f32);
        let x2 = ((box_px[2] - self.pad_x) * inv_scale) / (self.src_width as f32);
        let y2 = ((box_px[3] - self.pad_y) * inv_scale) / (self.src_height as f32);
        clamp_unit_bbox([x1, y1, x2, y2])
    }
}

/// Pure-Rust YOLOX anchor-free grid decoder + letterbox unscaler + class-aware NMS.
#[derive(Debug, Clone)]
pub struct YoloxPostProcessor {
    config: YoloxConfig,
    /// Precomputed `(grid_x, grid_y, stride)` table parallel to flat head predictions.
    grids: Vec<(f32, f32, f32)>,
}

impl YoloxPostProcessor {
    pub fn new(config: YoloxConfig) -> Result<Self, MediaCoreError> {
        let total = config.total_grid_cells()?;
        let mut grids = Vec::with_capacity(total);
        for &stride in &config.strides {
            let gw = config.input_width / stride;
            let gh = config.input_height / stride;
            let s = stride as f32;
            for gy in 0..gh {
                for gx in 0..gw {
                    grids.push((gx as f32, gy as f32, s));
                }
            }
        }
        Ok(Self { config, grids })
    }

    pub fn config(&self) -> &YoloxConfig {
        &self.config
    }

    pub fn grid_len(&self) -> usize {
        self.grids.len()
    }

    /// Decodes a flat row-major YOLOX output tensor of shape `[num_cells, 5 + num_classes]`
    /// into normalized, class-aware-NMS-filtered [`Detection`]s.
    ///
    /// Each row contains `[reg_x, reg_y, reg_w, reg_h, obj_conf, cls_0, ..., cls_{C-1}]`.
    pub fn decode(
        &self,
        raw_output: &[f32],
        letterbox: LetterboxTransform,
        min_confidence: f32,
    ) -> Result<Vec<Detection>, MediaCoreError> {
        let row_stride = 5 + self.config.num_classes;
        let expected_len = self.grids.len().saturating_mul(row_stride);
        if raw_output.len() != expected_len {
            return Err(MediaCoreError::detector(format!(
                "YOLOX raw output length {} != expected {} ({} cells x {} cols)",
                raw_output.len(),
                expected_len,
                self.grids.len(),
                row_stride
            )));
        }

        let mut candidates = Vec::new();
        for (cell_idx, &(gx, gy, stride)) in self.grids.iter().enumerate() {
            let row = &raw_output[cell_idx * row_stride..(cell_idx + 1) * row_stride];
            let obj_conf = if self.config.apply_sigmoid {
                sigmoid(row[4])
            } else {
                row[4]
            };
            if obj_conf < min_confidence {
                continue;
            }

            let mut best_cls = 0usize;
            let mut best_cls_score = f32::NEG_INFINITY;
            for (cls_idx, &raw_cls) in row[5..].iter().enumerate() {
                if raw_cls > best_cls_score {
                    best_cls_score = raw_cls;
                    best_cls = cls_idx;
                }
            }
            let cls_prob = if self.config.apply_sigmoid {
                sigmoid(best_cls_score)
            } else {
                best_cls_score
            };
            let confidence = obj_conf * cls_prob;
            if confidence < min_confidence || !confidence.is_finite() {
                continue;
            }

            let Some(label) = coco_class_to_category(best_cls) else {
                continue;
            };

            let cx = (row[0] + gx) * stride;
            let cy = (row[1] + gy) * stride;
            let w = row[2].clamp(-10.0, 10.0).exp() * stride;
            let h = row[3].clamp(-10.0, 10.0).exp() * stride;
            let x1 = cx - w * 0.5;
            let y1 = cy - h * 0.5;
            let x2 = cx + w * 0.5;
            let y2 = cy + h * 0.5;

            let bbox = letterbox.unscale_xyxy_to_norm([x1, y1, x2, y2]);
            candidates.push(Detection::new(best_cls as u32, label, confidence, bbox));
        }

        Ok(apply_class_aware_nms(
            candidates,
            self.config.nms_iou_threshold,
            self.config.max_detections,
        ))
    }
}

/// Applies class-aware Non-Maximum Suppression sorted by descending confidence.
pub fn apply_class_aware_nms(
    mut candidates: Vec<Detection>,
    iou_threshold: f32,
    max_keep: usize,
) -> Vec<Detection> {
    candidates.sort_by(|a, b| b.confidence.total_cmp(&a.confidence));
    let mut kept: Vec<Detection> = Vec::with_capacity(candidates.len().min(max_keep));

    for det in candidates {
        if kept.len() >= max_keep {
            break;
        }
        let suppressed = kept.iter().any(|existing| {
            existing.label == det.label && bbox_iou(existing.bbox, det.bbox) > iou_threshold
        });
        if !suppressed {
            kept.push(det);
        }
    }
    kept
}

/// Computes Intersection-over-Union (IoU) between two `[x1, y1, x2, y2]` boxes.
pub fn bbox_iou(a: [f32; 4], b: [f32; 4]) -> f32 {
    let ix1 = a[0].max(b[0]);
    let iy1 = a[1].max(b[1]);
    let ix2 = a[2].min(b[2]);
    let iy2 = a[3].min(b[3]);
    let inter = (ix2 - ix1).max(0.0) * (iy2 - iy1).max(0.0);
    if inter <= 0.0 {
        return 0.0;
    }
    let area_a = (a[2] - a[0]).max(0.0) * (a[3] - a[1]).max(0.0);
    let area_b = (b[2] - b[0]).max(0.0) * (b[3] - b[1]).max(0.0);
    inter / (area_a + area_b - inter).max(1e-6)
}

/// Clamps a `[x1, y1, x2, y2]` box into `[0.0, 1.0]` with non-zero width and height.
pub fn clamp_unit_bbox([x1, y1, x2, y2]: [f32; 4]) -> [f32; 4] {
    let cx1 = x1.clamp(0.0, 0.999);
    let cy1 = y1.clamp(0.0, 0.999);
    let cx2 = x2.clamp(cx1 + 0.001, 1.0);
    let cy2 = y2.clamp(cy1 + 0.001, 1.0);
    [cx1, cy1, cx2, cy2]
}

#[inline]
fn sigmoid(x: f32) -> f32 {
    1.0 / (1.0 + (-x).exp())
}

/// Deterministic foreground-blob detector for pure-Rust unit tests and stub execution.
#[derive(Debug, Clone)]
pub struct SyntheticDetector {
    model_id: String,
    nms_iou_threshold: f32,
    max_detections: usize,
}

impl Default for SyntheticDetector {
    fn default() -> Self {
        Self {
            model_id: "synthetic-yolox-stub-v1".to_string(),
            nms_iou_threshold: 0.50,
            max_detections: 16,
        }
    }
}

impl SyntheticDetector {
    pub fn new(model_id: impl Into<String>) -> Self {
        Self {
            model_id: model_id.into(),
            ..Self::default()
        }
    }
}

impl ObjectDetector for SyntheticDetector {
    fn model_id(&self) -> &str {
        &self.model_id
    }

    fn detect(
        &self,
        frame: &RgbFrame,
        min_confidence: f32,
    ) -> Result<Vec<Detection>, MediaCoreError> {
        let bg = estimate_border_bg(frame);
        let min_box_px = if frame.width() >= 160 && frame.height() >= 120 {
            16u32
        } else {
            6u32
        };

        let w = frame.width() as usize;
        let h = frame.height() as usize;
        let mut visited = vec![false; w * h];
        let mut stack = Vec::new();
        let mut out = Vec::new();

        for y in 0..h {
            for x in 0..w {
                let start = y * w + x;
                if visited[start] || !is_fg(frame.pixel_at(x as u32, y as u32), bg) {
                    continue;
                }
                visited[start] = true;
                stack.push((x, y));
                let mut min_x = x as u32;
                let mut min_y = y as u32;
                let mut max_x = x as u32;
                let mut max_y = y as u32;

                while let Some((cx, cy)) = stack.pop() {
                    min_x = min_x.min(cx as u32);
                    min_y = min_y.min(cy as u32);
                    max_x = max_x.max(cx as u32);
                    max_y = max_y.max(cy as u32);

                    let ny0 = cy.saturating_sub(2);
                    let ny1 = (cy + 2).min(h - 1);
                    let nx0 = cx.saturating_sub(2);
                    let nx1 = (cx + 2).min(w - 1);
                    for ny in ny0..=ny1 {
                        for nx in nx0..=nx1 {
                            let nidx = ny * w + nx;
                            if !visited[nidx] && is_fg(frame.pixel_at(nx as u32, ny as u32), bg) {
                                visited[nidx] = true;
                                stack.push((nx, ny));
                            }
                        }
                    }
                }

                let bw = max_x - min_x + 1;
                let bh = max_y - min_y + 1;
                if bw < min_box_px || bh < min_box_px {
                    continue;
                }
                let aspect = (bw as f32) / (bh as f32);
                let (label, confidence) = if aspect < 0.80 {
                    (ObjectCategory::Person, 0.92)
                } else if aspect >= 1.30 {
                    (ObjectCategory::Vehicle, 0.90)
                } else {
                    (ObjectCategory::Package, 0.86)
                };
                if confidence < min_confidence {
                    continue;
                }
                let bbox = clamp_unit_bbox([
                    (min_x as f32) / (frame.width() as f32),
                    (min_y as f32) / (frame.height() as f32),
                    ((max_x + 1) as f32) / (frame.width() as f32),
                    ((max_y + 1) as f32) / (frame.height() as f32),
                ]);
                out.push(Detection::new(label.class_id(), label, confidence, bbox));
            }
        }

        Ok(apply_class_aware_nms(
            out,
            self.nms_iou_threshold,
            self.max_detections,
        ))
    }
}

fn estimate_border_bg(frame: &RgbFrame) -> [u8; 3] {
    let mut rs = Vec::new();
    let mut gs = Vec::new();
    let mut bs = Vec::new();
    let step_x = (frame.width() / 16).max(1);
    let step_y = (frame.height() / 16).max(1);
    for x in (0..frame.width()).step_by(step_x as usize) {
        for y in [0, frame.height() - 1] {
            let p = frame.pixel_at(x, y);
            rs.push(p[0]);
            gs.push(p[1]);
            bs.push(p[2]);
        }
    }
    for y in (0..frame.height()).step_by(step_y as usize) {
        for x in [0, frame.width() - 1] {
            let p = frame.pixel_at(x, y);
            rs.push(p[0]);
            gs.push(p[1]);
            bs.push(p[2]);
        }
    }
    rs.sort_unstable();
    gs.sort_unstable();
    bs.sort_unstable();
    let mid = rs.len() / 2;
    [rs[mid], gs[mid], bs[mid]]
}

fn is_fg(rgb: [u8; 3], bg: [u8; 3]) -> bool {
    let dist = (i16::from(rgb[0]) - i16::from(bg[0])).unsigned_abs()
        + (i16::from(rgb[1]) - i16::from(bg[1])).unsigned_abs()
        + (i16::from(rgb[2]) - i16::from(bg[2])).unsigned_abs();
    dist >= 48
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn yolox_grid_decode_unscales_letterbox_and_applies_class_aware_nms() {
        let cfg = YoloxConfig {
            input_width: 64,
            input_height: 64,
            strides: vec![8, 16],
            num_classes: 80,
            nms_iou_threshold: 0.45,
            max_detections: 16,
            apply_sigmoid: false,
        };
        let post = YoloxPostProcessor::new(cfg).expect("valid yolox cfg");
        // Stride 8 -> 8x8=64 cells; Stride 16 -> 4x4=16 cells => 80 cells total.
        assert_eq!(post.grid_len(), 80);

        let cols = 5 + 80;
        let mut raw = vec![0.0f32; post.grid_len() * cols];

        // Cell (gx=4, gy=4) at stride 8 => index 4*8 + 4 = 36.
        // cx = (0.0 + 4.0) * 8 = 32, cy = (0.0 + 4.0) * 8 = 32
        // w = exp(ln(2.0)) * 8 = 16, h = exp(ln(4.0)) * 8 = 32
        // box in 64x64: [24, 16, 40, 48] => person (COCO class 0), conf = 0.90 * 0.95 = 0.855
        let c1 = 36 * cols;
        raw[c1] = 0.0;
        raw[c1 + 1] = 0.0;
        raw[c1 + 2] = 2.0f32.ln();
        raw[c1 + 3] = 4.0f32.ln();
        raw[c1 + 4] = 0.90;
        raw[c1 + 5] = 0.95; // COCO 0 = person

        // Overlapping lower-confidence person at stride 16, cell (2, 2) => index 64 + 2*4 + 2 = 74
        // cx = 32, cy = 32, w = 16, h = 32 => identical box, lower conf = 0.70 * 0.80 = 0.56
        let c2 = 74 * cols;
        raw[c2] = 0.0;
        raw[c2 + 1] = 0.0;
        raw[c2 + 2] = 1.0f32.ln();
        raw[c2 + 3] = 2.0f32.ln();
        raw[c2 + 4] = 0.70;
        raw[c2 + 5] = 0.80; // COCO 0 = person (should be suppressed by NMS)

        // Same box but different class (car, COCO 2 = Vehicle) -> should NOT be suppressed!
        let c3 = 37 * cols; // gx=5, gy=4
        raw[c3] = -1.0; // cx = 32
        raw[c3 + 1] = 0.0; // cy = 32
        raw[c3 + 2] = 2.0f32.ln();
        raw[c3 + 3] = 4.0f32.ln();
        raw[c3 + 4] = 0.85;
        raw[c3 + 5 + 2] = 0.90; // COCO 2 = car -> Vehicle

        // Source frame is 128x64 (2:1 aspect), letterboxed into 64x64:
        // scale = 0.5, scaled_w = 64, scaled_h = 32, pad_x = 0, pad_y = 16.
        // Box [24, 16, 40, 48] in dst -> x: [48, 80]/128 = [0.375, 0.625], y: [0, 64]/64 = [0.0, 1.0].
        let lb = LetterboxTransform::compute(128, 64, 64, 64).unwrap();
        let dets = post.decode(&raw, lb, 0.35).expect("decode ok");
        assert_eq!(
            dets.len(),
            2,
            "NMS must suppress duplicate person but keep vehicle"
        );
        assert_eq!(dets[0].label, ObjectCategory::Person);
        assert!((dets[0].confidence - 0.855).abs() < 1e-4);
        assert!((dets[0].bbox[0] - 0.375).abs() < 1e-3);
        assert!((dets[0].bbox[1] - 0.0).abs() < 1e-3);
        assert!((dets[0].bbox[2] - 0.625).abs() < 1e-3);
        assert!((dets[0].bbox[3] - 1.0).abs() < 1e-3);
        assert_eq!(dets[1].label, ObjectCategory::Vehicle);
    }

    #[test]
    fn synthetic_detector_finds_person_and_vehicle_blobs() {
        let mut frame = RgbFrame::solid(320, 180, [200, 200, 200]);
        // Tall person-shaped blob (30x80)
        frame.fill_rect(30, 50, 60, 130, [210, 30, 30]);
        // Wide vehicle-shaped blob (90x40)
        frame.fill_rect(180, 100, 270, 140, [30, 70, 210]);

        let detector = SyntheticDetector::default();
        let dets = detector.detect(&frame, 0.35).expect("synthetic detect ok");
        assert_eq!(dets.len(), 2);
        assert!(dets.iter().any(|d| d.label == ObjectCategory::Person));
        assert!(dets.iter().any(|d| d.label == ObjectCategory::Vehicle));
    }

    #[test]
    fn yolox_decode_raw_logits_sigmoid_max_detections_and_error_guards() {
        use crate::error::MediaCoreErrorKind;

        // Invalid stride not dividing input dimensions
        let bad_cfg = YoloxConfig {
            input_width: 64,
            input_height: 64,
            strides: vec![7],
            ..YoloxConfig::yolox_s()
        };
        assert!(matches!(
            YoloxPostProcessor::new(bad_cfg).unwrap_err().kind(),
            MediaCoreErrorKind::InvalidConfiguration(_)
        ));

        // Zero-dimension letterbox rejected
        assert!(matches!(
            LetterboxTransform::compute(0, 64, 64, 64)
                .unwrap_err()
                .kind(),
            MediaCoreErrorKind::InvalidFrame(_)
        ));

        // Valid raw-logit config (Candle/PyTorch head) with max_detections = 2
        let cfg = YoloxConfig {
            input_width: 32,
            input_height: 32,
            strides: vec![8],
            num_classes: 80,
            nms_iou_threshold: 0.45,
            max_detections: 2,
            apply_sigmoid: true,
        };
        let post = YoloxPostProcessor::new(cfg).expect("valid raw-logit yolox cfg");
        let lb = LetterboxTransform::compute(32, 32, 32, 32).unwrap();

        // Wrong raw tensor length rejected
        assert!(matches!(
            post.decode(&[0.0; 10], lb, 0.35).unwrap_err().kind(),
            MediaCoreErrorKind::Detector(_)
        ));

        let cols = 5 + 80;
        // Initialize all logits strongly negative so sigmoid(~ -10) ~= 4.5e-5
        let mut raw = vec![-10.0f32; post.grid_len() * cols];

        // Cell (1, 1) => idx 5: Person (COCO 0) with obj_logit=2.0, cls_logit=1.5
        // Independent oracle: sigmoid(2.0) * sigmoid(1.5)
        let expected_p1 = (1.0 / (1.0 + (-2.0f32).exp())) * (1.0 / (1.0 + (-1.5f32).exp()));
        let r1 = 5 * cols;
        raw[r1] = 0.0;
        raw[r1 + 1] = 0.0;
        raw[r1 + 2] = 1.0f32.ln();
        raw[r1 + 3] = 2.0f32.ln();
        raw[r1 + 4] = 2.0;
        raw[r1 + 5] = 1.5;

        // Cell (3, 1) => idx 7: Vehicle (COCO 2 = car) with obj_logit=3.0, cls_logit=2.5 (highest)
        let expected_v = (1.0 / (1.0 + (-3.0f32).exp())) * (1.0 / (1.0 + (-2.5f32).exp()));
        let r2 = 7 * cols;
        raw[r2] = 0.0;
        raw[r2 + 1] = 0.0;
        raw[r2 + 2] = 1.5f32.ln();
        raw[r2 + 3] = 1.0f32.ln();
        raw[r2 + 4] = 3.0;
        raw[r2 + 5 + 2] = 2.5;

        // Cell (1, 3) => idx 13: Bicycle (COCO 1) with lower confidence -> trimmed by max_detections=2
        let r3 = 13 * cols;
        raw[r3] = 0.0;
        raw[r3 + 1] = 0.0;
        raw[r3 + 2] = 1.0f32.ln();
        raw[r3 + 3] = 1.0f32.ln();
        raw[r3 + 4] = 0.5;
        raw[r3 + 5 + 1] = 0.5;

        // Cell (3, 3) => idx 15: Unmapped COCO class 40 (wine glass) with high logits -> filtered out
        let r4 = 15 * cols;
        raw[r4] = 0.0;
        raw[r4 + 1] = 0.0;
        raw[r4 + 2] = 1.0f32.ln();
        raw[r4 + 3] = 1.0f32.ln();
        raw[r4 + 4] = 5.0;
        raw[r4 + 5 + 40] = 5.0;

        let dets = post.decode(&raw, lb, 0.35).expect("raw logit decode ok");
        assert_eq!(
            dets.len(),
            2,
            "must filter unmapped COCO class and cap at max_detections"
        );
        assert_eq!(dets[0].label, ObjectCategory::Vehicle);
        assert!((dets[0].confidence - expected_v).abs() < 1e-4);
        assert_eq!(dets[1].label, ObjectCategory::Person);
        assert!((dets[1].confidence - expected_p1).abs() < 1e-4);
    }
}
