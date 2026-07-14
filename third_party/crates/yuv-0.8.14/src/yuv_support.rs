/*
 * Copyright (c) Radzivon Bartoshyk, 10/2024. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification,
 * are permitted provided that the following conditions are met:
 *
 * 1.  Redistributions of source code must retain the above copyright notice, this
 * list of conditions and the following disclaimer.
 *
 * 2.  Redistributions in binary form must reproduce the above copyright notice,
 * this list of conditions and the following disclaimer in the documentation
 * and/or other materials provided with the distribution.
 *
 * 3.  Neither the name of the copyright holder nor the names of its
 * contributors may be used to endorse or promote products derived from
 * this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
 * OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */
use crate::built_coefficients::{get_built_forward_transform, get_built_inverse_transform};
use num_traits::AsPrimitive;
use std::fmt::{Display, Formatter};

#[derive(Debug, Copy, Clone)]
pub struct CbCrInverseTransform<T> {
    pub y_coef: T,
    pub cr_coef: T,
    pub cb_coef: T,
    pub g_coeff_1: T,
    pub g_coeff_2: T,
}

impl<T> CbCrInverseTransform<T> {
    pub fn new(
        y_coef: T,
        cr_coef: T,
        cb_coef: T,
        g_coeff_1: T,
        g_coeff_2: T,
    ) -> CbCrInverseTransform<T> {
        CbCrInverseTransform {
            y_coef,
            cr_coef,
            cb_coef,
            g_coeff_1,
            g_coeff_2,
        }
    }
}

impl CbCrInverseTransform<f32> {
    /// Integral transformation adds an error not less than 1%
    pub fn to_integers(self, precision: u32) -> CbCrInverseTransform<i32> {
        let precision_scale: i32 = 1i32 << (precision as i32);
        let cr_coef = (self.cr_coef * precision_scale as f32).round() as i32;
        let cb_coef = (self.cb_coef * precision_scale as f32).round() as i32;
        let y_coef = (self.y_coef * precision_scale as f32).round() as i32;
        let g_coef_1 = (self.g_coeff_1 * precision_scale as f32).round() as i32;
        let g_coef_2 = (self.g_coeff_2 * precision_scale as f32).round() as i32;
        CbCrInverseTransform::<i32> {
            y_coef,
            cr_coef,
            cb_coef,
            g_coeff_1: g_coef_1,
            g_coeff_2: g_coef_2,
        }
    }
}

impl<V> CbCrInverseTransform<V> {
    #[inline]
    pub(crate) fn cast<T: Copy + 'static>(&self) -> CbCrInverseTransform<T>
    where
        V: AsPrimitive<T>,
    {
        CbCrInverseTransform {
            y_coef: self.y_coef.as_(),
            cb_coef: self.cb_coef.as_(),
            cr_coef: self.cr_coef.as_(),
            g_coeff_1: self.g_coeff_1.as_(),
            g_coeff_2: self.g_coeff_2.as_(),
        }
    }
}

/// Transformation RGB to YUV with coefficients as specified in [ITU-R](https://www.itu.int/rec/T-REC-H.273/en)
pub fn get_inverse_transform(
    range_bgra: u32,
    range_y: u32,
    range_uv: u32,
    kr: f32,
    kb: f32,
) -> CbCrInverseTransform<f32> {
    let range_uv = range_bgra as f32 / range_uv as f32;
    let y_coef = range_bgra as f32 / range_y as f32;
    let cr_coeff = (2f32 * (1f32 - kr)) * range_uv;
    let cb_coeff = (2f32 * (1f32 - kb)) * range_uv;
    let kg = 1.0f32 - kr - kb;
    assert_ne!(kg, 0., "1.0f - kr - kg must not be 0");
    let g_coeff_1 = (2f32 * ((1f32 - kr) * kr / kg)) * range_uv;
    let g_coeff_2 = (2f32 * ((1f32 - kb) * kb / kg)) * range_uv;
    CbCrInverseTransform::new(y_coef, cr_coeff, cb_coeff, g_coeff_1, g_coeff_2)
}

#[repr(C)]
#[derive(Debug, Copy, Clone, PartialOrd, PartialEq)]
pub struct CbCrForwardTransform<T> {
    pub yr: T,
    pub yg: T,
    pub yb: T,
    pub cb_r: T,
    pub cb_g: T,
    pub cb_b: T,
    pub cr_r: T,
    pub cr_g: T,
    pub cr_b: T,
}

