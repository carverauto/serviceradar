//! Pure-Rust Apache-2.0 YOLOX object detector built on `candle-core` + `candle-nn`.
//!
//! Loads standard Megvii `YOLOX` `.safetensors` weights (`backbone.backbone.*`,
//! `backbone.*`, `head.*`) from local disk with zero C/C++ dependencies,
//! consumes BGR `[0.0, 255.0]` centered-letterboxed frames (`114.0` pad), and
//! decodes anchor-free head logits through [`YoloxPostProcessor`].

use crate::backend::RawDetection;
use crate::errors::MediaWorkerError;
use crate::vision::{ObjectClass, RgbFrame};
use candle_core::{DType, Device, Module, ModuleT, Result as CandleResult, Tensor};
use candle_nn::{
    BatchNorm, BatchNormConfig, Conv2d, Conv2dConfig, VarBuilder, batch_norm, conv2d,
    conv2d_no_bias,
};
use serde::{Deserialize, Serialize};
use serviceradar_media_core::detector::{
    LetterboxTransform, ObjectCategory, YoloxConfig, YoloxPostProcessor, coco_class_to_category,
    coco_name_to_category,
};
use std::path::Path;

/// Official Megvii `init_yolo` BatchNorm2d epsilon (`1e-3`, NOT PyTorch's `1e-5` default).
const YOLOX_BATCH_NORM_EPS: f64 = 1e-3;
/// Official Megvii `ValTransform` letterbox border padding value (`114.0` in `[0.0, 255.0]` space).
const YOLOX_LETTERBOX_PAD_VALUE: f32 = 114.0;

/// Converts a `serviceradar-media-core` [`ObjectCategory`] to Stage 1 [`ObjectClass`].
pub fn object_category_to_class(category: ObjectCategory) -> Option<ObjectClass> {
    match category {
        ObjectCategory::Person => Some(ObjectClass::Person),
        ObjectCategory::Vehicle => Some(ObjectClass::Vehicle),
        ObjectCategory::Bicycle => Some(ObjectClass::Bicycle),
        ObjectCategory::Animal => Some(ObjectClass::Animal),
        ObjectCategory::Package => Some(ObjectClass::Package),
        ObjectCategory::Motion => None,
    }
}

/// Maps a standard 80-class COCO index to ServiceRadar's [`ObjectClass`].
pub fn coco_class_to_object_class(class_id: usize) -> Option<ObjectClass> {
    coco_class_to_category(class_id).and_then(object_category_to_class)
}

/// Maps a COCO class name string to ServiceRadar's [`ObjectClass`].
pub fn coco_name_to_object_class(name: &str) -> Option<ObjectClass> {
    coco_name_to_category(name).and_then(object_category_to_class)
}

fn default_family() -> String {
    "yolox".to_string()
}

fn default_variant() -> String {
    "yolox-s".to_string()
}

fn default_input_width() -> u32 {
    640
}

fn default_input_height() -> u32 {
    640
}

fn default_num_classes() -> usize {
    80
}

fn default_strides() -> Vec<u32> {
    vec![8, 16, 32]
}

fn default_depth_multiple() -> f64 {
    0.33
}

fn default_width_multiple() -> f64 {
    0.50
}

fn default_confidence_threshold() -> f32 {
    0.35
}

fn default_nms_iou_threshold() -> f32 {
    0.45
}

fn default_max_detections() -> usize {
    32
}

fn default_apply_sigmoid() -> bool {
    true
}

/// Configuration for loading a YOLOX `.safetensors` checkpoint (`detector_config.json`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct YoloxDetectorConfig {
    #[serde(default = "default_family")]
    pub family: String,
    #[serde(default = "default_variant")]
    pub variant: String,
    #[serde(default = "default_input_width")]
    pub input_width: u32,
    #[serde(default = "default_input_height")]
    pub input_height: u32,
    #[serde(default = "default_num_classes")]
    pub num_classes: usize,
    #[serde(default = "default_strides")]
    pub strides: Vec<u32>,
    #[serde(default = "default_depth_multiple")]
    pub depth_multiple: f64,
    #[serde(default = "default_width_multiple")]
    pub width_multiple: f64,
    #[serde(default = "default_confidence_threshold")]
    pub confidence_threshold: f32,
    #[serde(default = "default_nms_iou_threshold")]
    pub nms_iou_threshold: f32,
    #[serde(default = "default_max_detections")]
    pub max_detections: usize,
    #[serde(default = "default_apply_sigmoid")]
    pub apply_sigmoid: bool,
}

impl Default for YoloxDetectorConfig {
    fn default() -> Self {
        Self::yolox_s()
    }
}

impl YoloxDetectorConfig {
    /// Standard Apache-2.0 YOLOX-s (`640x640`, 80 COCO classes, `depth=0.33, width=0.50`).
    pub fn yolox_s() -> Self {
        Self {
            family: default_family(),
            variant: default_variant(),
            input_width: default_input_width(),
            input_height: default_input_height(),
            num_classes: default_num_classes(),
            strides: default_strides(),
            depth_multiple: default_depth_multiple(),
            width_multiple: default_width_multiple(),
            confidence_threshold: default_confidence_threshold(),
            nms_iou_threshold: default_nms_iou_threshold(),
            max_detections: default_max_detections(),
            apply_sigmoid: default_apply_sigmoid(),
        }
    }

    /// Validates configuration invariants prior to building tensors.
    pub fn validate(&self) -> Result<(), MediaWorkerError> {
        if !self.family.trim().eq_ignore_ascii_case("yolox") {
            return Err(MediaWorkerError::inference_failed(format!(
                "unsupported detector_config.json family '{}'; expected 'yolox'",
                self.family
            )));
        }
        if self.strides.len() != 3 {
            return Err(MediaWorkerError::inference_failed(format!(
                "YOLOX requires 3 FPN strides (got {:?})",
                self.strides
            )));
        }
        if self.input_width == 0
            || self.input_height == 0
            || !self.input_width.is_multiple_of(32)
            || !self.input_height.is_multiple_of(32)
        {
            return Err(MediaWorkerError::inference_failed(format!(
                "YOLOX input dimensions {}x{} must be non-zero multiples of 32",
                self.input_width, self.input_height
            )));
        }
        if self.num_classes == 0 {
            return Err(MediaWorkerError::inference_failed(
                "YOLOX num_classes must be > 0",
            ));
        }
        if !self.depth_multiple.is_finite()
            || self.depth_multiple <= 0.0
            || !self.width_multiple.is_finite()
            || self.width_multiple <= 0.0
        {
            return Err(MediaWorkerError::inference_failed(
                "YOLOX depth_multiple and width_multiple must be positive finite values",
            ));
        }
        Ok(())
    }

