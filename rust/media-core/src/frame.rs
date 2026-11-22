//! Canonical RGB8 and Y-plane frame representations used across gating, detection,
//! attribute extraction, tracking, and thumbnail encoding.

use crate::error::MediaCoreError;

/// Maximum accepted width or height for a decoded frame.
pub const MAX_FRAME_DIMENSION: u32 = 8192;

/// Decoded RGB8 frame (`width * height * 3` tightly packed bytes).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RgbFrame {
    width: u32,
    height: u32,
    pixels: Vec<u8>,
}

impl RgbFrame {
    /// Creates a solid-color RGB8 frame.
    pub fn solid(width: u32, height: u32, rgb: [u8; 3]) -> Self {
        let count = (width as usize).saturating_mul(height as usize);
        let mut pixels = Vec::with_capacity(count.saturating_mul(3));
        for _ in 0..count {
            pixels.extend_from_slice(&rgb);
        }
        Self {
            width,
            height,
            pixels,
        }
    }

    /// Validates dimensions and buffer length before constructing an [`RgbFrame`].
    pub fn from_rgb8(width: u32, height: u32, pixels: Vec<u8>) -> Result<Self, MediaCoreError> {
        if width == 0 || height == 0 {
            return Err(MediaCoreError::invalid_frame(format!(
                "frame dimensions must be non-zero, got {width}x{height}"
            )));
        }
        if width > MAX_FRAME_DIMENSION || height > MAX_FRAME_DIMENSION {
            return Err(MediaCoreError::invalid_frame(format!(
                "frame dimensions {width}x{height} exceed limit {MAX_FRAME_DIMENSION}"
            )));
        }
        let expected = (width as usize)
            .checked_mul(height as usize)
            .and_then(|n| n.checked_mul(3))
            .ok_or_else(|| MediaCoreError::invalid_frame("RGB8 frame byte length overflow"))?;
        if pixels.len() != expected {
            return Err(MediaCoreError::invalid_frame(format!(
                "RGB8 buffer length {} != expected {} for {width}x{height}",
                pixels.len(),
                expected
            )));
        }
        Ok(Self {
            width,
            height,
            pixels,
        })
    }

    #[inline]
    pub fn width(&self) -> u32 {
        self.width
    }

    #[inline]
    pub fn height(&self) -> u32 {
        self.height
    }

    #[inline]
    pub fn pixels(&self) -> &[u8] {
        &self.pixels
    }

    #[inline]
    pub fn pixel_at(&self, x: u32, y: u32) -> [u8; 3] {
        let idx = ((y as usize) * (self.width as usize) + (x as usize)) * 3;
        [self.pixels[idx], self.pixels[idx + 1], self.pixels[idx + 2]]
    }

    #[inline]
    pub fn set_pixel(&mut self, x: u32, y: u32, rgb: [u8; 3]) {
        if x < self.width && y < self.height {
            let idx = ((y as usize) * (self.width as usize) + (x as usize)) * 3;
            self.pixels[idx] = rgb[0];
            self.pixels[idx + 1] = rgb[1];
            self.pixels[idx + 2] = rgb[2];
        }
    }

    /// Paints an axis-aligned rectangle in pixel coordinates (clamped to frame bounds).
    pub fn fill_rect(&mut self, x1: u32, y1: u32, x2: u32, y2: u32, rgb: [u8; 3]) {
        let rx1 = x1.min(self.width);
        let ry1 = y1.min(self.height);
        let rx2 = x2.min(self.width);
        let ry2 = y2.min(self.height);
        for y in ry1..ry2 {
            for x in rx1..rx2 {
                self.set_pixel(x, y, rgb);
            }
        }
    }

