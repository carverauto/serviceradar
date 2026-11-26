//! Pure-Rust bounded JPEG keyframe thumbnail encoder.
//!
//! Downscales an [`RgbFrame`] to fit within configurable thumbnail dimensions (default
//! `480x270`) while preserving aspect ratio, encodes a standards-compliant Baseline
//! Sequential JFIF JPEG (SOF0, 8-bit YCbCr 4:4:4, Annex K quantization & Huffman tables)
//! with zero external C/C++ or crate dependencies, enforces a strict maximum byte size
//! ceiling (`max_bytes`), and attaches a SHA-256 hex digest.

use crate::error::MediaCoreError;
use crate::frame::RgbFrame;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::f32::consts::PI;

/// Configuration for bounded JPEG thumbnail generation.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ThumbnailConfig {
    /// Maximum thumbnail width in pixels (default `480`).
    pub max_width: u32,
    /// Maximum thumbnail height in pixels (default `270`).
    pub max_height: u32,
    /// Initial JPEG quality in `1..=100` (default `75`).
    pub quality: u8,
    /// Lowest JPEG quality allowed while shrinking to fit `max_bytes` (default `30`).
    pub min_quality: u8,
    /// Hard maximum JPEG payload size in bytes (default `32 KiB`).
    pub max_bytes: usize,
}

impl Default for ThumbnailConfig {
    fn default() -> Self {
        Self {
            max_width: 480,
            max_height: 270,
            quality: 75,
            min_quality: 30,
            max_bytes: 32 * 1024,
        }
    }
}

impl ThumbnailConfig {
    pub fn validate(&self) -> Result<(), MediaCoreError> {
        if self.max_width == 0 || self.max_height == 0 {
            return Err(MediaCoreError::invalid_configuration(
                "thumbnail max_width and max_height must be non-zero",
            ));
        }
        if self.quality == 0
            || self.quality > 100
            || self.min_quality == 0
            || self.min_quality > 100
        {
            return Err(MediaCoreError::invalid_configuration(
                "thumbnail quality and min_quality must be in 1..=100",
            ));
        }
        if self.min_quality > self.quality {
            return Err(MediaCoreError::invalid_configuration(
                "thumbnail min_quality cannot exceed quality",
            ));
        }
        if self.max_bytes < 512 {
            return Err(MediaCoreError::invalid_configuration(
                "thumbnail max_bytes must be at least 512 bytes",
            ));
        }
        Ok(())
    }
}

/// Encoded JPEG thumbnail payload with dimensions, quality, and SHA-256 digest.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EncodedThumbnail {
    pub width: u32,
    pub height: u32,
    pub quality: u8,
    pub jpeg_bytes: Vec<u8>,
    pub sha256_hex: String,
}

/// Downscales `frame` to fit within `config.max_width x config.max_height` and encodes a
/// bounded Baseline JPEG whose byte length does not exceed `config.max_bytes`.
pub fn encode_jpeg_thumbnail(
    frame: &RgbFrame,
    config: &ThumbnailConfig,
) -> Result<EncodedThumbnail, MediaCoreError> {
    config.validate()?;
    if frame.width() == 0 || frame.height() == 0 {
        return Err(MediaCoreError::invalid_frame(
            "cannot encode thumbnail from empty frame",
        ));
    }

    let mut cur = downscale_rgb_fit(frame, config.max_width, config.max_height);
    let mut quality = config.quality;

    loop {
        let jpeg_bytes = encode_baseline_jpeg(&cur, quality)?;
        if jpeg_bytes.len() <= config.max_bytes {
            let sha256_hex = hex::encode(Sha256::digest(&jpeg_bytes));
            return Ok(EncodedThumbnail {
                width: cur.width(),
                height: cur.height(),
                quality,
                jpeg_bytes,
                sha256_hex,
            });
        }

        if quality > config.min_quality {
            quality = quality.saturating_sub(15).max(config.min_quality);
            continue;
        }

        if cur.width() > 32 || cur.height() > 32 {
            let next_w = if cur.width() > 32 {
                ((cur.width() * 3) / 4).max(32)
            } else {
                cur.width()
            };
            let next_h = if cur.height() > 32 {
                ((cur.height() * 3) / 4).max(32)
            } else {
                cur.height()
            };
            let next = downscale_rgb_fit(&cur, next_w, next_h);
            if next.width() < cur.width() || next.height() < cur.height() {
                cur = next;
                continue;
            }
        }

        return Err(MediaCoreError::thumbnail(format!(
            "encoded thumbnail ({} bytes at {}x{}, q={quality}) exceeds max_bytes ({})",
            jpeg_bytes.len(),
            cur.width(),
            cur.height(),
            config.max_bytes
        )));
    }
}