impl CbCrForwardTransform<i32> {
    #[inline]
    pub(crate) const fn _interleaved_yr_yg(&self) -> i32 {
        let w0_as_u16 = self.yg.to_ne_bytes();
        let w1_as_u16 = self.yr.to_ne_bytes();
        i32::from_ne_bytes([w1_as_u16[0], w1_as_u16[1], w0_as_u16[0], w0_as_u16[1]])
    }

    #[inline]
    pub(crate) const fn _interleaved_cbr_cbg(&self) -> i32 {
        let w0_as_u16 = self.cb_g.to_ne_bytes();
        let w1_as_u16 = self.cb_r.to_ne_bytes();
        i32::from_ne_bytes([w1_as_u16[0], w1_as_u16[1], w0_as_u16[0], w0_as_u16[1]])
    }

    #[inline]
    pub(crate) const fn _interleaved_crr_crg(&self) -> i32 {
        let w0_as_u16 = self.cr_g as u16;
        let w1_as_u16 = self.cr_r as u16;
        (((w0_as_u16 as u32) << 16) | (w1_as_u16 as u32)) as i32
    }
}

pub trait ToIntegerTransform {
    fn to_integers(&self, precision: u32) -> CbCrForwardTransform<i32>;
}

impl ToIntegerTransform for CbCrForwardTransform<f32> {
    fn to_integers(&self, precision: u32) -> CbCrForwardTransform<i32> {
        let scale = (1 << precision) as f32;
        CbCrForwardTransform::<i32> {
            yr: (self.yr * scale).round() as i32,
            yg: (self.yg * scale).round() as i32,
            yb: (self.yb * scale).round() as i32,
            cb_r: (self.cb_r * scale).round() as i32,
            cb_g: (self.cb_g * scale).round() as i32,
            cb_b: (self.cb_b * scale).round() as i32,
            cr_r: (self.cr_r * scale).round() as i32,
            cr_g: (self.cr_g * scale).round() as i32,
            cr_b: (self.cr_b * scale).round() as i32,
        }
    }
}

impl<V> CbCrForwardTransform<V> {
    pub(crate) fn cast<T: Copy + 'static>(&self) -> CbCrForwardTransform<T>
    where
        V: AsPrimitive<T>,
    {
        CbCrForwardTransform {
            yr: self.yr.as_(),
            yg: self.yg.as_(),
            yb: self.yb.as_(),
            cb_r: self.cb_r.as_(),
            cb_g: self.cb_g.as_(),
            cb_b: self.cb_b.as_(),
            cr_r: self.cr_r.as_(),
            cr_g: self.cr_g.as_(),
            cr_b: self.cr_b.as_(),
        }
    }
}

/// Transformation YUV to RGB with coefficients as specified in [ITU-R](https://www.itu.int/rec/T-REC-H.273/en)
pub fn get_forward_transform(
    range_rgba: u32,
    range_y: u32,
    range_uv: u32,
    kr: f32,
    kb: f32,
) -> CbCrForwardTransform<f32> {
    let kg = 1.0f32 - kr - kb;

    let yr = kr * range_y as f32 / range_rgba as f32;
    let yg = kg * range_y as f32 / range_rgba as f32;
    let yb = kb * range_y as f32 / range_rgba as f32;

    let cb_r = -0.5f32 * kr / (1f32 - kb) * range_uv as f32 / range_rgba as f32;
    let cb_g = -0.5f32 * kg / (1f32 - kb) * range_uv as f32 / range_rgba as f32;
    let cb_b = 0.5f32 * range_uv as f32 / range_rgba as f32;

    let cr_r = 0.5f32 * range_uv as f32 / range_rgba as f32;
    let cr_g = -0.5f32 * kg / (1f32 - kr) * range_uv as f32 / range_rgba as f32;
    let cr_b = -0.5f32 * kb / (1f32 - kr) * range_uv as f32 / range_rgba as f32;
    CbCrForwardTransform {
        yr,
        yg,
        yb,
        cb_r,
        cb_g,
        cb_b,
        cr_r,
        cr_g,
        cr_b,
    }
}

