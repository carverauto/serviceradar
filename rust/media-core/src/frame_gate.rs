//! Two-tier frame-change and motion gate (`add-vms-frame-change-gate`).
//!
//! - **Tier 0 (`CompressedFrameGate`):** Zero-decode compressed H.264 IDR/P-frame payload size
//!   and digest delta gate. Quickly suppresses static scenes without touching the H.264 decoder,
//!   while guaranteeing periodic forced heartbeat refreshes (`max_skip_interval_ms`).
//! - **Tier 1 (`PixelMotionGate`):** Pre-Stage-1 decoded luma (`Y`) or RGB box-averaged
//!   spatial-grid (`32x18` default) SAD/MAD motion scorer with optional ROI masking,
//!   deterministic motion score in `[0.0, 1.0]`, and motion bounding box extraction.

use crate::error::MediaCoreError;
use crate::frame::{LumaPlaneView, RgbFrame};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

/// Why a frame was admitted past a gate tier.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GateAdmitReason {
    /// First observed frame (establishes baseline anchor).
    InitialAnchor,
    /// Compressed payload size or digest delta exceeded the Tier 0 threshold.
    CompressedDelta,
    /// Decoded spatial-grid luma SAD/MAD motion exceeded the Tier 1 threshold.
    PixelMotion,
    /// Forced periodic heartbeat refresh (`max_skip_interval_ms`) to guard against slow drift.
    HeartbeatRefresh,
}

/// Gate evaluation decision for a single frame.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "decision", rename_all = "snake_case")]
pub enum GateDecision {
    Admit {
        reason: GateAdmitReason,
        /// Deterministic change/motion score in `[0.0, 1.0]`.
        score: f32,
        /// Normalized `[x1, y1, x2, y2]` bounding box enclosing changed spatial blocks, if any.
        motion_bbox: Option<[f32; 4]>,
    },
    Skip {
        /// Deterministic change/motion score in `[0.0, 1.0]`.
        score: f32,
        /// Timestamp of the last admitted anchor frame whose index/state carries forward.
        carry_forward_since_ms: u64,
    },
}

impl GateDecision {
    pub fn is_admitted(&self) -> bool {
        matches!(self, Self::Admit { .. })
    }

    pub fn score(&self) -> f32 {
        match self {
            Self::Admit { score, .. } | Self::Skip { score, .. } => *score,
        }
    }

    pub fn motion_bbox(&self) -> Option<[f32; 4]> {
        match self {
            Self::Admit { motion_bbox, .. } => *motion_bbox,
            Self::Skip { .. } => None,
        }
    }
}

/// Configuration for the Tier 0 zero-decode compressed payload gate.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CompressedFrameGateConfig {
    /// Minimum relative byte-size delta (`|size - anchor| / max(anchor, 1)`) required to
    /// admit a frame when payload hashes differ. Default: `0.08` (8%).
    pub min_byte_delta_ratio: f32,
    /// Maximum elapsed time in milliseconds between admitted frames before forcing a
    /// heartbeat refresh. Default: `60_000` (60 seconds).
    pub max_skip_interval_ms: u64,
    /// When `true`, identical SHA-256 compressed payloads are always skipped (until heartbeat)
    /// regardless of `min_byte_delta_ratio`. Default: `true`.
    pub skip_identical_payload_hash: bool,
}

impl Default for CompressedFrameGateConfig {
    fn default() -> Self {
        Self {
            min_byte_delta_ratio: 0.08,
            max_skip_interval_ms: 60_000,
            skip_identical_payload_hash: true,
        }
    }
}

impl CompressedFrameGateConfig {
    pub fn validate(&self) -> Result<(), MediaCoreError> {
        if !(0.0..=1.0).contains(&self.min_byte_delta_ratio)
            || !self.min_byte_delta_ratio.is_finite()
        {
            return Err(MediaCoreError::invalid_configuration(format!(
                "min_byte_delta_ratio must be in [0.0, 1.0], got {}",
                self.min_byte_delta_ratio
            )));
        }
        Ok(())
    }
}

/// Tier 0 zero-decode compressed H.264 IDR/P-frame payload gate.
#[derive(Debug, Clone)]
pub struct CompressedFrameGate {
    config: CompressedFrameGateConfig,
    anchor_size: Option<usize>,
    anchor_hash: Option<[u8; 32]>,
    last_admitted_ms: Option<u64>,
}