/// Aspect-preserving box-filter downscaler for RGB8 frames.
pub fn downscale_rgb_fit(frame: &RgbFrame, max_width: u32, max_height: u32) -> RgbFrame {
    let sw = frame.width();
    let sh = frame.height();
    if sw <= max_width && sh <= max_height {
        return frame.clone();
    }

    let scale_x = (max_width as f32) / (sw as f32);
    let scale_y = (max_height as f32) / (sh as f32);
    let scale = scale_x.min(scale_y);
    let dw = ((sw as f32) * scale).round().max(1.0) as u32;
    let dh = ((sh as f32) * scale).round().max(1.0) as u32;

    let mut out = Vec::with_capacity((dw as usize) * (dh as usize) * 3);
    for dy in 0..dh {
        let sy0 = ((dy as u64) * (sh as u64) / (dh as u64)) as u32;
        let sy1 = ((((dy + 1) as u64) * (sh as u64)) / (dh as u64))
            .max(u64::from(sy0 + 1))
            .min(u64::from(sh)) as u32;
        for dx in 0..dw {
            let sx0 = ((dx as u64) * (sw as u64) / (dw as u64)) as u32;
            let sx1 = ((((dx + 1) as u64) * (sw as u64)) / (dw as u64))
                .max(u64::from(sx0 + 1))
                .min(u64::from(sw)) as u32;
            let mut r_sum = 0u64;
            let mut g_sum = 0u64;
            let mut b_sum = 0u64;
            let mut cnt = 0u64;
            for sy in sy0..sy1 {
                for sx in sx0..sx1 {
                    let p = frame.pixel_at(sx, sy);
                    r_sum += u64::from(p[0]);
                    g_sum += u64::from(p[1]);
                    b_sum += u64::from(p[2]);
                    cnt += 1;
                }
            }
            let c = cnt.max(1);
            out.push((r_sum / c) as u8);
            out.push((g_sum / c) as u8);
            out.push((b_sum / c) as u8);
        }
    }

    RgbFrame::from_rgb8(dw, dh, out).expect("downscaled buffer matches dw*dh*3")
}

// ----------------------------------------------------------------------------
// Pure-Rust Baseline Sequential JFIF JPEG Encoder (SOF0, 8-bit YCbCr 4:4:4)
// ----------------------------------------------------------------------------

const ZIGZAG: [usize; 64] = [
    0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20,
    13, 6, 7, 14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59,
    52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
];

const STD_LUM_QUANT: [u16; 64] = [
    16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56,
    14, 17, 22, 29, 51, 87, 80, 62, 18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113,
    92, 49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99,
];

const STD_CHROM_QUANT: [u16; 64] = [
    17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99, 24, 26, 56, 99, 99, 99, 99, 99,
    47, 66, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
];

const STD_DC_LUM_NRCODES: [u8; 16] = [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0];
const STD_DC_LUM_VALUES: [u8; 12] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];

const STD_DC_CHROM_NRCODES: [u8; 16] = [0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0];
const STD_DC_CHROM_VALUES: [u8; 12] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];

const STD_AC_LUM_NRCODES: [u8; 16] = [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 125];
const STD_AC_LUM_VALUES: [u8; 162] = [
    0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
    0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
    0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
    0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
    0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
    0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
    0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
    0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
    0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
    0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
    0xf9, 0xfa,
];

const STD_AC_CHROM_NRCODES: [u8; 16] = [0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 119];
const STD_AC_CHROM_VALUES: [u8; 162] = [
    0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
    0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0,
    0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
    0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
    0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
    0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
    0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5,
    0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3,
    0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
    0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
    0xf9, 0xfa,
];

#[derive(Clone, Copy, Default)]
struct HuffCode {
    code: u16,
    len: u8,
}