#[repr(C)]
#[derive(Debug, Copy, Clone, PartialOrd, PartialEq)]
/// Declares YUV range TV (limited) or Full
pub enum YuvRange {
    /// Limited range Y ∈ [16 << (depth - 8), 16 << (depth - 8) + 224 << (depth - 8)], UV ∈ [-1 << (depth - 1), -1 << (depth - 1) + 1 << (depth - 1)]
    Limited,
    /// Full range Y ∈ [0, 2^bit_depth - 1], UV ∈ [-1 << (depth - 1), -1 << (depth - 1) + 2^bit_depth - 1]
    Full,
}

/// Holds YUV bias values
#[derive(Debug, Copy, Clone, PartialOrd, PartialEq)]
pub struct YuvChromaRange {
    pub bias_y: u32,
    pub bias_uv: u32,
    pub range_y: u32,
    pub range_uv: u32,
    pub range: YuvRange,
}

/// Computes YUV ranges for given bit depth
pub const fn get_yuv_range(depth: u32, range: YuvRange) -> YuvChromaRange {
    match range {
        YuvRange::Limited => YuvChromaRange {
            bias_y: 16 << (depth - 8),
            bias_uv: 1 << (depth - 1),
            range_y: 219 << (depth - 8),
            range_uv: 224 << (depth - 8),
            range,
        },
        YuvRange::Full => YuvChromaRange {
            bias_y: 0,
            bias_uv: 1 << (depth - 1),
            range_uv: (1 << depth) - 1,
            range_y: (1 << depth) - 1,
            range,
        },
    }
}

#[repr(C)]
#[derive(Debug, Copy, Clone, PartialOrd, PartialEq)]
/// Declares standard prebuilt YUV conversion matrices, check [ITU-R](https://www.itu.int/rec/T-REC-H.273/en) information for more info
/// JPEG YUV Matrix corresponds Bt.601 + Full Range
pub enum YuvStandardMatrix {
    /// If you want to encode/decode JPEG YUV use Bt.601 + Full Range
    Bt601,
    Bt709,
    Bt2020,
    Smpte240,
    Bt470_6,
    Fcc,
    /// Custom parameters first goes for kr, second for kb.
    /// Methods will *panic* if 1.0f32 - kr - kb == 0
    Custom(f32, f32),
}

#[derive(Debug, Copy, Clone, PartialOrd, PartialEq)]
pub struct YuvBias {
    pub kr: f32,
    pub kb: f32,
}

impl YuvStandardMatrix {
    pub const fn get_kr_kb(self) -> YuvBias {
        match self {
            YuvStandardMatrix::Bt601 => YuvBias {
                kr: 0.299f32,
                kb: 0.114f32,
            },
            YuvStandardMatrix::Bt709 => YuvBias {
                kr: 0.2126f32,
                kb: 0.0722f32,
            },
            YuvStandardMatrix::Bt2020 => YuvBias {
                kr: 0.2627f32,
                kb: 0.0593f32,
            },
            YuvStandardMatrix::Smpte240 => YuvBias {
                kr: 0.212f32,
                kb: 0.087f32,
            },
            YuvStandardMatrix::Bt470_6 => YuvBias {
                kr: 0.2220f32,
                kb: 0.0713f32,
            },
            YuvStandardMatrix::Fcc => YuvBias { kr: 0.30, kb: 0.11 },
            YuvStandardMatrix::Custom(kr, kb) => YuvBias { kr, kb },
        }
    }
}

#[repr(u8)]
#[derive(Debug, Copy, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub enum YuvNVOrder {
    UV = 0,
    VU = 1,
}

impl YuvNVOrder {
    #[inline]
    pub const fn get_u_position(&self) -> usize {
        match self {
            YuvNVOrder::UV => 0,
            YuvNVOrder::VU => 1,
        }
    }
    #[inline]
    pub const fn get_v_position(&self) -> usize {
        match self {
            YuvNVOrder::UV => 1,
            YuvNVOrder::VU => 0,
        }
    }
}

impl From<u8> for YuvNVOrder {
    #[inline(always)]
    fn from(value: u8) -> Self {
        match value {
            0 => YuvNVOrder::UV,
            1 => YuvNVOrder::VU,
            _ => {
                unimplemented!("Unknown value")
            }
        }
    }
}

#[repr(u8)]
#[derive(Debug, Copy, Clone, PartialEq, Eq)]
pub enum YuvChromaSubsampling {
    Yuv420 = 0,
    Yuv422 = 1,
    Yuv444 = 2,
}