impl CompressedFrameGate {
    pub fn new(config: CompressedFrameGateConfig) -> Result<Self, MediaCoreError> {
        config.validate()?;
        Ok(Self {
            config,
            anchor_size: None,
            anchor_hash: None,
            last_admitted_ms: None,
        })
    }

    pub fn config(&self) -> &CompressedFrameGateConfig {
        &self.config
    }

    pub fn reset(&mut self) {
        self.anchor_size = None;
        self.anchor_hash = None;
        self.last_admitted_ms = None;
    }

    /// Evaluates a compressed frame payload (`payload_bytes`) at `timestamp_ms`.
    pub fn evaluate(&mut self, timestamp_ms: u64, payload_bytes: &[u8]) -> GateDecision {
        let size = payload_bytes.len();
        let hash: [u8; 32] = Sha256::digest(payload_bytes).into();
        self.evaluate_with_metadata(timestamp_ms, size, Some(hash))
    }

    /// Evaluates a compressed frame using pre-parsed `payload_size` (e.g. CMAF `trun`
    /// `first_sample_size`) and an optional precomputed SHA-256 digest.
    pub fn evaluate_with_metadata(
        &mut self,
        timestamp_ms: u64,
        payload_size: usize,
        payload_hash: Option<[u8; 32]>,
    ) -> GateDecision {
        let (Some(anchor_size), Some(last_admitted_ms)) = (self.anchor_size, self.last_admitted_ms)
        else {
            self.anchor_size = Some(payload_size);
            self.anchor_hash = payload_hash;
            self.last_admitted_ms = Some(timestamp_ms);
            return GateDecision::Admit {
                reason: GateAdmitReason::InitialAnchor,
                score: 1.0,
                motion_bbox: None,
            };
        };

        let elapsed_ms = timestamp_ms.saturating_sub(last_admitted_ms);
        if self.config.max_skip_interval_ms > 0 && elapsed_ms >= self.config.max_skip_interval_ms {
            self.anchor_size = Some(payload_size);
            self.anchor_hash = payload_hash;
            self.last_admitted_ms = Some(timestamp_ms);
            return GateDecision::Admit {
                reason: GateAdmitReason::HeartbeatRefresh,
                score: 0.0,
                motion_bbox: None,
            };
        }

        if self.config.skip_identical_payload_hash
            && let (Some(prev_h), Some(cur_h)) = (self.anchor_hash, payload_hash)
            && prev_h == cur_h
        {
            return GateDecision::Skip {
                score: 0.0,
                carry_forward_since_ms: last_admitted_ms,
            };
        }

        let delta_bytes = payload_size.abs_diff(anchor_size) as f32;
        let denom = anchor_size.max(1) as f32;
        let ratio = (delta_bytes / denom).clamp(0.0, 1.0);

        if ratio >= self.config.min_byte_delta_ratio {
            self.anchor_size = Some(payload_size);
            self.anchor_hash = payload_hash;
            self.last_admitted_ms = Some(timestamp_ms);
            GateDecision::Admit {
                reason: GateAdmitReason::CompressedDelta,
                score: ratio,
                motion_bbox: None,
            }
        } else {
            GateDecision::Skip {
                score: ratio,
                carry_forward_since_ms: last_admitted_ms,
            }
        }
    }
}

/// Normalized Region-of-Interest (ROI) mask for Tier 1 spatial motion scoring.
///
/// When `include_rects` is non-empty, only grid cells overlapping at least one rectangle
/// are scored. Any cell overlapping `exclude_rects` is ignored (e.g. swaying trees, clocks).
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct RoiMask {
    /// Optional inclusion regions in normalized `[x1, y1, x2, y2]` (`0.0..=1.0`).
    pub include_rects: Vec<[f32; 4]>,
    /// Optional exclusion regions in normalized `[x1, y1, x2, y2]` (`0.0..=1.0`).
    pub exclude_rects: Vec<[f32; 4]>,
}

impl RoiMask {
    /// Returns `true` if the normalized grid cell `[cx1, cy1, cx2, cy2]` is active under this mask.
    pub fn cell_active(&self, cell: [f32; 4]) -> bool {
        let included = if self.include_rects.is_empty() {
            true
        } else {
            self.include_rects.iter().any(|r| rects_overlap(cell, *r))
        };
        if !included {
            return false;
        }
        !self.exclude_rects.iter().any(|r| rects_overlap(cell, *r))
    }
}

fn rects_overlap(a: [f32; 4], b: [f32; 4]) -> bool {
    a[0] < b[2] && a[2] > b[0] && a[1] < b[3] && a[3] > b[1]
}