    pub fn to_yolox_config(&self) -> YoloxConfig {
        YoloxConfig {
            input_width: self.input_width,
            input_height: self.input_height,
            strides: self.strides.clone(),
            num_classes: self.num_classes,
            nms_iou_threshold: self.nms_iou_threshold,
            max_detections: self.max_detections,
            apply_sigmoid: self.apply_sigmoid,
        }
    }

    fn base_channels(&self) -> usize {
        ((64.0 * self.width_multiple).round() as usize).max(4)
    }

    fn base_depth(&self) -> usize {
        ((3.0 * self.depth_multiple).round() as usize).max(1)
    }

    fn head_mid_channels(&self) -> usize {
        ((256.0 * self.width_multiple).round() as usize).max(4)
    }
}

/// Megvii `BaseConv`: `Conv2d(bias=False)` + `BatchNorm2d(eps=1e-3)` + `SiLU`.
#[derive(Debug, Clone)]
struct BaseConv {
    conv: Conv2d,
    bn: BatchNorm,
}

impl BaseConv {
    fn load(
        vb: VarBuilder,
        in_channels: usize,
        out_channels: usize,
        ksize: usize,
        stride: usize,
    ) -> CandleResult<Self> {
        let padding = (ksize - 1) / 2;
        let cfg = Conv2dConfig {
            padding,
            stride,
            groups: 1,
            dilation: 1,
            cudnn_fwd_algo: None,
        };
        let conv = conv2d_no_bias(in_channels, out_channels, ksize, cfg, vb.pp("conv"))?;
        let bn = batch_norm(
            out_channels,
            BatchNormConfig::from(YOLOX_BATCH_NORM_EPS),
            vb.pp("bn"),
        )?;
        Ok(Self { conv, bn })
    }
}

impl Module for BaseConv {
    fn forward(&self, xs: &Tensor) -> CandleResult<Tensor> {
        let xs = self.conv.forward(xs)?;
        let xs = self.bn.forward_t(&xs, false)?;
        candle_nn::ops::silu(&xs)
    }
}

/// Megvii `Focus` space-to-depth stem: concatenates `[top_left, bot_left, top_right, bot_right]`
/// along the channel dimension before a `BaseConv`.
#[derive(Debug, Clone)]
struct Focus {
    conv: BaseConv,
}

impl Focus {
    fn load(
        vb: VarBuilder,
        in_channels: usize,
        out_channels: usize,
        ksize: usize,
    ) -> CandleResult<Self> {
        let conv = BaseConv::load(vb.pp("conv"), in_channels * 4, out_channels, ksize, 1)?;
        Ok(Self { conv })
    }

    fn pack_patches(xs: &Tensor) -> CandleResult<Tensor> {
        let (b, c, h, w) = xs.dims4()?;
        if h % 2 != 0 || w % 2 != 0 {
            candle_core::bail!("Focus input spatial dims ({h}x{w}) must be even");
        }
        // `(b, c, h/2, 2_dy, w/2, 2_dx)` -> `(b, 2_dx, 2_dy, c, h/2, w/2)` gives
        // channel blocks `(dx=0,dy=0)=top_left`, `(dx=0,dy=1)=bot_left`,
        // `(dx=1,dy=0)=top_right`, `(dx=1,dy=1)=bot_right`.
        xs.reshape((b, c, h / 2, 2, w / 2, 2))?
            .permute((0, 5, 3, 1, 2, 4))?
            .contiguous()?
            .reshape((b, c * 4, h / 2, w / 2))
    }
}

impl Module for Focus {
    fn forward(&self, xs: &Tensor) -> CandleResult<Tensor> {
        let packed = Self::pack_patches(xs)?;
        self.conv.forward(&packed)
    }
}

/// Megvii `Bottleneck`: `1x1 BaseConv` -> `3x3 BaseConv` (+ residual when `shortcut && c1 == c2`).
#[derive(Debug, Clone)]
struct Bottleneck {
    conv1: BaseConv,
    conv2: BaseConv,
    use_add: bool,
}

impl Bottleneck {
    fn load(
        vb: VarBuilder,
        in_channels: usize,
        out_channels: usize,
        shortcut: bool,
        expansion: f64,
    ) -> CandleResult<Self> {
        let hidden = ((out_channels as f64) * expansion).round() as usize;
        let conv1 = BaseConv::load(vb.pp("conv1"), in_channels, hidden, 1, 1)?;
        let conv2 = BaseConv::load(vb.pp("conv2"), hidden, out_channels, 3, 1)?;
        let use_add = shortcut && in_channels == out_channels;
        Ok(Self {
            conv1,
            conv2,
            use_add,
        })
    }
}

impl Module for Bottleneck {
    fn forward(&self, xs: &Tensor) -> CandleResult<Tensor> {
        let ys = self.conv2.forward(&self.conv1.forward(xs)?)?;
        if self.use_add { xs + ys } else { Ok(ys) }
    }
}

/// Megvii `CSPLayer`: split-transform-merge block with `n` `Bottleneck(expansion=1.0)` blocks.
#[derive(Debug, Clone)]
struct CSPLayer {
    conv1: BaseConv,
    conv2: BaseConv,
    conv3: BaseConv,
    m: Vec<Bottleneck>,
}

