//! Pure-Rust YOLOv8 object detector built on `candle-core` + `candle-nn`.
//!
//! Loads standard HuggingFace/Ultralytics YOLOv8 `.safetensors` weights
//! (`net.*`, `fpn.*`, `head.*`) from local disk with zero C/C++ dependencies
//! and maps COCO object classes into ServiceRadar's canonical `ObjectClass`.

use crate::backend::RawDetection;
use crate::errors::MediaWorkerError;
use crate::vision::{ObjectClass, RgbFrame};
use candle_core::{DType, Device, IndexOp, Module, ModuleT, Result as CandleResult, Tensor};
use candle_nn::{
    BatchNorm, BatchNormConfig, Conv2d, Conv2dConfig, VarBuilder, batch_norm, conv2d,
    conv2d_no_bias,
};
use serde::{Deserialize, Serialize};
use std::path::Path;

/// Maps a standard 80-class COCO index to ServiceRadar's `ObjectClass`.
pub fn coco_class_to_object_class(class_id: usize) -> Option<ObjectClass> {
    match class_id {
        0 => Some(ObjectClass::Person),              // person
        1 => Some(ObjectClass::Bicycle),             // bicycle
        2 | 3 | 5 | 7 => Some(ObjectClass::Vehicle), // car, motorcycle, bus, truck
        14 | 15 | 16 | 17 | 18 | 19 | 21 => Some(ObjectClass::Animal), // bird, cat, dog, horse, sheep, cow, bear
        24 | 26 | 28 => Some(ObjectClass::Package), // backpack, handbag, suitcase
        _ => None,
    }
}

/// Maps a COCO class name string to ServiceRadar's `ObjectClass`.
pub fn coco_name_to_object_class(name: &str) -> Option<ObjectClass> {
    match name.trim().to_ascii_lowercase().as_str() {
        "person" => Some(ObjectClass::Person),
        "car" | "truck" | "bus" | "motorcycle" => Some(ObjectClass::Vehicle),
        "bicycle" => Some(ObjectClass::Bicycle),
        "dog" | "cat" | "bird" | "horse" | "sheep" | "cow" | "bear" => Some(ObjectClass::Animal),
        "backpack" | "suitcase" | "handbag" => Some(ObjectClass::Package),
        _ => None,
    }
}

fn default_depth() -> f64 {
    0.33
}

fn default_width() -> f64 {
    0.25
}

fn default_ratio() -> f64 {
    2.0
}

fn default_num_classes() -> usize {
    80
}

fn default_input_size() -> usize {
    640
}

/// Configuration for loading a YOLOv8 `.safetensors` checkpoint (`detector_config.json`).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct YoloV8Config {
    #[serde(default = "default_depth")]
    pub depth: f64,
    #[serde(default = "default_width")]
    pub width: f64,
    #[serde(default = "default_ratio")]
    pub ratio: f64,
    #[serde(default = "default_num_classes")]
    pub num_classes: usize,
    #[serde(default = "default_input_size")]
    pub input_size: usize,
}

impl Default for YoloV8Config {
    fn default() -> Self {
        Self::n()
    }
}

impl YoloV8Config {
    /// Standard YOLOv8n (`640x640`, 80 COCO classes).
    pub fn n() -> Self {
        Self {
            depth: 0.33,
            width: 0.25,
            ratio: 2.0,
            num_classes: 80,
            input_size: 640,
        }
    }

    fn filters(&self) -> (usize, usize, usize) {
        let f1 = ((256.0 * self.width).round() as usize).max(4);
        let f2 = ((512.0 * self.width).round() as usize).max(4);
        let f3 = ((512.0 * self.width * self.ratio).round() as usize).max(4);
        (f1, f2, f3)
    }

    fn b1_out(&self) -> usize {
        ((64.0 * self.width).round() as usize).max(4)
    }

    fn b2_out(&self) -> usize {
        ((128.0 * self.width).round() as usize).max(4)
    }