impl From<u8> for YuvChromaSubsampling {
    #[inline(always)]
    fn from(value: u8) -> Self {
        match value {
            0 => YuvChromaSubsampling::Yuv420,
            1 => YuvChromaSubsampling::Yuv422,
            2 => YuvChromaSubsampling::Yuv444,
            _ => {
                unimplemented!("Unknown value")
            }
        }
    }
}

#[repr(u8)]
#[derive(Copy, Clone, PartialEq, Eq)]
/// This controls endianness of YUV storage format
pub enum YuvEndianness {
    #[cfg(feature = "big_endian")]
    BigEndian = 0,
    LittleEndian = 1,
}

impl From<u8> for YuvEndianness {
    #[inline(always)]
    fn from(value: u8) -> Self {
        match value {
            #[cfg(feature = "big_endian")]
            0 => YuvEndianness::BigEndian,
            1 => YuvEndianness::LittleEndian,
            _ => {
                unimplemented!("Unknown value")
            }
        }
    }
}

#[repr(u8)]
#[derive(Debug, Copy, Clone, PartialEq, Eq)]
/// Most of the cases of storage bytes is least significant whereas b`0000000111111` integers stored in low part.
///
/// However, most modern hardware encoders (Apple, Android manufacturers) uses most significant bytes
/// where same number stored as b`111111000000` and need to be shifted right before working with this.
/// This is not the same and endianness. I never met `big endian` packing with `most significant bytes`
/// so this case may not work fully correct, however, `little endian` + `most significant bytes`
/// can be easily derived from HDR camera stream on android and apple platforms.
/// This may also correspond to either [YCBCR_P010](https://developer.android.com/reference/android/graphics/ImageFormat#YCBCR_P010)
/// or [YCBCR_P210](https://developer.android.com/reference/android/graphics/ImageFormat#YCBCR_P210)
/// or [kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange](https://developer.apple.com/documentation/CoreVideo/kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
/// or [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange](https://developer.apple.com/documentation/CoreVideo/kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange).
pub enum YuvBytesPacking {
    MostSignificantBytes = 0,
    LeastSignificantBytes = 1,
}

impl From<u8> for YuvBytesPacking {
    #[inline(always)]
    fn from(value: u8) -> Self {
        match value {
            0 => YuvBytesPacking::MostSignificantBytes,
            1 => YuvBytesPacking::LeastSignificantBytes,
            _ => {
                unimplemented!("Unknown value")
            }
        }
    }
}

#[repr(u8)]
#[derive(Debug, Copy, Clone, PartialEq, Eq)]
pub enum YuvSourceChannels {
    Rgb = 0,
    Rgba = 1,
    Bgra = 2,
    Bgr = 3,
}

impl Display for YuvSourceChannels {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            YuvSourceChannels::Rgb => f.write_str("YuvSourceChannels::Rgb"),
            YuvSourceChannels::Rgba => f.write_str("YuvSourceChannels::Rgba"),
            YuvSourceChannels::Bgra => f.write_str("YuvSourceChannels::Bgra"),
            YuvSourceChannels::Bgr => f.write_str("YuvSourceChannels::Bgr"),
        }
    }
}

impl From<u8> for YuvSourceChannels {
    #[inline(always)]
    fn from(value: u8) -> Self {
        match value {
            0 => YuvSourceChannels::Rgb,
            1 => YuvSourceChannels::Rgba,
            2 => YuvSourceChannels::Bgra,
            3 => YuvSourceChannels::Bgr,
            _ => {
                unimplemented!("Unknown value")
            }
        }
    }
}

impl YuvSourceChannels {
    #[inline(always)]
    pub const fn get_channels_count(&self) -> usize {
        match self {
            YuvSourceChannels::Rgb | YuvSourceChannels::Bgr => 3,
            YuvSourceChannels::Rgba | YuvSourceChannels::Bgra => 4,
        }
    }

    #[inline(always)]
    pub const fn has_alpha(&self) -> bool {
        match self {
            YuvSourceChannels::Rgb | YuvSourceChannels::Bgr => false,
            YuvSourceChannels::Rgba | YuvSourceChannels::Bgra => true,
        }
    }
}

