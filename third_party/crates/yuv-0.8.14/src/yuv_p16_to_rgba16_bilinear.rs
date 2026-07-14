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
    y_plane: &[u16],
    u_plane: &[u16],
    v_plane: &[u16],
    rgba: &mut [u16],
    width: u32,
);

type DoubleRowInterpolator = fn(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i16>,
    y_plane: &[u16],
    u_plane0: &[u16],
    u_plane1: &[u16],
    v_plane0: &[u16],
    v_plane1: &[u16],
    rgba: &mut [u16],
    width: u32,
);

#[allow(dead_code)]
fn interpolate_1_row<const DESTINATION_CHANNELS: u8, const Q: i32, const BIT_DEPTH: usize>(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i16>,
    y_plane: &[u16],
    u_plane: &[u16],
    v_plane: &[u16],
    rgba: &mut [u16],
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

    let max_colors = ((1u32 << BIT_DEPTH) - 1) as u16;

    // Bilinear upscaling weights in Q0.2

    for (((rgba, y_src), u_src), v_src) in rgba
        .chunks_exact_mut(channels * 2)
        .zip(y_plane.chunks_exact(2))
        .zip(u_plane.windows(2))
        .zip(v_plane.windows(2))
    {
        let cb_0 = ((u_src[0] as u32 * 3 + u_src[1] as u32 + 2) >> 2) as u16;
        let cr_0 = ((v_src[0] as u32 * 3 + v_src[1] as u32 + 2) >> 2) as u16;

        let cb_1 = ((u_src[0] as u32 + (u_src[1] as u32) * 3 + 2) >> 2) as u16;
        let cr_1 = ((v_src[0] as u32 + (v_src[1] as u32) * 3 + 2) >> 2) as u16;

        let y_value0 = (y_src[0] as i32 - bias_y as i32) * y_coef as i32;
        let cb_value0 = cb_0 as i16 - bias_uv;
        let cr_value0 = cr_0 as i16 - bias_uv;

        let r0 = qrshr::<Q, BIT_DEPTH>(y_value0 + cr_coef as i32 * cr_value0 as i32);
        let b0 = qrshr::<Q, BIT_DEPTH>(y_value0 + cb_coef as i32 * cb_value0 as i32);
        let g0 = qrshr::<Q, BIT_DEPTH>(
            y_value0 - g_coef_1 as i32 * cr_value0 as i32 - g_coef_2 as i32 * cb_value0 as i32,
        );

        let rgba0 = &mut rgba[..channels];

        rgba0[dst_chans.get_r_channel_offset()] = r0 as u16;
        rgba0[dst_chans.get_g_channel_offset()] = g0 as u16;
        rgba0[dst_chans.get_b_channel_offset()] = b0 as u16;
        if dst_chans.has_alpha() {
            rgba0[dst_chans.get_a_channel_offset()] = max_colors;
        }

        let y_value1 = (y_src[1] as i32 - bias_y as i32) * y_coef as i32;
        let cb_value1 = cb_1 as i32 - bias_uv as i32;
        let cr_value1 = cr_1 as i32 - bias_uv as i32;

        let r0 = qrshr::<Q, BIT_DEPTH>(y_value1 + cr_coef as i32 * cr_value1);
        let b0 = qrshr::<Q, BIT_DEPTH>(y_value1 + cb_coef as i32 * cb_value1);
        let g0 = qrshr::<Q, BIT_DEPTH>(
            y_value1 - g_coef_1 as i32 * cr_value1 - g_coef_2 as i32 * cb_value1,
        );

        let rgba1 = &mut rgba[channels..channels * 2];

        rgba1[dst_chans.get_r_channel_offset()] = r0 as u16;
        rgba1[dst_chans.get_g_channel_offset()] = g0 as u16;
        rgba1[dst_chans.get_b_channel_offset()] = b0 as u16;
        if dst_chans.has_alpha() {
            rgba1[dst_chans.get_a_channel_offset()] = max_colors;
        }
    }

    let y_chunks = y_plane.chunks_exact(2);
    let y_remainder = y_chunks.remainder();
    let rgba_chunks = rgba.chunks_exact_mut(channels * 2);
    let rgba_remainder = rgba_chunks.into_remainder();

    if let ([last_y], rgba) = (y_remainder, rgba_remainder) {
        let y_value0 = (*last_y as i32 - bias_y as i32) * y_coef as i32;
        let cb_value = *u_plane.last().unwrap() as i32 - bias_uv as i32;
        let cr_value = *v_plane.last().unwrap() as i32 - bias_uv as i32;
        let rgba0 = &mut rgba[..channels];

        let r0 = qrshr::<Q, BIT_DEPTH>(y_value0 + cr_coef as i32 * cr_value);
        let b0 = qrshr::<Q, BIT_DEPTH>(y_value0 + cb_coef as i32 * cb_value);
        let g0 = qrshr::<Q, BIT_DEPTH>(
            y_value0 - g_coef_1 as i32 * cr_value - g_coef_2 as i32 * cb_value,
        );
        rgba0[dst_chans.get_r_channel_offset()] = r0 as u16;
        rgba0[dst_chans.get_g_channel_offset()] = g0 as u16;
        rgba0[dst_chans.get_b_channel_offset()] = b0 as u16;
        if dst_chans.has_alpha() {
            rgba0[dst_chans.get_a_channel_offset()] = max_colors;
        }
    }
}

