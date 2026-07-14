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
use crate::internals::ProcessedOffset;
#[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
use crate::neon::neon_yuv_nv_p16_to_rgba_row;
use crate::numerics::{qrshr_n, to_ne};
use crate::yuv_error::check_rgba_destination;
use crate::yuv_support::*;
use crate::{YuvBiPlanarImage, YuvError};
#[cfg(feature = "rayon")]
use rayon::iter::{IndexedParallelIterator, ParallelIterator};
#[cfg(feature = "rayon")]
use rayon::prelude::{ParallelSlice, ParallelSliceMut};

fn yuv_nv_p16_to_image_impl<
    const DESTINATION_CHANNELS: u8,
    const NV_ORDER: u8,
    const SAMPLING: u8,
    const ENDIANNESS: u8,
    const BYTES_POSITION: u8,
    const BIT_DEPTH: usize,
>(
    image: &YuvBiPlanarImage<u16>,
    bgra: &mut [u16],
    bgra_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    let dst_chans: YuvSourceChannels = DESTINATION_CHANNELS.into();
    let channels = dst_chans.get_channels_count();
    let uv_order: YuvNVOrder = NV_ORDER.into();
    let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();
    let chroma_range = get_yuv_range(BIT_DEPTH as u32, range);
    let kr_kb = matrix.get_kr_kb();
    let max_range = ((1u32 << (BIT_DEPTH as u32)) - 1u32) as i32;

    image.check_constraints(chroma_subsampling)?;
    check_rgba_destination(bgra, bgra_stride, image.width, image.height, channels)?;

    const PRECISION: i32 = 13;
    let i_transform = search_inverse_transform(
        PRECISION,
        BIT_DEPTH as u32,
        range,
        matrix,
        chroma_range,
        kr_kb,
    );
    let cr_coef = i_transform.cr_coef;
    let cb_coef = i_transform.cb_coef;
    let y_coef = i_transform.y_coef;
    let g_coef_1 = i_transform.g_coeff_1;
    let g_coef_2 = i_transform.g_coeff_2;

    let bias_y = chroma_range.bias_y as i32;
    let bias_uv = chroma_range.bias_uv as i32;

    #[cfg(all(any(target_arch = "x86", target_arch = "x86_64"), feature = "sse"))]
    let mut _use_sse = std::arch::is_x86_feature_detected!("sse4.1");
    #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
    let is_rdm_available = std::arch::is_aarch64_feature_detected!("rdm");
    #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
    let neon_wide_row_handler = if is_rdm_available && BIT_DEPTH <= 12 {
        #[cfg(feature = "rdm")]
        {
            use crate::neon::neon_yuv_nv_p16_to_rgba_row_rdm;
            neon_yuv_nv_p16_to_rgba_row_rdm::<
                DESTINATION_CHANNELS,
                NV_ORDER,
                SAMPLING,
                ENDIANNESS,
                BYTES_POSITION,
                BIT_DEPTH,
                PRECISION,
            >
        }
        #[cfg(not(feature = "rdm"))]
        {
            neon_yuv_nv_p16_to_rgba_row::<
                DESTINATION_CHANNELS,
                NV_ORDER,
                SAMPLING,
                ENDIANNESS,
                BYTES_POSITION,
                BIT_DEPTH,
                PRECISION,
            >
        }
    } else {
        neon_yuv_nv_p16_to_rgba_row::<
            DESTINATION_CHANNELS,
            NV_ORDER,
            SAMPLING,
            ENDIANNESS,
            BYTES_POSITION,
            BIT_DEPTH,
            PRECISION,
        >
    };

    let process_wide_row = |_rgba: &mut [u16], _y_src: &[u16], _uv_src: &[u16]| {
        let mut _offset = ProcessedOffset { cx: 0, ux: 0 };
        #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
        {
            #[cfg(feature = "sse")]
            if _use_sse {
                use crate::sse::sse_yuv_nv_p16_to_rgba_row;
                unsafe {
                    let processed = sse_yuv_nv_p16_to_rgba_row::<
                        DESTINATION_CHANNELS,
                        NV_ORDER,
                        SAMPLING,
                        ENDIANNESS,
                        BYTES_POSITION,
                        BIT_DEPTH,
                        PRECISION,
                    >(
                        _y_src,
                        _uv_src,
                        _rgba,
                        image.width,
                        &chroma_range,
                        &i_transform,
                        _offset.cx,
                        _offset.ux,
                    );
                    _offset = processed;
                }
            }
        }

        #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
        {
            unsafe {
                let processed = neon_wide_row_handler(
                    _y_src,
                    _uv_src,
                    _rgba,
                    image.width,
                    &chroma_range,
                    &i_transform,
                    0,
                    0,
                );
                _offset = processed;
            }
        }
        _offset
    };

    let msb_shift = (16 - BIT_DEPTH) as i32;
    let width = image.width;

    let process_halved_chroma_row = |y_src: &[u16], uv_src: &[u16], rgba: &mut [u16]| {
        let processed = process_wide_row(rgba, y_src, uv_src);

        for ((rgba, y_src), uv_src) in rgba
            .chunks_exact_mut(channels * 2)
            .zip(y_src.chunks_exact(2))
            .zip(uv_src.chunks_exact(2))
            .skip(processed.cx / 2)
        {
            let y_vl0 = to_ne::<ENDIANNESS, BYTES_POSITION>(y_src[0], msb_shift) as i32;
            let mut cb_value =
                to_ne::<ENDIANNESS, BYTES_POSITION>(uv_src[uv_order.get_u_position()], msb_shift)
                    as i32;
            let mut cr_value =
                to_ne::<ENDIANNESS, BYTES_POSITION>(uv_src[uv_order.get_v_position()], msb_shift)
                    as i32;

            let y_value0: i32 = (y_vl0 - bias_y) * y_coef;

            cb_value -= bias_uv;
            cr_value -= bias_uv;

            let r_p0 = qrshr_n::<PRECISION>(y_value0 + cr_coef * cr_value, max_range);
            let b_p0 = qrshr_n::<PRECISION>(y_value0 + cb_coef * cb_value, max_range);
            let g_p0 = qrshr_n::<PRECISION>(
                y_value0 - g_coef_1 * cr_value - g_coef_2 * cb_value,
                max_range,
            );

            let rgba0 = &mut rgba[..channels];

            rgba0[dst_chans.get_b_channel_offset()] = b_p0 as u16;
            rgba0[dst_chans.get_g_channel_offset()] = g_p0 as u16;
            rgba0[dst_chans.get_r_channel_offset()] = r_p0 as u16;

            if dst_chans.has_alpha() {
                rgba0[dst_chans.get_a_channel_offset()] = max_range as u16;
            }

            let y_vl1 = to_ne::<ENDIANNESS, BYTES_POSITION>(y_src[1], msb_shift) as i32;

            let y_value1: i32 = (y_vl1 - bias_y) * y_coef;

            let r_p1 = qrshr_n::<PRECISION>(y_value1 + cr_coef * cr_value, max_range);
            let b_p1 = qrshr_n::<PRECISION>(y_value1 + cb_coef * cb_value, max_range);
            let g_p1 = qrshr_n::<PRECISION>(
                y_value1 - g_coef_1 * cr_value - g_coef_2 * cb_value,
                max_range,
            );

            let rgba1 = &mut rgba[channels..channels * 2];

            rgba1[dst_chans.get_b_channel_offset()] = b_p1 as u16;
            rgba1[dst_chans.get_g_channel_offset()] = g_p1 as u16;
            rgba1[dst_chans.get_r_channel_offset()] = r_p1 as u16;

            if dst_chans.has_alpha() {
                rgba1[dst_chans.get_a_channel_offset()] = max_range as u16;
            }
        }

        if width & 1 != 0 {
            let rgba = rgba.chunks_exact_mut(channels * 2).into_remainder();
            let rgba = &mut rgba[0..channels];
            let uv_src = uv_src.chunks_exact(2).last().unwrap();
            let y_src = y_src.chunks_exact(2).remainder();

            let y_vl0 = to_ne::<ENDIANNESS, BYTES_POSITION>(y_src[0], msb_shift) as i32;
            let y_value0: i32 = (y_vl0 - bias_y) * y_coef;
            let mut cb_value =
                to_ne::<ENDIANNESS, BYTES_POSITION>(uv_src[uv_order.get_u_position()], msb_shift)
                    as i32;
            let mut cr_value =
                to_ne::<ENDIANNESS, BYTES_POSITION>(uv_src[uv_order.get_v_position()], msb_shift)
                    as i32;

            cb_value -= bias_uv;
            cr_value -= bias_uv;

            let r_p0 = qrshr_n::<PRECISION>(y_value0 + cr_coef * cr_value, max_range);
            let b_p0 = qrshr_n::<PRECISION>(y_value0 + cb_coef * cb_value, max_range);
            let g_p0 = qrshr_n::<PRECISION>(
                y_value0 - g_coef_1 * cr_value - g_coef_2 * cb_value,
                max_range,
            );

            rgba[dst_chans.get_b_channel_offset()] = b_p0 as u16;
            rgba[dst_chans.get_g_channel_offset()] = g_p0 as u16;
            rgba[dst_chans.get_r_channel_offset()] = r_p0 as u16;

            if dst_chans.has_alpha() {
                rgba[dst_chans.get_a_channel_offset()] = max_range as u16;
            }
        }
    };

    let y_stride = image.y_stride;
    let uv_stride = image.uv_stride;
    let y_plane = image.y_plane;
    let uv_plane = image.uv_plane;

    if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
        let iter;
        #[cfg(feature = "rayon")]
        {
            iter = y_plane
                .par_chunks_exact(y_stride as usize)
                .zip(uv_plane.par_chunks_exact(uv_stride as usize))
                .zip(bgra.par_chunks_exact_mut(bgra_stride as usize));
        }
        #[cfg(not(feature = "rayon"))]
        {
            iter = y_plane
                .chunks_exact(y_stride as usize)
                .zip(uv_plane.chunks_exact(uv_stride as usize))
                .zip(bgra.chunks_exact_mut(bgra_stride as usize));
        }
        iter.for_each(|((y_src, uv_src), rgba)| {
            let y_src = &y_src[..image.width as usize];
            let processed = process_wide_row(rgba, y_src, uv_src);

            for ((rgba, &y_src), uv_src) in rgba
                .chunks_exact_mut(channels)
                .zip(y_src.iter())
                .zip(uv_src.chunks_exact(2))
                .skip(processed.cx)
            {
                let y_vl = to_ne::<ENDIANNESS, BYTES_POSITION>(y_src, msb_shift) as i32;
                let mut cb_value = to_ne::<ENDIANNESS, BYTES_POSITION>(
                    uv_src[uv_order.get_u_position()],
                    msb_shift,
                ) as i32;
                let mut cr_value = to_ne::<ENDIANNESS, BYTES_POSITION>(
                    uv_src[uv_order.get_v_position()],
                    msb_shift,
                ) as i32;

                let y_value: i32 = (y_vl - bias_y) * y_coef;

                cb_value -= bias_uv;
                cr_value -= bias_uv;

                let r_p16 = qrshr_n::<PRECISION>(y_value + cr_coef * cr_value, max_range);
                let b_p16 = qrshr_n::<PRECISION>(y_value + cb_coef * cb_value, max_range);
                let g_p16 = qrshr_n::<PRECISION>(
                    y_value - g_coef_1 * cr_value - g_coef_2 * cb_value,
                    max_range,
                );

                let rgba0 = &mut rgba[..channels];

                rgba0[dst_chans.get_b_channel_offset()] = b_p16 as u16;
                rgba0[dst_chans.get_g_channel_offset()] = g_p16 as u16;
                rgba0[dst_chans.get_r_channel_offset()] = r_p16 as u16;

                if dst_chans.has_alpha() {
                    rgba0[dst_chans.get_a_channel_offset()] = max_range as u16;
                }
            }
        });
    } else if chroma_subsampling == YuvChromaSubsampling::Yuv422 {
        let iter;
        #[cfg(feature = "rayon")]
        {
            iter = y_plane
                .par_chunks_exact(y_stride as usize)
                .zip(uv_plane.par_chunks_exact(uv_stride as usize))
                .zip(bgra.par_chunks_exact_mut(bgra_stride as usize));
        }
        #[cfg(not(feature = "rayon"))]
        {
            iter = y_plane
                .chunks_exact(y_stride as usize)
                .zip(uv_plane.chunks_exact(uv_stride as usize))
                .zip(bgra.chunks_exact_mut(bgra_stride as usize));
        }
        iter.for_each(|((y_src, uv_src), rgba)| {
            process_halved_chroma_row(
                &y_src[..image.width as usize],
                &uv_src[..(image.width as usize).div_ceil(2) * 2],
                &mut rgba[..image.width as usize * channels],
            );
        });
    } else if chroma_subsampling == YuvChromaSubsampling::Yuv420 {
        let iter;
        #[cfg(feature = "rayon")]
        {
            iter = y_plane
                .par_chunks_exact(y_stride as usize * 2)
                .zip(uv_plane.par_chunks_exact(uv_stride as usize))
                .zip(bgra.par_chunks_exact_mut(bgra_stride as usize * 2));
        }
        #[cfg(not(feature = "rayon"))]
        {
            iter = y_plane
                .chunks_exact(y_stride as usize * 2)
                .zip(uv_plane.chunks_exact(uv_stride as usize))
                .zip(bgra.chunks_exact_mut(bgra_stride as usize * 2));
        }
        iter.for_each(|((y_src, uv_src), rgba)| {
            for (y_src, rgba) in y_src
                .chunks_exact(y_stride as usize)
                .zip(rgba.chunks_exact_mut(bgra_stride as usize))
            {
                process_halved_chroma_row(
                    &y_src[..image.width as usize],
                    &uv_src[..(image.width as usize).div_ceil(2) * 2],
                    &mut rgba[..image.width as usize * channels],
                );
            }
        });
        if image.height & 1 != 0 {
            let y_src = y_plane.chunks_exact(y_stride as usize * 2).remainder();
            let uv_src = uv_plane.chunks_exact(uv_stride as usize).last().unwrap();
            let rgba = bgra
                .chunks_exact_mut(bgra_stride as usize * 2)
                .into_remainder();
            process_halved_chroma_row(
                &y_src[..image.width as usize],
                &uv_src[..(image.width as usize).div_ceil(2) * 2],
                &mut rgba[..image.width as usize * channels],
            );
        }
    } else {
        unreachable!();
    }
    Ok(())
}