impl YuvSourceChannels {
    #[inline(always)]
    pub const fn get_r_channel_offset(&self) -> usize {
        match self {
            YuvSourceChannels::Rgb => 0,
            YuvSourceChannels::Rgba => 0,
            YuvSourceChannels::Bgra => 2,
            YuvSourceChannels::Bgr => 2,
        }
    }

    #[inline(always)]
    pub const fn get_g_channel_offset(&self) -> usize {
        match self {
            YuvSourceChannels::Rgb | YuvSourceChannels::Bgr => 1,
            YuvSourceChannels::Rgba | YuvSourceChannels::Bgra => 1,
        }
    }

    #[inline(always)]
    pub const fn get_b_channel_offset(&self) -> usize {
        match self {
            YuvSourceChannels::Rgb => 2,
            YuvSourceChannels::Rgba => 2,
            YuvSourceChannels::Bgra => 0,
            YuvSourceChannels::Bgr => 0,
        }
    }
    #[inline(always)]
    pub const fn get_a_channel_offset(&self) -> usize {
        match self {
            YuvSourceChannels::Rgb | YuvSourceChannels::Bgr => 0,
            YuvSourceChannels::Rgba | YuvSourceChannels::Bgra => 3,
        }
    }
}

#[repr(usize)]
#[derive(Debug, Copy, Clone, PartialEq, Eq)]
#[allow(clippy::upper_case_acronyms)]
pub(crate) enum Yuy2Description {
    YUYV = 0,
    UYVY = 1,
    YVYU = 2,
    VYUY = 3,
}

impl From<usize> for Yuy2Description {
    fn from(value: usize) -> Self {
        match value {
            0 => Yuy2Description::YUYV,
            1 => Yuy2Description::UYVY,
            2 => Yuy2Description::YVYU,
            3 => Yuy2Description::VYUY,
            _ => {
                unimplemented!("YUY2 not supported value {}", value)
            }
        }
    }
}

impl Yuy2Description {
    #[inline]
    pub(crate) const fn get_u_position(&self) -> usize {
        match self {
            Yuy2Description::YUYV => 1,
            Yuy2Description::UYVY => 0,
            Yuy2Description::YVYU => 3,
            Yuy2Description::VYUY => 2,
        }
    }

    #[inline]
    pub(crate) const fn get_v_position(&self) -> usize {
        match self {
            Yuy2Description::YUYV => 3,
            Yuy2Description::UYVY => 2,
            Yuy2Description::YVYU => 1,
            Yuy2Description::VYUY => 0,
        }
    }

    #[inline(always)]
    pub(crate) const fn get_first_y_position(&self) -> usize {
        match self {
            Yuy2Description::YUYV => 0,
            Yuy2Description::UYVY => 1,
            Yuy2Description::YVYU => 0,
            Yuy2Description::VYUY => 1,
        }
    }

    #[inline]
    pub(crate) const fn get_second_y_position(&self) -> usize {
        match self {
            Yuy2Description::YUYV => 2,
            Yuy2Description::UYVY => 3,
            Yuy2Description::YVYU => 2,
            Yuy2Description::VYUY => 3,
        }
    }
}

#[derive(Debug, Copy, Clone, PartialEq, Eq, Hash, Ord, PartialOrd)]
pub(crate) enum YuvPacked444Format {
    Ayuv = 0,
    Vuya = 1,
}

impl From<u8> for YuvPacked444Format {
    fn from(value: u8) -> Self {
        match value {
            0 => YuvPacked444Format::Ayuv,
            1 => YuvPacked444Format::Vuya,
            _ => unimplemented!("{} is not implemented on PackedYuv444", value),
        }
    }
}

#[cfg(not(all(target_arch = "aarch64", target_feature = "neon")))]
impl YuvPacked444Format {
    pub(crate) const fn get_a_ps(&self) -> usize {
        match self {
            YuvPacked444Format::Ayuv => 0,
            YuvPacked444Format::Vuya => 3,
        }
    }

    pub(crate) const fn get_u_ps(&self) -> usize {
        match self {
            YuvPacked444Format::Ayuv => 2,
            YuvPacked444Format::Vuya => 1,
        }
    }

    pub(crate) const fn get_v_ps(&self) -> usize {
        match self {
            YuvPacked444Format::Ayuv => 3,
            YuvPacked444Format::Vuya => 0,
        }
    }