#[allow(dead_code)]
fn interpolate_2_rows<const DESTINATION_CHANNELS: u8, const Q: i32, const BIT_DEPTH: usize>(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i16>,
    y_plane: &[u16],
    u_plane0: &[u16],
    u_plane1: &[u16],
    v_plane0: &[u16],
    v_plane1: &[u16],
    rgba: &mut [u16],
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

    let max_colors = ((1u32 << BIT_DEPTH) - 1) as u16;

    // Bilinear upscaling weights in Q0.4

    for (((((rgba0, y_src0), u_src), u_src_next), v_src), v_src_next) in rgba
        .chunks_exact_mut(channels * 2)
        .zip(y_plane.chunks_exact(2))
        .zip(u_plane0.windows(2))
        .zip(u_plane1.windows(2))
        .zip(v_plane0.windows(2))
        .zip(v_plane1.windows(2))
    {
        let cb_0 = (u_src[0] as u32 * 9
            + u_src[1] as u32 * 3
            + u_src_next[0] as u32 * 3
            + u_src_next[1] as u32
            + (1 << 3))
            >> 4;
        let cr_0 = (v_src[0] as u32 * 9
            + v_src[1] as u32 * 3
            + v_src_next[0] as u32 * 3
            + v_src_next[1] as u32
            + (1 << 3))
            >> 4;

        let cb_1 = (u_src[0] as u32 * 3
            + u_src[1] as u32 * 9
            + u_src_next[0] as u32
            + u_src_next[1] as u32 * 3
            + (1 << 3))
            >> 4;
        let cr_1 = (v_src[0] as u32 * 3
            + v_src[1] as u32 * 9
            + v_src_next[0] as u32
            + v_src_next[1] as u32 * 3
            + (1 << 3))
            >> 4;

        let y_value0 = (y_src0[0] as i32 - bias_y as i32) * y_coef as i32;
        let cb_value0 = cb_0 as i32 - bias_uv as i32;
        let cr_value0 = cr_0 as i32 - bias_uv as i32;

        let g_built_coeff0 = -g_coef_1 as i32 * cr_value0 - g_coef_2 as i32 * cb_value0;

        let r0 = qrshr::<Q, BIT_DEPTH>(y_value0 + cr_coef as i32 * cr_value0);
        let b0 = qrshr::<Q, BIT_DEPTH>(y_value0 + cb_coef as i32 * cb_value0);
        let g0 = qrshr::<Q, BIT_DEPTH>(y_value0 + g_built_coeff0);

        let rgba00 = &mut rgba0[..channels];

        rgba00[dst_chans.get_r_channel_offset()] = r0 as u16;
        rgba00[dst_chans.get_g_channel_offset()] = g0 as u16;
        rgba00[dst_chans.get_b_channel_offset()] = b0 as u16;
        if dst_chans.has_alpha() {
            rgba00[dst_chans.get_a_channel_offset()] = max_colors;
        }

        let y_value1 = (y_src0[1] as i32 - bias_y as i32) * y_coef as i32;
        let cb_value1 = cb_1 as i32 - bias_uv as i32;
        let cr_value1 = cr_1 as i32 - bias_uv as i32;

        let g_built_coeff1 = -g_coef_1 as i32 * cr_value1 - g_coef_2 as i32 * cb_value1;

        let r1 = qrshr::<Q, BIT_DEPTH>(y_value1 + cr_coef as i32 * cr_value1);
        let b1 = qrshr::<Q, BIT_DEPTH>(y_value1 + cb_coef as i32 * cb_value1);
        let g1 = qrshr::<Q, BIT_DEPTH>(y_value1 + g_built_coeff1);

        let rgba01 = &mut rgba0[channels..channels * 2];

        rgba01[dst_chans.get_r_channel_offset()] = r1 as u16;
        rgba01[dst_chans.get_g_channel_offset()] = g1 as u16;
        rgba01[dst_chans.get_b_channel_offset()] = b1 as u16;
        if dst_chans.has_alpha() {
            rgba01[dst_chans.get_a_channel_offset()] = max_colors;
        }
    }

    let y_chunks = y_plane.chunks_exact(2);
    let y_remainder = y_chunks.remainder();
    let rgba_chunks = rgba.chunks_exact_mut(channels * 2);
    let rgba_remainder = rgba_chunks.into_remainder();

    if let ([last_y], rgba) = (y_remainder, rgba_remainder) {
        let y_value0 = (*last_y as i32 - bias_y as i32) * y_coef as i32;

        let cb_0 =
            (*u_plane0.last().unwrap() as u32 * 3 + *u_plane1.last().unwrap() as u32 + 2) >> 2;
        let cr_0 =
            (*v_plane0.last().unwrap() as u32 + (*v_plane1.last().unwrap()) as u32 * 3 + 2) >> 2;

        let cb_value = cb_0 as i32 - bias_uv as i32;
        let cr_value = cr_0 as i32 - bias_uv as i32;
        let rgba0 = &mut rgba[..channels];

        let g_built_coeff = -g_coef_1 as i32 * cr_value - g_coef_2 as i32 * cb_value;

        let r0 = qrshr::<Q, BIT_DEPTH>(y_value0 + cr_coef as i32 * cr_value);
        let b0 = qrshr::<Q, BIT_DEPTH>(y_value0 + cb_coef as i32 * cb_value);
        let g0 = qrshr::<Q, BIT_DEPTH>(y_value0 + g_built_coeff);

        rgba0[dst_chans.get_r_channel_offset()] = r0 as u16;
        rgba0[dst_chans.get_g_channel_offset()] = g0 as u16;
        rgba0[dst_chans.get_b_channel_offset()] = b0 as u16;
        if dst_chans.has_alpha() {
            rgba0[dst_chans.get_a_channel_offset()] = max_colors;
        }
    }
}

