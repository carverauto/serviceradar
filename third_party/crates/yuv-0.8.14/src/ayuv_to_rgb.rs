/*
 * Copyright (c) Radzivon Bartoshyk, 2/2025. All rights reserved.
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
use crate::yuv_error::check_rgba_destination;
use crate::yuv_support::{
    get_yuv_range, search_inverse_transform, CbCrInverseTransform, YuvPacked444Format,
    YuvSourceChannels,
};
use crate::{YuvError, YuvPackedImage, YuvRange, YuvStandardMatrix};
#[cfg(feature = "rayon")]
use rayon::iter::{IndexedParallelIterator, ParallelIterator};
#[cfg(feature = "rayon")]
use rayon::prelude::{ParallelSlice, ParallelSliceMut};

#[allow(unused, dead_code)]
macro_rules! cnv_exec {
    ($src: expr, $dst: expr, $premultiply_alpha: expr, $ts: expr, $bias_y: expr, $bias_uv: expr, $cn: expr, $packed: expr) => {
        use crate::numerics::*;
        if $premultiply_alpha {
            for (src, dst) in $src
                .chunks_exact(4)
                .zip($dst.chunks_exact_mut($cn.get_channels_count()))
            {
                let y = src[$packed.get_y_ps()] as i16;
                let u = src[$packed.get_u_ps()] as i16;
                let v = src[$packed.get_v_ps()] as i16;
                let a = src[$packed.get_a_ps()];
                let y_value = (y - $bias_y) as i32 * $ts.y_coef as i32;
                let cb_value = u - $bias_uv;
                let cr_value = v - $bias_uv;

                let r = qrshr::<PRECISION, 8>(y_value + $ts.cr_coef as i32 * cr_value as i32);
                let b = qrshr::<PRECISION, 8>(y_value + $ts.cb_coef as i32 * cb_value as i32);
                let g = qrshr::<PRECISION, 8>(
                    y_value
                        - $ts.g_coeff_1 as i32 * cr_value as i32
                        - $ts.g_coeff_2 as i32 * cb_value as i32,
                );

                let r = div_by_255(r as u16 * a as u16);
                let b = div_by_255(b as u16 * a as u16);
                let g = div_by_255(g as u16 * a as u16);

                dst[$cn.get_r_channel_offset()] = r as u8;
                dst[$cn.get_g_channel_offset()] = g as u8;
                dst[$cn.get_b_channel_offset()] = b as u8;
                if $cn.has_alpha() {
                    dst[$cn.get_a_channel_offset()] = a;
                }
            }
        } else {
            for (src, dst) in $src
                .chunks_exact(4)
                .zip($dst.chunks_exact_mut($cn.get_channels_count()))
            {
                let y = src[$packed.get_y_ps()] as i16;
                let u = src[$packed.get_u_ps()] as i16;
                let v = src[$packed.get_v_ps()] as i16;
                let a = src[$packed.get_a_ps()];
                let y_value = (y - $bias_y) as i32 * $ts.y_coef as i32;
                let cb_value = u - $bias_uv;
                let cr_value = v - $bias_uv;

                let r = qrshr::<PRECISION, 8>(y_value + $ts.cr_coef as i32 * cr_value as i32);
                let b = qrshr::<PRECISION, 8>(y_value + $ts.cb_coef as i32 * cb_value as i32);
                let g = qrshr::<PRECISION, 8>(
                    y_value
                        - $ts.g_coeff_1 as i32 * cr_value as i32
                        - $ts.g_coeff_2 as i32 * cb_value as i32,
                );

                dst[$cn.get_r_channel_offset()] = r as u8;
                dst[$cn.get_g_channel_offset()] = g as u8;
                dst[$cn.get_b_channel_offset()] = b as u8;
                if $cn.has_alpha() {
                    dst[$cn.get_a_channel_offset()] = a;
                }
            }
        }
    };
}

type RowExecutor = unsafe fn(&[u8], &mut [u8], bool, CbCrInverseTransform<i16>, i16, i16, usize);

#[cfg(not(all(target_arch = "aarch64", target_feature = "neon")))]
fn default_executor<const DST: u8, const PACKED: u8, const PRECISION: i32>(
    src: &[u8],
    dst: &mut [u8],
    premultiply_alpha: bool,
    ts: CbCrInverseTransform<i16>,
    bias_y: i16,
    bias_uv: i16,
    _: usize,
) {
    let cn: YuvSourceChannels = DST.into();
    let packed: YuvPacked444Format = PACKED.into();
    cnv_exec!(src, dst, premultiply_alpha, ts, bias_y, bias_uv, cn, packed);
}

#[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
fn default_executor_neon<const DST: u8, const PACKED: u8, const PRECISION: i32>(
    src: &[u8],
    dst: &mut [u8],
    premultiply_alpha: bool,
    ts: CbCrInverseTransform<i16>,
    bias_y: i16,
    bias_uv: i16,
    width: usize,
) {
    use crate::neon::neon_ayuv_to_rgba;
    unsafe {
        neon_ayuv_to_rgba::<DST, PACKED>(src, dst, &ts, bias_y, bias_uv, width, premultiply_alpha);
    }
}

#[cfg(all(target_arch = "aarch64", target_feature = "neon", feature = "rdm"))]
fn default_executor_neon_rdm<const DST: u8, const PACKED: u8, const PRECISION: i32>(
    src: &[u8],
    dst: &mut [u8],
    premultiply_alpha: bool,
    ts: CbCrInverseTransform<i16>,
    bias_y: i16,
    bias_uv: i16,
    width: usize,
) {
    use crate::neon::neon_ayuv_to_rgba_rdm;
    unsafe {
        neon_ayuv_to_rgba_rdm::<DST, PACKED>(
            src,
            dst,
            &ts,
            bias_y,
            bias_uv,
            width,
            premultiply_alpha,
        );
    }
}

#[cfg(all(any(target_arch = "x86", target_arch = "x86_64"), feature = "avx"))]
#[target_feature(enable = "avx2")]
unsafe fn default_executor_avx2<const DST: u8, const PACKED: u8, const PRECISION: i32>(
    src: &[u8],
    dst: &mut [u8],
    premultiply_alpha: bool,
    ts: CbCrInverseTransform<i16>,
    bias_y: i16,
    bias_uv: i16,
    width: usize,
) {
    use crate::avx2::avx2_ayuv_to_rgba;
    avx2_ayuv_to_rgba::<DST, PACKED>(src, dst, &ts, bias_y, bias_uv, width, premultiply_alpha);
}

#[cfg(all(any(target_arch = "x86", target_arch = "x86_64"), feature = "sse"))]
#[target_feature(enable = "sse4.1")]
unsafe fn default_executor_sse<const DST: u8, const PACKED: u8, const PRECISION: i32>(
    src: &[u8],
    dst: &mut [u8],
    premultiply_alpha: bool,
    ts: CbCrInverseTransform<i16>,
    bias_y: i16,
    bias_uv: i16,
    _: usize,
) {
    let cn: YuvSourceChannels = DST.into();
    let packed: YuvPacked444Format = PACKED.into();
    cnv_exec!(src, dst, premultiply_alpha, ts, bias_y, bias_uv, cn, packed);
}

fn make_executor<const DST: u8, const PACKED: u8, const PRECISION: i32>() -> RowExecutor {
    #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
    {
        #[cfg(feature = "avx")]
        if std::arch::is_x86_feature_detected!("avx2") {
            return default_executor_avx2::<DST, PACKED, PRECISION>;
        }
        #[cfg(feature = "sse")]
        if std::arch::is_x86_feature_detected!("sse4.1") {
            return default_executor_sse::<DST, PACKED, PRECISION>;
        }
    }
    #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
    {
        #[cfg(feature = "rdm")]
        {
            if std::arch::is_aarch64_feature_detected!("rdm") {
                return default_executor_neon_rdm::<DST, PACKED, PRECISION>;
            }
        }
        default_executor_neon::<DST, PACKED, PRECISION>
    }
    #[cfg(not(all(target_arch = "aarch64", target_feature = "neon")))]
    default_executor::<DST, PACKED, PRECISION>
}

fn ayuv_to_rgb_launch<const DST: u8, const PACKED: u8>(
    image: &YuvPackedImage<u8>,
    dst: &mut [u8],
    dst_stride: usize,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    premultiply_alpha: bool,
) -> Result<(), YuvError> {
    let cn: YuvSourceChannels = DST.into();
    image.check_constraints444()?;
    check_rgba_destination(
        dst,
        dst_stride as u32,
        image.width,
        image.height,
        cn.get_channels_count(),
    )?;

    let chroma_range = get_yuv_range(8, range);
    let kr_kb = matrix.get_kr_kb();
    let bias_y = chroma_range.bias_y as i16;
    let bias_uv = chroma_range.bias_uv as i16;

    const PRECISION: i32 = 13;

    let ts =
        search_inverse_transform(PRECISION, 8, range, matrix, chroma_range, kr_kb).cast::<i16>();

    let iter;

    #[cfg(not(feature = "rayon"))]
    {
        iter = image
            .yuy
            .chunks_exact(image.yuy_stride as usize)
            .zip(dst.chunks_exact_mut(dst_stride));
    }
    #[cfg(feature = "rayon")]
    {
        iter = image
            .yuy
            .par_chunks_exact(image.yuy_stride as usize)
            .zip(dst.par_chunks_exact_mut(dst_stride));
    }

    let mut _executor: RowExecutor = make_executor::<DST, PACKED, PRECISION>();

    iter.for_each(|(src, dst)| {
        let src = &src[..image.width as usize * 4];
        let dst = &mut dst[..image.width as usize * cn.get_channels_count()];
        unsafe {
            _executor(
                src,
                dst,
                premultiply_alpha,
                ts,
                bias_y,
                bias_uv,
                image.width as usize,
            );
        }
    });

    Ok(())
}

macro_rules! d_cnv {
    ($method: ident, $px_fmt: expr, $packed_fmt: expr, $px_fmt_name: expr, $to_fmt: expr) => {
        #[doc = concat!("Converts ", $px_fmt_name," to ", $to_fmt," 8-bit depth precision.")]
        pub fn $method(
            image: &YuvPackedImage<u8>,
            dst: &mut [u8],
            dst_stride: u32,
            range: YuvRange,
            matrix: YuvStandardMatrix,
            premultiply_alpha: bool,
        ) -> Result<(), YuvError> {
            ayuv_to_rgb_launch::<{ $px_fmt as u8 }, { $packed_fmt as u8 }>(
                image,
                dst,
                dst_stride as usize,
                range,
                matrix,
                premultiply_alpha,
            )
        }
    };
}

d_cnv!(
    vyua_to_rgb,
    YuvSourceChannels::Rgb,
    YuvPacked444Format::Vuya,
    "VUYA",
    "RGB"
);
d_cnv!(
    vyua_to_rgba,
    YuvSourceChannels::Rgba,
    YuvPacked444Format::Vuya,
    "VUYA",
    "RGBA"
);

d_cnv!(
    ayuv_to_rgb,
    YuvSourceChannels::Rgb,
    YuvPacked444Format::Ayuv,
    "AYUV",
    "RGB"
);
d_cnv!(
    ayuv_to_rgba,
    YuvSourceChannels::Rgba,
    YuvPacked444Format::Ayuv,
    "AYUV",
    "RGBA"
);