/// Configuration for the Tier 1 decoded luma/RGB spatial-grid motion gate.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PixelMotionGateConfig {
    /// Downsampled spatial grid width (default `32`).
    pub grid_cols: u32,
    /// Downsampled spatial grid height (default `18`).
    pub grid_rows: u32,
    /// Normalized `[0.0, 1.0]` per-block MAD threshold to classify a block as changed.
    /// Default: `0.10` (~26/255 luma delta) to reject night-IR sensor grain and mild foliage shimmer.
    pub block_delta_threshold: f32,
    /// Maximum single-block normalized delta that triggers admission even if global mean
    /// change is tiny (prevents small distant objects from aliasing out while ignoring isolated
    /// swaying leaves or IR noise spikes). Default: `0.18` (~46/255 luma delta).
    pub max_block_admit_threshold: f32,
    /// Fraction of active ROI blocks that must exceed `block_delta_threshold` to trigger
    /// admission via area coverage. Default: `0.05` (5% of blocks).
    pub changed_block_ratio_threshold: f32,
    /// Maximum elapsed milliseconds before forcing a heartbeat refresh. Default: `60_000`.
    pub max_skip_interval_ms: u64,
    /// Optional ROI inclusion/exclusion mask.
    pub roi: RoiMask,
}

impl Default for PixelMotionGateConfig {
    fn default() -> Self {
        Self {
            grid_cols: 32,
            grid_rows: 18,
            block_delta_threshold: 0.10,
            max_block_admit_threshold: 0.18,
            changed_block_ratio_threshold: 0.05,
            max_skip_interval_ms: 60_000,
            roi: RoiMask::default(),
        }
    }
}

impl PixelMotionGateConfig {
    pub fn validate(&self) -> Result<(), MediaCoreError> {
        if self.grid_cols == 0
            || self.grid_rows == 0
            || self.grid_cols > 256
            || self.grid_rows > 256
        {
            return Err(MediaCoreError::invalid_configuration(format!(
                "grid dimensions must be in 1..=256, got {}x{}",
                self.grid_cols, self.grid_rows
            )));
        }
        if !(0.0..=1.0).contains(&self.block_delta_threshold)
            || !self.block_delta_threshold.is_finite()
        {
            return Err(MediaCoreError::invalid_configuration(
                "block_delta_threshold must be in [0.0, 1.0]",
            ));
        }
        if !(0.0..=1.0).contains(&self.max_block_admit_threshold)
            || !self.max_block_admit_threshold.is_finite()
        {
            return Err(MediaCoreError::invalid_configuration(
                "max_block_admit_threshold must be in [0.0, 1.0]",
            ));
        }
        if !(0.0..=1.0).contains(&self.changed_block_ratio_threshold)
            || !self.changed_block_ratio_threshold.is_finite()
        {
            return Err(MediaCoreError::invalid_configuration(
                "changed_block_ratio_threshold must be in [0.0, 1.0]",
            ));
        }
        Ok(())
    }
}

/// Detailed Tier 1 spatial-grid motion metrics.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PixelMotionMetrics {
    /// Combined deterministic motion score in `[0.0, 1.0]`.
    pub score: f32,
    /// Mean absolute difference across active grid blocks in `[0.0, 1.0]`.
    pub mean_mad: f32,
    /// Maximum single-block absolute difference across active grid blocks in `[0.0, 1.0]`.
    pub max_block_delta: f32,
    /// Fraction of active grid blocks exceeding `block_delta_threshold`.
    pub changed_block_ratio: f32,
    /// Normalized `[x1, y1, x2, y2]` bounding box covering all changed blocks, if any.
    pub motion_bbox: Option<[f32; 4]>,
    /// Final gate decision.
    pub decision: GateDecision,
}

/// Tier 1 pre-Stage-1 decoded luma/RGB spatial-grid motion gate.
///
/// Pre-allocates both the anchor and scratch downsampled grids so steady-state frame
/// evaluations perform zero heap allocations.
#[derive(Debug, Clone)]
pub struct PixelMotionGate {
    config: PixelMotionGateConfig,
    active_mask: Vec<bool>,
    anchor_grid: Vec<u8>,
    scratch_grid: Vec<u8>,
    has_anchor: bool,
    last_admitted_ms: Option<u64>,
}