    fn c2f_repeats(&self, base: usize) -> usize {
        ((base as f64 * self.depth).round() as usize).max(1)
    }
}

#[derive(Debug, Clone)]
struct Upsample {
    scale_factor: usize,
}

impl Upsample {
    fn new(scale_factor: usize) -> Self {
        Self { scale_factor }
    }
}

impl Module for Upsample {
    fn forward(&self, xs: &Tensor) -> CandleResult<Tensor> {
        let (_b, _c, h, w) = xs.dims4()?;
        xs.upsample_nearest2d(self.scale_factor * h, self.scale_factor * w)
    }
}

#[derive(Debug, Clone)]
struct ConvBlock {
    conv: Conv2d,
    bn: BatchNorm,
}

impl ConvBlock {
    fn load(
        vb: VarBuilder,
        c1: usize,
        c2: usize,
        k: usize,
        stride: usize,
        padding: Option<usize>,
    ) -> CandleResult<Self> {
        let padding = padding.unwrap_or(k / 2);
        let cfg = Conv2dConfig {
            padding,
            stride,
            groups: 1,
            dilation: 1,
            cudnn_fwd_algo: None,
        };
        let conv = conv2d_no_bias(c1, c2, k, cfg, vb.pp("conv"))?;
        let bn = batch_norm(c2, BatchNormConfig::default(), vb.pp("bn"))?;
        Ok(Self { conv, bn })
    }
}

impl Module for ConvBlock {
    fn forward(&self, xs: &Tensor) -> CandleResult<Tensor> {
        let xs = self.conv.forward(xs)?;
        let xs = self.bn.forward_t(&xs, false)?;
        candle_nn::ops::silu(&xs)
    }
}

#[derive(Debug, Clone)]
struct Bottleneck {
    cv1: ConvBlock,
    cv2: ConvBlock,
    residual: bool,
}

impl Bottleneck {
    fn load(vb: VarBuilder, c1: usize, c2: usize, shortcut: bool) -> CandleResult<Self> {
        let channel_factor = 1usize;
        let c_ = c2 / channel_factor;
        let cv1 = ConvBlock::load(vb.pp("cv1"), c1, c_, 3, 1, None)?;
        let cv2 = ConvBlock::load(vb.pp("cv2"), c_, c2, 3, 1, None)?;
        let residual = c1 == c2 && shortcut;
        Ok(Self { cv1, cv2, residual })
    }
}

impl Module for Bottleneck {
    fn forward(&self, xs: &Tensor) -> CandleResult<Tensor> {
        let ys = self.cv2.forward(&self.cv1.forward(xs)?)?;
        if self.residual { xs + ys } else { Ok(ys) }
    }
}

#[derive(Debug, Clone)]
struct C2f {
    cv1: ConvBlock,
    cv2: ConvBlock,
    bottleneck: Vec<Bottleneck>,
}

impl C2f {
    fn load(vb: VarBuilder, c1: usize, c2: usize, n: usize, shortcut: bool) -> CandleResult<Self> {
        let c = c2 / 2;
        let cv1 = ConvBlock::load(vb.pp("cv1"), c1, 2 * c, 1, 1, None)?;
        let cv2 = ConvBlock::load(vb.pp("cv2"), (2 + n) * c, c2, 1, 1, None)?;
        let mut bottleneck = Vec::with_capacity(n);
        for idx in 0..n {
            let b = Bottleneck::load(vb.pp(format!("bottleneck.{idx}")), c, c, shortcut)?;
            bottleneck.push(b);
        }
        Ok(Self {
            cv1,
            cv2,
            bottleneck,
        })
    }
}

impl Module for C2f {
    fn forward(&self, xs: &Tensor) -> CandleResult<Tensor> {
        let ys = self.cv1.forward(xs)?;
        let mut ys = ys.chunk(2, 1)?;
        for m in self.bottleneck.iter() {
            let last = ys.last().expect("chunk produces 2 tensors");
            ys.push(m.forward(last)?);
        }
        let zs = Tensor::cat(ys.as_slice(), 1)?;
        self.cv2.forward(&zs)
    }
}