macro_rules! d_cnv {
    ($method: ident, $px_fmt: expr, $subsampling: expr, $yuv_name: expr, $px_name: expr, $bit_precision: expr) => {
        #[doc = concat!("Convert ", $yuv_name," format to ", $px_name, stringify!($bit_precision)," format.

This function takes ", $yuv_name," data with ", stringify!($bit_precision),"-bit precision
and converts it to ", $px_name, stringify!($bit_precision)," format with ", $bit_precision," bit-depth precision.

# Arguments

* `bi_planar_image` - Source ", stringify!($bit_precision)," bit-depth ", $yuv_name," image.
* `dst` - A mutable slice to store the converted ", $px_name," ", $bit_precision," bit-depth data.
* `dst_stride` - The stride (components per row) for the ", $px_name," image data.
* `range` - range of YUV, see [YuvRange] for more info.
* `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).

# Panics

This function panics if the lengths of the planes or the input ", $px_name," data are not valid based
on the specified width, height, and strides, or if invalid YUV range or matrix is provided.")]
        pub fn $method(
            bi_planar_image: &YuvBiPlanarImage<u16>,
            rgba: &mut [u16],
            rgba_stride: u32,
            range: YuvRange,
            matrix: YuvStandardMatrix,
        ) -> Result<(), YuvError> {
            let dispatcher = yuv_nv_p16_to_image_impl::<
                    { $px_fmt as u8 },
                    { YuvNVOrder::UV as u8 },
                    { $subsampling as u8 },
                    { YuvEndianness::LittleEndian as u8 },
                    { YuvBytesPacking::MostSignificantBytes as u8 },
                    $bit_precision,
                >;
            dispatcher(bi_planar_image, rgba, rgba_stride, range, matrix)
        }
    };
}

d_cnv!(
    p010_to_rgba10,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv420,
    "P010",
    "RGBA",
    10
);
d_cnv!(
    p010_to_rgb10,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv420,
    "P010",
    "RGB",
    10
);
d_cnv!(
    p210_to_rgba10,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv422,
    "P210",
    "RGBA",
    10
);
d_cnv!(
    p210_to_rgb10,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv422,
    "P210",
    "RGB",
    10
);
d_cnv!(
    p410_to_rgba10,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv444,
    "P410",
    "RGBA",
    10
);
d_cnv!(
    p410_to_rgb10,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv444,
    "P410",
    "RGB",
    10
);

d_cnv!(
    p012_to_rgba12,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv420,
    "P012",
    "RGBA",
    12
);
d_cnv!(
    p012_to_rgb12,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv420,
    "P012",
    "RGB",
    12
);
d_cnv!(
    p212_to_rgba12,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv422,
    "P212",
    "RGBA",
    12
);
d_cnv!(
    p212_to_rgb12,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv422,
    "P212",
    "RGB",
    12
);
d_cnv!(
    p412_to_rgba12,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv444,
    "P412",
    "RGBA",
    12
);
d_cnv!(
    p412_to_rgb12,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv444,
    "P412",
    "RGB",
    12
);