    pub(crate) const fn get_y_ps(&self) -> usize {
        match self {
            YuvPacked444Format::Ayuv => 1,
            YuvPacked444Format::Vuya => 2,
        }
    }
}

#[derive(Debug, Copy, Clone, PartialEq, Eq)]
pub(crate) enum Rgb30 {
    Ar30 = 0,
    Ab30 = 1,
    Ra30 = 2,
    Ba30 = 3,
}

impl From<usize> for Rgb30 {
    fn from(value: usize) -> Self {
        match value {
            0 => Rgb30::Ar30,
            1 => Rgb30::Ab30,
            2 => Rgb30::Ra30,
            3 => Rgb30::Ba30,
            _ => {
                unimplemented!("Rgb30 is not implemented for value {}", value)
            }
        }
    }
}

/// Converts a value from host byte order to network byte order.
#[inline]
const fn htonl(hostlong: u32) -> u32 {
    hostlong.to_be()
}

/// Converts a value from network byte order to host byte order.
#[inline]
const fn ntohl(netlong: u32) -> u32 {
    u32::from_be(netlong)
}

impl Rgb30 {
    #[inline(always)]
    pub(crate) const fn pack<const STORE: usize>(self, r: i32, g: i32, b: i32) -> u32 {
        let value: u32 = match self {
            Rgb30::Ar30 => (((3 << 30) | (b << 20)) | ((g << 10) | r)) as u32,
            Rgb30::Ab30 => (((3 << 30) | (r << 20)) | ((g << 10) | b)) as u32,
            Rgb30::Ra30 => (((r << 22) | (g << 12)) | ((b << 2) | 3)) as u32,
            Rgb30::Ba30 => (((b << 22) | (g << 12)) | ((r << 2) | 3)) as u32,
        };
        if STORE == 0 {
            value
        } else {
            htonl(value)
        }
    }

    pub(crate) const fn pack_w_a<const STORE: usize>(self, r: i32, g: i32, b: i32, a: i32) -> u32 {
        let value: u32 = match self {
            Rgb30::Ar30 => ((a << 30) | (b << 20) | (g << 10) | r) as u32,
            Rgb30::Ab30 => ((a << 30) | (r << 20) | (g << 10) | b) as u32,
            Rgb30::Ra30 => ((r << 22) | (g << 12) | (b << 2) | a) as u32,
            Rgb30::Ba30 => ((b << 22) | (g << 12) | (r << 2) | a) as u32,
        };
        if STORE == 0 {
            value
        } else {
            htonl(value)
        }
    }

    #[inline(always)]
    pub(crate) const fn unpack<const STORE: usize>(self, value: u32) -> (u32, u32, u32, u32) {
        let pixel = if STORE == 0 { value } else { ntohl(value) };
        match self {
            Rgb30::Ar30 => {
                let r10 = pixel & 0x3ff;
                let g10 = (pixel >> 10) & 0x3ff;
                let b10 = (pixel >> 20) & 0x3ff;
                let a10 = pixel >> 30;
                (r10, g10, b10, a10)
            }
            Rgb30::Ab30 => {
                let b10 = pixel & 0x3ff;
                let g10 = (pixel >> 10) & 0x3ff;
                let r10 = (pixel >> 20) & 0x3ff;
                let a10 = pixel >> 30;
                (r10, g10, b10, a10)
            }
            Rgb30::Ra30 => {
                let a2 = pixel & 0x3;
                let r10 = (pixel >> 22) & 0x3ff;
                let g10 = (pixel >> 12) & 0x3ff;
                let b10 = (pixel >> 2) & 0x3ff;
                (r10, g10, b10, a2)
            }
            Rgb30::Ba30 => {
                let a2 = pixel & 0x3;
                let b10 = (pixel >> 22) & 0x3ff;
                let g10 = (pixel >> 12) & 0x3ff;
                let r10 = (pixel >> 2) & 0x3ff;
                (r10, g10, b10, a2)
            }
        }
    }
}

#[derive(Debug, Copy, Clone, Ord, PartialOrd, Eq, PartialEq)]
/// Represents the byte order for storing RGBA data in 30-bit formats such as RGBA1010102 or RGBA2101010.
///
/// # Overview
/// RGBA1010102 and RGBA2101010 are 30-bit color formats where each component (R, G, B, and A)
/// uses 10 bits for color depth, and the remaining 2 bits are used for additional purposes (e.g., alpha).
///
/// In certain systems, the byte order used for storage can differ:
/// - **Host Byte Order**: Uses the native endianness of the host machine (little-endian or big-endian).
/// - **Network Byte Order**: Always uses big-endian format, often required for consistent data
///   transfer across different platforms or network protocols. Used by Apple.
pub enum Rgb30ByteOrder {
    Host = 0,
    Network = 1,
}