#[derive(Debug, Clone)]
struct Sppf {
    cv1: ConvBlock,
    cv2: ConvBlock,
    k: usize,
}

impl Sppf {
    fn load(vb: VarBuilder, c1: usize, c2: usize, k: usize) -> CandleResult<Self> {
        let c_ = c1 / 2;
        let cv1 = ConvBlock::load(vb.pp("cv1"), c1, c_, 1, 1, None)?;
        let cv2 = ConvBlock::load(vb.pp("cv2"), c_ * 4, c2, 1, 1, None)?;
        Ok(Self { cv1, cv2, k })
    }
}

impl Module for Sppf {
    fn forward(&self, xs: &Tensor) -> CandleResult<Tensor> {
        let (_, _, _, _) = xs.dims4()?;
        let xs = self.cv1.forward(xs)?;
        let pad = self.k / 2;
        let xs2 = xs
            .pad_with_zeros(2, pad, pad)?
            .pad_with_zeros(3, pad, pad)?
            .max_pool2d_with_stride(self.k, 1)?;
        let xs3 = xs2
            .pad_with_zeros(2, pad, pad)?
            .pad_with_zeros(3, pad, pad)?
            .max_pool2d_with_stride(self.k, 1)?;
        let xs4 = xs3
            .pad_with_zeros(2, pad, pad)?
            .pad_with_zeros(3, pad, pad)?
            .max_pool2d_with_stride(self.k, 1)?;
        self.cv2.forward(&Tensor::cat(&[&xs, &xs2, &xs3, &xs4], 1)?)
    }
}

#[derive(Debug, Clone)]
struct Dfl {
    conv: Conv2d,
    num_classes: usize,
}

impl Dfl {
    fn load(vb: VarBuilder, num_classes: usize) -> CandleResult<Self> {
        let conv = conv2d_no_bias(num_classes, 1, 1, Default::default(), vb.pp("conv"))?;
        Ok(Self { conv, num_classes })
    }
}

impl Module for Dfl {
    fn forward(&self, xs: &Tensor) -> CandleResult<Tensor> {
        let (b_sz, _channels, anchors) = xs.dims3()?;
        let xs = xs
            .reshape((b_sz, 4, self.num_classes, anchors))?
            .transpose(2, 1)?;
        let xs = candle_nn::ops::softmax(&xs, 1)?;
        self.conv.forward(&xs)?.reshape((b_sz, 4, anchors))
    }
}

#[derive(Debug, Clone)]
struct DarkNet {
    b1_0: ConvBlock,
    b1_1: ConvBlock,
    b2_0: C2f,
    b2_1: ConvBlock,
    b2_2: C2f,
    b3_0: ConvBlock,
    b3_1: C2f,
    b4_0: ConvBlock,
    b4_1: C2f,
    b5_0: Sppf,
}

impl DarkNet {
    fn load(vb: VarBuilder, cfg: &YoloV8Config) -> CandleResult<Self> {
        let (f1, f2, f3) = cfg.filters();
        let b1_c = cfg.b1_out();
        let b2_c = cfg.b2_out();
        let n3 = cfg.c2f_repeats(3);
        let n6 = cfg.c2f_repeats(6);

        let b1_0 = ConvBlock::load(vb.pp("b1.0"), 3, b1_c, 3, 2, Some(1))?;
        let b1_1 = ConvBlock::load(vb.pp("b1.1"), b1_c, b2_c, 3, 2, Some(1))?;
        let b2_0 = C2f::load(vb.pp("b2.0"), b2_c, b2_c, n3, true)?;
        let b2_1 = ConvBlock::load(vb.pp("b2.1"), b2_c, f1, 3, 2, Some(1))?;
        let b2_2 = C2f::load(vb.pp("b2.2"), f1, f1, n6, true)?;
        let b3_0 = ConvBlock::load(vb.pp("b3.0"), f1, f2, 3, 2, Some(1))?;
        let b3_1 = C2f::load(vb.pp("b3.1"), f2, f2, n6, true)?;
        let b4_0 = ConvBlock::load(vb.pp("b4.0"), f2, f3, 3, 2, Some(1))?;
        let b4_1 = C2f::load(vb.pp("b4.1"), f3, f3, n3, true)?;
        let b5_0 = Sppf::load(vb.pp("b5.0"), f3, f3, 5)?;

        Ok(Self {
            b1_0,
            b1_1,
            b2_0,
            b2_1,
            b2_2,
            b3_0,
            b3_1,
            b4_0,
            b4_1,
            b5_0,
        })
    }