impl CSPLayer {
    fn load(
        vb: VarBuilder,
        in_channels: usize,
        out_channels: usize,
        n: usize,
        shortcut: bool,
        expansion: f64,
    ) -> CandleResult<Self> {
        let hidden = ((out_channels as f64) * expansion).round() as usize;
        let conv1 = BaseConv::load(vb.pp("conv1"), in_channels, hidden, 1, 1)?;
        let conv2 = BaseConv::load(vb.pp("conv2"), in_channels, hidden, 1, 1)?;
        let conv3 = BaseConv::load(vb.pp("conv3"), 2 * hidden, out_channels, 1, 1)?;
        let mut m = Vec::with_capacity(n);
        for idx in 0..n {
            m.push(Bottleneck::load(
                vb.pp(format!("m.{idx}")),
                hidden,
                hidden,
                shortcut,
                1.0,
            )?);
        }
        Ok(Self {
            conv1,
            conv2,
            conv3,
            m,
        })
    }
}

impl Module for CSPLayer {
    fn forward(&self, xs: &Tensor) -> CandleResult<Tensor> {
        let mut x1 = self.conv1.forward(xs)?;
        for block in &self.m {
            x1 = block.forward(&x1)?;
        }
        let x2 = self.conv2.forward(xs)?;
        let cat = Tensor::cat(&[&x1, &x2], 1)?;
        self.conv3.forward(&cat)
    }
}

/// Megvii `SPPBottleneck`: `conv1` followed by parallel `MaxPool2d` branches `(5, 9, 13)`
/// concatenated with the unpooled projection and fused by `conv2`.
#[derive(Debug, Clone)]
struct SPPBottleneck {
    conv1: BaseConv,
    conv2: BaseConv,
    kernel_sizes: [usize; 3],
}

impl SPPBottleneck {
    fn load(vb: VarBuilder, in_channels: usize, out_channels: usize) -> CandleResult<Self> {
        let hidden = in_channels / 2;
        let kernel_sizes = [5usize, 9, 13];
        let conv1 = BaseConv::load(vb.pp("conv1"), in_channels, hidden, 1, 1)?;
        let conv2 = BaseConv::load(
            vb.pp("conv2"),
            hidden * (kernel_sizes.len() + 1),
            out_channels,
            1,
            1,
        )?;
        Ok(Self {
            conv1,
            conv2,
            kernel_sizes,
        })
    }
}

/// Spatial max-pooling with `-inf` padding matching PyTorch `nn.MaxPool2d(k, stride=1, padding=k/2)`
/// so negative `SiLU` border activations are never clamped upward to `0.0`.
fn max_pool2d_neg_inf_pad(x: &Tensor, kernel_size: usize) -> CandleResult<Tensor> {
    let pad = kernel_size / 2;
    if pad == 0 {
        return x.max_pool2d_with_stride(kernel_size, 1);
    }
    let (b, c, h, w) = x.dims4()?;
    let dtype = x.dtype();
    let device = x.device();

    let h_pad = Tensor::full(f32::NEG_INFINITY, (b, c, pad, w), device)?.to_dtype(dtype)?;
    let x_h = Tensor::cat(&[&h_pad, x, &h_pad], 2)?;

    let w_pad =
        Tensor::full(f32::NEG_INFINITY, (b, c, h + 2 * pad, pad), device)?.to_dtype(dtype)?;
    let x_padded = Tensor::cat(&[&w_pad, &x_h, &w_pad], 3)?;

    x_padded.max_pool2d_with_stride(kernel_size, 1)
}

impl Module for SPPBottleneck {
    fn forward(&self, xs: &Tensor) -> CandleResult<Tensor> {
        let x = self.conv1.forward(xs)?;
        let mut parts = Vec::with_capacity(1 + self.kernel_sizes.len());
        parts.push(x.clone());
        for &k in &self.kernel_sizes {
            parts.push(max_pool2d_neg_inf_pad(&x, k)?);
        }
        let cat = Tensor::cat(&parts, 1)?;
        self.conv2.forward(&cat)
    }
}

/// Megvii `CSPDarknet` backbone emitting `(dark3, dark4, dark5)` feature maps.
#[derive(Debug, Clone)]
struct CSPDarknet {
    stem: Focus,
    dark2_conv: BaseConv,
    dark2_csp: CSPLayer,
    dark3_conv: BaseConv,
    dark3_csp: CSPLayer,
    dark4_conv: BaseConv,
    dark4_csp: CSPLayer,
    dark5_conv: BaseConv,
    dark5_spp: SPPBottleneck,
    dark5_csp: CSPLayer,
}

impl CSPDarknet {
    fn load(vb: VarBuilder, cfg: &YoloxDetectorConfig) -> CandleResult<Self> {
        let base_c = cfg.base_channels();
        let base_d = cfg.base_depth();

        let stem = Focus::load(vb.pp("stem"), 3, base_c, 3)?;

        let dark2_vb = vb.pp("dark2");
        let dark2_conv = BaseConv::load(dark2_vb.pp("0"), base_c, base_c * 2, 3, 2)?;
        let dark2_csp =
            CSPLayer::load(dark2_vb.pp("1"), base_c * 2, base_c * 2, base_d, true, 0.5)?;

        let dark3_vb = vb.pp("dark3");
        let dark3_conv = BaseConv::load(dark3_vb.pp("0"), base_c * 2, base_c * 4, 3, 2)?;
        let dark3_csp = CSPLayer::load(
            dark3_vb.pp("1"),
            base_c * 4,
            base_c * 4,
            base_d * 3,
            true,
            0.5,
        )?;

        let dark4_vb = vb.pp("dark4");
        let dark4_conv = BaseConv::load(dark4_vb.pp("0"), base_c * 4, base_c * 8, 3, 2)?;
        let dark4_csp = CSPLayer::load(
            dark4_vb.pp("1"),
            base_c * 8,
            base_c * 8,
            base_d * 3,
            true,
            0.5,
        )?;

        let dark5_vb = vb.pp("dark5");
        let dark5_conv = BaseConv::load(dark5_vb.pp("0"), base_c * 8, base_c * 16, 3, 2)?;
        let dark5_spp = SPPBottleneck::load(dark5_vb.pp("1"), base_c * 16, base_c * 16)?;
        let dark5_csp = CSPLayer::load(
            dark5_vb.pp("2"),
            base_c * 16,
            base_c * 16,
            base_d,
            false,
            0.5,
        )?;

        Ok(Self {
            stem,
            dark2_conv,
            dark2_csp,
            dark3_conv,
            dark3_csp,
            dark4_conv,
            dark4_csp,
            dark5_conv,
            dark5_spp,
            dark5_csp,
        })
    }