fn make_1_row_interpolator<const DESTINATION_CHANNELS: u8, const Q: i32, const BIT_DEPTH: usize>(
) -> OneRowInterpolator {
    #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
    {
        if BIT_DEPTH <= 14 {
            use crate::neon::neon_planar16_bilinear_1_row_rgba16;
            return neon_planar16_bilinear_1_row_rgba16::<DESTINATION_CHANNELS, Q, BIT_DEPTH>;
        }
    }
    #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
    {
        #[cfg(feature = "avx")]
        if std::arch::is_x86_feature_detected!("avx2") {
            use crate::avx2::avx_planar16_bilinear_1_row_rgba;
            return avx_planar16_bilinear_1_row_rgba::<DESTINATION_CHANNELS, Q, BIT_DEPTH>;
        }
        #[cfg(feature = "sse")]
        if std::arch::is_x86_feature_detected!("sse4.1") {
            use crate::sse::sse_planar16_bilinear_1_row_rgba;
            return sse_planar16_bilinear_1_row_rgba::<DESTINATION_CHANNELS, Q, BIT_DEPTH>;
        }
    }
    interpolate_1_row::<DESTINATION_CHANNELS, Q, BIT_DEPTH>
}

fn make_2_rows_interpolator<
    const DESTINATION_CHANNELS: u8,
    const Q: i32,
    const BIT_DEPTH: usize,