    fn forward(&self, xs: &Tensor) -> CandleResult<(Tensor, Tensor, Tensor)> {
        let x1 = self.b1_1.forward(&self.b1_0.forward(xs)?)?;
        let x2 = self
            .b2_2
            .forward(&self.b2_1.forward(&self.b2_0.forward(&x1)?)?)?;
        let x3 = self.b3_1.forward(&self.b3_0.forward(&x2)?)?;
        let x4 = self.b4_1.forward(&self.b4_0.forward(&x3)?)?;
        let x5 = self.b5_0.forward(&x4)?;
        Ok((x2, x3, x5))
    }
}

#[derive(Debug, Clone)]
struct YoloV8Neck {
    up: Upsample,
    n1: C2f,
    n2: C2f,
    n3: ConvBlock,
    n4: C2f,
    n5: ConvBlock,
    n6: C2f,
}

impl YoloV8Neck {
    fn load(vb: VarBuilder, cfg: &YoloV8Config) -> CandleResult<Self> {
        let (f1, f2, f3) = cfg.filters();
        let n = cfg.c2f_repeats(3);
        let up = Upsample::new(2);
        let n1 = C2f::load(vb.pp("n1"), f2 + f3, f2, n, false)?;
        let n2 = C2f::load(vb.pp("n2"), f1 + f2, f1, n, false)?;
        let n3 = ConvBlock::load(vb.pp("n3"), f1, f1, 3, 2, Some(1))?;
        let n4 = C2f::load(vb.pp("n4"), f1 + f2, f2, n, false)?;
        let n5 = ConvBlock::load(vb.pp("n5"), f2, f2, 3, 2, Some(1))?;
        let n6 = C2f::load(vb.pp("n6"), f2 + f3, f3, n, false)?;
        Ok(Self {
            up,
            n1,
            n2,
            n3,
            n4,
            n5,
            n6,
        })
    }

    fn forward(
        &self,
        p3: &Tensor,
        p4: &Tensor,
        p5: &Tensor,
    ) -> CandleResult<(Tensor, Tensor, Tensor)> {
        let x = self
            .n1
            .forward(&Tensor::cat(&[&self.up.forward(p5)?, p4], 1)?)?;
        let head_1 = self
            .n2
            .forward(&Tensor::cat(&[&self.up.forward(&x)?, p3], 1)?)?;
        let head_2 = self
            .n4
            .forward(&Tensor::cat(&[&self.n3.forward(&head_1)?, &x], 1)?)?;
        let head_3 = self
            .n6
            .forward(&Tensor::cat(&[&self.n5.forward(&head_2)?, p5], 1)?)?;
        Ok((head_1, head_2, head_3))
    }
}

#[derive(Debug, Clone)]
struct DetectionHead {
    dfl: Dfl,
    cv2: [(ConvBlock, ConvBlock, Conv2d); 3],
    cv3: [(ConvBlock, ConvBlock, Conv2d); 3],
    ch: usize,
    no: usize,
    span: Tensor,
}