    fn forward(&self, xs: &Tensor) -> CandleResult<(Tensor, Tensor, Tensor)> {
        let x = self.stem.forward(xs)?;
        let x = self.dark2_csp.forward(&self.dark2_conv.forward(&x)?)?;
        let dark3 = self.dark3_csp.forward(&self.dark3_conv.forward(&x)?)?;
        let dark4 = self.dark4_csp.forward(&self.dark4_conv.forward(&dark3)?)?;
        let dark5 = self
            .dark5_csp
            .forward(&self.dark5_spp.forward(&self.dark5_conv.forward(&dark4)?)?)?;
        Ok((dark3, dark4, dark5))
    }
}

/// Megvii `YOLOPAFPN` neck wrapping `CSPDarknet` under `backbone.backbone` and emitting
/// `(pan_out2, pan_out1, pan_out0)` for strides `[8, 16, 32]`.
#[derive(Debug, Clone)]
struct YoloPafpn {
    backbone: CSPDarknet,
    lateral_conv0: BaseConv,
    c3_p4: CSPLayer,
    reduce_conv1: BaseConv,
    c3_p3: CSPLayer,
    bu_conv2: BaseConv,
    c3_n3: CSPLayer,
    bu_conv1: BaseConv,
    c3_n4: CSPLayer,
}

impl YoloPafpn {
    fn load(vb: VarBuilder, cfg: &YoloxDetectorConfig) -> CandleResult<Self> {
        let base_c = cfg.base_channels();
        let base_d = cfg.base_depth();
        let c3 = base_c * 4;
        let c4 = base_c * 8;
        let c5 = base_c * 16;

        let backbone = CSPDarknet::load(vb.pp("backbone"), cfg)?;
        let lateral_conv0 = BaseConv::load(vb.pp("lateral_conv0"), c5, c4, 1, 1)?;
        let c3_p4 = CSPLayer::load(vb.pp("C3_p4"), c4 + c4, c4, base_d, false, 0.5)?;
        let reduce_conv1 = BaseConv::load(vb.pp("reduce_conv1"), c4, c3, 1, 1)?;
        let c3_p3 = CSPLayer::load(vb.pp("C3_p3"), c3 + c3, c3, base_d, false, 0.5)?;
        let bu_conv2 = BaseConv::load(vb.pp("bu_conv2"), c3, c3, 3, 2)?;
        let c3_n3 = CSPLayer::load(vb.pp("C3_n3"), c3 + c3, c4, base_d, false, 0.5)?;
        let bu_conv1 = BaseConv::load(vb.pp("bu_conv1"), c4, c4, 3, 2)?;
        let c3_n4 = CSPLayer::load(vb.pp("C3_n4"), c4 + c4, c5, base_d, false, 0.5)?;

        Ok(Self {
            backbone,
            lateral_conv0,
            c3_p4,
            reduce_conv1,
            c3_p3,
            bu_conv2,
            c3_n3,
            bu_conv1,
            c3_n4,
        })
    }

    fn forward(&self, xs: &Tensor) -> CandleResult<[Tensor; 3]> {
        let (feat2, feat1, feat0) = self.backbone.forward(xs)?;

        let fpn_out0 = self.lateral_conv0.forward(&feat0)?;
        let (_, _, h1, w1) = feat1.dims4()?;
        let f_out0 = fpn_out0.upsample_nearest2d(h1, w1)?;
        let f_out0 = self.c3_p4.forward(&Tensor::cat(&[&f_out0, &feat1], 1)?)?;

        let fpn_out1 = self.reduce_conv1.forward(&f_out0)?;
        let (_, _, h2, w2) = feat2.dims4()?;
        let f_out1 = fpn_out1.upsample_nearest2d(h2, w2)?;
        let pan_out2 = self.c3_p3.forward(&Tensor::cat(&[&f_out1, &feat2], 1)?)?;

        let p_out1 = self.bu_conv2.forward(&pan_out2)?;
        let pan_out1 = self
            .c3_n3
            .forward(&Tensor::cat(&[&p_out1, &fpn_out1], 1)?)?;

        let p_out0 = self.bu_conv1.forward(&pan_out1)?;
        let pan_out0 = self
            .c3_n4
            .forward(&Tensor::cat(&[&p_out0, &fpn_out0], 1)?)?;

        Ok([pan_out2, pan_out1, pan_out0])
    }
}

/// Decoupled anchor-free `YOLOXHead` where `obj_preds` reads `reg_feat`.
#[derive(Debug, Clone)]
struct YoloxHead {
    stems: [BaseConv; 3],
    cls_convs: [[BaseConv; 2]; 3],
    reg_convs: [[BaseConv; 2]; 3],
    cls_preds: [Conv2d; 3],
    reg_preds: [Conv2d; 3],
    obj_preds: [Conv2d; 3],
    num_classes: usize,
}