    /// Extracts a normalized `[x1, y1, x2, y2]` sub-frame from the full-resolution image.
    pub fn crop_normalized(&self, bbox_norm: [f32; 4]) -> Self {
        let [x1, y1, x2, y2] = bbox_norm;
        let px1 = ((x1.clamp(0.0, 1.0) * (self.width as f32)).floor() as u32)
            .min(self.width.saturating_sub(1));
        let py1 = ((y1.clamp(0.0, 1.0) * (self.height as f32)).floor() as u32)
            .min(self.height.saturating_sub(1));
        let px2 =
            ((x2.clamp(0.0, 1.0) * (self.width as f32)).ceil() as u32).clamp(px1 + 1, self.width);
        let py2 =
            ((y2.clamp(0.0, 1.0) * (self.height as f32)).ceil() as u32).clamp(py1 + 1, self.height);

        let cw = px2 - px1;
        let ch = py2 - py1;
        let mut out = Vec::with_capacity((cw as usize) * (ch as usize) * 3);
        for y in py1..py2 {
            let row_start = ((y as usize) * (self.width as usize) + (px1 as usize)) * 3;
            let row_end = row_start + (cw as usize) * 3;
            out.extend_from_slice(&self.pixels[row_start..row_end]);
        }
        Self {
            width: cw,
            height: ch,
            pixels: out,
        }
    }

    /// Converts the RGB8 frame into an 8-bit BT.601 luma (`Y`) plane.
    pub fn to_luma_plane(&self) -> LumaPlane {
        let mut y_data = Vec::with_capacity((self.width as usize) * (self.height as usize));
        for px in self.pixels.as_chunks::<3>().0 {
            // Standard integer BT.601 luma approximation: (77*R + 150*G + 29*B) >> 8
            let y = ((77u32 * u32::from(px[0])
                + 150u32 * u32::from(px[1])
                + 29u32 * u32::from(px[2])
                + 128)
                >> 8) as u8;
            y_data.push(y);
        }
        LumaPlane {
            width: self.width,
            height: self.height,
            y: y_data,
        }
    }

    /// Computes a local gradient-energy sharpness metric for a normalized crop region.
    ///
    /// Returns a bounded multiplier in `[0.5, 2.0]` where higher values indicate sharper
    /// edges/detail inside the crop, suitable for best-keyframe selection.
    pub fn crop_sharpness_factor(&self, bbox_norm: [f32; 4]) -> f32 {
        let crop = self.crop_normalized(bbox_norm);
        if crop.width < 3 || crop.height < 3 {
            return 1.0;
        }
        let luma = crop.to_luma_plane();
        let w = luma.width as usize;
        let h = luma.height as usize;
        let step_x = (w / 32).max(1);
        let step_y = (h / 32).max(1);
        let mut energy_sum = 0.0f64;
        let mut samples = 0u64;

        let mut y = 1usize;
        while y + 1 < h {
            let mut x = 1usize;
            while x + 1 < w {
                let c = i32::from(luma.y[y * w + x]);
                let gx = i32::from(luma.y[y * w + (x + 1)]) - i32::from(luma.y[y * w + (x - 1)]);
                let gy = i32::from(luma.y[(y + 1) * w + x]) - i32::from(luma.y[(y - 1) * w + x]);
                let lap = (4 * c
                    - i32::from(luma.y[y * w + (x - 1)])
                    - i32::from(luma.y[y * w + (x + 1)])
                    - i32::from(luma.y[(y - 1) * w + x])
                    - i32::from(luma.y[(y + 1) * w + x]))
                .abs();
                energy_sum += f64::from(gx.abs() + gy.abs() + lap) / 255.0;
                samples += 1;
                x += step_x;
            }
            y += step_y;
        }

        if samples == 0 {
            return 1.0;
        }
        let mean_energy = (energy_sum / (samples as f64)) as f32;
        // Map energy [0.0, 1.5+] smoothly into [0.5, 2.0].
        (0.5 + mean_energy * 1.5).clamp(0.5, 2.0)
    }
}