impl DetectionHead {
    fn load(vb: VarBuilder, cfg: &YoloV8Config) -> CandleResult<Self> {
        let (f1, f2, f3) = cfg.filters();
        let ch = 16usize;
        let nc = cfg.num_classes;
        let no = nc + ch * 4;
        let c1 = (f1 / 4).max(ch * 4).max(16);
        let c2 = f1.max(nc.min(100));

        let dfl = Dfl::load(vb.pp("dfl"), ch)?;
        let cv2 = [
            Self::load_branch(vb.pp("cv2.0"), f1, c1, 4 * ch)?,
            Self::load_branch(vb.pp("cv2.1"), f2, c1, 4 * ch)?,
            Self::load_branch(vb.pp("cv2.2"), f3, c1, 4 * ch)?,
        ];
        let cv3 = [
            Self::load_branch(vb.pp("cv3.0"), f1, c2, nc)?,
            Self::load_branch(vb.pp("cv3.1"), f2, c2, nc)?,
            Self::load_branch(vb.pp("cv3.2"), f3, c2, nc)?,
        ];
        let span = Tensor::arange(0u32, ch as u32, vb.device())?.to_dtype(DType::F32)?;

        Ok(Self {
            dfl,
            cv2,
            cv3,
            ch,
            no,
            span,
        })
    }

    fn load_branch(
        vb: VarBuilder,
        in_c: usize,
        mid_c: usize,
        out_c: usize,
    ) -> CandleResult<(ConvBlock, ConvBlock, Conv2d)> {
        let b0 = ConvBlock::load(vb.pp("0"), in_c, mid_c, 3, 1, None)?;
        let b1 = ConvBlock::load(vb.pp("1"), mid_c, mid_c, 3, 1, None)?;
        let b2 = conv2d(mid_c, out_c, 1, Default::default(), vb.pp("2"))?;
        Ok((b0, b1, b2))
    }

    fn forward(&self, xs0: &Tensor, xs1: &Tensor, xs2: &Tensor) -> CandleResult<Tensor> {
        let inputs = [xs0, xs1, xs2];
        let mut outputs = Vec::with_capacity(3);
        let mut shapes = Vec::with_capacity(3);
        for (i, &x) in inputs.iter().enumerate() {
            let (b, _, h, w) = x.dims4()?;
            shapes.push((h, w));
            let reg = self.cv2[i]
                .2
                .forward(&self.cv2[i].1.forward(&self.cv2[i].0.forward(x)?)?)?;
            let cls = self.cv3[i]
                .2
                .forward(&self.cv3[i].1.forward(&self.cv3[i].0.forward(x)?)?)?;
            let cat = Tensor::cat(&[&reg, &cls], 1)?.reshape((b, self.no, h * w))?;
            outputs.push(cat);
        }

        let (anchors, strides) = make_anchors(&shapes, xs0.device())?;
        let x_cat = Tensor::cat(&outputs, 2)?;
        let box_part = x_cat.i((.., ..self.ch * 4, ..))?;
        let cls_part = x_cat.i((.., self.ch * 4.., ..))?;

        let dbox = self.dfl.forward(&box_part)?;
        let _ = &self.span;
        let lt = dbox.i((.., ..2, ..))?;
        let rb = dbox.i((.., 2.., ..))?;
        let x1y1 = anchors.broadcast_sub(&lt)?;
        let x2y2 = anchors.broadcast_add(&rb)?;
        let c_xy = ((&x1y1 + &x2y2)? * 0.5)?;
        let wh = (&x2y2 - &x1y1)?;
        let decoded_box = Tensor::cat(&[&c_xy, &wh], 1)?.broadcast_mul(&strides)?;
        let probs = candle_nn::ops::sigmoid(&cls_part)?;
        Tensor::cat(&[&decoded_box, &probs], 1)
    }
}