>() -> DoubleRowInterpolator {
    #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
    {
        if BIT_DEPTH <= 14 {
            use crate::neon::neon_planar16_bilinear_2_rows_rgba;
            return neon_planar16_bilinear_2_rows_rgba::<DESTINATION_CHANNELS, Q, BIT_DEPTH>;
        }
    }
    #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
    {
        #[cfg(feature = "avx")]
        if std::arch::is_x86_feature_detected!("avx2") {
            use crate::avx2::avx_planar16_bilinear_2_rows_rgba;
            return avx_planar16_bilinear_2_rows_rgba::<DESTINATION_CHANNELS, Q, BIT_DEPTH>;
        }
        #[cfg(feature = "sse")]
        if std::arch::is_x86_feature_detected!("sse4.1") {
            use crate::sse::sse_planar16_bilinear_2_rows_rgba;
            return sse_planar16_bilinear_2_rows_rgba::<DESTINATION_CHANNELS, Q, BIT_DEPTH>;
        }
    }
    interpolate_2_rows::<DESTINATION_CHANNELS, Q, BIT_DEPTH>
}

fn yuv16_to_rgbx_impl_bilinear<
    const DESTINATION_CHANNELS: u8,
    const SAMPLING: u8,
    const Q: i32,
    const BIT_DEPTH: usize,