impl PixelMotionGate {
    pub fn new(config: PixelMotionGateConfig) -> Result<Self, MediaCoreError> {
        config.validate()?;
        let cells = (config.grid_cols as usize) * (config.grid_rows as usize);
        let mut active_mask = Vec::with_capacity(cells);
        let cols_f = config.grid_cols as f32;
        let rows_f = config.grid_rows as f32;
        for gy in 0..config.grid_rows {
            for gx in 0..config.grid_cols {
                let cell = [
                    (gx as f32) / cols_f,
                    (gy as f32) / rows_f,
                    ((gx + 1) as f32) / cols_f,
                    ((gy + 1) as f32) / rows_f,
                ];
                active_mask.push(config.roi.cell_active(cell));
            }
        }
        Ok(Self {
            config,
            active_mask,
            anchor_grid: vec![0u8; cells],
            scratch_grid: vec![0u8; cells],
            has_anchor: false,
            last_admitted_ms: None,
        })
    }

    pub fn config(&self) -> &PixelMotionGateConfig {
        &self.config
    }

    pub fn reset(&mut self) {
        self.has_anchor = false;
        self.last_admitted_ms = None;
        self.anchor_grid.fill(0);
        self.scratch_grid.fill(0);
    }

    /// Evaluates motion directly from a decoded Y-plane (zero YUV-to-RGB cost, zero alloc).
    pub fn evaluate_luma(
        &mut self,
        timestamp_ms: u64,
        luma: LumaPlaneView<'_>,
    ) -> Result<PixelMotionMetrics, MediaCoreError> {
        let expected = (luma.width as usize)
            .checked_mul(luma.height as usize)
            .ok_or_else(|| MediaCoreError::invalid_frame("luma dimensions overflow"))?;
        if luma.width == 0 || luma.height == 0 || luma.y.len() != expected {
            return Err(MediaCoreError::invalid_frame(format!(
                "invalid luma plane {}x{} (len {})",
                luma.width,
                luma.height,
                luma.y.len()
            )));
        }

        downsample_luma_box_avg(
            luma.y,
            luma.width as usize,
            luma.height as usize,
            self.config.grid_cols as usize,
            self.config.grid_rows as usize,
            &mut self.scratch_grid,
        );
        Ok(self.score_scratch_grid(timestamp_ms))
    }

    /// Evaluates motion from a decoded [`RgbFrame`] using BT.601 luma box-averaging (zero alloc).
    pub fn evaluate_rgb(
        &mut self,
        timestamp_ms: u64,
        frame: &RgbFrame,
    ) -> Result<PixelMotionMetrics, MediaCoreError> {
        if frame.width() == 0 || frame.height() == 0 {
            return Err(MediaCoreError::invalid_frame("empty RGB frame"));
        }
        downsample_rgb_luma_box_avg(
            frame.pixels(),
            frame.width() as usize,
            frame.height() as usize,
            self.config.grid_cols as usize,
            self.config.grid_rows as usize,
            &mut self.scratch_grid,
        );
        Ok(self.score_scratch_grid(timestamp_ms))
    }