/// Decoded 8-bit luma (`Y`) plane (`width * height` bytes), usable directly from
/// H.264 `DecodedPicture.y` without paying for YUV-to-RGB conversion.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LumaPlane {
    width: u32,
    height: u32,
    y: Vec<u8>,
}

impl LumaPlane {
    /// Creates a solid-luma plane.
    pub fn solid(width: u32, height: u32, luma: u8) -> Self {
        Self {
            width,
            height,
            y: vec![luma; (width as usize).saturating_mul(height as usize)],
        }
    }

    /// Validates dimensions and buffer length before constructing a [`LumaPlane`].
    pub fn from_y(width: u32, height: u32, y: Vec<u8>) -> Result<Self, MediaCoreError> {
        if width == 0 || height == 0 {
            return Err(MediaCoreError::invalid_frame(format!(
                "luma plane dimensions must be non-zero, got {width}x{height}"
            )));
        }
        if width > MAX_FRAME_DIMENSION || height > MAX_FRAME_DIMENSION {
            return Err(MediaCoreError::invalid_frame(format!(
                "luma plane dimensions {width}x{height} exceed limit {MAX_FRAME_DIMENSION}"
            )));
        }
        let expected = (width as usize)
            .checked_mul(height as usize)
            .ok_or_else(|| MediaCoreError::invalid_frame("luma plane byte length overflow"))?;
        if y.len() != expected {
            return Err(MediaCoreError::invalid_frame(format!(
                "luma plane length {} != expected {} for {width}x{height}",
                y.len(),
                expected
            )));
        }
        Ok(Self { width, height, y })
    }

    #[inline]
    pub fn width(&self) -> u32 {
        self.width
    }

    #[inline]
    pub fn height(&self) -> u32 {
        self.height
    }

    #[inline]
    pub fn data(&self) -> &[u8] {
        &self.y
    }

    #[inline]
    pub fn as_slice(&self) -> LumaPlaneView<'_> {
        LumaPlaneView {
            width: self.width,
            height: self.height,
            y: &self.y,
        }
    }

    /// Paints an axis-aligned rectangle in pixel coordinates.
    pub fn fill_rect(&mut self, x1: u32, y1: u32, x2: u32, y2: u32, luma: u8) {
        let rx1 = x1.min(self.width);
        let ry1 = y1.min(self.height);
        let rx2 = x2.min(self.width);
        let ry2 = y2.min(self.height);
        for y in ry1..ry2 {
            let row = (y as usize) * (self.width as usize);
            for x in rx1..rx2 {
                self.y[row + (x as usize)] = luma;
            }
        }
    }
}

/// Borrowed view over an 8-bit luma (`Y`) plane for zero-copy Tier-1 motion gating.
#[derive(Debug, Clone, Copy)]
pub struct LumaPlaneView<'a> {
    pub width: u32,
    pub height: u32,
    pub y: &'a [u8],
}

impl<'a> LumaPlaneView<'a> {
    pub fn new(width: u32, height: u32, y: &'a [u8]) -> Result<Self, MediaCoreError> {
        if width == 0 || height == 0 {
            return Err(MediaCoreError::invalid_frame(format!(
                "luma plane view dimensions must be non-zero, got {width}x{height}"
            )));
        }
        if width > MAX_FRAME_DIMENSION || height > MAX_FRAME_DIMENSION {
            return Err(MediaCoreError::invalid_frame(format!(
                "luma plane view dimensions {width}x{height} exceed limit {MAX_FRAME_DIMENSION}"
            )));
        }
        let expected = (width as usize)
            .checked_mul(height as usize)
            .ok_or_else(|| MediaCoreError::invalid_frame("luma plane view length overflow"))?;
        if y.len() != expected {
            return Err(MediaCoreError::invalid_frame(format!(
                "luma plane view length {} != expected {} for {width}x{height}",
                y.len(),
                expected
            )));
        }
        Ok(Self { width, height, y })
    }
}