impl YoloxHead {
    fn load(vb: VarBuilder, cfg: &YoloxDetectorConfig) -> CandleResult<Self> {
        let base_c = cfg.base_channels();
        let in_channels = [base_c * 4, base_c * 8, base_c * 16];
        let mid_c = cfg.head_mid_channels();
        let nc = cfg.num_classes;

        let stems = [
            BaseConv::load(vb.pp("stems.0"), in_channels[0], mid_c, 1, 1)?,
            BaseConv::load(vb.pp("stems.1"), in_channels[1], mid_c, 1, 1)?,
            BaseConv::load(vb.pp("stems.2"), in_channels[2], mid_c, 1, 1)?,
        ];
        let cls_convs = [
            [
                BaseConv::load(vb.pp("cls_convs.0.0"), mid_c, mid_c, 3, 1)?,
                BaseConv::load(vb.pp("cls_convs.0.1"), mid_c, mid_c, 3, 1)?,
            ],
            [
                BaseConv::load(vb.pp("cls_convs.1.0"), mid_c, mid_c, 3, 1)?,
                BaseConv::load(vb.pp("cls_convs.1.1"), mid_c, mid_c, 3, 1)?,
            ],
            [
                BaseConv::load(vb.pp("cls_convs.2.0"), mid_c, mid_c, 3, 1)?,
                BaseConv::load(vb.pp("cls_convs.2.1"), mid_c, mid_c, 3, 1)?,
            ],
        ];
        let reg_convs = [
            [
                BaseConv::load(vb.pp("reg_convs.0.0"), mid_c, mid_c, 3, 1)?,
                BaseConv::load(vb.pp("reg_convs.0.1"), mid_c, mid_c, 3, 1)?,
            ],
            [
                BaseConv::load(vb.pp("reg_convs.1.0"), mid_c, mid_c, 3, 1)?,
                BaseConv::load(vb.pp("reg_convs.1.1"), mid_c, mid_c, 3, 1)?,
            ],
            [
                BaseConv::load(vb.pp("reg_convs.2.0"), mid_c, mid_c, 3, 1)?,
                BaseConv::load(vb.pp("reg_convs.2.1"), mid_c, mid_c, 3, 1)?,
            ],
        ];
        let cls_preds = [
            conv2d(mid_c, nc, 1, Default::default(), vb.pp("cls_preds.0"))?,
            conv2d(mid_c, nc, 1, Default::default(), vb.pp("cls_preds.1"))?,
            conv2d(mid_c, nc, 1, Default::default(), vb.pp("cls_preds.2"))?,
        ];
        let reg_preds = [
            conv2d(mid_c, 4, 1, Default::default(), vb.pp("reg_preds.0"))?,
            conv2d(mid_c, 4, 1, Default::default(), vb.pp("reg_preds.1"))?,
            conv2d(mid_c, 4, 1, Default::default(), vb.pp("reg_preds.2"))?,
        ];
        let obj_preds = [
            conv2d(mid_c, 1, 1, Default::default(), vb.pp("obj_preds.0"))?,
            conv2d(mid_c, 1, 1, Default::default(), vb.pp("obj_preds.1"))?,
            conv2d(mid_c, 1, 1, Default::default(), vb.pp("obj_preds.2"))?,
        ];

        Ok(Self {
            stems,
            cls_convs,
            reg_convs,
            cls_preds,
            reg_preds,
            obj_preds,
            num_classes: nc,
        })
    }

    /// Emits flat row-major predictions of shape `[total_cells, 5 + num_classes]` where each row
    /// is `[reg_x, reg_y, reg_w, reg_h, obj_logit, cls_0, ..., cls_{C-1}]`.
    fn forward(&self, feats: &[Tensor; 3]) -> CandleResult<Vec<f32>> {
        let mut levels = Vec::with_capacity(3);
        for (k, feat) in feats.iter().enumerate() {
            let x = self.stems[k].forward(feat)?;
            let cls_feat = self.cls_convs[k][1].forward(&self.cls_convs[k][0].forward(&x)?)?;
            let reg_feat = self.reg_convs[k][1].forward(&self.reg_convs[k][0].forward(&x)?)?;

            let cls_out = self.cls_preds[k].forward(&cls_feat)?;
            let reg_out = self.reg_preds[k].forward(&reg_feat)?;
            let obj_out = self.obj_preds[k].forward(&reg_feat)?;

            let (b, _, gh, gw) = reg_out.dims4()?;
            let level = Tensor::cat(&[&reg_out, &obj_out, &cls_out], 1)?.reshape((
                b,
                5 + self.num_classes,
                gh * gw,
            ))?;
            levels.push(level);
        }

        Tensor::cat(&levels, 2)?
            .squeeze(0)?
            .transpose(0, 1)?
            .contiguous()?
            .to_device(&Device::Cpu)?
            .flatten_all()?
            .to_vec1::<f32>()
    }
}

/// Pure-Rust Apache-2.0 YOLOX object detector loaded from local `.safetensors` weights.
#[derive(Debug, Clone)]
pub struct YoloxDetector {
    backbone: YoloPafpn,
    head: YoloxHead,
    cfg: YoloxDetectorConfig,
    post: YoloxPostProcessor,
    device: Device,
}

impl YoloxDetector {
    /// Loads YOLOX weights (`F32` safetensors matching Megvii `yolox_s.pth` keys) and config.
    pub fn load(
        weights_path: &Path,
        cfg: YoloxDetectorConfig,
        device: &Device,
    ) -> Result<Self, MediaWorkerError> {
        cfg.validate()?;
        let post = YoloxPostProcessor::new(cfg.to_yolox_config())
            .map_err(|err| MediaWorkerError::inference_failed(err.to_string()))?;

        let bytes = std::fs::read(weights_path).map_err(|err| {
            MediaWorkerError::inference_failed(format!(
                "failed reading YOLOX weights '{}': {err}",
                weights_path.display()
            ))
        })?;
        let vb =
            VarBuilder::from_buffered_safetensors(bytes, DType::F32, device).map_err(|err| {
                MediaWorkerError::inference_failed(format!(
                    "failed loading YOLOX safetensors '{}': {err}",
                    weights_path.display()
                ))
            })?;
        let backbone = YoloPafpn::load(vb.pp("backbone"), &cfg).map_err(|err| {
            MediaWorkerError::inference_failed(format!("failed loading YOLOX backbone/neck: {err}"))
        })?;
        let head = YoloxHead::load(vb.pp("head"), &cfg).map_err(|err| {
            MediaWorkerError::inference_failed(format!("failed loading YOLOX detect head: {err}"))
        })?;

        Ok(Self {
            backbone,
            head,
            cfg,
            post,
            device: device.clone(),
        })
    }

    pub fn config(&self) -> &YoloxDetectorConfig {
        &self.cfg
    }

