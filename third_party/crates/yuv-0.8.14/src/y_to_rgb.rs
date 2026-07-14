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
use crate::yuv_error::check_rgba_destination;
use crate::yuv_support::*;
use crate::{YuvError, YuvGrayImage};
#[cfg(feature = "rayon")]
use rayon::iter::{IndexedParallelIterator, ParallelIterator};
#[cfg(feature = "rayon")]
use rayon::prelude::{ParallelSlice, ParallelSliceMut};

type RgbFullHandler = unsafe fn(&mut [u8], &[u8], usize);

type RgbLimitedHandler = unsafe fn(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
    y_plane: &[u8],
    rgba: &mut [u8],
    start_cx: usize,
    width: usize,
);

#[inline(always)]
fn default_full_converter<const CN: u8>(rgba: &mut [u8], y_plane: &[u8], _: usize) {
    let cn: YuvSourceChannels = CN.into();

    for (y_src, rgba) in y_plane
        .iter()
        .zip(rgba.chunks_exact_mut(cn.get_channels_count()))
    {
        let r = *y_src;
        rgba[cn.get_r_channel_offset()] = r;
        rgba[cn.get_g_channel_offset()] = r;
        rgba[cn.get_b_channel_offset()] = r;
        if cn.has_alpha() {
            rgba[cn.get_a_channel_offset()] = 255;
        }
    }
}

#[inline(always)]
#[cfg(not(any(
    all(target_arch = "aarch64", target_feature = "neon"),
    all(target_arch = "wasm32", target_feature = "simd128")
)))]
unsafe fn default_limited_converter<const CN: u8, const PRECISION: i32>(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
    y_plane: &[u8],
    rgba: &mut [u8],
    _: usize,
    _: usize,
) {
    let cn: YuvSourceChannels = CN.into();
    let ts = transform.cast::<i16>();
    let bias_y = range.bias_y as i16;

    for (y_src, rgba) in y_plane
        .iter()
        .zip(rgba.chunks_exact_mut(cn.get_channels_count()))
    {
        use crate::numerics::qrshr;

        let y0 = *y_src as i16;
        let y_value = (y0 - bias_y) as i32 * ts.y_coef as i32;

        let r = qrshr::<PRECISION, 8>(y_value);
        rgba[cn.get_r_channel_offset()] = r as u8;
        rgba[cn.get_g_channel_offset()] = r as u8;
        rgba[cn.get_b_channel_offset()] = r as u8;
        if cn.has_alpha() {
            rgba[cn.get_a_channel_offset()] = 255;
        }
    }
}

#[cfg(all(any(target_arch = "x86", target_arch = "x86_64"), feature = "sse"))]
#[target_feature(enable = "sse4.1")]
unsafe fn default_full_converter_sse4_1<const CN: u8>(
    rgba: &mut [u8],
    y_plane: &[u8],
    width: usize,
) {
    default_full_converter::<CN>(rgba, y_plane, width);
}

#[cfg(all(any(target_arch = "x86", target_arch = "x86_64"), feature = "avx"))]
#[target_feature(enable = "avx2")]
unsafe fn default_full_converter_avx2<const CN: u8>(rgba: &mut [u8], y_plane: &[u8], width: usize) {
    default_full_converter::<CN>(rgba, y_plane, width);
}

#[cfg(all(
    any(target_arch = "x86", target_arch = "x86_64"),
    feature = "nightly_avx512"
))]
#[target_feature(enable = "avx512bw")]
unsafe fn default_full_converter_avx512<const CN: u8>(
    rgba: &mut [u8],
    y_plane: &[u8],
    width: usize,
) {
    default_full_converter::<CN>(rgba, y_plane, width);
}

fn make_full_converter<const CN: u8>() -> RgbFullHandler {
    #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
    {
        #[cfg(feature = "nightly_avx512")]
        {
            if std::arch::is_x86_feature_detected!("avx512bw") {
                return default_full_converter_avx512::<CN>;
            }
        }
        #[cfg(feature = "avx")]
        {
            if std::arch::is_x86_feature_detected!("avx2") {
                return default_full_converter_avx2::<CN>;
            }
        }
        #[cfg(feature = "sse")]
        {
            if std::arch::is_x86_feature_detected!("sse4.1") {
                return default_full_converter_sse4_1::<CN>;
            }
        }
    }
    default_full_converter::<CN>
}

