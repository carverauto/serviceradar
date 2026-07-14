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
use crate::numerics::qrshr;
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

/// Convert YCgCo with alpha to RGBA
/// Note: YCgCo requires to adjust range on RGB rather than YUV
fn ycgco_ro_rgbx_alpha<
    V: AsPrimitive<J> + 'static + Default + Debug + Send + Sync,
    J: Copy + AsPrimitive<i32> + 'static + Sub<Output = J> + Send + Sync,
    const DESTINATION_CHANNELS: u8,
    const SAMPLING: u8,
    const BIT_DEPTH: usize,
>(
    image: &YuvPlanarImageWithAlpha<V>,
    rgba: &mut [V],
    rgba_stride: u32,
    range: YuvRange,
) -> Result<(), YuvError>
where
    i32: AsPrimitive<V>,
    u32: AsPrimitive<J>,
{
    let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();
    let dst_chans: YuvSourceChannels = DESTINATION_CHANNELS.into();
    assert!(dst_chans == YuvSourceChannels::Rgba || dst_chans == YuvSourceChannels::Bgra);
    assert!(dst_chans.has_alpha());
    let channels = dst_chans.get_channels_count();

    check_rgba_destination(rgba, rgba_stride, image.width, image.height, channels)?;
    image.check_constraints(chroma_subsampling)?;

    let range = get_yuv_range(BIT_DEPTH as u32, range);
    let bias_y: J = range.bias_y.as_();
    let bias_uv: J = range.bias_uv.as_();

    const PRECISION: i32 = 13;

    let max_colors = (1 << BIT_DEPTH) - 1i32;
    let precision_scale = (1 << PRECISION) as f32;

    let range_reduction_y =
        (max_colors as f32 / range.range_y as f32 * precision_scale).round() as i16;

    let process_halved_chroma_row =
        |y_plane: &[V], u_plane: &[V], v_plane: &[V], a_plane: &[V], rgba: &mut [V]| {
            for ((((rgba, y_src), &u_src), &v_src), a_src) in rgba
                .chunks_exact_mut(channels * 2)
                .zip(y_plane.chunks_exact(2))
                .zip(u_plane.iter())
                .zip(v_plane.iter())
                .zip(a_plane.chunks_exact(2))
            {
                let y_value0 = (y_src[0].as_() - bias_y).as_();
                let cb_value = (u_src.as_() - bias_uv).as_();
                let cr_value = (v_src.as_() - bias_uv).as_();
                let a0 = a_src[0];

                let t0 = y_value0 - cb_value;

                let r0 = qrshr::<PRECISION, BIT_DEPTH>((t0 + cr_value) * range_reduction_y as i32);
                let b0 = qrshr::<PRECISION, BIT_DEPTH>((t0 - cr_value) * range_reduction_y as i32);
                let g0 =
                    qrshr::<PRECISION, BIT_DEPTH>((y_value0 + cb_value) * range_reduction_y as i32);

                let rgba0 = &mut rgba[..channels];

                rgba0[dst_chans.get_r_channel_offset()] = r0.as_();
                rgba0[dst_chans.get_g_channel_offset()] = g0.as_();
                rgba0[dst_chans.get_b_channel_offset()] = b0.as_();
                rgba0[dst_chans.get_a_channel_offset()] = a0;

                let y_value1 = (y_src[1].as_() - bias_y).as_();

                let t1 = y_value1 - cb_value;

                let a1 = a_src[1];

                let r1 = qrshr::<PRECISION, BIT_DEPTH>((t1 + cr_value) * range_reduction_y as i32);
                let b1 = qrshr::<PRECISION, BIT_DEPTH>((t1 - cr_value) * range_reduction_y as i32);
                let g1 =
                    qrshr::<PRECISION, BIT_DEPTH>((y_value1 + cb_value) * range_reduction_y as i32);

                let rgba1 = &mut rgba[channels..channels * 2];

                rgba1[dst_chans.get_r_channel_offset()] = r1.as_();
                rgba1[dst_chans.get_g_channel_offset()] = g1.as_();
                rgba1[dst_chans.get_b_channel_offset()] = b1.as_();
                rgba1[dst_chans.get_a_channel_offset()] = a1;
            }

            if image.width & 1 != 0 {
                let y_value0 = (y_plane.last().unwrap().as_() - bias_y).as_();
                let a_value0 = a_plane.last().unwrap();
                let cb_value = (u_plane.last().unwrap().as_() - bias_uv).as_();
                let cr_value = (v_plane.last().unwrap().as_() - bias_uv).as_();
                let rgba = rgba.chunks_exact_mut(channels).last().unwrap();
                let rgba0 = &mut rgba[..channels];

                let t0 = y_value0 - cb_value;

                let r0 = qrshr::<PRECISION, BIT_DEPTH>((t0 + cr_value) * range_reduction_y as i32);
                let b0 = qrshr::<PRECISION, BIT_DEPTH>((t0 - cr_value) * range_reduction_y as i32);
                let g0 =
                    qrshr::<PRECISION, BIT_DEPTH>((y_value0 + cb_value) * range_reduction_y as i32);
                rgba0[dst_chans.get_r_channel_offset()] = r0.as_();
                rgba0[dst_chans.get_g_channel_offset()] = g0.as_();
                rgba0[dst_chans.get_b_channel_offset()] = b0.as_();
                rgba0[dst_chans.get_a_channel_offset()] = *a_value0;
            }
        };

    let process_doubled_chroma_row = |y_plane0: &[V],
                                      y_plane1: &[V],
                                      u_plane: &[V],
                                      v_plane: &[V],
                                      a_plane0: &[V],
                                      a_plane1: &[V],
                                      rgba0: &mut [V],
                                      rgba1: &mut [V]| {
        for (((((((rgba0, rgba1), y_src0), y_src1), &u_src), &v_src), a_src0), a_src1) in rgba0
            .chunks_exact_mut(channels * 2)
            .zip(rgba1.chunks_exact_mut(channels * 2))
            .zip(y_plane0.chunks_exact(2))
            .zip(y_plane1.chunks_exact(2))
            .zip(u_plane.iter())
            .zip(v_plane.iter())
            .zip(a_plane0.chunks_exact(2))
            .zip(a_plane1.chunks_exact(2))
        {
            let y_value0 = (y_src0[0].as_() - bias_y).as_();
            let cb_value = (u_src.as_() - bias_uv).as_();
            let cr_value = (v_src.as_() - bias_uv).as_();

            let t0 = y_value0 - cb_value;

            let r0 = qrshr::<PRECISION, BIT_DEPTH>((t0 + cr_value) * range_reduction_y as i32);
            let b0 = qrshr::<PRECISION, BIT_DEPTH>((t0 - cr_value) * range_reduction_y as i32);
            let g0 =
                qrshr::<PRECISION, BIT_DEPTH>((y_value0 + cb_value) * range_reduction_y as i32);

            let rgba00 = &mut rgba0[..channels];

            rgba00[dst_chans.get_r_channel_offset()] = r0.as_();
            rgba00[dst_chans.get_g_channel_offset()] = g0.as_();
            rgba00[dst_chans.get_b_channel_offset()] = b0.as_();
            rgba00[dst_chans.get_a_channel_offset()] = a_src0[0];

            let y_value1 = (y_src0[1].as_() - bias_y).as_();

            let t1 = y_value1 - cb_value;

            let r1 = qrshr::<PRECISION, BIT_DEPTH>((t1 + cr_value) * range_reduction_y as i32);
            let b1 = qrshr::<PRECISION, BIT_DEPTH>((t1 - cr_value) * range_reduction_y as i32);
            let g1 =
                qrshr::<PRECISION, BIT_DEPTH>((y_value1 + cb_value) * range_reduction_y as i32);

            let rgba01 = &mut rgba0[channels..channels * 2];

            rgba01[dst_chans.get_r_channel_offset()] = r1.as_();
            rgba01[dst_chans.get_g_channel_offset()] = g1.as_();
            rgba01[dst_chans.get_b_channel_offset()] = b1.as_();
            rgba01[dst_chans.get_a_channel_offset()] = a_src0[1];

            let y_value10 = (y_src1[0].as_() - bias_y).as_();

            let t10 = y_value10 - cb_value;

            let r10 = qrshr::<PRECISION, BIT_DEPTH>((t10 + cr_value) * range_reduction_y as i32);
            let b10 = qrshr::<PRECISION, BIT_DEPTH>((t10 - cr_value) * range_reduction_y as i32);
            let g10 =
                qrshr::<PRECISION, BIT_DEPTH>((y_value10 + cb_value) * range_reduction_y as i32);

            let rgba10 = &mut rgba1[..channels];

            rgba10[dst_chans.get_r_channel_offset()] = r10.as_();
            rgba10[dst_chans.get_g_channel_offset()] = g10.as_();
            rgba10[dst_chans.get_b_channel_offset()] = b10.as_();
            rgba10[dst_chans.get_a_channel_offset()] = a_src1[0];

            let y_value11 = (y_src1[1].as_() - bias_y).as_();

            let t11 = y_value11 - cb_value;

            let r11 = qrshr::<PRECISION, BIT_DEPTH>((t11 + cr_value) * range_reduction_y as i32);
            let b11 = qrshr::<PRECISION, BIT_DEPTH>((t11 - cr_value) * range_reduction_y as i32);
            let g11 =
                qrshr::<PRECISION, BIT_DEPTH>((y_value11 + cb_value) * range_reduction_y as i32);

            let rgba11 = &mut rgba1[channels..channels * 2];

            rgba11[dst_chans.get_r_channel_offset()] = r11.as_();
            rgba11[dst_chans.get_g_channel_offset()] = g11.as_();
            rgba11[dst_chans.get_b_channel_offset()] = b11.as_();
            rgba11[dst_chans.get_a_channel_offset()] = a_src1[1];
        }

        if image.width & 1 != 0 {
            let y_value0 = (y_plane0.last().unwrap().as_() - bias_y).as_();
            let y_value1 = (y_plane1.last().unwrap().as_() - bias_y).as_();
            let a_value0 = a_plane0.last().unwrap();
            let a_value1 = a_plane1.last().unwrap();
            let cb_value = (u_plane.last().unwrap().as_() - bias_uv).as_();
            let cr_value = (v_plane.last().unwrap().as_() - bias_uv).as_();
            let rgba = rgba0.chunks_exact_mut(channels).last().unwrap();
            let rgba0 = &mut rgba[..channels];

            let t0 = y_value0 - cb_value;

            let r0 = qrshr::<PRECISION, BIT_DEPTH>((t0 + cr_value) * range_reduction_y as i32);
            let b0 = qrshr::<PRECISION, BIT_DEPTH>((t0 - cr_value) * range_reduction_y as i32);
            let g0 =
                qrshr::<PRECISION, BIT_DEPTH>((y_value0 + cb_value) * range_reduction_y as i32);

            rgba0[dst_chans.get_r_channel_offset()] = r0.as_();
            rgba0[dst_chans.get_g_channel_offset()] = g0.as_();
            rgba0[dst_chans.get_b_channel_offset()] = b0.as_();
            rgba0[dst_chans.get_a_channel_offset()] = *a_value0;

            let t1 = y_value1 - cb_value;

            let r1 = qrshr::<PRECISION, BIT_DEPTH>((t1 + cr_value) * range_reduction_y as i32);
            let b1 = qrshr::<PRECISION, BIT_DEPTH>((t1 - cr_value) * range_reduction_y as i32);
            let g1 =
                qrshr::<PRECISION, BIT_DEPTH>((y_value1 + cb_value) * range_reduction_y as i32);

            let rgba = rgba1.chunks_exact_mut(channels).last().unwrap();
            let rgba1 = &mut rgba[..channels];
            rgba1[dst_chans.get_r_channel_offset()] = r1.as_();
            rgba1[dst_chans.get_g_channel_offset()] = g1.as_();
            rgba1[dst_chans.get_b_channel_offset()] = b1.as_();
            rgba1[dst_chans.get_a_channel_offset()] = *a_value1;
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
            let a_plane = &a_plane[..image.width as usize];
            for ((((rgba, &y_src), &u_src), &v_src), &a_src) in rgba
                .chunks_exact_mut(channels)
                .zip(y_plane.iter())
                .zip(u_plane.iter())
                .zip(v_plane.iter())
                .zip(a_plane.iter())
            {
                let y_value = (y_src.as_() - bias_y).as_();
                let cb_value = (u_src.as_() - bias_uv).as_();
                let cr_value = (v_src.as_() - bias_uv).as_();

                let t0 = y_value - cb_value;

                let r = qrshr::<PRECISION, BIT_DEPTH>((t0 + cr_value) * range_reduction_y as i32);
                let b = qrshr::<PRECISION, BIT_DEPTH>((t0 - cr_value) * range_reduction_y as i32);
                let g =
                    qrshr::<PRECISION, BIT_DEPTH>((y_value + cb_value) * range_reduction_y as i32);

                rgba[dst_chans.get_r_channel_offset()] = r.as_();
                rgba[dst_chans.get_g_channel_offset()] = g.as_();
                rgba[dst_chans.get_b_channel_offset()] = b.as_();
                rgba[dst_chans.get_a_channel_offset()] = a_src;
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
                let (y_plane0, y_plane1) = y_plane.split_at(image.y_stride as usize);
                let (a_plane0, a_plane1) = a_plane.split_at(image.a_stride as usize);
                process_doubled_chroma_row(
                    &y_plane0[..image.width as usize],
                    &y_plane1[..image.width as usize],
                    &u_plane[..(image.width as usize).div_ceil(2)],
                    &v_plane[..(image.width as usize).div_ceil(2)],
                    &a_plane0[..image.width as usize],
                    &a_plane1[..image.width as usize],
                    &mut rgba0[..image.width as usize * channels],
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
    ($method: ident, $clazz: ident, $bp: expr, $cn: expr, $subsampling: expr, $rgb_name: expr, $yuv_name: expr, $intermediate: ident) => {
        #[doc = concat!("Convert ", $yuv_name," planar format to  ", $rgb_name, stringify!($bp)," format.

This function takes ", $yuv_name," planar format data with alpha ", stringify!($bp),"-bit precision,
and converts it to ", $rgb_name, stringify!($bp)," format to ", stringify!($bp),"-bit per channel precision.

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
            dst: &mut [$clazz],
            dst_stride: u32,
            range: YuvRange,
        ) -> Result<(), YuvError> {
            ycgco_ro_rgbx_alpha::<$clazz, $intermediate, { $cn as u8 }, { $subsampling as u8 }, $bp>(
                image,
                dst,
                dst_stride,
                range,
            )
        }
    };
}

d_cnv!(
    ycgco420_alpha_to_rgba,
    u8,
    8,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv420,
    "RGBA",
    "YCgCo 420",
    i16
);
d_cnv!(
    ycgco420_alpha_to_bgra,
    u8,
    8,
    YuvSourceChannels::Bgra,
    YuvChromaSubsampling::Yuv420,
    "BGRA",
    "YCgCo 420",
    i16
);

d_cnv!(
    ycgco422_alpha_to_rgba,
    u8,
    8,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv422,
    "RGBA",
    "YCgCo 422",
    i16
);
d_cnv!(
    ycgco422_alpha_to_bgra,
    u8,
    8,
    YuvSourceChannels::Bgra,
    YuvChromaSubsampling::Yuv422,
    "BGRA",
    "YCgCo 422",
    i16
);

d_cnv!(
    ycgco444_alpha_to_rgba,
    u8,
    8,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv444,
    "RGBA",
    "YCgCo 444",
    i16
);
d_cnv!(
    ycgco444_alpha_to_bgra,
    u8,
    8,
    YuvSourceChannels::Bgra,
    YuvChromaSubsampling::Yuv444,
    "BGRA",
    "YCgCo 444",
    i16
);

d_cnv!(
    icgc010_alpha_to_rgba10,
    u16,
    10,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv420,
    "RGBA",
    "YCgCo 4:2:0 10-bit",
    i16
);
d_cnv!(
    icgc210_alpha_to_rgba10,
    u16,
    10,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv422,
    "RGBA",
    "YCgCo 4:2:2 10-bit",
    i16
);
d_cnv!(
    icgc410_alpha_to_rgba10,
    u16,
    10,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv444,
    "RGBA",
    "YCgCo 4:4:4 10-bit",
    i16
);

// 12-bit
d_cnv!(
    icgc012_alpha_to_rgba12,
    u16,
    12,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv420,
    "RGBA",
    "YCgCo 4:2:0 12-bit",
    i16
);
d_cnv!(
    icgc212_alpha_to_rgba12,
    u16,
    12,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv422,
    "RGBA",
    "YCgCo 4:2:2 12-bit",
    i16
);
d_cnv!(
    icgc412_alpha_to_rgba12,
    u16,
    12,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv444,
    "RGBA",
    "YCgCo 4:4:4 12-bit",
    i16
);