    /// Runs YOLOX forward pass on `frame` and returns normalized `[x1, y1, x2, y2]` detections.
    pub fn detect(
        &self,
        frame: &RgbFrame,
        min_confidence: f32,
    ) -> Result<Vec<RawDetection>, MediaWorkerError> {
        let dst_w = self.cfg.input_width as usize;
        let dst_h = self.cfg.input_height as usize;
        let lb = LetterboxTransform::compute(
            frame.width(),
            frame.height(),
            self.cfg.input_width,
            self.cfg.input_height,
        )
        .map_err(|err| MediaWorkerError::inference_failed(err.to_string()))?;

        let chw = letterbox_bgr_255_chw(frame, dst_w, dst_h, lb);
        let input = Tensor::from_vec(chw, (1, 3, dst_h, dst_w), &self.device).map_err(|err| {
            MediaWorkerError::inference_failed(format!("YOLOX input tensor failed: {err}"))
        })?;

        let feats = self.backbone.forward(&input).map_err(|err| {
            MediaWorkerError::inference_failed(format!("YOLOX backbone/neck forward failed: {err}"))
        })?;
        let raw = self.head.forward(&feats).map_err(|err| {
            MediaWorkerError::inference_failed(format!("YOLOX head forward failed: {err}"))
        })?;

        let effective_min_conf = min_confidence.max(self.cfg.confidence_threshold);
        let detections = self
            .post
            .decode(&raw, lb, effective_min_conf)
            .map_err(|err| MediaWorkerError::inference_failed(err.to_string()))?;

        let mut out = Vec::with_capacity(detections.len());
        for det in detections {
            if let Some(object_class) = object_category_to_class(det.label) {
                out.push(RawDetection::new(object_class, det.confidence, det.bbox));
            }
        }
        Ok(out)
    }
}