fn make_limited_converter<const CN: u8, const PRECISION: i32>() -> RgbLimitedHandler {
    #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
    {
        #[cfg(feature = "rdm")]
        {
            if std::arch::is_aarch64_feature_detected!("rdm") {
                use crate::neon::neon_y_to_rgb_row_rdm;
                return neon_y_to_rgb_row_rdm::<CN>;
            }
        }
        use crate::neon::neon_y_to_rgb_row;
        neon_y_to_rgb_row::<CN>
    }
    #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
    {
        #[cfg(feature = "nightly_avx512")]
        {
            use crate::avx512bw::avx512_y_to_rgb_row;
            if std::arch::is_x86_feature_detected!("avx512bw") {
                let use_vbmi = std::arch::is_x86_feature_detected!("avx512vbmi");
                return if use_vbmi {
                    avx512_y_to_rgb_row::<CN, true>
                } else {
                    avx512_y_to_rgb_row::<CN, false>
                };
            }
        }
        #[cfg(feature = "avx")]
        {
            if std::arch::is_x86_feature_detected!("avx2") {
                use crate::avx2::avx2_y_to_rgba_row;
                return avx2_y_to_rgba_row::<CN>;
            }
        }
        #[cfg(feature = "sse")]
        {
            if std::arch::is_x86_feature_detected!("sse4.1") {
                use crate::sse::sse_y_to_rgba_row;
                return sse_y_to_rgba_row::<CN>;
            }
        }
    }
    #[cfg(all(target_arch = "wasm32", target_feature = "simd128"))]
    {
        use crate::wasm32::wasm_y_to_rgb_row;
        return wasm_y_to_rgb_row::<CN>;
    }
    #[cfg(not(any(
        all(target_arch = "aarch64", target_feature = "neon"),
        all(target_arch = "wasm32", target_feature = "simd128")
    )))]
    default_limited_converter::<CN, PRECISION>
}

// Chroma subsampling always assumed as 400
fn y_to_rgbx<const CN: u8>(
    image: &YuvGrayImage<u8>,
    rgba: &mut [u8],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    let cn: YuvSourceChannels = CN.into();
    let channels = cn.get_channels_count();

    check_rgba_destination(rgba, rgba_stride, image.width, image.height, channels)?;
    image.check_constraints()?;

    let chroma_range = get_yuv_range(8, range);
    let kr_kb = matrix.get_kr_kb();

    const PRECISION: i32 = 13;
    let inverse_transform =
        search_inverse_transform(PRECISION, 8, range, matrix, chroma_range, kr_kb);

    let y_plane = image.y_plane;
    let y_stride = image.y_stride;

    let iter;
    let y_iter;
    #[cfg(feature = "rayon")]
    {
        iter = rgba.par_chunks_exact_mut(rgba_stride as usize);
        y_iter = y_plane.par_chunks_exact(y_stride as usize);
    }
    #[cfg(not(feature = "rayon"))]
    {
        iter = rgba.chunks_exact_mut(rgba_stride as usize);
        y_iter = y_plane.chunks_exact(y_stride as usize);
    }

    if range == YuvRange::Limited {
        let executor = make_limited_converter::<CN, PRECISION>();

        iter.zip(y_iter).for_each(|(rgba, y_plane)| {
            let y_plane = &y_plane[..image.width as usize];
            let rgba = &mut rgba[..channels * image.width as usize];

            unsafe {
                executor(
                    &chroma_range,
                    &inverse_transform,
                    y_plane,
                    rgba,
                    0,
                    image.width as usize,
                );
            }
        });
    } else {
        let executor = make_full_converter::<CN>();
        iter.zip(y_iter).for_each(|(rgba, y_plane)| {
            let y_plane = &y_plane[..image.width as usize];
            unsafe {
                executor(rgba, y_plane, image.width as usize);
            }
        });
    }

    Ok(())
}

/// Convert YUV 400 planar format to RGB format.
///
/// This function takes YUV 400 planar format data with 8-bit precision,
/// and converts it to RGB format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `gray_image` - Source YUV gray image.
/// * `rgb_data` - A mutable slice to store the converted RGB data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input RGB data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv400_to_rgb(
    gray_image: &YuvGrayImage<u8>,
    rgb: &mut [u8],
    rgb_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    y_to_rgbx::<{ YuvSourceChannels::Rgb as u8 }>(gray_image, rgb, rgb_stride, range, matrix)
}

/// Convert YUV 400 planar format to BGR format.
///
/// This function takes YUV 400 planar format data with 8-bit precision,
/// and converts it to BGR format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `gray_image` - Source YUV gray image.
/// * `rgb_data` - A mutable slice to store the converted BGR data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGR data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv400_to_bgr(
    gray_image: &YuvGrayImage<u8>,
    bgr: &mut [u8],
    bgr_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    y_to_rgbx::<{ YuvSourceChannels::Bgr as u8 }>(gray_image, bgr, bgr_stride, range, matrix)
}

/// Convert YUV 400 planar format to RGBA format.
///
/// This function takes YUV 400 planar format data with 8-bit precision,
/// and converts it to RGBA format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `gray_image` - Source YUV gray image.
/// * `rgba_data` - A mutable slice to store the converted RGBA data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGRA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv400_to_rgba(
    gray_image: &YuvGrayImage<u8>,
    rgba: &mut [u8],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    y_to_rgbx::<{ YuvSourceChannels::Rgba as u8 }>(gray_image, rgba, rgba_stride, range, matrix)
}

/// Convert YUV 400 planar format to BGRA format.
///
/// This function takes YUV 400 planar format data with 8-bit precision,
/// and converts it to BGRA format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `gray_image` - Source YUV gray image.
/// * `bgra_data` - A mutable slice to store the converted BGRA data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGRA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv400_to_bgra(
    gray_image: &YuvGrayImage<u8>,
    bgra: &mut [u8],
    bgra_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    y_to_rgbx::<{ YuvSourceChannels::Bgra as u8 }>(gray_image, bgra, bgra_stride, range, matrix)
}
