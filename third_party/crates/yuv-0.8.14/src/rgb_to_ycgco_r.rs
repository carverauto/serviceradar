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
use crate::images::projected_rgba_plane;
use crate::ycgcor_support::YCgCoR;
use crate::yuv_error::check_rgba_destination;
use crate::yuv_support::*;
use crate::{YuvError, YuvPlanarImageMut};
use num_traits::AsPrimitive;
#[cfg(feature = "rayon")]
use rayon::iter::{IndexedParallelIterator, ParallelIterator};
#[cfg(feature = "rayon")]
use rayon::prelude::{ParallelSlice, ParallelSliceMut};
use std::fmt::Debug;

/// Convert RGB to YCgCo
/// Note: YCgCo requires to adjust range on RGB rather than YUV
fn rgbx_to_ycgco<
    V: Copy + AsPrimitive<i32> + 'static + Clone + Debug + Send + Sync,
    F: Copy + 'static + Clone + Debug + Send + Sync + Default,
    const ORIGIN_CHANNELS: u8,
    const SAMPLING: u8,
    const BP: i32,
    const R_TYPE: usize,
>(
    image: &mut YuvPlanarImageMut<F>,
    rgba: &[V],
    rgba_stride: u32,
    yuv_range: YuvRange,
) -> Result<(), YuvError>
where
    i32: AsPrimitive<V> + AsPrimitive<F>,
{
    let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();
    let src_chans: YuvSourceChannels = ORIGIN_CHANNELS.into();
    let channels = src_chans.get_channels_count();
    const PRECISION: i32 = 13;

    let new_yuv_bp = match YCgCoR::from(R_TYPE) {
        YCgCoR::YCgCoRo => BP + 1,
        YCgCoR::YCgCoRe => BP + 2,
    };
    let range = get_yuv_range(new_yuv_bp as u32, yuv_range);

    let precision_scale = (1 << PRECISION) as f32;
    let rounding_const_bias: i32 = (1 << (PRECISION - 1)) - 1;

    let bias_y = range.bias_y as i32 * (1 << PRECISION) + rounding_const_bias;
    let bias_uv = range.bias_uv as i32 * (1 << PRECISION) + rounding_const_bias;
    let max_colors_rgb = (1 << BP) - 1i32;

    let max_colors = (1 << new_yuv_bp) - 1i32;

    check_rgba_destination(rgba, rgba_stride, image.width, image.height, channels)?;
    image.check_constraints(chroma_subsampling)?;

    let old_range = get_yuv_range(BP as u32, yuv_range);
    let range_reduction_y =
        (old_range.range_y as f32 / max_colors_rgb as f32 * precision_scale).round() as i16;

    let width = image.width;
    let height = image.height;

    let process_halved_chroma_row = |y_plane: &mut [F],
                                     u_plane: &mut [F],
                                     v_plane: &mut [F],
                                     rgba: &[V]| {
        for (((y_dst, u_dst), v_dst), rgba) in y_plane
            .chunks_exact_mut(2)
            .zip(u_plane.iter_mut())
            .zip(v_plane.iter_mut())
            .zip(rgba.chunks_exact(channels * 2))
        {
            let src0 = &rgba[..channels];

            let r0 = src0[src_chans.get_r_channel_offset()].as_() * range_reduction_y as i32;
            let g0 = src0[src_chans.get_g_channel_offset()].as_() * range_reduction_y as i32;
            let b0 = src0[src_chans.get_b_channel_offset()].as_() * range_reduction_y as i32;

            let src1 = &rgba[channels..channels * 2];

            let r1 = src1[src_chans.get_r_channel_offset()].as_() * range_reduction_y as i32;
            let g1 = src1[src_chans.get_g_channel_offset()].as_() * range_reduction_y as i32;
            let b1 = src1[src_chans.get_b_channel_offset()].as_() * range_reduction_y as i32;

            let t0 = b0 + ((r0 - b0) >> 1);
            let cg0 = g0 - t0;
            let y_0 = ((t0 + (cg0 >> 1)) + bias_y) >> PRECISION;

            y_dst[0] = y_0.min(max_colors).max(0).as_();

            let t1 = b1 + ((r1 - b1) >> 1);
            let cg1 = g1 - t1;

            let y_1 = ((t1 + (cg1 >> 1)) + bias_y) >> PRECISION;

            y_dst[1] = y_1.min(max_colors).max(0).as_();

            let r = (r0 + r1 + 1) >> 1;
            let g = (g0 + g1 + 1) >> 1;
            let b = (b0 + b1 + 1) >> 1;

            let t = b + ((r - b) >> 1);

            let co = (r - b + bias_uv) >> PRECISION;
            let cg = (g - t + bias_uv) >> PRECISION;

            *u_dst = cg.min(max_colors).max(0).as_();
            *v_dst = co.min(max_colors).max(0).as_();
        }

        if width & 1 != 0 {
            let rgb_last = rgba.chunks_exact(channels * 2).remainder();
            let r0 = rgb_last[src_chans.get_r_channel_offset()].as_() * range_reduction_y as i32;
            let g0 = rgb_last[src_chans.get_g_channel_offset()].as_() * range_reduction_y as i32;
            let b0 = rgb_last[src_chans.get_b_channel_offset()].as_() * range_reduction_y as i32;

            let y_last = y_plane.last_mut().unwrap();
            let u_last = u_plane.last_mut().unwrap();
            let v_last = v_plane.last_mut().unwrap();

            let t = b0 + ((r0 - b0) >> 1);
            let co = (r0 - b0 + bias_uv) >> PRECISION;
            let cg = g0 - t;
            let y_0 = ((t + (cg >> 1)) + bias_y) >> PRECISION;

            *y_last = y_0.min(max_colors).max(0).as_();
            *u_last = ((cg + bias_uv) >> PRECISION).min(max_colors).max(0).as_();
            *v_last = co.min(max_colors).max(0).as_();
        }
    };

    let process_doubled_row = |y_plane0: &mut [F],
                               y_plane1: &mut [F],
                               u_plane: &mut [F],
                               v_plane: &mut [F],
                               rgba0: &[V],
                               rgba1: &[V]| {
        for (((((y_dst0, y_dst1), u_dst), v_dst), rgba0), rgba1) in y_plane0
            .chunks_exact_mut(2)
            .zip(y_plane1.chunks_exact_mut(2))
            .zip(u_plane.iter_mut())
            .zip(v_plane.iter_mut())
            .zip(rgba0.chunks_exact(channels * 2))
            .zip(rgba1.chunks_exact(channels * 2))
        {
            let src00 = &rgba0[0..channels];

            let r00 = src00[src_chans.get_r_channel_offset()].as_() * range_reduction_y as i32;
            let g00 = src00[src_chans.get_g_channel_offset()].as_() * range_reduction_y as i32;
            let b00 = src00[src_chans.get_b_channel_offset()].as_() * range_reduction_y as i32;

            let t00 = b00 + ((r00 - b00) >> 1);
            let cg00 = g00 - t00;
            let y_00 = ((t00 + (cg00 >> 1)) + bias_y) >> PRECISION;

            y_dst0[0] = y_00.min(max_colors).max(0).as_();

            let src1 = &rgba0[channels..channels * 2];

            let r01 = src1[src_chans.get_r_channel_offset()].as_() * range_reduction_y as i32;
            let g01 = src1[src_chans.get_g_channel_offset()].as_() * range_reduction_y as i32;
            let b01 = src1[src_chans.get_b_channel_offset()].as_() * range_reduction_y as i32;

            let t01 = b01 + ((r01 - b01) >> 1);
            let cg01 = g01 - t01;
            let y_01 = ((t01 + (cg01 >> 1)) + bias_y) >> PRECISION;

            y_dst0[1] = y_01.min(max_colors).max(0).as_();

            let src10 = &rgba1[0..channels];

            let r10 = src10[src_chans.get_r_channel_offset()].as_() * range_reduction_y as i32;
            let g10 = src10[src_chans.get_g_channel_offset()].as_() * range_reduction_y as i32;
            let b10 = src10[src_chans.get_b_channel_offset()].as_() * range_reduction_y as i32;

            let t10 = b10 + ((r10 - b10) >> 1);
            let cg10 = g10 - t10;
            let y_10 = ((t10 + (cg10 >> 1)) + bias_y) >> PRECISION;

            y_dst1[0] = y_10.min(max_colors).max(0).as_();

            let src11 = &rgba1[channels..channels * 2];

            let r11 = src11[src_chans.get_r_channel_offset()].as_() * range_reduction_y as i32;
            let g11 = src11[src_chans.get_g_channel_offset()].as_() * range_reduction_y as i32;
            let b11 = src11[src_chans.get_b_channel_offset()].as_() * range_reduction_y as i32;

            let t11 = b11 + ((r11 - b11) >> 1);
            let cg11 = g11 - t11;
            let y_11 = ((t11 + (cg11 >> 1)) + bias_y) >> PRECISION;

            y_dst1[1] = y_11.min(max_colors).max(0).as_();

            let ruv = (r00 + r01 + r10 + r11 + 2) >> 2;
            let guv = (g00 + g01 + g10 + g11 + 2) >> 2;
            let buv = (b00 + b01 + b10 + b11 + 2) >> 2;

            let t = buv + ((ruv - buv) >> 1);

            let co = (ruv - buv + bias_uv) >> PRECISION;
            let cg = (guv - t + bias_uv) >> PRECISION;

            *u_dst = cg.min(max_colors).max(0).as_();
            *v_dst = co.min(max_colors).max(0).as_();
        }

        if width & 1 != 0 {
            let rgb_last0 = rgba0.chunks_exact(channels * 2).remainder();
            let rgb_last1 = rgba1.chunks_exact(channels * 2).remainder();
            let r0 = rgb_last0[src_chans.get_r_channel_offset()].as_() * range_reduction_y as i32;
            let g0 = rgb_last0[src_chans.get_g_channel_offset()].as_() * range_reduction_y as i32;
            let b0 = rgb_last0[src_chans.get_b_channel_offset()].as_() * range_reduction_y as i32;

            let r1 = rgb_last1[src_chans.get_r_channel_offset()].as_() * range_reduction_y as i32;
            let g1 = rgb_last1[src_chans.get_g_channel_offset()].as_() * range_reduction_y as i32;
            let b1 = rgb_last1[src_chans.get_b_channel_offset()].as_() * range_reduction_y as i32;

            let y0_last = y_plane0.last_mut().unwrap();
            let y1_last = y_plane1.last_mut().unwrap();
            let u_last = u_plane.last_mut().unwrap();
            let v_last = v_plane.last_mut().unwrap();

            let t0 = b0 + ((r0 - b0) >> 1);
            let cg0 = g0 - t0;
            let y_0 = ((t0 + (cg0 >> 1)) + bias_y) >> PRECISION;
            *y0_last = y_0.min(max_colors).max(0).as_();

            let t1 = b1 + ((r1 - b1) >> 1);
            let cg1 = g1 - t1;
            let y_1 = ((t1 + (cg1 >> 1)) + bias_y) >> PRECISION;
            *y1_last = y_1.min(max_colors).max(0).as_();

            let r = (r0 + r1) >> 1;
            let g = (g0 + g1) >> 1;
            let b = (b0 + b1) >> 1;

            let t = b + ((r - b) >> 1);

            let co = (r - b + bias_uv) >> PRECISION;
            let cg = (g - t + bias_uv) >> PRECISION;

            *u_last = cg.min(max_colors).max(0).as_();
            *v_last = co.min(max_colors).max(0).as_();
        }
    };

    let y_stride = image.y_stride as usize;
    let u_stride = image.u_stride as usize;
    let v_stride = image.v_stride as usize;

    let (y_plane, u_plane, v_plane) = image.projected_planes_mut(chroma_subsampling);
    let rgba = projected_rgba_plane(rgba, width, height, rgba_stride, src_chans);

    if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
        let iter;
        #[cfg(feature = "rayon")]
        {
            iter = y_plane
                .par_chunks_mut(y_stride)
                .zip(u_plane.par_chunks_mut(u_stride))
                .zip(v_plane.par_chunks_mut(v_stride))
                .zip(rgba.par_chunks(rgba_stride as usize));
        }
        #[cfg(not(feature = "rayon"))]
        {
            iter = y_plane
                .chunks_mut(y_stride)
                .zip(u_plane.chunks_mut(u_stride))
                .zip(v_plane.chunks_mut(v_stride))
                .zip(rgba.chunks(rgba_stride as usize));
        }
        iter.for_each(|(((y_dst, u_plane), v_plane), rgba)| {
            let y_dst = &mut y_dst[..width as usize];
            for (((y_dst, u_dst), v_dst), rgba) in y_dst
                .iter_mut()
                .zip(u_plane.iter_mut())
                .zip(v_plane.iter_mut())
                .zip(rgba.chunks_exact(channels))
            {
                let r0 = rgba[src_chans.get_r_channel_offset()].as_() * range_reduction_y as i32;
                let g0 = rgba[src_chans.get_g_channel_offset()].as_() * range_reduction_y as i32;
                let b0 = rgba[src_chans.get_b_channel_offset()].as_() * range_reduction_y as i32;

                let co = r0 - b0;
                let t = b0 + (co >> 1);
                let cg = g0 - t;

                let y_0 = ((t + (cg >> 1)) + bias_y) >> PRECISION;
                *y_dst = y_0.min(max_colors).max(0).as_();

                *u_dst = ((cg + bias_uv) >> PRECISION).min(max_colors).max(0).as_();
                *v_dst = ((co + bias_uv) >> PRECISION).min(max_colors).max(0).as_();
            }
        });
    } else if chroma_subsampling == YuvChromaSubsampling::Yuv422 {
        let iter;
        #[cfg(feature = "rayon")]
        {
            iter = y_plane
                .par_chunks_mut(y_stride)
                .zip(u_plane.par_chunks_mut(u_stride))
                .zip(v_plane.par_chunks_mut(v_stride))
                .zip(rgba.par_chunks(rgba_stride as usize));
        }
        #[cfg(not(feature = "rayon"))]
        {
            iter = y_plane
                .chunks_mut(y_stride)
                .zip(u_plane.chunks_mut(u_stride))
                .zip(v_plane.chunks_mut(v_stride))
                .zip(rgba.chunks(rgba_stride as usize));
        }

        iter.for_each(|(((y_plane, u_plane), v_plane), rgba)| {
            process_halved_chroma_row(
                &mut y_plane[..width as usize],
                &mut u_plane[..(width as usize).div_ceil(2)],
                &mut v_plane[..(width as usize).div_ceil(2)],
                &rgba[..width as usize * channels],
            );
        });
    } else if chroma_subsampling == YuvChromaSubsampling::Yuv420 {
        let iter;
        #[cfg(feature = "rayon")]
        {
            iter = y_plane
                .par_chunks_mut(y_stride * 2)
                .zip(u_plane.par_chunks_mut(u_stride))
                .zip(v_plane.par_chunks_mut(v_stride))
                .zip(rgba.par_chunks(rgba_stride as usize * 2));
        }
        #[cfg(not(feature = "rayon"))]
        {
            iter = y_plane
                .chunks_mut(y_stride * 2)
                .zip(u_plane.chunks_mut(u_stride))
                .zip(v_plane.chunks_mut(v_stride))
                .zip(rgba.chunks(rgba_stride as usize * 2));
        }
        iter.take(height as usize / 2)
            .for_each(|(((y_plane, u_plane), v_plane), rgba)| {
                let (rgba0, rgba1) = rgba.split_at(rgba_stride as usize);
                let (y_plane0, y_plane1) = y_plane.split_at_mut(y_stride);
                process_doubled_row(
                    &mut y_plane0[..width as usize],
                    &mut y_plane1[..width as usize],
                    &mut u_plane[..(width as usize).div_ceil(2)],
                    &mut v_plane[..(width as usize).div_ceil(2)],
                    &rgba0[..width as usize * channels],
                    &rgba1[..width as usize * channels],
                );
            });

        if height & 1 != 0 {
            let remainder_y_plane = y_plane.chunks_mut(y_stride * 2).last().unwrap();
            let remainder_rgba = rgba.chunks(rgba_stride as usize * 2).last().unwrap();
            let u_plane = u_plane.chunks_mut(u_stride).last().unwrap();
            let v_plane = v_plane.chunks_mut(v_stride).last().unwrap();
            process_halved_chroma_row(
                &mut remainder_y_plane[..width as usize],
                &mut u_plane[..(width as usize).div_ceil(2)],
                &mut v_plane[..(width as usize).div_ceil(2)],
                &remainder_rgba[..width as usize * channels],
            );
        }
    } else {
        unreachable!();
    }

    Ok(())
}