    fn score_scratch_grid(&mut self, timestamp_ms: u64) -> PixelMotionMetrics {
        if !self.has_anchor {
            self.anchor_grid.copy_from_slice(&self.scratch_grid);
            self.has_anchor = true;
            self.last_admitted_ms = Some(timestamp_ms);
            return PixelMotionMetrics {
                score: 1.0,
                mean_mad: 1.0,
                max_block_delta: 1.0,
                changed_block_ratio: 1.0,
                motion_bbox: Some([0.0, 0.0, 1.0, 1.0]),
                decision: GateDecision::Admit {
                    reason: GateAdmitReason::InitialAnchor,
                    score: 1.0,
                    motion_bbox: Some([0.0, 0.0, 1.0, 1.0]),
                },
            };
        }

        let cols = self.config.grid_cols as usize;
        let rows = self.config.grid_rows as usize;
        let mut active_count = 0usize;
        let mut changed_count = 0usize;
        let mut sad_sum = 0u64;
        let mut max_delta = 0.0f32;
        let mut min_gx = usize::MAX;
        let mut min_gy = usize::MAX;
        let mut max_gx = 0usize;
        let mut max_gy = 0usize;

        for gy in 0..rows {
            for gx in 0..cols {
                let idx = gy * cols + gx;
                if !self.active_mask[idx] {
                    continue;
                }
                active_count += 1;
                let diff = self.scratch_grid[idx].abs_diff(self.anchor_grid[idx]);
                sad_sum += u64::from(diff);
                let norm = f32::from(diff) / 255.0;
                if norm > max_delta {
                    max_delta = norm;
                }
                if norm >= self.config.block_delta_threshold {
                    changed_count += 1;
                    min_gx = min_gx.min(gx);
                    min_gy = min_gy.min(gy);
                    max_gx = max_gx.max(gx);
                    max_gy = max_gy.max(gy);
                }
            }
        }

        let (mean_mad, changed_block_ratio) = if active_count == 0 {
            (0.0, 0.0)
        } else {
            let mad = (sad_sum as f32) / ((active_count as f32) * 255.0);
            let ratio = (changed_count as f32) / (active_count as f32);
            (mad.clamp(0.0, 1.0), ratio.clamp(0.0, 1.0))
        };

        let motion_bbox = if changed_count > 0 {
            let cols_f = cols as f32;
            let rows_f = rows as f32;
            Some([
                (min_gx as f32) / cols_f,
                (min_gy as f32) / rows_f,
                ((max_gx + 1) as f32) / cols_f,
                ((max_gy + 1) as f32) / rows_f,
            ])
        } else {
            None
        };

        // Combine max_block_delta (sensitive to small movers) and changed_block_ratio/mean_mad
        // into a deterministic `[0.0, 1.0]` motion score.
        let score =
            (0.65 * max_delta + 0.25 * changed_block_ratio + 0.10 * mean_mad).clamp(0.0, 1.0);

        let last_admitted_ms = self.last_admitted_ms.unwrap_or(timestamp_ms);
        let elapsed_ms = timestamp_ms.saturating_sub(last_admitted_ms);
        let heartbeat =
            self.config.max_skip_interval_ms > 0 && elapsed_ms >= self.config.max_skip_interval_ms;
        let motion_triggered = max_delta >= self.config.max_block_admit_threshold
            || changed_block_ratio >= self.config.changed_block_ratio_threshold;

        let decision = if motion_triggered {
            self.anchor_grid.copy_from_slice(&self.scratch_grid);
            self.last_admitted_ms = Some(timestamp_ms);
            GateDecision::Admit {
                reason: GateAdmitReason::PixelMotion,
                score,
                motion_bbox,
            }
        } else if heartbeat {
            self.anchor_grid.copy_from_slice(&self.scratch_grid);
            self.last_admitted_ms = Some(timestamp_ms);
            GateDecision::Admit {
                reason: GateAdmitReason::HeartbeatRefresh,
                score,
                motion_bbox,
            }
        } else {
            GateDecision::Skip {
                score,
                carry_forward_since_ms: last_admitted_ms,
            }
        };

        PixelMotionMetrics {
            score,
            mean_mad,
            max_block_delta: max_delta,
            changed_block_ratio,
            motion_bbox,
            decision,
        }
    }
}

/// Combined two-tier frame gate coordinating Tier 0 (compressed) and Tier 1 (decoded pixel).
#[derive(Debug, Clone)]
pub struct TwoTierFrameGate {
    tier0: CompressedFrameGate,
    tier1: PixelMotionGate,
}

impl TwoTierFrameGate {
    pub fn new(
        tier0_config: CompressedFrameGateConfig,
        tier1_config: PixelMotionGateConfig,
    ) -> Result<Self, MediaCoreError> {
        Ok(Self {
            tier0: CompressedFrameGate::new(tier0_config)?,
            tier1: PixelMotionGate::new(tier1_config)?,
        })
    }

    pub fn tier0(&self) -> &CompressedFrameGate {
        &self.tier0
    }

    pub fn tier1(&self) -> &PixelMotionGate {
        &self.tier1
    }

    pub fn reset(&mut self) {
        self.tier0.reset();
        self.tier1.reset();
    }

    /// Evaluates Tier 0 on compressed payload bytes. Callers should only decode the frame
    /// when this returns `GateDecision::Admit`.
    pub fn evaluate_compressed(&mut self, timestamp_ms: u64, payload_bytes: &[u8]) -> GateDecision {
        self.tier0.evaluate(timestamp_ms, payload_bytes)
    }

    /// Evaluates Tier 1 on a decoded Y-plane.
    pub fn evaluate_luma(
        &mut self,
        timestamp_ms: u64,
        luma: LumaPlaneView<'_>,
    ) -> Result<PixelMotionMetrics, MediaCoreError> {
        self.tier1.evaluate_luma(timestamp_ms, luma)
    }