fn build_huffman_table(nrcodes: &[u8; 16], values: &[u8]) -> [HuffCode; 256] {
    let mut table = [HuffCode::default(); 256];
    let mut code = 0u16;
    let mut val_idx = 0usize;
    for (len_minus_1, &count) in nrcodes.iter().enumerate() {
        let bit_len = (len_minus_1 + 1) as u8;
        for _ in 0..count {
            let sym = values[val_idx] as usize;
            table[sym] = HuffCode { code, len: bit_len };
            code += 1;
            val_idx += 1;
        }
        code <<= 1;
    }
    table
}

fn scale_quant_table(base: &[u16; 64], quality: u8) -> [u8; 64] {
    let q = u32::from(quality.clamp(1, 100));
    let scale = if q < 50 { 5000 / q } else { 200 - 2 * q };
    let mut out = [1u8; 64];
    for (dst, &b) in out.iter_mut().zip(base.iter()) {
        let v = ((u32::from(b) * scale + 50) / 100).clamp(1, 255);
        *dst = v as u8;
    }
    out
}

fn build_dct_cos_table() -> [[f32; 8]; 8] {
    let mut cos_t = [[0.0f32; 8]; 8];
    for (u, row) in cos_t.iter_mut().enumerate() {
        let cu = if u == 0 { 1.0 / 2.0f32.sqrt() } else { 1.0 };
        for (x, slot) in row.iter_mut().enumerate() {
            *slot = 0.5 * cu * (((2 * x + 1) as f32) * (u as f32) * PI / 16.0).cos();
        }
    }
    cos_t
}

fn forward_dct_8x8(block: &[f32; 64], cos_t: &[[f32; 8]; 8]) -> [f32; 64] {
    // Separable 2D DCT: tmp = C * block, out = tmp * C^T
    let mut tmp = [0.0f32; 64];
    for r in 0..8 {
        for c in 0..8 {
            let mut sum = 0.0f32;
            for k in 0..8 {
                sum += block[r * 8 + k] * cos_t[c][k];
            }
            tmp[r * 8 + c] = sum;
        }
    }
    let mut out = [0.0f32; 64];
    for r in 0..8 {
        for c in 0..8 {
            let mut sum = 0.0f32;
            for k in 0..8 {
                sum += cos_t[r][k] * tmp[k * 8 + c];
            }
            out[r * 8 + c] = sum;
        }
    }
    out
}

struct JpegBitWriter {
    buf: Vec<u8>,
    bit_buf: u32,
    bit_count: u8,
}

impl JpegBitWriter {
    fn new(capacity: usize) -> Self {
        Self {
            buf: Vec::with_capacity(capacity),
            bit_buf: 0,
            bit_count: 0,
        }
    }

    fn write_bits(&mut self, value: u16, len: u8) {
        if len == 0 {
            return;
        }
        let mask = (1u32 << len) - 1;
        self.bit_buf = (self.bit_buf << len) | (u32::from(value) & mask);
        self.bit_count += len;
        while self.bit_count >= 8 {
            self.bit_count -= 8;
            let byte = ((self.bit_buf >> self.bit_count) & 0xFF) as u8;
            self.buf.push(byte);
            if byte == 0xFF {
                self.buf.push(0x00);
            }
        }
    }

    fn flush(&mut self) {
        if self.bit_count > 0 {
            let pad = 8 - self.bit_count;
            let ones = (1u16 << pad) - 1;
            self.write_bits(ones, pad);
        }
    }

    fn encode_block(
        &mut self,
        dct: &[f32; 64],
        quant: &[u8; 64],
        prev_dc: &mut i32,
        dc_table: &[HuffCode; 256],
        ac_table: &[HuffCode; 256],
    ) {
        let mut zz = [0i32; 64];
        for (i, &z_idx) in ZIGZAG.iter().enumerate() {
            zz[i] = (dct[z_idx] / f32::from(quant[z_idx])).round() as i32;
        }

        // DC differential
        let dc_diff = zz[0] - *prev_dc;
        *prev_dc = zz[0];
        let (dc_cat, dc_bits) = encode_magnitude(dc_diff);
        let h_dc = dc_table[dc_cat as usize];
        self.write_bits(h_dc.code, h_dc.len);
        self.write_bits(dc_bits, dc_cat);

        // AC run-length encoding
        let mut zero_run = 0u8;
        for &coeff in &zz[1..] {
            if coeff == 0 {
                zero_run += 1;
            } else {
                while zero_run >= 16 {
                    let zrl = ac_table[0xF0];
                    self.write_bits(zrl.code, zrl.len);
                    zero_run -= 16;
                }
                let (cat, bits) = encode_magnitude(coeff);
                let sym = ((zero_run << 4) | cat) as usize;
                let h_ac = ac_table[sym];
                self.write_bits(h_ac.code, h_ac.len);
                self.write_bits(bits, cat);
                zero_run = 0;
            }
        }
        if zero_run > 0 {
            let eob = ac_table[0x00];
            self.write_bits(eob.code, eob.len);
        }
    }
}