/// Resizes `frame` into a centered letterbox canvas of `(dst_w, dst_h)` in **BGR** channel
/// order, unnormalized `[0.0, 255.0]` `f32` values, padded with `114.0` (matching Megvii
/// `ValTransform(legacy=False)`).
pub(crate) fn letterbox_bgr_255_chw(
    frame: &RgbFrame,
    dst_w: usize,
    dst_h: usize,
    lb: LetterboxTransform,
) -> Vec<f32> {
    let sw = frame.width() as f32;
    let sh = frame.height() as f32;
    let new_w = ((sw * lb.scale).round() as usize).clamp(1, dst_w);
    let new_h = ((sh * lb.scale).round() as usize).clamp(1, dst_h);
    let pad_x = (lb.pad_x.round() as usize).min(dst_w.saturating_sub(new_w));
    let pad_y = (lb.pad_y.round() as usize).min(dst_h.saturating_sub(new_h));

    let plane = dst_w * dst_h;
    let mut chw = vec![YOLOX_LETTERBOX_PAD_VALUE; 3 * plane];
    let bgr_src_channels = [2usize, 1, 0];

    for dy in 0..new_h {
        let sy = ((dy as f32 + 0.5) * sh / (new_h as f32) - 0.5).clamp(0.0, sh - 1.0);
        let y0 = sy.floor() as u32;
        let y1 = (y0 + 1).min(frame.height() - 1);
        let fy = sy - (y0 as f32);

        for dx in 0..new_w {
            let sx = ((dx as f32 + 0.5) * sw / (new_w as f32) - 0.5).clamp(0.0, sw - 1.0);
            let x0 = sx.floor() as u32;
            let x1 = (x0 + 1).min(frame.width() - 1);
            let fx = sx - (x0 as f32);

            let p00 = frame.pixel_at(x0, y0);
            let p10 = frame.pixel_at(x1, y0);
            let p01 = frame.pixel_at(x0, y1);
            let p11 = frame.pixel_at(x1, y1);

            let out_idx = (pad_y + dy) * dst_w + (pad_x + dx);
            for (out_c, &src_c) in bgr_src_channels.iter().enumerate() {
                let top = (p00[src_c] as f32) * (1.0 - fx) + (p10[src_c] as f32) * fx;
                let bot = (p01[src_c] as f32) * (1.0 - fx) + (p11[src_c] as f32) * fx;
                chw[out_c * plane + out_idx] = top * (1.0 - fy) + bot * fy;
            }
        }
    }

    chw
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn focus_packs_spatial_patches_in_megvii_order() {
        // Shape (1, 2, 4, 4) with unique values per `(c, y, x)`.
        let mut data = Vec::with_capacity(2 * 4 * 4);
        for c in 0..2 {
            for y in 0..4 {
                for x in 0..4 {
                    data.push((c * 100 + y * 10 + x) as f32);
                }
            }
        }
        let input = Tensor::from_vec(data, (1, 2, 4, 4), &Device::Cpu).expect("input");
        let packed = Focus::pack_patches(&input).expect("pack patches");
        assert_eq!(packed.dims4().expect("dims"), (1, 8, 2, 2));

        let vals = packed
            .squeeze(0)
            .expect("squeeze")
            .to_vec3::<f32>()
            .expect("to_vec3");
        // Channel blocks:
        //   0..2: top_left (y%2==0, x%2==0)
        //   2..4: bot_left (y%2==1, x%2==0)
        //   4..6: top_right (y%2==0, x%2==1)
        //   6..8: bot_right (y%2==1, x%2==1)
        for c in 0..2 {
            let base = (c * 100) as f32;
            // (dy_out=1, dx_out=1) corresponds to original (y=2..4, x=2..4)
            assert_eq!(vals[c][1][1], base + 22.0); // top_left: y=2, x=2
            assert_eq!(vals[2 + c][1][1], base + 32.0); // bot_left: y=3, x=2
            assert_eq!(vals[4 + c][1][1], base + 23.0); // top_right: y=2, x=3
            assert_eq!(vals[6 + c][1][1], base + 33.0); // bot_right: y=3, x=3
        }
    }

    #[test]
    fn base_conv_uses_megvii_batch_norm_eps_1e_3() {
        // Populate exact known tensors directly through VarBuilder::from_tensors.
        let mut tensors = std::collections::HashMap::new();
        // 1x1 conv with weight = 1.0 -> passes input 1.0 through unchanged
        tensors.insert(
            "conv.weight".to_string(),
            Tensor::from_vec(vec![1.0f32], (1, 1, 1, 1), &Device::Cpu).unwrap(),
        );
        tensors.insert(
            "bn.weight".to_string(),
            Tensor::from_vec(vec![1.0f32], (1,), &Device::Cpu).unwrap(),
        );
        tensors.insert(
            "bn.bias".to_string(),
            Tensor::from_vec(vec![0.0f32], (1,), &Device::Cpu).unwrap(),
        );
        tensors.insert(
            "bn.running_mean".to_string(),
            Tensor::from_vec(vec![0.0f32], (1,), &Device::Cpu).unwrap(),
        );
        // With running_var = 0.0 and input = 0.1:
        // - eps = 1e-3 => bn_out = 0.1 / sqrt(1e-3) = 3.1622777
        // - eps = 1e-5 => bn_out = 0.1 / sqrt(1e-5) = 31.622776 (10x larger!)
        tensors.insert(
            "bn.running_var".to_string(),
            Tensor::from_vec(vec![0.0f32], (1,), &Device::Cpu).unwrap(),
        );
        let vb = VarBuilder::from_tensors(tensors, DType::F32, &Device::Cpu);
        let block = BaseConv::load(vb, 1, 1, 1, 1).expect("load BaseConv");

        let xs = Tensor::from_vec(vec![0.1f32], (1, 1, 1, 1), &Device::Cpu).unwrap();
        let ys = block
            .forward(&xs)
            .expect("forward")
            .flatten_all()
            .unwrap()
            .to_vec1::<f32>()
            .unwrap();
        let expected_bn = 0.1f32 / (1e-3f32).sqrt();
        let expected_silu = expected_bn / (1.0 + (-expected_bn).exp());
        assert!(
            (ys[0] - expected_silu).abs() < 1e-4,
            "expected SiLU(0.1/sqrt(1e-3)) = {expected_silu}, got {}",
            ys[0]
        );
    }

    #[test]
    fn spp_bottleneck_preserves_shape_and_applies_parallel_max_pool() {
        let mut tensors = std::collections::HashMap::new();
        // in_c = 2 -> hidden = 1, conv1 = identity on channel 0, zero on channel 1
        tensors.insert(
            "conv1.conv.weight".to_string(),
            Tensor::from_vec(vec![1.0f32, 0.0], (1, 2, 1, 1), &Device::Cpu).unwrap(),
        );
        tensors.insert(
            "conv1.bn.weight".to_string(),
            Tensor::from_vec(vec![1.0f32], (1,), &Device::Cpu).unwrap(),
        );
        tensors.insert(
            "conv1.bn.bias".to_string(),
            Tensor::from_vec(vec![0.0f32], (1,), &Device::Cpu).unwrap(),
        );
        tensors.insert(
            "conv1.bn.running_mean".to_string(),
            Tensor::from_vec(vec![0.0f32], (1,), &Device::Cpu).unwrap(),
        );
        tensors.insert(
            "conv1.bn.running_var".to_string(),
            Tensor::from_vec(vec![1.0f32 - 1e-3], (1,), &Device::Cpu).unwrap(),
        );

        // conv2 takes 4 * hidden = 4 channels -> 2 channels; check all 4 SPP branches feed it
        tensors.insert(
            "conv2.conv.weight".to_string(),
            Tensor::from_vec(vec![1.0f32; 8], (2, 4, 1, 1), &Device::Cpu).unwrap(),
        );
        tensors.insert(
            "conv2.bn.weight".to_string(),
            Tensor::from_vec(vec![1.0f32; 2], (2,), &Device::Cpu).unwrap(),
        );
        tensors.insert(
            "conv2.bn.bias".to_string(),
            Tensor::from_vec(vec![0.0f32; 2], (2,), &Device::Cpu).unwrap(),
        );
        tensors.insert(
            "conv2.bn.running_mean".to_string(),
            Tensor::from_vec(vec![0.0f32; 2], (2,), &Device::Cpu).unwrap(),
        );
        tensors.insert(
            "conv2.bn.running_var".to_string(),
            Tensor::from_vec(vec![1.0f32 - 1e-3; 2], (2,), &Device::Cpu).unwrap(),
        );

        let vb = VarBuilder::from_tensors(tensors, DType::F32, &Device::Cpu);
        let spp = SPPBottleneck::load(vb, 2, 2).expect("load SPPBottleneck");

        // 7x7 input with a peak at center (3, 3) so 5x5, 9x9, 13x13 pools propagate it differently.
        let mut input = vec![0.0f32; 2 * 7 * 7];
        input[3 * 7 + 3] = 4.0;
        let xs = Tensor::from_vec(input, (1, 2, 7, 7), &Device::Cpu).unwrap();
        let out = spp.forward(&xs).expect("spp forward");
        assert_eq!(out.dims4().expect("dims"), (1, 2, 7, 7));

        let vals = out
            .squeeze(0)
            .expect("squeeze")
            .to_vec3::<f32>()
            .expect("to_vec3");
        // At corner (0, 0): 5x5 pool doesn't reach (3,3), while 9x9 and 13x13 do.
        // At center (3, 3): all 4 branches (identity + 5x5 + 9x9 + 13x13) see peak > 0.
        assert!(vals[0][3][3] > vals[0][0][0]);
        assert!(vals[0][0][0] > 0.0);
    }

    #[test]
    fn spp_bottleneck_pads_with_neg_inf_not_zero_on_negative_borders() {
        // Direct check on `max_pool2d_neg_inf_pad`: uniform -0.25 must stay -0.25 at borders
        // rather than clamping to 0.0 (which zero-padding would cause).
        let neg = Tensor::full(-0.25f32, (1, 1, 7, 7), &Device::Cpu).unwrap();
        for k in [5usize, 9, 13] {
            let pooled = max_pool2d_neg_inf_pad(&neg, k)
                .unwrap()
                .squeeze(0)
                .unwrap()
                .squeeze(0)
                .unwrap()
                .to_vec2::<f32>()
                .unwrap();
            assert_eq!(pooled[0][0], -0.25, "k={k} corner must stay -0.25");
            assert_eq!(pooled[0][3], -0.25, "k={k} top edge must stay -0.25");
            assert_eq!(pooled[6][6], -0.25, "k={k} bottom-right must stay -0.25");
        }

        // End-to-end SPPBottleneck check: conv1 outputs uniform -0.25 across the 7x7 map
        // (since SiLU(-0.8351303) = -0.25). All 4 branches contribute -0.25 -> sum = -1.0
        // before conv2's SiLU, yielding SiLU(-1.0) instead of zero-padded SiLU(-0.25).
        let mut tensors = std::collections::HashMap::new();
        tensors.insert(
            "conv1.conv.weight".to_string(),
            Tensor::from_vec(vec![1.0f32, 0.0], (1, 2, 1, 1), &Device::Cpu).unwrap(),
        );
        tensors.insert(
            "conv1.bn.weight".to_string(),
            Tensor::from_vec(vec![1.0f32], (1,), &Device::Cpu).unwrap(),
        );
        tensors.insert(
            "conv1.bn.bias".to_string(),
            Tensor::from_vec(vec![0.0f32], (1,), &Device::Cpu).unwrap(),
        );
        tensors.insert(
            "conv1.bn.running_mean".to_string(),
            Tensor::from_vec(vec![0.0f32], (1,), &Device::Cpu).unwrap(),
        );
        tensors.insert(
            "conv1.bn.running_var".to_string(),
            Tensor::from_vec(vec![1.0f32 - 1e-3], (1,), &Device::Cpu).unwrap(),
        );
        tensors.insert(
            "conv2.conv.weight".to_string(),
            Tensor::from_vec(vec![1.0f32; 8], (2, 4, 1, 1), &Device::Cpu).unwrap(),
        );
        tensors.insert(
            "conv2.bn.weight".to_string(),
            Tensor::from_vec(vec![1.0f32; 2], (2,), &Device::Cpu).unwrap(),
        );
        tensors.insert(
            "conv2.bn.bias".to_string(),
            Tensor::from_vec(vec![0.0f32; 2], (2,), &Device::Cpu).unwrap(),
        );
        tensors.insert(
            "conv2.bn.running_mean".to_string(),
            Tensor::from_vec(vec![0.0f32; 2], (2,), &Device::Cpu).unwrap(),
        );
        tensors.insert(
            "conv2.bn.running_var".to_string(),
            Tensor::from_vec(vec![1.0f32 - 1e-3; 2], (2,), &Device::Cpu).unwrap(),
        );

        let vb = VarBuilder::from_tensors(tensors, DType::F32, &Device::Cpu);
        let spp = SPPBottleneck::load(vb, 2, 2).expect("load SPPBottleneck");

        // Solve SiLU(z) ≈ -0.25 -> z = -0.8147
        let z = -0.814_7f32;
        let xs = Tensor::full(z, (1, 2, 7, 7), &Device::Cpu).unwrap();
        let out = spp.forward(&xs).expect("spp forward");
        let vals = out
            .squeeze(0)
            .expect("squeeze")
            .to_vec3::<f32>()
            .expect("to_vec3");
        let expected_silu = |v: f32| v / (1.0 + (-v).exp());
        let conv1_out = expected_silu(z);
        assert!((conv1_out - (-0.25)).abs() < 1e-3);
        let expected = expected_silu(4.0 * conv1_out);
        let zero_padded_wrong = expected_silu(conv1_out);
        assert!(
            (vals[0][0][0] - expected).abs() < 1e-4,
            "border (0,0) expected SiLU(4 * {conv1_out})={expected}, got {} (zero-padded would be {zero_padded_wrong})",
            vals[0][0][0]
        );
        assert!((vals[0][0][0] - zero_padded_wrong).abs() > 0.1);
    }

    #[test]
    fn letterbox_bgr_255_chw_uses_bgr_255_scale_and_114_padding() {
        // 4x2 source frame with pure Red pixel (255, 10, 20) letterboxed into 4x4:
        // scale = 1.0, scaled = 4x2, pad_x = 0, pad_y = 1.
        let frame = RgbFrame::solid(4, 2, [255, 10, 20]);
        let lb = LetterboxTransform::compute(4, 2, 4, 4).expect("letterbox");
        let chw = letterbox_bgr_255_chw(&frame, 4, 4, lb);
        let plane = 4 * 4;
        assert_eq!(chw.len(), 3 * plane);

        // Top pad row (y=0) must be 114.0 across all 3 BGR channels.
        for c in 0..3 {
            for x in 0..4 {
                assert_eq!(chw[c * plane + x], 114.0);
                assert_eq!(chw[c * plane + 3 * 4 + x], 114.0);
            }
        }
        // Active row (y=1) must be BGR = [20.0, 10.0, 255.0] (NOT divided by 255.0!).
        assert!((chw[4] - 20.0).abs() < 1e-4); // B
        assert!((chw[plane + 4] - 10.0).abs() < 1e-4); // G
        assert!((chw[2 * plane + 4] - 255.0).abs() < 1e-4); // R
    }

    #[test]
    fn yolox_detector_config_defaults_and_rejects_non_yolox_family() {
        let cfg: YoloxDetectorConfig =
            serde_json::from_str("{}").expect("empty JSON fills defaults");
        assert_eq!(cfg, YoloxDetectorConfig::yolox_s());
        assert!((cfg.confidence_threshold - 0.35).abs() < 1e-6);
        assert!(cfg.apply_sigmoid);
        assert!(cfg.validate().is_ok());

        let wrong_family: YoloxDetectorConfig =
            serde_json::from_str(r#"{"family":"yolov8"}"#).expect("parse wrong family");
        assert!(wrong_family.validate().is_err());

        let bad_dims = YoloxDetectorConfig {
            input_width: 630,
            ..YoloxDetectorConfig::yolox_s()
        };
        assert!(bad_dims.validate().is_err());
    }
}