impl From<usize> for Rgb30ByteOrder {
    fn from(value: usize) -> Self {
        match value {
            0 => Rgb30ByteOrder::Host,
            1 => Rgb30ByteOrder::Network,
            _ => {
                unimplemented!("Rgb30ByteOrder is not implemented for value {}", value)
            }
        }
    }
}

/// Search for prebuilt forward transform, otherwise computes new transform
pub(crate) fn search_forward_transform(
    precision: i32,
    bit_depth: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    chroma_range: YuvChromaRange,
    kr_kb: YuvBias,
) -> CbCrForwardTransform<i32> {
    if let Some(stored_t) = get_built_forward_transform(precision as u32, bit_depth, range, matrix)
    {
        stored_t
    } else {
        let transform_precise = get_forward_transform(
            (1 << bit_depth) - 1,
            chroma_range.range_y,
            chroma_range.range_uv,
            kr_kb.kr,
            kr_kb.kb,
        );
        transform_precise.to_integers(precision as u32)
    }
}

/// Search for prebuilt inverse transform, otherwise computes new transform
pub(crate) fn search_inverse_transform(
    precision: i32,
    bit_depth: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    chroma_range: YuvChromaRange,
    kr_kb: YuvBias,
) -> CbCrInverseTransform<i32> {
    if let Some(stored) = get_built_inverse_transform(precision as u32, bit_depth, range, matrix) {
        stored
    } else {
        let transform = get_inverse_transform(
            (1 << bit_depth) - 1,
            chroma_range.range_y,
            chroma_range.range_uv,
            kr_kb.kr,
            kr_kb.kb,
        );
        if precision == 6 {
            // We can't allow infinite contribution to fastest 6 bit approximation
            let mut transform = transform.to_integers(precision as u32);
            transform.cr_coef = transform.cr_coef.min(127);
            transform.cb_coef = transform.cb_coef.min(127);
            transform.g_coeff_1 = transform.g_coeff_1.min(127);
            transform.g_coeff_2 = transform.g_coeff_2.min(127);
            transform
        } else {
            transform.to_integers(precision as u32)
        }
    }
}

/// Declares YUV conversion accuracy mode
///
/// In common case, each step for increasing accuracy have at least 30% slowdown.
#[derive(Copy, Clone, Debug, Ord, PartialOrd, Eq, PartialEq, Default)]
pub enum YuvConversionMode {
    /// Minimal precision, but the fastest option. Same as libyuv does use.
    /// This may encode with notable changes in the image,
    /// consider using this when you're migrating from libyuv and want same,
    /// or fastest performance, or you just need the fastest available performance.
    /// On aarch64 `i8mm` activated feature may be preferred, nightly compiler channel is required,
    /// when encoding RGBA/BGRA only.
    /// For `x86` consider activating `avx512` feature ( nightly compiler channel is required ),
    /// it may significantly increase throughout on some modern CPU's,
    /// even without AVX-512 available. `avxvnni` may be used instead.
    #[cfg(feature = "fast_mode")]
    #[cfg_attr(docsrs, doc(cfg(feature = "fast_mode")))]
    Fast,
    /// Mixed, but high precision, very good performance.
    /// This is still a VERY fast method, with much more precise encoding.
    /// This option is more suitable for common encoding, where fast speed is critical along the
    /// high precision.
    #[default]
    Balanced,
    /// Maximizes quality and precision over speed while maintaining reasonable performance.
    #[cfg(feature = "professional_mode")]
    #[cfg_attr(docsrs, doc(cfg(feature = "professional_mode")))]
    Professional,
}

impl Display for YuvConversionMode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            #[cfg(feature = "fast_mode")]
            YuvConversionMode::Fast => f.write_str("YuvAccuracy::Fast"),
            YuvConversionMode::Balanced => f.write_str("YuvAccuracy::Balanced"),
            #[cfg(feature = "professional_mode")]
            YuvConversionMode::Professional => f.write_str("YuvAccuracy::Professional"),
        }
    }
}