fn make_anchors(shapes: &[(usize, usize)], device: &Device) -> CandleResult<(Tensor, Tensor)> {
    let strides_val = [8.0f32, 16.0f32, 32.0f32];
    let mut anchor_points = Vec::with_capacity(3);
    let mut stride_tensors = Vec::with_capacity(3);

    for (&(h, w), &stride) in shapes.iter().zip(strides_val.iter()) {
        let sx = (Tensor::arange(0u32, w as u32, device)?.to_dtype(DType::F32)? + 0.5)?;
        let sy = (Tensor::arange(0u32, h as u32, device)?.to_dtype(DType::F32)? + 0.5)?;
        let grid_x = sx.unsqueeze(0)?.repeat((h, 1))?.flatten_all()?;
        let grid_y = sy.unsqueeze(1)?.repeat((1, w))?.flatten_all()?;
        anchor_points.push(Tensor::stack(&[&grid_x, &grid_y], 0)?);
        stride_tensors.push(Tensor::full(stride, (1, h * w), device)?);
    }

    let anchors = Tensor::cat(&anchor_points, 1)?.unsqueeze(0)?;
    let strides = Tensor::cat(&stride_tensors, 1)?.unsqueeze(0)?;
    Ok((anchors, strides))
}

/// Pure-Rust YOLOv8 detector loaded from local `.safetensors` weights.
#[derive(Debug, Clone)]
pub struct YoloV8Detector {
    net: DarkNet,
    fpn: YoloV8Neck,
    head: DetectionHead,
    cfg: YoloV8Config,
    device: Device,
}

impl YoloV8Detector {
    /// Loads YOLOv8 weights from a local `.safetensors` file and optional config.
    pub fn load(
        weights_path: &Path,
        cfg: YoloV8Config,
        device: &Device,
    ) -> Result<Self, MediaWorkerError> {
        let bytes = std::fs::read(weights_path).map_err(|err| {
            MediaWorkerError::inference_failed(format!(
                "failed reading YOLOv8 weights '{}': {err}",
                weights_path.display()
            ))
        })?;
        let vb =
            VarBuilder::from_buffered_safetensors(bytes, DType::F32, device).map_err(|err| {
                MediaWorkerError::inference_failed(format!(
                    "failed loading YOLOv8 safetensors '{}': {err}",
                    weights_path.display()
                ))
            })?;
        let net = DarkNet::load(vb.pp("net"), &cfg).map_err(|err| {
            MediaWorkerError::inference_failed(format!("failed loading YOLOv8 backbone: {err}"))
        })?;
        let fpn = YoloV8Neck::load(vb.pp("fpn"), &cfg).map_err(|err| {
            MediaWorkerError::inference_failed(format!("failed loading YOLOv8 neck: {err}"))
        })?;
        let head = DetectionHead::load(vb.pp("head"), &cfg).map_err(|err| {
            MediaWorkerError::inference_failed(format!("failed loading YOLOv8 detect head: {err}"))
        })?;
        Ok(Self {
            net,
            fpn,
            head,
            cfg,
            device: device.clone(),
        })
    }

