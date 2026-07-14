/*
 * Copyright (c) Radzivon Bartoshyk, 6/2025. All rights reserved.
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
use crate::numerics::qrshr;
use crate::yuv_error::check_rgba_destination;
use crate::yuv_support::*;
use crate::{YuvError, YuvPlanarImage};
#[cfg(feature = "rayon")]
use rayon::iter::{IndexedParallelIterator, ParallelIterator};
#[cfg(feature = "rayon")]
use rayon::prelude::{ParallelSlice, ParallelSliceMut};

type OneRowInterpolator = fn(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i16>,
    y_plane: &[u8],
    u_plane: &[u8],
    v_plane: &[u8],
    rgba: &mut [u8],
    width: u32,
);

type DoubleRowInterpolator = fn(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i16>,
    y_plane: &[u8],
    u_plane0: &[u8],
    u_plane1: &[u8],
    v_plane0: &[u8],
    v_plane1: &[u8],
    rgba: &mut [u8],
    width: u32,
);

#[allow(dead_code)]
fn interpolate_1_row<const DESTINATION_CHANNELS: u8, const Q: i32>(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i16>,
    y_plane: &[u8],
    u_plane: &[u8],
    v_plane: &[u8],
    rgba: &mut [u8],
    _: u32,
) {
    let dst_chans: YuvSourceChannels = DESTINATION_CHANNELS.into();
    let channels = dst_chans.get_channels_count();

    let cr_coef = transform.cr_coef;
    let cb_coef = transform.cb_coef;
    let y_coef = transform.y_coef;
    let g_coef_1 = transform.g_coeff_1;
    let g_coef_2 = transform.g_coeff_2;

    let bias_y = range.bias_y as i16;
    let bias_uv = range.bias_uv as i16;

    const BIT_DEPTH: usize = 8;

    // Bilinear upscaling weights in Q0.2

    for (((rgba, y_src), u_src), v_src) in rgba
        .chunks_exact_mut(channels * 2)
        .zip(y_plane.chunks_exact(2))
        .zip(u_plane.windows(2))
        .zip(v_plane.windows(2))
    {
        let cb_0 = (u_src[0] as u16 * 3 + u_src[1] as u16 + 2) >> 2;
        let cr_0 = (v_src[0] as u16 * 3 + v_src[1] as u16 + 2) >> 2;

        let cb_1 = (u_src[0] as u16 + u_src[1] as u16 * 3 + 2) >> 2;
        let cr_1 = (v_src[0] as u16 + v_src[1] as u16 * 3 + 2) >> 2;

        let y_value0 = (y_src[0] as i32 - bias_y as i32) * y_coef as i32;
        let cb_value0 = cb_0 as i16 - bias_uv;
        let cr_value0 = cr_0 as i16 - bias_uv;

        let r0 = qrshr::<Q, BIT_DEPTH>(y_value0 + cr_coef as i32 * cr_value0 as i32);
        let b0 = qrshr::<Q, BIT_DEPTH>(y_value0 + cb_coef as i32 * cb_value0 as i32);
        let g0 = qrshr::<Q, BIT_DEPTH>(
            y_value0 - g_coef_1 as i32 * cr_value0 as i32 - g_coef_2 as i32 * cb_value0 as i32,
        );

        let rgba0 = &mut rgba[..channels];

        rgba0[dst_chans.get_r_channel_offset()] = r0 as u8;
        rgba0[dst_chans.get_g_channel_offset()] = g0 as u8;
        rgba0[dst_chans.get_b_channel_offset()] = b0 as u8;
        if dst_chans.has_alpha() {
            rgba0[dst_chans.get_a_channel_offset()] = 255u8;
        }

        let y_value1 = (y_src[1] as i32 - bias_y as i32) * y_coef as i32;
        let cb_value1 = cb_1 as i16 - bias_uv;
        let cr_value1 = cr_1 as i16 - bias_uv;

        let r0 = qrshr::<Q, BIT_DEPTH>(y_value1 + cr_coef as i32 * cr_value1 as i32);
        let b0 = qrshr::<Q, BIT_DEPTH>(y_value1 + cb_coef as i32 * cb_value1 as i32);
        let g0 = qrshr::<Q, BIT_DEPTH>(
            y_value1 - g_coef_1 as i32 * cr_value1 as i32 - g_coef_2 as i32 * cb_value1 as i32,
        );

        let rgba1 = &mut rgba[channels..channels * 2];

        rgba1[dst_chans.get_r_channel_offset()] = r0 as u8;
        rgba1[dst_chans.get_g_channel_offset()] = g0 as u8;
        rgba1[dst_chans.get_b_channel_offset()] = b0 as u8;
        if dst_chans.has_alpha() {
            rgba1[dst_chans.get_a_channel_offset()] = 255u8;
        }
    }

    let y_chunks = y_plane.chunks_exact(2);
    let y_remainder = y_chunks.remainder();
    let rgba_chunks = rgba.chunks_exact_mut(channels * 2);
    let rgba_remainder = rgba_chunks.into_remainder();

    if let ([last_y], rgba) = (y_remainder, rgba_remainder) {
        let y_value0 = (*last_y as i32 - bias_y as i32) * y_coef as i32;
        let cb_value = *u_plane.last().unwrap() as i16 - bias_uv;
        let cr_value = *v_plane.last().unwrap() as i16 - bias_uv;
        let rgba0 = &mut rgba[..channels];

        let r0 = qrshr::<Q, BIT_DEPTH>(y_value0 + cr_coef as i32 * cr_value as i32);
        let b0 = qrshr::<Q, BIT_DEPTH>(y_value0 + cb_coef as i32 * cb_value as i32);
        let g0 = qrshr::<Q, BIT_DEPTH>(
            y_value0 - g_coef_1 as i32 * cr_value as i32 - g_coef_2 as i32 * cb_value as i32,
        );
        rgba0[dst_chans.get_r_channel_offset()] = r0 as u8;
        rgba0[dst_chans.get_g_channel_offset()] = g0 as u8;
        rgba0[dst_chans.get_b_channel_offset()] = b0 as u8;
        if dst_chans.has_alpha() {
            rgba0[dst_chans.get_a_channel_offset()] = 255;
        }
    }
}

#[allow(dead_code)]
fn interpolate_2_rows<const DESTINATION_CHANNELS: u8, const Q: i32>(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i16>,
    y_plane: &[u8],
    u_plane0: &[u8],
    u_plane1: &[u8],
    v_plane0: &[u8],
    v_plane1: &[u8],
    rgba: &mut [u8],
    _: u32,
) {
    let dst_chans: YuvSourceChannels = DESTINATION_CHANNELS.into();
    let channels = dst_chans.get_channels_count();

    let cr_coef = transform.cr_coef;
    let cb_coef = transform.cb_coef;
    let y_coef = transform.y_coef;
    let g_coef_1 = transform.g_coeff_1;
    let g_coef_2 = transform.g_coeff_2;

    let bias_y = range.bias_y as i16;
    let bias_uv = range.bias_uv as i16;

    const BIT_DEPTH: usize = 8;

    // Bilinear upscaling weights in Q0.4

    for (((((rgba0, y_src0), u_src), u_src_next), v_src), v_src_next) in rgba
        .chunks_exact_mut(channels * 2)
        .zip(y_plane.chunks_exact(2))
        .zip(u_plane0.windows(2))
        .zip(u_plane1.windows(2))
        .zip(v_plane0.windows(2))
        .zip(v_plane1.windows(2))
    {
        let cb_0 = (u_src[0] as u16 * 9
            + u_src[1] as u16 * 3
            + u_src_next[0] as u16 * 3
            + u_src_next[1] as u16
            + (1 << 3))
            >> 4;
        let cr_0 = (v_src[0] as u16 * 9
            + v_src[1] as u16 * 3
            + v_src_next[0] as u16 * 3
            + v_src_next[1] as u16
            + (1 << 3))
            >> 4;

        let cb_1 = (u_src[0] as u16 * 3
            + u_src[1] as u16 * 9
            + u_src_next[0] as u16
            + u_src_next[1] as u16 * 3
            + (1 << 3))
            >> 4;
        let cr_1 = (v_src[0] as u16 * 3
            + v_src[1] as u16 * 9
            + v_src_next[0] as u16
            + v_src_next[1] as u16 * 3
            + (1 << 3))
            >> 4;

        let y_value0 = (y_src0[0] as i32 - bias_y as i32) * y_coef as i32;
        let cb_value0 = cb_0 as i16 - bias_uv;
        let cr_value0 = cr_0 as i16 - bias_uv;

        let g_built_coeff0 =
            -g_coef_1 as i32 * cr_value0 as i32 - g_coef_2 as i32 * cb_value0 as i32;

        let r0 = qrshr::<Q, BIT_DEPTH>(y_value0 + cr_coef as i32 * cr_value0 as i32);
        let b0 = qrshr::<Q, BIT_DEPTH>(y_value0 + cb_coef as i32 * cb_value0 as i32);
        let g0 = qrshr::<Q, BIT_DEPTH>(y_value0 + g_built_coeff0);

        let rgba00 = &mut rgba0[..channels];

        rgba00[dst_chans.get_r_channel_offset()] = r0 as u8;
        rgba00[dst_chans.get_g_channel_offset()] = g0 as u8;
        rgba00[dst_chans.get_b_channel_offset()] = b0 as u8;
        if dst_chans.has_alpha() {
            rgba00[dst_chans.get_a_channel_offset()] = 255u8;
        }

        let y_value1 = (y_src0[1] as i32 - bias_y as i32) * y_coef as i32;
        let cb_value1 = cb_1 as i16 - bias_uv;
        let cr_value1 = cr_1 as i16 - bias_uv;

        let g_built_coeff1 =
            -g_coef_1 as i32 * cr_value1 as i32 - g_coef_2 as i32 * cb_value1 as i32;

        let r1 = qrshr::<Q, BIT_DEPTH>(y_value1 + cr_coef as i32 * cr_value1 as i32);
        let b1 = qrshr::<Q, BIT_DEPTH>(y_value1 + cb_coef as i32 * cb_value1 as i32);
        let g1 = qrshr::<Q, BIT_DEPTH>(y_value1 + g_built_coeff1);

        let rgba01 = &mut rgba0[channels..channels * 2];

        rgba01[dst_chans.get_r_channel_offset()] = r1 as u8;
        rgba01[dst_chans.get_g_channel_offset()] = g1 as u8;
        rgba01[dst_chans.get_b_channel_offset()] = b1 as u8;
        if dst_chans.has_alpha() {
            rgba01[dst_chans.get_a_channel_offset()] = 255u8;
        }
    }

    let y_chunks = y_plane.chunks_exact(2);
    let y_remainder = y_chunks.remainder();
    let rgba_chunks = rgba.chunks_exact_mut(channels * 2);
    let rgba_remainder = rgba_chunks.into_remainder();

    if let ([last_y], rgba) = (y_remainder, rgba_remainder) {
        let y_value0 = (*last_y as i32 - bias_y as i32) * y_coef as i32;

        let cb_0 =
            (*u_plane0.last().unwrap() as u16 * 3 + *u_plane1.last().unwrap() as u16 + 2) >> 2;
        let cr_0 =
            (*v_plane0.last().unwrap() as u16 + (*v_plane1.last().unwrap()) as u16 * 3 + 2) >> 2;

        let cb_value = cb_0 as i16 - bias_uv;
        let cr_value = cr_0 as i16 - bias_uv;
        let rgba0 = &mut rgba[..channels];

        let g_built_coeff = -g_coef_1 as i32 * cr_value as i32 - g_coef_2 as i32 * cb_value as i32;

        let r0 = qrshr::<Q, BIT_DEPTH>(y_value0 + cr_coef as i32 * cr_value as i32);
        let b0 = qrshr::<Q, BIT_DEPTH>(y_value0 + cb_coef as i32 * cb_value as i32);
        let g0 = qrshr::<Q, BIT_DEPTH>(y_value0 + g_built_coeff);

        rgba0[dst_chans.get_r_channel_offset()] = r0 as u8;
        rgba0[dst_chans.get_g_channel_offset()] = g0 as u8;
        rgba0[dst_chans.get_b_channel_offset()] = b0 as u8;
        if dst_chans.has_alpha() {
            rgba0[dst_chans.get_a_channel_offset()] = 255;
        }
    }
}

fn make_1_row_interpolator<const DESTINATION_CHANNELS: u8, const Q: i32>() -> OneRowInterpolator {
    #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
    {
        use crate::neon::neon_bilinear_interpolate_1_row_rgba;
        neon_bilinear_interpolate_1_row_rgba::<DESTINATION_CHANNELS, Q>
    }
    #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
    {
        #[cfg(feature = "avx")]
        if std::arch::is_x86_feature_detected!("avx2") {
            use crate::avx2::avx_bilinear_interpolate_1_row_rgba;
            return avx_bilinear_interpolate_1_row_rgba::<DESTINATION_CHANNELS, Q>;
        }
        #[cfg(feature = "sse")]
        if std::arch::is_x86_feature_detected!("sse4.1") {
            use crate::sse::sse_bilinear_interpolate_1_row_rgba;
            return sse_bilinear_interpolate_1_row_rgba::<DESTINATION_CHANNELS, Q>;
        }
    }
    #[cfg(not(all(target_arch = "aarch64", target_feature = "neon")))]
    {
        interpolate_1_row::<DESTINATION_CHANNELS, Q>
    }
}

fn make_2_rows_interpolator<const DESTINATION_CHANNELS: u8, const Q: i32>() -> DoubleRowInterpolator
{
    #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
    {
        use crate::neon::neon_bilinear_interpolate_2_rows_rgba;
        neon_bilinear_interpolate_2_rows_rgba::<DESTINATION_CHANNELS, Q>
    }
    #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
    {
        #[cfg(feature = "avx")]
        if std::arch::is_x86_feature_detected!("avx2") {
            use crate::avx2::avx_bilinear_interpolate_2_rows_rgba;
            return avx_bilinear_interpolate_2_rows_rgba::<DESTINATION_CHANNELS, Q>;
        }
        #[cfg(feature = "sse")]
        if std::arch::is_x86_feature_detected!("sse4.1") {
            use crate::sse::sse_bilinear_interpolate_2_rows_rgba;
            return sse_bilinear_interpolate_2_rows_rgba::<DESTINATION_CHANNELS, Q>;
        }
    }
    #[cfg(not(all(target_arch = "aarch64", target_feature = "neon")))]
    {
        interpolate_2_rows::<DESTINATION_CHANNELS, Q>
    }
}

fn yuv_to_rgbx_impl_bilinear<const DESTINATION_CHANNELS: u8, const SAMPLING: u8, const Q: i32>(
    image: &YuvPlanarImage<u8>,
    rgba: &mut [u8],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();
    assert_ne!(chroma_subsampling, YuvChromaSubsampling::Yuv444);
    let dst_chans: YuvSourceChannels = DESTINATION_CHANNELS.into();
    let channels = dst_chans.get_channels_count();

    check_rgba_destination(rgba, rgba_stride, image.width, image.height, channels)?;
    image.check_constraints(chroma_subsampling)?;

    let chroma_range = get_yuv_range(8, range);
    let kr_kb = matrix.get_kr_kb();

    let inverse_transform =
        search_inverse_transform(Q, 8, range, matrix, chroma_range, kr_kb).cast();

    let one_row_interpolator = make_1_row_interpolator::<DESTINATION_CHANNELS, Q>();
    let two_rows_interpolator = make_2_rows_interpolator::<DESTINATION_CHANNELS, Q>();

    if chroma_subsampling == YuvChromaSubsampling::Yuv422 {
        let iter;
        #[cfg(feature = "rayon")]
        {
            iter = rgba
                .par_chunks_exact_mut(rgba_stride as usize)
                .zip(image.y_plane.par_chunks_exact(image.y_stride as usize))
                .zip(image.u_plane.par_chunks_exact(image.u_stride as usize))
                .zip(image.v_plane.par_chunks_exact(image.v_stride as usize));
        }
        #[cfg(not(feature = "rayon"))]
        {
            iter = rgba
                .chunks_exact_mut(rgba_stride as usize)
                .zip(image.y_plane.chunks_exact(image.y_stride as usize))
                .zip(image.u_plane.chunks_exact(image.u_stride as usize))
                .zip(image.v_plane.chunks_exact(image.v_stride as usize));
        }
        iter.for_each(|(((rgba, y_plane), u_plane), v_plane)| {
            one_row_interpolator(
                &chroma_range,
                &inverse_transform,
                &y_plane[..image.width as usize],
                &u_plane[..(image.width as usize).div_ceil(2)],
                &v_plane[..(image.width as usize).div_ceil(2)],
                &mut rgba[..image.width as usize * channels],
                image.width,
            );
        });
    } else if chroma_subsampling == YuvChromaSubsampling::Yuv420 {
        let iter;
        #[cfg(feature = "rayon")]
        {
            iter = rgba
                .par_chunks_exact_mut(rgba_stride as usize)
                .zip(image.y_plane.par_chunks_exact(image.y_stride as usize))
                .zip(
                    image
                        .u_plane
                        .par_windows(image.u_stride as usize * 2)
                        .step_by(image.u_stride as usize),
                )
                .zip(
                    image
                        .v_plane
                        .par_windows(image.v_stride as usize * 2)
                        .step_by(image.v_stride as usize),
                );
        }
        #[cfg(not(feature = "rayon"))]
        {
            iter = rgba
                .chunks_exact_mut(rgba_stride as usize * 2)
                .zip(image.y_plane.chunks_exact(image.y_stride as usize * 2))
                .zip(
                    image
                        .u_plane
                        .windows(image.u_stride as usize * 2)
                        .step_by(image.u_stride as usize),
                )
                .zip(
                    image
                        .v_plane
                        .windows(image.v_stride as usize * 2)
                        .step_by(image.v_stride as usize),
                );
        }
        iter.for_each(|(((rgba, y_plane), u_plane), v_plane)| {
            let (y_plane0, y_plane1) = y_plane.split_at(image.y_stride as usize);
            let (rgba0, rgba1) = rgba.split_at_mut(rgba_stride as usize);
            let (u_plane0, u_plane1) = u_plane.split_at(image.u_stride as usize);
            let (v_plane0, v_plane1) = v_plane.split_at(image.v_stride as usize);
            two_rows_interpolator(
                &chroma_range,
                &inverse_transform,
                &y_plane0[..image.width as usize],
                &u_plane0[..(image.width as usize).div_ceil(2)],
                &u_plane1[..(image.width as usize).div_ceil(2)],
                &v_plane0[..(image.width as usize).div_ceil(2)],
                &v_plane1[..(image.width as usize).div_ceil(2)],
                &mut rgba0[..image.width as usize * channels],
                image.width,
            );
            two_rows_interpolator(
                &chroma_range,
                &inverse_transform,
                &y_plane1[..image.width as usize],
                &u_plane1[..(image.width as usize).div_ceil(2)],
                &u_plane0[..(image.width as usize).div_ceil(2)],
                &v_plane1[..(image.width as usize).div_ceil(2)],
                &v_plane0[..(image.width as usize).div_ceil(2)],
                &mut rgba1[..image.width as usize * channels],
                image.width,
            );
        });

        if image.height & 1 != 0 {
            let rgba = rgba.chunks_exact_mut(rgba_stride as usize).last().unwrap();
            let u_plane = image
                .u_plane
                .chunks_exact(image.u_stride as usize)
                .last()
                .unwrap();
            let v_plane = image
                .v_plane
                .chunks_exact(image.v_stride as usize)
                .last()
                .unwrap();
            let y_plane = image
                .y_plane
                .chunks_exact(image.y_stride as usize)
                .last()
                .unwrap();
            one_row_interpolator(
                &chroma_range,
                &inverse_transform,
                &y_plane[..image.width as usize],
                &u_plane[..(image.width as usize).div_ceil(2)],
                &v_plane[..(image.width as usize).div_ceil(2)],
                &mut rgba[..image.width as usize * channels],
                image.width,
            );
        }
    } else {
        unreachable!();
    }

    Ok(())
}

fn yuv_to_rgbx<const DESTINATION_CHANNELS: u8, const SAMPLING: u8>(
    image: &YuvPlanarImage<u8>,
    rgba: &mut [u8],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuv_to_rgbx_impl_bilinear::<DESTINATION_CHANNELS, SAMPLING, 13>(
        image,
        rgba,
        rgba_stride,
        range,
        matrix,
    )
}

/// Convert YUV 420 planar format to RGB format with bi-linear upscaling.
///
/// This function takes YUV 420 planar format data with 8-bit precision,
/// and converts it to RGB format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `planar_image` - Source planar image.
/// * `rgb` - A mutable slice to store the converted RGB data.
/// * `rgb_stride` - The stride (components per row) for the RGB image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input RGB data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv420_to_rgb_bilinear(
    planar_image: &YuvPlanarImage<u8>,
    rgb: &mut [u8],
    rgb_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuv_to_rgbx::<{ YuvSourceChannels::Rgb as u8 }, { YuvChromaSubsampling::Yuv420 as u8 }>(
        planar_image,
        rgb,
        rgb_stride,
        range,
        matrix,
    )
}

/// Convert YUV 420 planar format to BGR format with bi-linear upscaling.
///
/// This function takes YUV 420 planar format data with 8-bit precision,
/// and converts it to BGR format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `planar_image` - Source planar image.
/// * `rgb` - A mutable slice to store the converted BGR data.
/// * `rgb_stride` - The stride (components per row) for the BGR image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGR data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv420_to_bgr_bilinear(
    planar_image: &YuvPlanarImage<u8>,
    bgr: &mut [u8],
    bgr_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuv_to_rgbx::<{ YuvSourceChannels::Bgr as u8 }, { YuvChromaSubsampling::Yuv420 as u8 }>(
        planar_image,
        bgr,
        bgr_stride,
        range,
        matrix,
    )
}

/// Convert YUV 420 planar format to RGBA format with bi-linear upscaling.
///
/// This function takes YUV 420 planar format data with 8-bit precision,
/// and converts it to RGBA format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `planar_image` - Source planar image.
/// * `rgba` - A mutable slice to store the converted RGBA data.
/// * `rgba_stride` - Elements per row.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input RGBA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv420_to_rgba_bilinear(
    planar_image: &YuvPlanarImage<u8>,
    rgba: &mut [u8],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuv_to_rgbx::<{ YuvSourceChannels::Rgba as u8 }, { YuvChromaSubsampling::Yuv420 as u8 }>(
        planar_image,
        rgba,
        rgba_stride,
        range,
        matrix,
    )
}

/// Convert YUV 420 planar format to BGRA format with bi-linear upscaling.
///
/// This function takes YUV 420 planar format data with 8-bit precision,
/// and converts it to BGRA format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `planar_image` - Source planar image.
/// * `bgra` - A mutable slice to store the converted BGRA data.
/// * `bgra_stride` - Elements per BGRA row.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGRA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv420_to_bgra_bilinear(
    planar_image: &YuvPlanarImage<u8>,
    bgra: &mut [u8],
    bgra_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuv_to_rgbx::<{ YuvSourceChannels::Bgra as u8 }, { YuvChromaSubsampling::Yuv420 as u8 }>(
        planar_image,
        bgra,
        bgra_stride,
        range,
        matrix,
    )
}

/// Convert YUV 422 planar format to RGB format with bi-linear upscaling.
///
/// This function takes YUV 422 data with 8-bit precision,
/// and converts it to RGB format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `planar_image` - Source planar image.
/// * `rgb` - A mutable slice to store the converted RGB data.
/// * `rgb_stride` - The stride (components per row) for the RGB image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input RGB data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv422_to_rgb_bilinear(
    planar_image: &YuvPlanarImage<u8>,
    rgb: &mut [u8],
    rgb_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuv_to_rgbx::<{ YuvSourceChannels::Rgb as u8 }, { YuvChromaSubsampling::Yuv422 as u8 }>(
        planar_image,
        rgb,
        rgb_stride,
        range,
        matrix,
    )
}

/// Convert YUV 422 planar format to BGR format with bi-linear upscaling.
///
/// This function takes YUV 422 data with 8-bit precision,
/// and converts it to BGR format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `planar_image` - Source planar image.
/// * `bgr` - A mutable slice to store the converted BGR data.
/// * `bgr_stride` - The stride (components per row) for the BGR image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGR data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv422_to_bgr_bilinear(
    planar_image: &YuvPlanarImage<u8>,
    bgr: &mut [u8],
    bgr_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuv_to_rgbx::<{ YuvSourceChannels::Bgr as u8 }, { YuvChromaSubsampling::Yuv422 as u8 }>(
        planar_image,
        bgr,
        bgr_stride,
        range,
        matrix,
    )
}

/// Convert YUV 422 planar format to RGBA format with bi-linear upscaling.
///
/// This function takes YUV 422 data with 8-bit precision,
/// and converts it to RGBA format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `planar_image` - Source planar image.
/// * `rgba` - A mutable slice to store the converted RGBA data.
/// * `rgba_stride` - Elements per RGBA data row.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGRA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv422_to_rgba_bilinear(
    planar_image: &YuvPlanarImage<u8>,
    rgba: &mut [u8],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuv_to_rgbx::<{ YuvSourceChannels::Rgba as u8 }, { YuvChromaSubsampling::Yuv422 as u8 }>(
        planar_image,
        rgba,
        rgba_stride,
        range,
        matrix,
    )
}

/// Convert YUV 422 planar format to BGRA format with bi-linear upscaling.
///
/// This function takes YUV 422 data with 8-bit precision,
/// and converts it to BGRA format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `planar_image` - Source planar image.
/// * `bgra` - A mutable slice to store the converted BGRA data.
/// * `bgra_stride` - Elements per RGBA data row.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGRA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv422_to_bgra_bilinear(
    planar_image: &YuvPlanarImage<u8>,
    bgra: &mut [u8],
    bgra_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuv_to_rgbx::<{ YuvSourceChannels::Bgra as u8 }, { YuvChromaSubsampling::Yuv422 as u8 }>(
        planar_image,
        bgra,
        bgra_stride,
        range,
        matrix,
    )
}