macro_rules! d_cv {
    ($m_name: ident, $bp: expr, $t_source: ident, $t_target: ident, $cn: expr, $sampling: expr, $yuv_name: expr, $rgb_name: expr, $r_type: expr) => {
        #[doc = concat!("Convert ", $rgb_name, stringify!($bp)," image data to ", $yuv_name ," planar format.                                           
                                                                                              
This function performs ", $rgb_name, stringify!($bp)," to ", $yuv_name ," conversion and stores the result in ", $yuv_name ," planar format,
with separate planes for Y (luminance), Cg (chrominance), and Co (chrominance) components.    
                                                                                              
# Arguments                                                                                   
                                                                                              
* `image` - Target ", $yuv_name ," planar image.                                                              
* `bgra` - The input ", $rgb_name, stringify!($bp)," image data slice.                                                   
* `bgra_stride` - The stride (components per row) for the ", $rgb_name, stringify!($bp)," image data.                    
* `range` - The YUV range (limited or full).                                                  
                                                                                              
# Panics                                                                                      
                                                                                              
This function panics if the lengths of the planes or the input ", $rgb_name, stringify!($bp)," data are not valid based  
on the specified width, height, and strides, or if invalid YUV range or matrix is provided.   ")]
        pub fn $m_name(
            image: &mut YuvPlanarImageMut<$t_target>,
            dst: &[$t_source],
            dst_stride: u32,
            range: YuvRange,
        ) -> Result<(), YuvError> {
            rgbx_to_ycgco::<$t_source, $t_target, { $cn as u8 }, { $sampling as u8 }, $bp, {  $r_type as usize }>(
                image, dst, dst_stride, range,
            )
        }
    };
}