fn encode_magnitude(val: i32) -> (u8, u16) {
    if val == 0 {
        return (0, 0);
    }
    let abs = val.unsigned_abs();
    let cat = (32 - abs.leading_zeros()) as u8;
    let bits = if val > 0 {
        val as u16
    } else {
        ((val + ((1i32 << cat) - 1)) as u16) & ((1u16 << cat) - 1)
    };
    (cat, bits)
}

fn write_dqt(out: &mut Vec<u8>, table_id: u8, quant: &[u8; 64]) {
    out.extend_from_slice(&[0xFF, 0xDB, 0x00, 0x43, table_id]);
    for &z_idx in &ZIGZAG {
        out.push(quant[z_idx]);
    }
}

fn write_dht(out: &mut Vec<u8>, table_class_and_id: u8, nrcodes: &[u8; 16], values: &[u8]) {
    let len = (2 + 1 + 16 + values.len()) as u16;
    out.push(0xFF);
    out.push(0xC4);
    out.extend_from_slice(&len.to_be_bytes());
    out.push(table_class_and_id);
    out.extend_from_slice(nrcodes);
    out.extend_from_slice(values);
}

fn encode_baseline_jpeg(frame: &RgbFrame, quality: u8) -> Result<Vec<u8>, MediaCoreError> {
    let w = u16::try_from(frame.width())
        .map_err(|_| MediaCoreError::thumbnail("frame width exceeds JPEG u16 limit"))?;
    let h = u16::try_from(frame.height())
        .map_err(|_| MediaCoreError::thumbnail("frame height exceeds JPEG u16 limit"))?;

    let q_lum = scale_quant_table(&STD_LUM_QUANT, quality);
    let q_chrom = scale_quant_table(&STD_CHROM_QUANT, quality);
    let dc_lum = build_huffman_table(&STD_DC_LUM_NRCODES, &STD_DC_LUM_VALUES);
    let ac_lum = build_huffman_table(&STD_AC_LUM_NRCODES, &STD_AC_LUM_VALUES);
    let dc_chrom = build_huffman_table(&STD_DC_CHROM_NRCODES, &STD_DC_CHROM_VALUES);
    let ac_chrom = build_huffman_table(&STD_AC_CHROM_NRCODES, &STD_AC_CHROM_VALUES);
    let cos_t = build_dct_cos_table();

    let mut out = Vec::with_capacity(((w as usize) * (h as usize) / 2).max(1024));
    // SOI
    out.extend_from_slice(&[0xFF, 0xD8]);
    // APP0 (JFIF 1.01)
    out.extend_from_slice(&[
        0xFF, 0xE0, 0x00, 0x10, b'J', b'F', b'I', b'F', 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00,
        0x01, 0x00, 0x00,
    ]);
    // DQT
    write_dqt(&mut out, 0x00, &q_lum);
    write_dqt(&mut out, 0x01, &q_chrom);
    // SOF0 (Baseline DCT, 8-bit, 3 components 4:4:4)
    out.extend_from_slice(&[0xFF, 0xC0, 0x00, 0x11, 0x08]);
    out.extend_from_slice(&h.to_be_bytes());
    out.extend_from_slice(&w.to_be_bytes());
    out.extend_from_slice(&[
        0x03, // 3 components
        0x01, 0x11, 0x00, // Y: 1x1 sampling, quant table 0
        0x02, 0x11, 0x01, // Cb: 1x1 sampling, quant table 1
        0x03, 0x11, 0x01, // Cr: 1x1 sampling, quant table 1
    ]);
    // DHT
    write_dht(&mut out, 0x00, &STD_DC_LUM_NRCODES, &STD_DC_LUM_VALUES);
    write_dht(&mut out, 0x10, &STD_AC_LUM_NRCODES, &STD_AC_LUM_VALUES);
    write_dht(&mut out, 0x01, &STD_DC_CHROM_NRCODES, &STD_DC_CHROM_VALUES);
    write_dht(&mut out, 0x11, &STD_AC_CHROM_NRCODES, &STD_AC_CHROM_VALUES);
    // SOS
    out.extend_from_slice(&[
        0xFF, 0xDA, 0x00, 0x0C, 0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11, 0x00, 0x3F, 0x00,
    ]);

    let mut bw = JpegBitWriter::new(((w as usize) * (h as usize) / 2).max(512));
    let mut prev_dc_y = 0i32;
    let mut prev_dc_cb = 0i32;
    let mut prev_dc_cr = 0i32;

    let mut y_block = [0.0f32; 64];
    let mut cb_block = [0.0f32; 64];
    let mut cr_block = [0.0f32; 64];

    let max_x = frame.width() - 1;
    let max_y = frame.height() - 1;

    let mut by = 0u32;
    while by < frame.height() {
        let mut bx = 0u32;
        while bx < frame.width() {
            for dy in 0..8u32 {
                let py = (by + dy).min(max_y);
                for dx in 0..8u32 {
                    let px = (bx + dx).min(max_x);
                    let [r, g, b] = frame.pixel_at(px, py);
                    let rf = f32::from(r);
                    let gf = f32::from(g);
                    let bf = f32::from(b);
                    let idx = (dy as usize) * 8 + (dx as usize);
                    y_block[idx] = (0.299 * rf + 0.587 * gf + 0.114 * bf) - 128.0;
                    cb_block[idx] = -0.168736 * rf - 0.331264 * gf + 0.5 * bf;
                    cr_block[idx] = 0.5 * rf - 0.418688 * gf - 0.081312 * bf;
                }
            }

            let y_dct = forward_dct_8x8(&y_block, &cos_t);
            let cb_dct = forward_dct_8x8(&cb_block, &cos_t);
            let cr_dct = forward_dct_8x8(&cr_block, &cos_t);

            bw.encode_block(&y_dct, &q_lum, &mut prev_dc_y, &dc_lum, &ac_lum);
            bw.encode_block(&cb_dct, &q_chrom, &mut prev_dc_cb, &dc_chrom, &ac_chrom);
            bw.encode_block(&cr_dct, &q_chrom, &mut prev_dc_cr, &dc_chrom, &ac_chrom);

            bx += 8;
        }
        by += 8;
    }

    bw.flush();
    out.extend_from_slice(&bw.buf);
    // EOI
    out.extend_from_slice(&[0xFF, 0xD9]);
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Parses the SOF0 marker from a JFIF JPEG to verify header structure and dimensions.
    fn parse_sof0_dimensions(jpeg: &[u8]) -> Option<(u16, u16)> {
        if jpeg.len() < 4 || jpeg[0] != 0xFF || jpeg[1] != 0xD8 {
            return None;
        }
        if jpeg[jpeg.len() - 2] != 0xFF || jpeg[jpeg.len() - 1] != 0xD9 {
            return None;
        }
        let mut i = 2usize;
        while i + 4 < jpeg.len() {
            if jpeg[i] != 0xFF {
                return None;
            }
            let marker = jpeg[i + 1];
            i += 2;
            if marker == 0xD9 || marker == 0xDA {
                break;
            }
            let seg_len = u16::from_be_bytes([jpeg[i], jpeg[i + 1]]) as usize;
            if seg_len < 2 || i + seg_len > jpeg.len() {
                return None;
            }
            if marker == 0xC0 {
                let height = u16::from_be_bytes([jpeg[i + 3], jpeg[i + 4]]);
                let width = u16::from_be_bytes([jpeg[i + 5], jpeg[i + 6]]);
                return Some((width, height));
            }
            i += seg_len;
        }
        None
    }

    #[test]
    fn encodes_valid_bounded_jpeg_thumbnail_and_preserves_aspect() {
        // Synthetic 960x540 gradient + colored boxes
        let mut frame = RgbFrame::solid(960, 540, [40, 60, 90]);
        frame.fill_rect(100, 100, 350, 420, [220, 40, 40]);
        frame.fill_rect(500, 200, 820, 400, [40, 200, 80]);

        let cfg = ThumbnailConfig {
            max_width: 480,
            max_height: 270,
            quality: 75,
            min_quality: 30,
            max_bytes: 24 * 1024,
        };
        let thumb = encode_jpeg_thumbnail(&frame, &cfg).expect("thumbnail encode ok");
        assert_eq!(thumb.width, 480);
        assert_eq!(thumb.height, 270);
        assert!(thumb.jpeg_bytes.len() <= cfg.max_bytes);
        assert_eq!(thumb.sha256_hex.len(), 64);

        let dims = parse_sof0_dimensions(&thumb.jpeg_bytes).expect("valid JFIF SOF0 header");
        assert_eq!(dims, (480, 270));
    }

    #[test]
    fn enforces_tight_byte_cap_by_lowering_quality_or_scale() {
        // High-frequency checkerboard pattern that compresses poorly at high quality
        let mut pixels = Vec::with_capacity(320 * 180 * 3);
        for y in 0..180u32 {
            for x in 0..320u32 {
                let v = if ((x / 2) + (y / 2)).is_multiple_of(2) {
                    240u8
                } else {
                    15u8
                };
                pixels.extend_from_slice(&[v, 255 - v, ((x * 7 + y * 13) & 0xFF) as u8]);
            }
        }
        let frame = RgbFrame::from_rgb8(320, 180, pixels).unwrap();
        let cfg = ThumbnailConfig {
            max_width: 320,
            max_height: 180,
            quality: 85,
            min_quality: 30,
            max_bytes: 4096,
        };
        let thumb = encode_jpeg_thumbnail(&frame, &cfg).expect("should fit under 4 KiB");
        assert!(thumb.jpeg_bytes.len() <= 4096);
        let dims = parse_sof0_dimensions(&thumb.jpeg_bytes).expect("valid JPEG");
        assert_eq!(dims, (thumb.width as u16, thumb.height as u16));
    }

    #[test]
    fn validates_config_and_encodes_worst_case_quality_100_jfif_structure() {
        use crate::error::MediaCoreErrorKind;

        let tiny = RgbFrame::solid(16, 16, [100, 120, 140]);
        for bad in [
            ThumbnailConfig {
                max_width: 0,
                ..ThumbnailConfig::default()
            },
            ThumbnailConfig {
                quality: 0,
                ..ThumbnailConfig::default()
            },
            ThumbnailConfig {
                quality: 50,
                min_quality: 60,
                ..ThumbnailConfig::default()
            },
            ThumbnailConfig {
                max_bytes: 256,
                ..ThumbnailConfig::default()
            },
        ] {
            assert!(matches!(
                encode_jpeg_thumbnail(&tiny, &bad).unwrap_err().kind(),
                MediaCoreErrorKind::InvalidConfiguration(_)
            ));
        }

        // Worst-case high-contrast u=4 DCT basis pattern at quality=100 (quant=1)
        let mut pixels = Vec::with_capacity(64 * 64 * 3);
        let pat = [255u8, 0, 0, 255, 255, 0, 0, 255];
        for y in 0..64usize {
            for x in 0..64usize {
                let v = if (y / 8).is_multiple_of(2) {
                    pat[x % 8]
                } else {
                    255 - pat[x % 8]
                };
                pixels.extend_from_slice(&[v, 255 - v, v]);
            }
        }
        let frame = RgbFrame::from_rgb8(64, 64, pixels).unwrap();
        let cfg = ThumbnailConfig {
            max_width: 64,
            max_height: 64,
            quality: 100,
            min_quality: 100,
            max_bytes: 64 * 1024,
        };
        let thumb = encode_jpeg_thumbnail(&frame, &cfg).expect("q=100 worst-case encode ok");
        assert_eq!(thumb.quality, 100);
        assert_eq!(
            thumb.sha256_hex,
            hex::encode(Sha256::digest(&thumb.jpeg_bytes))
        );

        // Independently walk every JFIF marker and verify valid byte-stuffing in the entropy scan
        let b = &thumb.jpeg_bytes;
        assert_eq!(&b[0..2], &[0xFF, 0xD8]);
        assert_eq!(&b[b.len() - 2..], &[0xFF, 0xD9]);
        let mut i = 2usize;
        let mut saw_app0_jfif = false;
        let mut dqt_count = 0usize;
        let mut dht_count = 0usize;
        let mut sof0_dims = None;
        let mut sos_scan_start = None;
        while i + 2 < b.len() {
            assert_eq!(b[i], 0xFF, "expected JPEG marker at offset {i}");
            let marker = b[i + 1];
            i += 2;
            let seg_len = u16::from_be_bytes([b[i], b[i + 1]]) as usize;
            assert!(seg_len >= 2 && i + seg_len <= b.len() - 2);
            match marker {
                0xE0 => {
                    if &b[i + 2..i + 7] == b"JFIF\0" {
                        saw_app0_jfif = true;
                    }
                }
                0xDB => dqt_count += 1,
                0xC4 => dht_count += 1,
                0xC0 => {
                    let h = u16::from_be_bytes([b[i + 3], b[i + 4]]);
                    let w = u16::from_be_bytes([b[i + 5], b[i + 6]]);
                    sof0_dims = Some((w, h));
                }
                0xDA => {
                    sos_scan_start = Some(i + seg_len);
                    break;
                }
                _ => {}
            }
            i += seg_len;
        }
        assert!(saw_app0_jfif, "missing JFIF APP0 header");
        assert_eq!(dqt_count, 2, "expected lum + chrom DQT tables");
        assert_eq!(dht_count, 4, "expected 4 Baseline DHT tables");
        assert_eq!(sof0_dims, Some((64, 64)));
        let scan_start = sos_scan_start.expect("missing SOS marker");
        // Verify entropy-coded scan has zero unstuffed markers before EOI
        let mut j = scan_start;
        while j < b.len() - 2 {
            if b[j] == 0xFF {
                assert_eq!(
                    b[j + 1],
                    0x00,
                    "unstuffed 0xFF {:02X} inside JPEG entropy scan at {j}",
                    b[j + 1]
                );
                j += 2;
            } else {
                j += 1;
            }
        }
    }

    #[test]
    fn downscales_thin_aspect_ratio_frames_under_tight_max_bytes() {
        let mut state: u32 = 0x1357_9BDF;
        let make_noisy_frame = |w: u32, h: u32, seed: &mut u32| {
            let mut pixels = Vec::with_capacity((w as usize) * (h as usize) * 3);
            for _ in 0..(w * h) {
                *seed = seed.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                let r = ((*seed >> 24) & 0xFF) as u8;
                let g = ((*seed >> 16) & 0xFF) as u8;
                let b = ((*seed >> 8) & 0xFF) as u8;
                pixels.extend_from_slice(&[r, g, b]);
            }
            RgbFrame::from_rgb8(w, h, pixels).unwrap()
        };

        // Wide thin strip (640x30) under 4096-byte cap
        let wide_strip = make_noisy_frame(640, 30, &mut state);
        let wide_cfg = ThumbnailConfig {
            max_width: 640,
            max_height: 640,
            quality: 75,
            min_quality: 30,
            max_bytes: 4096,
        };
        let wide_thumb =
            encode_jpeg_thumbnail(&wide_strip, &wide_cfg).expect("640x30 thin strip should fit");
        assert!(wide_thumb.jpeg_bytes.len() <= 4096);
        assert!(wide_thumb.width < 640);
        let wide_dims = parse_sof0_dimensions(&wide_thumb.jpeg_bytes).expect("valid SOF0 JFIF");
        assert_eq!(
            wide_dims,
            (wide_thumb.width as u16, wide_thumb.height as u16)
        );

        // Tall thin strip (30x640) under 4096-byte cap
        let tall_strip = make_noisy_frame(30, 640, &mut state);
        let tall_thumb =
            encode_jpeg_thumbnail(&tall_strip, &wide_cfg).expect("30x640 thin strip should fit");
        assert!(tall_thumb.jpeg_bytes.len() <= 4096);
        assert!(tall_thumb.height < 640);
        let tall_dims = parse_sof0_dimensions(&tall_thumb.jpeg_bytes).expect("valid SOF0 JFIF");
        assert_eq!(
            tall_dims,
            (tall_thumb.width as u16, tall_thumb.height as u16)
        );
    }
}