    /// Runs YOLOv8 forward pass on `frame`, maps COCO classes to `ObjectClass`,
    /// and returns normalized `[x1, y1, x2, y2]` detections above `min_confidence`.
    pub fn detect(
        &self,
        frame: &RgbFrame,
        min_confidence: f32,
    ) -> Result<Vec<RawDetection>, MediaWorkerError> {
        let input_size = self.cfg.input_size;
        let (chw, scale, pad_x, pad_y) = letterbox_rgb_to_chw(frame, input_size);
        let input =
            Tensor::from_vec(chw, (1, 3, input_size, input_size), &self.device).map_err(|err| {
                MediaWorkerError::inference_failed(format!("YOLOv8 input tensor failed: {err}"))
            })?;

        let (p3, p4, p5) = self.net.forward(&input).map_err(|err| {
            MediaWorkerError::inference_failed(format!("YOLOv8 backbone forward failed: {err}"))
        })?;
        let (h1, h2, h3) = self.fpn.forward(&p3, &p4, &p5).map_err(|err| {
            MediaWorkerError::inference_failed(format!("YOLOv8 neck forward failed: {err}"))
        })?;
        let pred = self
            .head
            .forward(&h1, &h2, &h3)
            .and_then(|t| t.squeeze(0))
            .and_then(|t| t.to_device(&Device::Cpu))
            .map_err(|err| {
                MediaWorkerError::inference_failed(format!("YOLOv8 head forward failed: {err}"))
            })?;

        let (rows, num_anchors) = pred.dims2().map_err(|err| {
            MediaWorkerError::inference_failed(format!("unexpected YOLOv8 output dims: {err}"))
        })?;
        if rows < 5 {
            return Ok(Vec::new());
        }
        let flat = pred
            .flatten_all()
            .and_then(|t| t.to_vec1::<f32>())
            .map_err(|err| {
                MediaWorkerError::inference_failed(format!("failed reading YOLOv8 output: {err}"))
            })?;

        let num_classes = rows - 4;
        let orig_w = frame.width() as f32;
        let orig_h = frame.height() as f32;
        let mut detections = Vec::new();

        for a in 0..num_anchors {
            let mut best_cls = 0usize;
            let mut best_score = 0.0f32;
            for c in 0..num_classes {
                let score = flat[(4 + c) * num_anchors + a];
                if score > best_score {
                    best_score = score;
                    best_cls = c;
                }
            }
            if !best_score.is_finite() || best_score < min_confidence {
                continue;
            }
            let Some(object_class) = coco_class_to_object_class(best_cls) else {
                continue;
            };

            let cx = flat[a];
            let cy = flat[num_anchors + a];
            let bw = flat[2 * num_anchors + a];
            let bh = flat[3 * num_anchors + a];
            if !cx.is_finite() || !cy.is_finite() || !bw.is_finite() || !bh.is_finite() {
                continue;
            }

            let x1 = ((cx - bw * 0.5) - pad_x) / (scale * orig_w);
            let y1 = ((cy - bh * 0.5) - pad_y) / (scale * orig_h);
            let x2 = ((cx + bw * 0.5) - pad_x) / (scale * orig_w);
            let y2 = ((cy + bh * 0.5) - pad_y) / (scale * orig_h);

            let cx1 = x1.clamp(0.0, 0.999);
            let cy1 = y1.clamp(0.0, 0.999);
            let cx2 = x2.clamp(cx1 + 0.001, 1.0);
            let cy2 = y2.clamp(cy1 + 0.001, 1.0);

            detections.push(RawDetection::new(
                object_class,
                best_score,
                [cx1, cy1, cx2, cy2],
            ));
        }

        Ok(detections)
    }
}

fn letterbox_rgb_to_chw(frame: &RgbFrame, target: usize) -> (Vec<f32>, f32, f32, f32) {
    let sw = frame.width() as f32;
    let sh = frame.height() as f32;
    let t = target as f32;
    let scale = (t / sw).min(t / sh);
    let new_w = ((sw * scale).round() as usize).clamp(1, target);
    let new_h = ((sh * scale).round() as usize).clamp(1, target);
    let pad_x = (target - new_w) / 2;
    let pad_y = (target - new_h) / 2;

    let plane = target * target;
    let fill = 114.0f32 / 255.0;
    let mut chw = vec![fill; 3 * plane];

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

            let out_idx = (pad_y + dy) * target + (pad_x + dx);
            for c in 0..3 {
                let top = (p00[c] as f32) * (1.0 - fx) + (p10[c] as f32) * fx;
                let bot = (p01[c] as f32) * (1.0 - fx) + (p11[c] as f32) * fx;
                let val = (top * (1.0 - fy) + bot * fy) / 255.0;
                chw[c * plane + out_idx] = val;
            }
        }
    }

    (chw, scale, pad_x as f32, pad_y as f32)
}