macro_rules! d_bundle {
    ($rgb: ident, $rgba: ident, $t_source: ident, $t_target: ident, $sampling: expr, $name: expr, $r_type: expr) => {
        d_cv!(
            $rgb,
            8,
            $t_source,
            $t_target,
            YuvSourceChannels::Rgb,
            $sampling,
            $name,
            "RGB",
            $r_type
        );

        d_cv!(
            $rgba,
            8,
            $t_source,
            $t_target,
            YuvSourceChannels::Rgba,
            $sampling,
            $name,
            "RGBA",
            $r_type
        );
    };
}

macro_rules! d_bundle10 {
    ($rgb: ident, $rgba: ident, $t_source: ident, $t_target: ident, $sampling: expr, $name: expr, $r_type: expr) => {
        d_cv!(
            $rgb,
            10,
            $t_source,
            $t_target,
            YuvSourceChannels::Rgb,
            $sampling,
            $name,
            "RGB",
            $r_type
        );

        d_cv!(
            $rgba,
            10,
            $t_source,
            $t_target,
            YuvSourceChannels::Rgba,
            $sampling,
            $name,
            "RGBA",
            $r_type
        );
    };
}

d_bundle!(
    rgb_to_icgc_ro010,
    rgba_to_icgc_ro010,
    u8,
    u16,
    YuvChromaSubsampling::Yuv420,
    "YCgCo-Ro 4:2:0 10 bit-depth",
    YCgCoR::YCgCoRo
);