    /// Evaluates Tier 1 on a decoded RGB8 frame.
    pub fn evaluate_rgb(
        &mut self,
        timestamp_ms: u64,
        frame: &RgbFrame,
    ) -> Result<PixelMotionMetrics, MediaCoreError> {
        self.tier1.evaluate_rgb(timestamp_ms, frame)
    }
}

fn downsample_luma_box_avg(
    y_plane: &[u8],
    width: usize,
    height: usize,
    grid_cols: usize,
    grid_rows: usize,
    out: &mut [u8],
) {
    for gy in 0..grid_rows {
        let y0 = (gy * height) / grid_rows;
        let y1 = (((gy + 1) * height) / grid_rows).max(y0 + 1).min(height);
        for gx in 0..grid_cols {
            let x0 = (gx * width) / grid_cols;
            let x1 = (((gx + 1) * width) / grid_cols).max(x0 + 1).min(width);
            let mut sum = 0u64;
            let mut count = 0u64;
            for y in y0..y1 {
                let row = y * width;
                for &sample in &y_plane[row + x0..row + x1] {
                    sum += u64::from(sample);
                    count += 1;
                }
            }
            out[gy * grid_cols + gx] = sum.checked_div(count).unwrap_or(0) as u8;
        }
    }
}

fn downsample_rgb_luma_box_avg(
    rgb_pixels: &[u8],
    width: usize,
    height: usize,
    grid_cols: usize,
    grid_rows: usize,
    out: &mut [u8],
) {
    for gy in 0..grid_rows {
        let y0 = (gy * height) / grid_rows;
        let y1 = (((gy + 1) * height) / grid_rows).max(y0 + 1).min(height);
        for gx in 0..grid_cols {
            let x0 = (gx * width) / grid_cols;
            let x1 = (((gx + 1) * width) / grid_cols).max(x0 + 1).min(width);
            let mut sum = 0u64;
            let mut count = 0u64;
            for y in y0..y1 {
                let row = y * width;
                for x in x0..x1 {
                    let idx = (row + x) * 3;
                    let luma = (77u64 * u64::from(rgb_pixels[idx])
                        + 150u64 * u64::from(rgb_pixels[idx + 1])
                        + 29u64 * u64::from(rgb_pixels[idx + 2])
                        + 128)
                        >> 8;
                    sum += luma;
                    count += 1;
                }
            }
            out[gy * grid_cols + gx] = sum.checked_div(count).unwrap_or(0) as u8;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::frame::LumaPlane;

    #[test]
    fn tier0_skips_static_and_admits_delta_and_heartbeat() {
        let mut gate = CompressedFrameGate::new(CompressedFrameGateConfig {
            min_byte_delta_ratio: 0.10,
            max_skip_interval_ms: 10_000,
            skip_identical_payload_hash: true,
        })
        .expect("valid tier0 config");

        let base = vec![0x41u8; 1000];
        let d0 = gate.evaluate(0, &base);
        assert!(matches!(
            d0,
            GateDecision::Admit {
                reason: GateAdmitReason::InitialAnchor,
                ..
            }
        ));

        // Identical payload at t=2s -> Skip
        let d1 = gate.evaluate(2_000, &base);
        assert!(matches!(
            d1,
            GateDecision::Skip {
                carry_forward_since_ms: 0,
                ..
            }
        ));

        // Slightly different bytes (<10% size delta) at t=5s -> Skip
        let small_delta = vec![0x42u8; 1040];
        let d2 = gate.evaluate(5_000, &small_delta);
        assert!(!d2.is_admitted());

        // Heartbeat at t=10s -> Admit even with identical bytes
        let d3 = gate.evaluate(10_000, &base);
        assert!(matches!(
            d3,
            GateDecision::Admit {
                reason: GateAdmitReason::HeartbeatRefresh,
                ..
            }
        ));

        // Large payload jump (+25%) at t=12s -> Admit via CompressedDelta
        let burst = vec![0x55u8; 1250];
        let d4 = gate.evaluate(12_000, &burst);
        assert!(matches!(
            d4,
            GateDecision::Admit {
                reason: GateAdmitReason::CompressedDelta,
                ..
            }
        ));
        assert!(d4.score() >= 0.24);
    }

    #[test]
    fn tier1_detects_small_localized_motion_and_honors_roi_exclusion() {
        let mut gate = PixelMotionGate::new(PixelMotionGateConfig {
            grid_cols: 16,
            grid_rows: 16,
            block_delta_threshold: 0.08,
            max_block_admit_threshold: 0.12,
            changed_block_ratio_threshold: 0.05,
            max_skip_interval_ms: 30_000,
            roi: RoiMask {
                include_rects: vec![],
                exclude_rects: vec![[0.0, 0.0, 0.25, 0.25]], // ignore top-left clock/tree
            },
        })
        .expect("valid tier1 config");

        let base = LumaPlane::solid(160, 160, 40);
        let m0 = gate.evaluate_luma(0, base.as_slice()).unwrap();
        assert!(m0.decision.is_admitted());

        // Identical frame -> Skip with score 0
        let m1 = gate.evaluate_luma(1_000, base.as_slice()).unwrap();
        assert!(!m1.decision.is_admitted());
        assert_eq!(m1.score, 0.0);

        // Motion ONLY inside excluded top-left ROI -> Skip
        let mut excluded_motion = base.clone();
        excluded_motion.fill_rect(0, 0, 32, 32, 240);
        let m2 = gate
            .evaluate_luma(2_000, excluded_motion.as_slice())
            .unwrap();
        assert!(!m2.decision.is_admitted());

        // Small person-sized bright block in bottom-right (outside exclusion) -> Admit + bbox
        let mut active_motion = base.clone();
        active_motion.fill_rect(120, 120, 140, 150, 220);
        let m3 = gate.evaluate_luma(3_000, active_motion.as_slice()).unwrap();
        assert!(matches!(
            m3.decision,
            GateDecision::Admit {
                reason: GateAdmitReason::PixelMotion,
                ..
            }
        ));
        let bbox = m3.motion_bbox.expect("motion bbox should be computed");
        assert!(bbox[0] >= 0.70 && bbox[1] >= 0.70 && bbox[2] <= 1.0 && bbox[3] <= 1.0);

        // Heartbeat after 30s on static frame -> Admit via HeartbeatRefresh
        let m4 = gate
            .evaluate_luma(33_000, active_motion.as_slice())
            .unwrap();
        assert!(matches!(
            m4.decision,
            GateDecision::Admit {
                reason: GateAdmitReason::HeartbeatRefresh,
                ..
            }
        ));
    }

    #[test]
    fn tier1_roi_include_and_exclude_and_config_or_frame_validation() {
        use crate::error::MediaCoreErrorKind;

        // Invalid Tier 0 configs
        for bad_ratio in [-0.01, 1.01, f32::NAN, f32::INFINITY] {
            let err = CompressedFrameGate::new(CompressedFrameGateConfig {
                min_byte_delta_ratio: bad_ratio,
                ..CompressedFrameGateConfig::default()
            })
            .unwrap_err();
            assert!(matches!(
                err.kind(),
                MediaCoreErrorKind::InvalidConfiguration(_)
            ));
        }

        // Invalid Tier 1 configs
        let bad_grid = PixelMotionGate::new(PixelMotionGateConfig {
            grid_cols: 0,
            ..PixelMotionGateConfig::default()
        })
        .unwrap_err();
        assert!(matches!(
            bad_grid.kind(),
            MediaCoreErrorKind::InvalidConfiguration(_)
        ));

        let bad_thresh = PixelMotionGate::new(PixelMotionGateConfig {
            block_delta_threshold: f32::NAN,
            ..PixelMotionGateConfig::default()
        })
        .unwrap_err();
        assert!(matches!(
            bad_thresh.kind(),
            MediaCoreErrorKind::InvalidConfiguration(_)
        ));

        // Tier 0 size-only metadata evaluation (no hash, e.g. CMAF trun sample size)
        let mut t0 = CompressedFrameGate::new(CompressedFrameGateConfig {
            min_byte_delta_ratio: 0.10,
            max_skip_interval_ms: 60_000,
            skip_identical_payload_hash: true,
        })
        .unwrap();
        assert!(t0.evaluate_with_metadata(0, 1000, None).is_admitted());
        assert!(!t0.evaluate_with_metadata(1_000, 1050, None).is_admitted());
        assert!(matches!(
            t0.evaluate_with_metadata(2_000, 1120, None),
            GateDecision::Admit {
                reason: GateAdmitReason::CompressedDelta,
                ..
            }
        ));

        // Combined include + exclude ROI: only cells inside [0.25, 0.25, 0.75, 0.75] and
        // outside [0.50, 0.25, 0.75, 0.50] are scored.
        let mut gate = PixelMotionGate::new(PixelMotionGateConfig {
            grid_cols: 16,
            grid_rows: 16,
            block_delta_threshold: 0.08,
            max_block_admit_threshold: 0.12,
            changed_block_ratio_threshold: 0.05,
            max_skip_interval_ms: 60_000,
            roi: RoiMask {
                include_rects: vec![[0.25, 0.25, 0.75, 0.75]],
                exclude_rects: vec![[0.50, 0.25, 0.75, 0.50]],
            },
        })
        .unwrap();

        let base = LumaPlane::solid(160, 160, 40);
        assert!(
            gate.evaluate_luma(0, base.as_slice())
                .unwrap()
                .decision
                .is_admitted()
        );

        // Motion outside include_rects (top-left corner) -> Skip with score 0
        let mut outside = base.clone();
        outside.fill_rect(0, 0, 32, 32, 230);
        let m_out = gate.evaluate_luma(1_000, outside.as_slice()).unwrap();
        assert!(!m_out.decision.is_admitted());
        assert_eq!(m_out.score, 0.0);

        // Motion inside exclude_rects (upper-right of included box) -> Skip with score 0
        let mut excluded = base.clone();
        excluded.fill_rect(84, 44, 116, 76, 230);
        let m_exc = gate.evaluate_luma(2_000, excluded.as_slice()).unwrap();
        assert!(!m_exc.decision.is_admitted());
        assert_eq!(m_exc.score, 0.0);

        // Motion inside included & non-excluded quadrant (lower-left of included box) -> Admit
        let mut active = base.clone();
        active.fill_rect(44, 84, 76, 116, 230);
        let m_act = gate.evaluate_luma(3_000, active.as_slice()).unwrap();
        assert!(matches!(
            m_act.decision,
            GateDecision::Admit {
                reason: GateAdmitReason::PixelMotion,
                ..
            }
        ));
        let bbox = m_act.motion_bbox.expect("active ROI motion bbox");
        assert!(bbox[0] >= 0.25 && bbox[1] >= 0.50 && bbox[2] <= 0.50 && bbox[3] <= 0.75);

        // Invalid luma slice length returns InvalidFrame
        let bad_view = LumaPlaneView {
            width: 16,
            height: 16,
            y: &[0u8; 10],
        };
        let err = gate.evaluate_luma(4_000, bad_view).unwrap_err();
        assert!(matches!(err.kind(), MediaCoreErrorKind::InvalidFrame(_)));
    }

    #[test]
    fn tier1_defaults_suppress_ir_grain_and_foliage_while_admitting_real_movers() {
        let mut gate = PixelMotionGate::new(PixelMotionGateConfig::default())
            .expect("valid default tier1 config");

        let base = LumaPlane::solid(320, 180, 60);
        assert!(
            gate.evaluate_luma(0, base.as_slice())
                .unwrap()
                .decision
                .is_admitted()
        );

        // Faint night-IR sensor grain (+12 luma across the whole frame, ~0.047 delta) -> Skip
        let ir_grain = LumaPlane::solid(320, 180, 72);
        let m_grain = gate.evaluate_luma(1_000, ir_grain.as_slice()).unwrap();
        assert!(
            !m_grain.decision.is_admitted(),
            "faint IR grain should be suppressed by default thresholds (max_delta={}, ratio={})",
            m_grain.max_block_delta,
            m_grain.changed_block_ratio
        );

        // Localized swaying foliage (small 2x2 grid patch shifting by +30 luma, ~0.118 delta,
        // ~0.7% of blocks) -> Skip
        let mut foliage = base.clone();
        foliage.fill_rect(10, 10, 30, 30, 90);
        let m_foliage = gate.evaluate_luma(2_000, foliage.as_slice()).unwrap();
        assert!(
            !m_foliage.decision.is_admitted(),
            "small swaying foliage patch should be suppressed (max_delta={}, ratio={})",
            m_foliage.max_block_delta,
            m_foliage.changed_block_ratio
        );

        // Real person/animal/vehicle entering frame (high-contrast +90 luma region) -> Admit
        let mut mover = base.clone();
        mover.fill_rect(120, 60, 180, 140, 150);
        let m_mover = gate.evaluate_luma(3_000, mover.as_slice()).unwrap();
        assert!(matches!(
            m_mover.decision,
            GateDecision::Admit {
                reason: GateAdmitReason::PixelMotion,
                ..
            }
        ));
        assert!(m_mover.motion_bbox.is_some());
    }
}
