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
#[allow(unused_imports)]
use crate::internals::ProcessedOffset;
#[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
use crate::neon::neon_yuv_p16_to_rgba16_alpha_row;
use crate::numerics::{qrshr, to_ne};
use crate::yuv_error::check_rgba_destination;
use crate::yuv_support::{
    get_yuv_range, search_inverse_transform, YuvBytesPacking, YuvChromaSubsampling, YuvEndianness,
    YuvRange, YuvSourceChannels, YuvStandardMatrix,
};
use crate::{YuvError, YuvPlanarImageWithAlpha};
#[cfg(feature = "rayon")]
use rayon::iter::{IndexedParallelIterator, ParallelIterator};
#[cfg(feature = "rayon")]
use rayon::prelude::{ParallelSlice, ParallelSliceMut};

fn yuv_p16_to_image_alpha_ant<
    const DESTINATION_CHANNELS: u8,
    const SAMPLING: u8,
    const ENDIANNESS: u8,
    const BYTES_POSITION: u8,
    const BIT_DEPTH: usize,
>(
    image: &YuvPlanarImageWithAlpha<u16>,
    rgba16: &mut [u16],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    let dst_chans: YuvSourceChannels = DESTINATION_CHANNELS.into();
    let channels = dst_chans.get_channels_count();

    assert!(
        dst_chans != YuvSourceChannels::Rgb && dst_chans != YuvSourceChannels::Bgr,
        "Cannot call YUV p16 to Rgb8 with alpha without real alpha"
    );

    let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();
    let chroma_range = get_yuv_range(BIT_DEPTH as u32, range);
    let kr_kb = matrix.get_kr_kb();

    image.check_constraints(chroma_subsampling)?;
    check_rgba_destination(rgba16, rgba_stride, image.width, image.height, channels)?;

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

    let msb_shift = (16 - BIT_DEPTH) as i32;

    #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
    let is_rdm_available = std::arch::is_aarch64_feature_detected!("rdm");
    #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
    let neon_wide_row_handler = if is_rdm_available && BIT_DEPTH == 10 {
        #[cfg(feature = "rdm")]
        {
            use crate::neon::neon_yuv_p16_to_rgba16_alpha_row_rdm;
            neon_yuv_p16_to_rgba16_alpha_row_rdm::<
                DESTINATION_CHANNELS,
                SAMPLING,
                ENDIANNESS,
                BYTES_POSITION,
                PRECISION,
                BIT_DEPTH,
            >
        }
        #[cfg(not(feature = "rdm"))]
        {
            neon_yuv_p16_to_rgba16_alpha_row::<
                DESTINATION_CHANNELS,
                SAMPLING,
                ENDIANNESS,
                BYTES_POSITION,
                PRECISION,
                BIT_DEPTH,
            >
        }
    } else {
        neon_yuv_p16_to_rgba16_alpha_row::<
            DESTINATION_CHANNELS,
            SAMPLING,
            ENDIANNESS,
            BYTES_POSITION,
            PRECISION,
            BIT_DEPTH,
        >
    };
    #[cfg(all(any(target_arch = "x86", target_arch = "x86_64"), feature = "sse"))]
    let use_sse = std::arch::is_x86_feature_detected!("sse4.1");
    #[cfg(all(any(target_arch = "x86", target_arch = "x86_64"), feature = "avx"))]
    let use_avx = std::arch::is_x86_feature_detected!("avx2");

    let process_wide_row = |_y_plane: &[u16],
                            _u_plane: &[u16],
                            _v_plane: &[u16],
                            _a_plane: &[u16],
                            _rgba: &mut [u16]| {
        let mut _cx = 0usize;
        #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
        {
            unsafe {
                let offset = neon_wide_row_handler(
                    _y_plane,
                    _u_plane,
                    _v_plane,
                    _a_plane,
                    _rgba,
                    image.width,
                    &chroma_range,
                    &i_transform,
                    0,
                    0,
                );
                _cx = offset.cx;
            }
        }
        #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
        {
            let mut _v_offset = ProcessedOffset { cx: 0, ux: 0 };
            #[cfg(feature = "avx")]
            if use_avx && BIT_DEPTH <= 12 {
                use crate::avx2::avx_yuv_p16_to_rgba_alpha_row;
                unsafe {
                    let offset = avx_yuv_p16_to_rgba_alpha_row::<
                        DESTINATION_CHANNELS,
                        SAMPLING,
                        ENDIANNESS,
                        BYTES_POSITION,
                        BIT_DEPTH,
                        PRECISION,
                    >(
                        _y_plane,
                        _u_plane,
                        _v_plane,
                        _a_plane,
                        _rgba,
                        image.width,
                        &chroma_range,
                        &i_transform,
                        _v_offset.cx,
                        _v_offset.ux,
                    );
                    _v_offset = offset;
                    _cx = offset.cx;
                }
            }
            #[cfg(feature = "sse")]
            if use_sse && BIT_DEPTH <= 12 {
                use crate::sse::sse_yuv_p16_to_rgba_alpha_row;
                unsafe {
                    let offset = sse_yuv_p16_to_rgba_alpha_row::<
                        DESTINATION_CHANNELS,
                        SAMPLING,
                        ENDIANNESS,
                        BYTES_POSITION,
                        BIT_DEPTH,
                        PRECISION,
                    >(
                        _y_plane,
                        _u_plane,
                        _v_plane,
                        _a_plane,
                        _rgba,
                        image.width,
                        &chroma_range,
                        &i_transform,
                        _v_offset.cx,
                        _v_offset.ux,
                    );
                    _cx = offset.cx;
                }
            }
        }
        _cx
    };

    let process_halved_chroma_row = |y_plane: &[u16],
                                     u_plane: &[u16],
                                     v_plane: &[u16],
                                     a_plane: &[u16],
                                     rgba: &mut [u16]| {
        let cx = process_wide_row(y_plane, u_plane, v_plane, a_plane, rgba);

        for ((((rgba, y_src), &u_src), &v_src), a_src) in rgba
            .chunks_exact_mut(channels * 2)
            .zip(y_plane.chunks_exact(2))
            .zip(u_plane.iter())
            .zip(v_plane.iter())
            .zip(a_plane.chunks_exact(2))
            .skip(cx / 2)
        {
            let y_value0 =
                (to_ne::<ENDIANNESS, BYTES_POSITION>(y_src[0], msb_shift) as i32 - bias_y) * y_coef;
            let cb_value = to_ne::<ENDIANNESS, BYTES_POSITION>(u_src, msb_shift) as i32 - bias_uv;
            let cr_value = to_ne::<ENDIANNESS, BYTES_POSITION>(v_src, msb_shift) as i32 - bias_uv;

            let r0 = qrshr::<PRECISION, BIT_DEPTH>(y_value0 + cr_coef * cr_value);
            let b0 = qrshr::<PRECISION, BIT_DEPTH>(y_value0 + cb_coef * cb_value);
            let g0 =
                qrshr::<PRECISION, BIT_DEPTH>(y_value0 - g_coef_1 * cr_value - g_coef_2 * cb_value);

            let rgba0 = &mut rgba[..channels];

            rgba0[dst_chans.get_r_channel_offset()] = r0 as u16;
            rgba0[dst_chans.get_g_channel_offset()] = g0 as u16;
            rgba0[dst_chans.get_b_channel_offset()] = b0 as u16;
            rgba0[dst_chans.get_a_channel_offset()] = a_src[0];

            let y_value1 =
                (to_ne::<ENDIANNESS, BYTES_POSITION>(y_src[1], msb_shift) as i32 - bias_y) * y_coef;

            let r1 = qrshr::<PRECISION, BIT_DEPTH>(y_value1 + cr_coef * cr_value);
            let b1 = qrshr::<PRECISION, BIT_DEPTH>(y_value1 + cb_coef * cb_value);
            let g1 =
                qrshr::<PRECISION, BIT_DEPTH>(y_value1 - g_coef_1 * cr_value - g_coef_2 * cb_value);

            let rgba1 = &mut rgba[channels..channels * 2];

            rgba1[dst_chans.get_r_channel_offset()] = r1 as u16;
            rgba1[dst_chans.get_g_channel_offset()] = g1 as u16;
            rgba1[dst_chans.get_b_channel_offset()] = b1 as u16;
            rgba1[dst_chans.get_a_channel_offset()] = a_src[1];
        }

        if image.width & 1 != 0 {
            let y_value0 = (to_ne::<ENDIANNESS, BYTES_POSITION>(*y_plane.last().unwrap(), msb_shift)
                as i32
                - bias_y)
                * y_coef;
            let cb_value = to_ne::<ENDIANNESS, BYTES_POSITION>(*u_plane.last().unwrap(), msb_shift)
                as i32
                - bias_uv;
            let cr_value = to_ne::<ENDIANNESS, BYTES_POSITION>(*v_plane.last().unwrap(), msb_shift)
                as i32
                - bias_uv;
            let a_value = *a_plane.last().unwrap();
            let rgba = rgba.chunks_exact_mut(channels).last().unwrap();
            let rgba0 = &mut rgba[0..channels];

            let r0 = qrshr::<PRECISION, BIT_DEPTH>(y_value0 + cr_coef * cr_value);
            let b0 = qrshr::<PRECISION, BIT_DEPTH>(y_value0 + cb_coef * cb_value);
            let g0 =
                qrshr::<PRECISION, BIT_DEPTH>(y_value0 - g_coef_1 * cr_value - g_coef_2 * cb_value);
            rgba0[dst_chans.get_r_channel_offset()] = r0 as u16;
            rgba0[dst_chans.get_g_channel_offset()] = g0 as u16;
            rgba0[dst_chans.get_b_channel_offset()] = b0 as u16;
            rgba0[dst_chans.get_a_channel_offset()] = a_value;
        }
    };

    if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
        let iter;
        #[cfg(feature = "rayon")]
        {
            iter = rgba16
                .par_chunks_exact_mut(rgba_stride as usize)
                .zip(image.y_plane.par_chunks_exact(image.y_stride as usize))
                .zip(image.a_plane.par_chunks_exact(image.a_stride as usize))
                .zip(image.u_plane.par_chunks_exact(image.u_stride as usize))
                .zip(image.v_plane.par_chunks_exact(image.v_stride as usize));
        }
        #[cfg(not(feature = "rayon"))]
        {
            iter = rgba16
                .chunks_exact_mut(rgba_stride as usize)
                .zip(image.y_plane.chunks_exact(image.y_stride as usize))
                .zip(image.a_plane.chunks_exact(image.a_stride as usize))
                .zip(image.u_plane.chunks_exact(image.u_stride as usize))
                .zip(image.v_plane.chunks_exact(image.v_stride as usize));
        }
        iter.for_each(|((((rgba, y_plane), a_plane), u_plane), v_plane)| {
            let y_plane = &y_plane[..image.width as usize];
            let cx = process_wide_row(y_plane, u_plane, v_plane, a_plane, rgba);

            for ((((rgba, &y_src), &u_src), &v_src), &a_src) in rgba
                .chunks_exact_mut(channels)
                .zip(y_plane.iter())
                .zip(u_plane.iter())
                .zip(v_plane.iter())
                .zip(a_plane.iter())
                .skip(cx)
            {
                let y_value = (to_ne::<ENDIANNESS, BYTES_POSITION>(y_src, msb_shift) as i32
                    - bias_y)
                    * y_coef;
                let cb_value =
                    to_ne::<ENDIANNESS, BYTES_POSITION>(u_src, msb_shift) as i32 - bias_uv;
                let cr_value =
                    to_ne::<ENDIANNESS, BYTES_POSITION>(v_src, msb_shift) as i32 - bias_uv;

                let r = qrshr::<PRECISION, BIT_DEPTH>(y_value + cr_coef * cr_value);
                let b = qrshr::<PRECISION, BIT_DEPTH>(y_value + cb_coef * cb_value);
                let g = qrshr::<PRECISION, BIT_DEPTH>(
                    y_value - g_coef_1 * cr_value - g_coef_2 * cb_value,
                );

                rgba[dst_chans.get_r_channel_offset()] = r as u16;
                rgba[dst_chans.get_g_channel_offset()] = g as u16;
                rgba[dst_chans.get_b_channel_offset()] = b as u16;
                rgba[dst_chans.get_a_channel_offset()] = a_src;
            }
        });
    } else if chroma_subsampling == YuvChromaSubsampling::Yuv422 {
        let iter;
        #[cfg(feature = "rayon")]
        {
            iter = rgba16
                .par_chunks_exact_mut(rgba_stride as usize)
                .zip(image.y_plane.par_chunks_exact(image.y_stride as usize))
                .zip(image.a_plane.par_chunks_exact(image.a_stride as usize))
                .zip(image.u_plane.par_chunks_exact(image.u_stride as usize))
                .zip(image.v_plane.par_chunks_exact(image.v_stride as usize));
        }
        #[cfg(not(feature = "rayon"))]
        {
            iter = rgba16
                .chunks_exact_mut(rgba_stride as usize)
                .zip(image.y_plane.chunks_exact(image.y_stride as usize))
                .zip(image.a_plane.chunks_exact(image.a_stride as usize))
                .zip(image.u_plane.chunks_exact(image.u_stride as usize))
                .zip(image.v_plane.chunks_exact(image.v_stride as usize));
        }
        iter.for_each(|((((rgba, y_plane), a_plane), u_plane), v_plane)| {
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
            iter = rgba16
                .par_chunks_exact_mut(rgba_stride as usize * 2)
                .zip(image.y_plane.par_chunks_exact(image.y_stride as usize * 2))
                .zip(image.a_plane.par_chunks_exact(image.a_stride as usize * 2))
                .zip(image.u_plane.par_chunks_exact(image.u_stride as usize))
                .zip(image.v_plane.par_chunks_exact(image.v_stride as usize));
        }
        #[cfg(not(feature = "rayon"))]
        {
            iter = rgba16
                .chunks_exact_mut(rgba_stride as usize * 2)
                .zip(image.y_plane.chunks_exact(image.y_stride as usize * 2))
                .zip(image.a_plane.chunks_exact(image.a_stride as usize * 2))
                .zip(image.u_plane.chunks_exact(image.u_stride as usize))
                .zip(image.v_plane.chunks_exact(image.v_stride as usize));
        }
        iter.for_each(|((((rgba, y_plane), a_plane), u_plane), v_plane)| {
            for ((rgba, y_plane), a_plane) in rgba
                .chunks_exact_mut(rgba_stride as usize)
                .zip(y_plane.chunks_exact(image.y_stride as usize))
                .zip(a_plane.chunks_exact(image.a_stride as usize))
            {
                process_halved_chroma_row(
                    &y_plane[..image.width as usize],
                    &u_plane[..(image.width as usize).div_ceil(2)],
                    &v_plane[..(image.width as usize).div_ceil(2)],
                    &a_plane[..image.width as usize],
                    &mut rgba[..image.width as usize * channels],
                );
            }
        });

        if image.height & 1 != 0 {
            let rgba = rgba16
                .chunks_exact_mut(rgba_stride as usize)
                .last()
                .unwrap();
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
            let a_plane = image
                .a_plane
                .chunks_exact(image.a_stride as usize)
                .last()
                .unwrap();
            let y_plane = image
                .y_plane
                .chunks_exact(image.y_stride as usize)
                .last()
                .unwrap();
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
    ($method: ident, $px_fmt: expr, $sampling: expr, $endian: expr, $sampling_written: expr, $px_written: expr, $px_written_small: expr, $bit_depth: expr) => {
        #[doc = concat!("
Convert ",$sampling_written, " planar format with ", stringify!($bit_depth), " bit pixel format to ", $px_written," ", stringify!($bit_depth), " bit-depth format with interleaving alpha.

This function takes ", $sampling_written, " planar data with ", stringify!($bit_depth), " bit precision and interleaved provided alpha channel,
and converts it to ", $px_written," format with ", stringify!($bit_depth), " bit-depth precision per channel.

# Arguments

* `planar_image` - Source ",$sampling_written," planar image.
* `", $px_written_small, "` - A mutable slice to store the converted ", $px_written," ", stringify!($bit_depth), " bit-depth data.
* `", $px_written_small, "_stride` - The stride (components per row) for ", $px_written," ", stringify!($bit_depth), " bit-depth data.
* `range` - The YUV range (limited or full).
* `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
* `bit_depth` - Bit depth of source YUV planes, only 10 and 12 is supported.

# Panics

This function panics if the lengths of the planes or the input ", $px_written," data are not valid based
on the specified width, height, and strides, or if invalid YUV range or matrix is provided.")]
        pub fn $method(
            planar_image_with_alpha: &YuvPlanarImageWithAlpha<u16>,
            dst: &mut [u16],
            dst_stride: u32,
            range: YuvRange,
            matrix: YuvStandardMatrix,
        ) -> Result<(), YuvError> {
            yuv_p16_to_image_alpha_ant::<{ $px_fmt as u8 },
                            { $sampling as u8 },
                            { $endian as u8 },
                            { YuvBytesPacking::LeastSignificantBytes as u8 }, $bit_depth>(
                planar_image_with_alpha, dst, dst_stride, range, matrix)
        }
    };
}

d_cnv!(
    i010_alpha_to_rgba10,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv420,
    YuvEndianness::LittleEndian,
    "I010A",
    "RGBA",
    "rgba",
    10
);
#[cfg(feature = "big_endian")]
d_cnv!(
    i010_be_alpha_to_rgba10,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv420,
    YuvEndianness::BigEndian,
    "I010ABE",
    "RGBA",
    "rgba",
    10
);

d_cnv!(
    i210_alpha_to_rgba10,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv422,
    YuvEndianness::LittleEndian,
    "I210A",
    "RGBA",
    "rgba",
    10
);
#[cfg(feature = "big_endian")]
d_cnv!(
    i210_alpha_be_to_rgba10,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv422,
    YuvEndianness::LittleEndian,
    "I210ABE",
    "RGBA",
    "rgba",
    10
);
d_cnv!(
    i410_alpha_to_rgba10,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv444,
    YuvEndianness::LittleEndian,
    "I410A",
    "RGBA",
    "rgba",
    10
);
#[cfg(feature = "big_endian")]
d_cnv!(
    i410_be_alpha_to_rgba10,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv444,
    YuvEndianness::BigEndian,
    "I410ABE",
    "RGBA",
    "rgba",
    10
);

d_cnv!(
    i012_alpha_to_rgba12,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv420,
    YuvEndianness::LittleEndian,
    "I012A",
    "RGBA",
    "rgba",
    12
);
#[cfg(feature = "big_endian")]
d_cnv!(
    i012_be_alpha_to_rgba12,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv420,
    YuvEndianness::BigEndian,
    "I012ABE",
    "RGBA",
    "rgba",
    12
);
d_cnv!(
    i014_alpha_to_rgba14,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv420,
    YuvEndianness::LittleEndian,
    "I014A",
    "RGBA",
    "rgba",
    14
);
#[cfg(feature = "big_endian")]
d_cnv!(
    i014_be_alpha_to_rgba14,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv420,
    YuvEndianness::BigEndian,
    "I014ABE",
    "RGBA",
    "rgba",
    14
);

d_cnv!(
    i212_alpha_to_rgba12,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv422,
    YuvEndianness::LittleEndian,
    "I212A",
    "RGBA",
    "rgba",
    12
);
#[cfg(feature = "big_endian")]
d_cnv!(
    i212_be_alpha_to_rgba12,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv422,
    YuvEndianness::LittleEndian,
    "I212ABE",
    "RGBA",
    "rgba",
    12
);
d_cnv!(
    i214_alpha_to_rgba14,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv422,
    YuvEndianness::LittleEndian,
    "I214A",
    "RGBA",
    "rgba",
    14
);
#[cfg(feature = "big_endian")]
d_cnv!(
    i214_be_alpha_to_rgba14,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv422,
    YuvEndianness::LittleEndian,
    "I214ABE",
    "RGBA",
    "rgba",
    14
);

d_cnv!(
    i412_alpha_to_rgba12,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv444,
    YuvEndianness::LittleEndian,
    "I412A",
    "RGBA",
    "rgba",
    12
);
#[cfg(feature = "big_endian")]
d_cnv!(
    i412_be_alpha_to_rgba12,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv444,
    YuvEndianness::BigEndian,
    "I412ABE",
    "RGBA",
    "rgba",
    12
);
d_cnv!(
    i414_alpha_to_rgba14,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv444,
    YuvEndianness::LittleEndian,
    "I414A",
    "RGBA",
    "rgba",
    14
);
#[cfg(feature = "big_endian")]
d_cnv!(
    i414_be_alpha_to_rgba14,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv444,
    YuvEndianness::BigEndian,
    "I414ABE",
    "RGBA",
    "rgba",
    14
);