d_bundle!(
    rgb_to_icgc_re010,
    rgba_to_icgc_re010,
    u8,
    u16,
    YuvChromaSubsampling::Yuv420,
    "YCgCo-Re 4:2:0 10 bit-depth",
    YCgCoR::YCgCoRe
);

d_bundle!(
    rgb_to_icgc_ro210,
    rgba_to_icgc_ro210,
    u8,
    u16,
    YuvChromaSubsampling::Yuv422,
    "YCgCo-Ro 4:2:2 10 bit-depth",
    YCgCoR::YCgCoRo
);

d_bundle!(
    rgb_to_icgc_re210,
    rgba_to_icgc_re210,
    u8,
    u16,
    YuvChromaSubsampling::Yuv422,
    "YCgCo-Re 4:2:2 10 bit-depth",
    YCgCoR::YCgCoRe
);

d_bundle!(
    rgb_to_icgc_ro410,
    rgba_to_icgc_ro410,
    u8,
    u16,
    YuvChromaSubsampling::Yuv444,
    "YCgCo-Ro 4:4:4 10 bit-depth",
    YCgCoR::YCgCoRo
);

d_bundle!(
    rgb_to_icgc_re410,
    rgba_to_icgc_re410,
    u8,
    u16,
    YuvChromaSubsampling::Yuv444,
    "YCgCo-Re 4:4:4 10 bit-depth",
    YCgCoR::YCgCoRe
);