>(
    image: &YuvPlanarImage<u16>,
    rgba: &mut [u16],
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

    let chroma_range = get_yuv_range(BIT_DEPTH as u32, range);
    let kr_kb = matrix.get_kr_kb();

    let inverse_transform =
        search_inverse_transform(Q, BIT_DEPTH as u32, range, matrix, chroma_range, kr_kb).cast();

    let one_row_interpolator = make_1_row_interpolator::<DESTINATION_CHANNELS, Q, BIT_DEPTH>();
    let two_rows_interpolator = make_2_rows_interpolator::<DESTINATION_CHANNELS, Q, BIT_DEPTH>();

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

fn yuv_to_rgbx<const DESTINATION_CHANNELS: u8, const SAMPLING: u8, const BIT_DEPTH: usize>(
    image: &YuvPlanarImage<u16>,
    rgba: &mut [u16],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuv16_to_rgbx_impl_bilinear::<DESTINATION_CHANNELS, SAMPLING, 13, BIT_DEPTH>(
        image,
        rgba,
        rgba_stride,
        range,
        matrix,
    )
}

macro_rules! d_cnv {
    ($method: ident, $px_fmt: expr, $sampling: expr, $sampling_written: expr, $px_written: expr, $px_written_small: expr, $bit_depth: expr) => {
        #[doc = concat!("
Convert ",$sampling_written, " planar format with ", stringify!($bit_depth), " bit pixel format to ", $px_written," ", stringify!($bit_depth), " bit-depth format using bi-linear upsampling.

This function takes ", $sampling_written, " planar data with ", stringify!($bit_depth), " bit precision.
and converts it to ", $px_written," format with ", stringify!($bit_depth), " bit-depth precision per channel
with bilinear upscampling.

# Arguments

* `planar_image` - Source ",$sampling_written," planar image.
* `", $px_written_small, "` - A mutable slice to store the converted ", $px_written," ", stringify!($bit_depth), " bit-depth data.
* `", $px_written_small, "_stride` - The stride (components per row) for ", $px_written," ", stringify!($bit_depth), " bit-depth data.
* `range` - The YUV range (limited or full).
* `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).

# Panics

This function panics if the lengths of the planes or the input ", $px_written," data are not valid based
on the specified width, height, and strides, or if invalid YUV range or matrix is provided.")]
        pub fn $method(
            planar_image: &YuvPlanarImage<u16>,
            dst: &mut [u16],
            dst_stride: u32,
            range: YuvRange,
            matrix: YuvStandardMatrix,
        ) -> Result<(), YuvError> {
            yuv_to_rgbx::<{ $px_fmt as u8 },
                            { $sampling as u8 }, $bit_depth>(
                planar_image, dst, dst_stride, range, matrix)
        }
    };
}

d_cnv!(
    i010_to_rgba10_bilinear,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv420,
    "I010",
    "RGBA",
    "rgba",
    10
);
d_cnv!(
    i010_to_rgb10_bilinear,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv420,
    "I010",
    "RGB",
    "rgb",
    10
);
d_cnv!(
    i210_to_rgba10_bilinear,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv422,
    "I210",
    "RGBA",
    "rgba",
    10
);
d_cnv!(
    i210_to_rgb10_bilinear,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv422,
    "I210",
    "RGB",
    "rgb",
    10
);

d_cnv!(
    i012_to_rgba12_bilinear,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv420,
    "I012",
    "RGBA",
    "rgba",
    12
);
d_cnv!(
    i012_to_rgb12_bilinear,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv420,
    "I012",
    "RGB",
    "rgb",
    12
);
d_cnv!(
    i212_to_rgba12_bilinear,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv422,
    "I212",
    "RGBA",
    "rgba",
    12
);
d_cnv!(
    i212_to_rgb12_bilinear,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv422,
    "I212",
    "RGB",
    "rgb",
    12
);

// 4:2:0, 14 bit

d_cnv!(
    i014_to_rgba14_bilinear,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv420,
    "I014",
    "RGBA",
    "rgba",
    14
);
d_cnv!(
    i014_to_rgb14_bilinear,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv420,
    "I014",
    "RGB",
    "rgb",
    14
);

// 14-bit, 4:2:2

d_cnv!(
    i214_to_rgba14_bilinear,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv422,
    "I214",
    "RGBA",
    "rgba",
    14
);
d_cnv!(
    i214_to_rgb14_bilinear,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv422,
    "I214",
    "RGB",
    "rgb",
    14
);
// 14-bit, 4:4:4

d_cnv!(
    i414_to_rgba14_bilinear,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv444,
    "I414",
    "RGBA",
    "rgba",
    14
);
d_cnv!(
    i414_to_rgb14_bilinear,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv444,
    "I414",
    "RGB",
    "rgb",
    14
);

// 4:2:0, 16 bit

d_cnv!(
    i016_to_rgba16_bilinear,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv420,
    "I016",
    "RGBA",
    "rgba",
    16
);
d_cnv!(
    i016_to_rgb16_bilinear,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv420,
    "I016",
    "RGB",
    "rgb",
    16
);

// 16-bit, 4:2:2

d_cnv!(
    i216_to_rgba16_bilinear,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv422,
    "I216",
    "RGBA",
    "rgba",
    16
);
d_cnv!(
    i216_to_rgb16_bilinear,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv422,
    "I216",
    "RGB",
    "rgb",
    16
);
