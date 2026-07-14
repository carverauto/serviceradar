/*
 * Copyright (c) Radzivon Bartoshyk, 02/2025. All rights reserved.
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
use crate::images::{projected_rgba_plane_mut, YuvPlanarProjectionAlpha};
use crate::ycgcor_support::YCgCoR;
use crate::yuv_error::check_rgba_destination;
use crate::yuv_support::*;
use crate::{YuvError, YuvPlanarImageWithAlpha};
use num_traits::AsPrimitive;
#[cfg(feature = "rayon")]
use rayon::iter::{IndexedParallelIterator, ParallelIterator};
#[cfg(feature = "rayon")]
use rayon::prelude::{ParallelSlice, ParallelSliceMut};
use std::fmt::Debug;
use std::ops::Sub;

#[inline(always)]
/// Saturating rounding shift right against bit depth
fn qrshr<const PRECISION: i32, const BP: usize, const R_TYPE: usize>(val: i32) -> i32 {
    let r_type: YCgCoR = YCgCoR::from(R_TYPE);
    let max_value: i32 = (1 << BP) - 1;
    let rounding: i32 = (1 << (PRECISION)) - 1;
    match r_type {
        YCgCoR::YCgCoRo => ((val + rounding) >> PRECISION).min(max_value).max(0),
        YCgCoR::YCgCoRe => ((val + rounding) >> PRECISION).min(max_value).max(0),
    }
}

/// Convert YCgCo-Re/YCgCo-Ro with alpha to RGB
/// Note: YCgCo-Re/YCgCo-Ro requires to adjust range on RGB rather than YUV
fn ycgce_ro_alpha_rgbx<
    V: AsPrimitive<J> + 'static + Default + Debug + Sync + Send + AsPrimitive<i32>,
    W: 'static + Default + Debug + Sync + Send + Copy + Clone,
    J: Copy + AsPrimitive<i32> + 'static + Sub<Output = J> + Send + Sync,
    const DESTINATION_CHANNELS: u8,
    const SAMPLING: u8,
    const BIT_DEPTH: usize,
    const R_TYPE: usize,
>(
    image: &YuvPlanarImageWithAlpha<V>,
    rgba: &mut [W],
    rgba_stride: u32,
    range: YuvRange,
) -> Result<(), YuvError>
where
    i32: AsPrimitive<V> + AsPrimitive<W>,
    u32: AsPrimitive<J>,
{
    let r_type: YCgCoR = YCgCoR::from(R_TYPE);
    let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();
    let dst_chans: YuvSourceChannels = DESTINATION_CHANNELS.into();
    let channels = dst_chans.get_channels_count();

    check_rgba_destination(rgba, rgba_stride, image.width, image.height, channels)?;
    image.check_constraints(chroma_subsampling)?;

    let yuv_bit_depth = match YCgCoR::from(R_TYPE) {
        YCgCoR::YCgCoRo => BIT_DEPTH as u32 + 1,
        YCgCoR::YCgCoRe => BIT_DEPTH as u32 + 2,
    };

    let chroma_range = get_yuv_range(yuv_bit_depth, range);

    let bias_y: J = chroma_range.bias_y.as_();
    let bias_uv: J = chroma_range.bias_uv.as_();

    const PRECISION: i32 = 13;

    let cap_colors = ((1u32 << BIT_DEPTH) - 1u32) as i32;
    let precision_scale = (1 << PRECISION) as f32;

    let max_colors_for_reduction = ((1u32 << yuv_bit_depth) - 1u32) as i32;

    let range_reduction_y = (max_colors_for_reduction as f32 / chroma_range.range_y as f32
        * precision_scale)
        .round() as i16;

    let a_shift = match r_type {
        YCgCoR::YCgCoRo => 1,
        YCgCoR::YCgCoRe => 2,
    };
    let a_rounding = match r_type {
        YCgCoR::YCgCoRo => 1,
        YCgCoR::YCgCoRe => 2,
    };

    let process_halved_chroma_row = |y_plane: &[V],
                                     u_plane: &[V],
                                     v_plane: &[V],
                                     a_plane: &[V],
                                     rgba: &mut [W]| {
        for ((((rgba, y_src), &u_src), &v_src), a_src) in rgba
            .chunks_exact_mut(channels * 2)
            .zip(y_plane.chunks_exact(2))
            .zip(u_plane.iter())
            .zip(v_plane.iter())
            .zip(a_plane.chunks_exact(2))
        {
            let yy0: J = y_src[0].as_();
            let y_value0 = (yy0 - bias_y).as_();
            let uu0: J = u_src.as_();
            let cg_value: i32 = (uu0 - bias_uv).as_();
            let vv0: J = v_src.as_();
            let co_value = (vv0 - bias_uv).as_();

            let t0 = y_value0 - (cg_value >> 1);
            let bz0 = t0 - (co_value >> 1);

            let r0 =
                qrshr::<PRECISION, BIT_DEPTH, R_TYPE>((bz0 + co_value) * range_reduction_y as i32);
            let b0 = qrshr::<PRECISION, BIT_DEPTH, R_TYPE>(bz0 * range_reduction_y as i32);
            let g0 =
                qrshr::<PRECISION, BIT_DEPTH, R_TYPE>((t0 + cg_value) * range_reduction_y as i32);

            let rgba0 = &mut rgba[..channels];

            rgba0[dst_chans.get_r_channel_offset()] = r0.as_();
            rgba0[dst_chans.get_g_channel_offset()] = g0.as_();
            rgba0[dst_chans.get_b_channel_offset()] = b0.as_();
            if dst_chans.has_alpha() {
                let a: i32 = a_src[0].as_();
                rgba0[dst_chans.get_a_channel_offset()] =
                    ((a + a_rounding) >> a_shift).min(cap_colors).as_();
            }

            let yy1: J = y_src[1].as_();
            let y_value1 = (yy1 - bias_y).as_();

            let t1 = y_value1 - (cg_value >> 1);
            let bz1 = t1 - (co_value >> 1);

            let r1 =
                qrshr::<PRECISION, BIT_DEPTH, R_TYPE>((bz1 + co_value) * range_reduction_y as i32);
            let b1 = qrshr::<PRECISION, BIT_DEPTH, R_TYPE>(bz1 * range_reduction_y as i32);
            let g1 =
                qrshr::<PRECISION, BIT_DEPTH, R_TYPE>((t1 + cg_value) * range_reduction_y as i32);

            let rgba1 = &mut rgba[channels..channels * 2];

            rgba1[dst_chans.get_r_channel_offset()] = r1.as_();
            rgba1[dst_chans.get_g_channel_offset()] = g1.as_();
            rgba1[dst_chans.get_b_channel_offset()] = b1.as_();
            if dst_chans.has_alpha() {
                let a: i32 = a_src[1].as_();
                rgba1[dst_chans.get_a_channel_offset()] =
                    ((a + a_rounding) >> a_shift).min(cap_colors).as_();
            }
        }

        if image.width & 1 != 0 {
            let yy0: J = y_plane.last().unwrap().as_();
            let y_value0 = (yy0 - bias_y).as_();
            let cg0: J = u_plane.last().unwrap().as_();
            let cg_value = (cg0 - bias_uv).as_();
            let co0: J = v_plane.last().unwrap().as_();
            let co_value = (co0 - bias_uv).as_();
            let rgba = rgba.chunks_exact_mut(channels).last().unwrap();
            let a: i32 = a_plane.last().unwrap().as_();
            let rgba0 = &mut rgba[0..channels];

            let t0 = y_value0 - (cg_value >> 1);
            let bz0 = t0 - (co_value >> 1);

            let r0 =
                qrshr::<PRECISION, BIT_DEPTH, R_TYPE>((bz0 + co_value) * range_reduction_y as i32);
            let b0 = qrshr::<PRECISION, BIT_DEPTH, R_TYPE>(bz0 * range_reduction_y as i32);
            let g0 =
                qrshr::<PRECISION, BIT_DEPTH, R_TYPE>((t0 + cg_value) * range_reduction_y as i32);

            rgba0[dst_chans.get_r_channel_offset()] = r0.as_();
            rgba0[dst_chans.get_g_channel_offset()] = g0.as_();
            rgba0[dst_chans.get_b_channel_offset()] = b0.as_();
            if dst_chans.has_alpha() {
                rgba0[dst_chans.get_a_channel_offset()] =
                    ((a + a_rounding) >> a_shift).min(cap_colors).as_();
            }
        }
    };

    let YuvPlanarProjectionAlpha {
        y: y_plane,
        u: u_plane,
        v: v_plane,
        a: a_plane,
    } = image.projected_planes(chroma_subsampling);
    let rgba = projected_rgba_plane_mut(rgba, image.width, image.height, rgba_stride, dst_chans);

    if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
        let iter;
        #[cfg(feature = "rayon")]
        {
            iter = rgba
                .par_chunks_mut(rgba_stride as usize)
                .zip(y_plane.par_chunks(image.y_stride as usize))
                .zip(u_plane.par_chunks(image.u_stride as usize))
                .zip(v_plane.par_chunks(image.v_stride as usize))
                .zip(a_plane.par_chunks(image.a_stride as usize));
        }
        #[cfg(not(feature = "rayon"))]
        {
            iter = rgba
                .chunks_mut(rgba_stride as usize)
                .zip(y_plane.chunks(image.y_stride as usize))
                .zip(u_plane.chunks(image.u_stride as usize))
                .zip(v_plane.chunks(image.v_stride as usize))
                .zip(a_plane.chunks(image.a_stride as usize));
        }
        iter.for_each(|((((rgba, y_plane), u_plane), v_plane), a_plane)| {
            let y_plane = &y_plane[..image.width as usize];
            for ((((rgba, &y_src), &u_src), &v_src), &a_src) in rgba
                .chunks_exact_mut(channels)
                .zip(y_plane.iter())
                .zip(u_plane.iter())
                .zip(v_plane.iter())
                .zip(a_plane.iter())
            {
                let yy0: J = y_src.as_();
                let y_value = (yy0 - bias_y).as_();
                let cg0: J = u_src.as_();
                let cg_value = (cg0 - bias_uv).as_();
                let co0: J = v_src.as_();
                let co_value = (co0 - bias_uv).as_();

                let t0 = y_value - (cg_value >> 1);
                let bz0 = t0 - (co_value >> 1);

                let r = qrshr::<PRECISION, BIT_DEPTH, R_TYPE>(
                    (bz0 + co_value) * range_reduction_y as i32,
                );
                let b = qrshr::<PRECISION, BIT_DEPTH, R_TYPE>((bz0) * range_reduction_y as i32);
                let g = qrshr::<PRECISION, BIT_DEPTH, R_TYPE>(
                    (t0 + cg_value) * range_reduction_y as i32,
                );

                rgba[dst_chans.get_r_channel_offset()] = r.as_();
                rgba[dst_chans.get_g_channel_offset()] = g.as_();
                rgba[dst_chans.get_b_channel_offset()] = b.as_();
                if dst_chans.has_alpha() {
                    let a: i32 = a_src.as_();
                    rgba[dst_chans.get_a_channel_offset()] =
                        ((a + 1) >> a_shift).min(cap_colors).as_();
                }
            }
        });
    } else if chroma_subsampling == YuvChromaSubsampling::Yuv422 {
        let iter;
        #[cfg(feature = "rayon")]
        {
            iter = rgba
                .par_chunks_mut(rgba_stride as usize)
                .zip(y_plane.par_chunks(image.y_stride as usize))
                .zip(u_plane.par_chunks(image.u_stride as usize))
                .zip(v_plane.par_chunks(image.v_stride as usize))
                .zip(a_plane.par_chunks(image.a_stride as usize));
        }
        #[cfg(not(feature = "rayon"))]
        {
            iter = rgba
                .chunks_mut(rgba_stride as usize)
                .zip(y_plane.chunks(image.y_stride as usize))
                .zip(u_plane.chunks(image.u_stride as usize))
                .zip(v_plane.chunks(image.v_stride as usize))
                .zip(a_plane.chunks(image.a_stride as usize));
        }
        iter.for_each(|((((rgba, y_plane), u_plane), v_plane), a_plane)| {
            process_halved_chroma_row(
                &y_plane[..image.width as usize],
                &u_plane[..(image.width as usize).div_ceil(2)],
                &v_plane[..(image.width as usize).div_ceil(2)],
                &a_plane[..image.width as usize],
                &mut rgba[..image.width as usize * channels],
            );
        });
    } else if chroma_subsampling == YuvChromaSubsampling::Yuv420 {
        let iter;
        #[cfg(feature = "rayon")]
        {
            iter = rgba
                .par_chunks_mut(rgba_stride as usize * 2)
                .zip(y_plane.par_chunks(image.y_stride as usize * 2))
                .zip(u_plane.par_chunks(image.u_stride as usize))
                .zip(v_plane.par_chunks(image.v_stride as usize))
                .zip(a_plane.par_chunks(image.a_stride as usize * 2));
        }
        #[cfg(not(feature = "rayon"))]
        {
            iter = rgba
                .chunks_mut(rgba_stride as usize * 2)
                .zip(y_plane.chunks(image.y_stride as usize * 2))
                .zip(u_plane.chunks(image.u_stride as usize))
                .zip(v_plane.chunks(image.v_stride as usize))
                .zip(a_plane.chunks(image.a_stride as usize * 2));
        }
        iter.take(image.height as usize / 2).for_each(
            |((((rgba, y_plane), u_plane), v_plane), a_plane)| {
                let (rgba0, rgba1) = rgba.split_at_mut(rgba_stride as usize);
                let (alpha0, alpha1) = a_plane.split_at(image.a_stride as usize);
                let (y_plane0, y_plane1) = y_plane.split_at(image.y_stride as usize);

                process_halved_chroma_row(
                    &y_plane0[..image.width as usize],
                    &u_plane[..(image.width as usize).div_ceil(2)],
                    &v_plane[..(image.width as usize).div_ceil(2)],
                    &alpha0[..image.width as usize],
                    &mut rgba0[..image.width as usize * channels],
                );

                process_halved_chroma_row(
                    &y_plane1[..image.width as usize],
                    &u_plane[..(image.width as usize).div_ceil(2)],
                    &v_plane[..(image.width as usize).div_ceil(2)],
                    &alpha1[..image.width as usize],
                    &mut rgba1[..image.width as usize * channels],
                );
            },
        );

        if image.height & 1 != 0 {
            let rgba = rgba.chunks_mut(rgba_stride as usize).last().unwrap();
            let u_plane = u_plane.chunks(image.u_stride as usize).last().unwrap();
            let v_plane = v_plane.chunks(image.v_stride as usize).last().unwrap();
            let y_plane = y_plane.chunks(image.y_stride as usize).last().unwrap();
            let a_plane = a_plane.chunks(image.a_stride as usize).last().unwrap();
            process_halved_chroma_row(
                &y_plane[..image.width as usize],
                &u_plane[..(image.width as usize).div_ceil(2)],
                &v_plane[..(image.width as usize).div_ceil(2)],
                &a_plane[..image.width as usize],
                &mut rgba[..image.width as usize * channels],
            );
        }
    } else {
        unreachable!();
    }

    Ok(())
}

macro_rules! d_cnv {
    ($method: ident, $clazz: ident, $target_clazz: ident, $r_type: expr, $bp: expr, $cn: expr, $subsampling: expr, $rgb_name: expr, $yuv_name: expr, $intermediate: ident) => {
        #[doc = concat!("Convert ", $yuv_name," planar format with alpha to  ", $rgb_name, stringify!($bp)," format.

This function takes ", $yuv_name," planar format with alpha data with ", stringify!($bp),"-bit precision,
and converts it to ", $rgb_name, stringify!($bp)," format with ", stringify!($bp),"-bit per channel precision.

# Arguments

* `image` - Source ",$yuv_name," image.
* `dst` - A mutable slice to store the converted ", $rgb_name, stringify!($bp)," data.
* `dst_stride` - Elements per row.
* `range` - The YUV range (limited or full).

# Panics

This function panics if the lengths of the planes or the input ", $rgb_name, stringify!($bp)," data are not valid based
on the specified width, height, and strides, or if invalid YUV range or matrix is provided.")]
        pub fn $method(
            image: &YuvPlanarImageWithAlpha<$clazz>,
            dst: &mut [$target_clazz],
            dst_stride: u32,
            range: YuvRange,
        ) -> Result<(), YuvError> {
            ycgce_ro_alpha_rgbx::<$clazz, $target_clazz, $intermediate, { $cn as u8 }, { $subsampling as u8 }, $bp, $r_type>(
                image,
                dst,
                dst_stride,
                range,
            )
        }
    };
}

d_cnv!(
    icgc_re_alpha010_to_rgba,
    u16,
    u8,
    { YCgCoR::YCgCoRe as usize },
    8,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv420,
    "RGBA",
    "YCgCo-Re 420 10-bit",
    i16
);
d_cnv!(
    icgc_re_alpha010_to_bgra,
    u16,
    u8,
    { YCgCoR::YCgCoRe as usize },
    8,
    YuvSourceChannels::Bgra,
    YuvChromaSubsampling::Yuv420,
    "BGRA",
    "YCgCo-Re 420 10-bit",
    i16
);

d_cnv!(
    icgc_ro_alpha010_to_rgba,
    u16,
    u8,
    { YCgCoR::YCgCoRo as usize },
    8,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv420,
    "RGBA",
    "YCgCo-Ro 420 10-bit",
    i16
);
d_cnv!(
    icgc_ro_alpha010_to_bgra,
    u16,
    u8,
    { YCgCoR::YCgCoRo as usize },
    8,
    YuvSourceChannels::Bgra,
    YuvChromaSubsampling::Yuv420,
    "BGRA",
    "YCgCo-Ro 420 10-bit",
    i16
);

// YUV 4:2:@

d_cnv!(
    icgc_re_alpha210_to_rgba,
    u16,
    u8,
    { YCgCoR::YCgCoRe as usize },
    8,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv422,
    "RGBA",
    "YCgCo-Re 422 10-bit",
    i16
);
d_cnv!(
    icgc_re_alpha210_to_bgra,
    u16,
    u8,
    { YCgCoR::YCgCoRe as usize },
    8,
    YuvSourceChannels::Bgra,
    YuvChromaSubsampling::Yuv422,
    "BGRA",
    "YCgCo-Re 422 10-bit",
    i16
);

d_cnv!(
    icgc_ro_alpha210_to_rgba,
    u16,
    u8,
    { YCgCoR::YCgCoRo as usize },
    8,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv422,
    "RGBA",
    "YCgCo-Ro 422 10-bit",
    i16
);
d_cnv!(
    icgc_ro_alpha210_to_bgra,
    u16,
    u8,
    { YCgCoR::YCgCoRo as usize },
    8,
    YuvSourceChannels::Bgra,
    YuvChromaSubsampling::Yuv422,
    "BGRA",
    "YCgCo-Ro 422 10-bit",
    i16
);

// YUV 4:4:4

d_cnv!(
    icgc_re_alpha410_to_rgba,
    u16,
    u8,
    { YCgCoR::YCgCoRe as usize },
    8,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv444,
    "RGBA",
    "YCgCo-Re 444 10-bit",
    i16
);
d_cnv!(
    icgc_re_alpha410_to_bgra,
    u16,
    u8,
    { YCgCoR::YCgCoRe as usize },
    8,
    YuvSourceChannels::Bgra,
    YuvChromaSubsampling::Yuv444,
    "BGRA",
    "YCgCo-Re 444 10-bit",
    i16
);

d_cnv!(
    icgc_ro_alpha410_to_rgba,
    u16,
    u8,
    { YCgCoR::YCgCoRo as usize },
    8,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv444,
    "RGBA",
    "YCgCo-Ro 444 10-bit",
    i16
);
d_cnv!(
    icgc_ro_alpha410_to_bgra,
    u16,
    u8,
    { YCgCoR::YCgCoRo as usize },
    8,
    YuvSourceChannels::Bgra,
    YuvChromaSubsampling::Yuv444,
    "BGRA",
    "YCgCo-Ro 444 10-bit",
    i16
);

// ICgC 0 12-bit

d_cnv!(
    icgc_re_alpha012_to_rgba10,
    u16,
    u16,
    { YCgCoR::YCgCoRe as usize },
    10,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv420,
    "RGBA",
    "YCgCo-Re 4:2:0 12-bit",
    i16
);

d_cnv!(
    icgc_ro_alpha012_to_rgba10,
    u16,
    u16,
    { YCgCoR::YCgCoRo as usize },
    10,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv420,
    "RGBA",
    "YCgCo-Ro 4:2:0 12-bit",
    i16
);

// ICgC 2 12-bit

d_cnv!(
    icgc_re_alpha212_to_rgba10,
    u16,
    u16,
    { YCgCoR::YCgCoRe as usize },
    10,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv422,
    "RGBA",
    "YCgCo-Re 4:2:2 12-bit",
    i16
);

d_cnv!(
    icgc_ro_alpha212_to_rgba10,
    u16,
    u16,
    { YCgCoR::YCgCoRo as usize },
    10,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv422,
    "RGBA",
    "YCgCo-Ro 4:2:2 12-bit",
    i16
);

// ICgC 4 12-bit

d_cnv!(
    icgc_re_alpha412_to_rgba10,
    u16,
    u16,
    { YCgCoR::YCgCoRe as usize },
    10,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv444,
    "RGBA",
    "YCgCo-Re 4:4:4 12-bit",
    i16
);

d_cnv!(
    icgc_ro_alpha412_to_rgba10,
    u16,
    u16,
    { YCgCoR::YCgCoRo as usize },
    10,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv444,
    "RGBA",
    "YCgCo-Ro 4:4:4 12-bit",
    i16
);