// ICgC-Re/ICgC-Ro 12-bit

d_bundle10!(
    rgb10_to_icgc_ro012,
    rgba10_to_icgc_ro012,
    u16,
    u16,
    YuvChromaSubsampling::Yuv420,
    "YCgCo-Ro 4:2:0 12 bit-depth",
    YCgCoR::YCgCoRo
);

d_bundle10!(
    rgb10_to_icgc_re012,
    rgba10_to_icgc_re012,
    u16,
    u16,
    YuvChromaSubsampling::Yuv420,
    "YCgCo-Re 4:2:0 12 bit-depth",
    YCgCoR::YCgCoRe
);

d_bundle10!(
    rgb10_to_icgc_ro212,
    rgba10_to_icgc_ro212,
    u16,
    u16,
    YuvChromaSubsampling::Yuv422,
    "YCgCo-Ro 4:2:2 12 bit-depth",
    YCgCoR::YCgCoRo
);

d_bundle10!(
    rgb10_to_icgc_re212,
    rgba10_to_icgc_re212,
    u16,
    u16,
    YuvChromaSubsampling::Yuv422,
    "YCgCo-Re 4:2:2 12 bit-depth",
    YCgCoR::YCgCoRe
);

d_bundle10!(
    rgb10_to_icgc_ro412,
    rgba10_to_icgc_ro412,
    u16,
    u16,
    YuvChromaSubsampling::Yuv444,
    "YCgCo-Ro 4:4:4 12 bit-depth",
    YCgCoR::YCgCoRo
);

d_bundle10!(
    rgb10_to_icgc_re412,
    rgba10_to_icgc_re412,
    u16,
    u16,
    YuvChromaSubsampling::Yuv444,
    "YCgCo-Re 4:4:4 12 bit-depth",
    YCgCoR::YCgCoRe
);
