/*
 * Copyright (c) Radzivon Bartoshyk, 01/2025. All rights reserved.
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
use crate::internals::WideDRowInversionHandler;
use crate::numerics::{qrshr, to_ne};
use crate::yuv_error::check_rgba_destination;
use crate::yuv_support::{
    get_yuv_range, search_inverse_transform, CbCrInverseTransform, YuvBytesPacking, YuvChromaRange,
    YuvChromaSubsampling, YuvEndianness, YuvRange, YuvSourceChannels, YuvStandardMatrix,
};
use crate::{YuvError, YuvPlanarImage};
use core::f16;
#[cfg(feature = "rayon")]
use rayon::iter::{IndexedParallelIterator, ParallelIterator};
#[cfg(feature = "rayon")]
use rayon::prelude::{ParallelSlice, ParallelSliceMut};

struct WideRowAnyHandler<
    const DESTINATION_CHANNELS: u8,
    const SAMPLING: u8,
    const ENDIANNESS: u8,
    const BYTES_POSITION: u8,
    const PRECISION: i32,
    const BIT_DEPTH: usize,
> {
    handler: Option<
        unsafe fn(
            y_ld_ptr: &[u16],
            u_ld_ptr: &[u16],
            v_ld_ptr: &[u16],
            rgba: &mut [f16],
            width: u32,
            range: &YuvChromaRange,
            transform: &CbCrInverseTransform<i32>,
            start_cx: usize,
            start_ux: usize,
        ) -> ProcessedOffset,
    >,
}

impl<
        const DESTINATION_CHANNELS: u8,
        const SAMPLING: u8,
        const ENDIANNESS: u8,
        const BYTES_POSITION: u8,
        const PRECISION: i32,
        const BIT_DEPTH: usize,
    > Default
    for WideRowAnyHandler<
        DESTINATION_CHANNELS,
        SAMPLING,
        ENDIANNESS,
        BYTES_POSITION,
        PRECISION,
        BIT_DEPTH,
    >
{
    fn default() -> WideRowAnyHandler<
        DESTINATION_CHANNELS,
        SAMPLING,
        ENDIANNESS,
        BYTES_POSITION,
        PRECISION,
        BIT_DEPTH,
    > {
        if PRECISION != 13 {
            return WideRowAnyHandler { handler: None };
        }
        assert_eq!(PRECISION, 13);
        #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
        {
            if BIT_DEPTH <= 12 {
                use crate::neon::neon_yuv_p16_to_rgba_f16_row;
                return WideRowAnyHandler {
                    handler: Some(
                        neon_yuv_p16_to_rgba_f16_row::<
                            DESTINATION_CHANNELS,
                            SAMPLING,
                            ENDIANNESS,
                            BYTES_POSITION,
                            PRECISION,
                            BIT_DEPTH,
                        >,
                    ),
                };
            }
        }
        #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
        {
            #[cfg(feature = "avx")]
            {
                let use_avx = std::arch::is_x86_feature_detected!("avx2");
                let has_f16c = std::arch::is_x86_feature_detected!("f16c");
                if use_avx && has_f16c && BIT_DEPTH <= 12 {
                    use crate::avx2::avx_yuv_p16_to_rgba_f16_row;
                    return WideRowAnyHandler {
                        handler: Some(
                            avx_yuv_p16_to_rgba_f16_row::<
                                DESTINATION_CHANNELS,
                                SAMPLING,
                                ENDIANNESS,
                                BYTES_POSITION,
                                BIT_DEPTH,
                                PRECISION,
                            >,
                        ),
                    };
                }
            }
        }
        WideRowAnyHandler { handler: None }
    }
}

impl<
        const DESTINATION_CHANNELS: u8,
        const SAMPLING: u8,
        const ENDIANNESS: u8,
        const BYTES_POSITION: u8,
        const PRECISION: i32,
        const BIT_DEPTH: usize,
    > WideDRowInversionHandler<u16, f16, i32>
    for WideRowAnyHandler<
        DESTINATION_CHANNELS,
        SAMPLING,
        ENDIANNESS,
        BYTES_POSITION,
        PRECISION,
        BIT_DEPTH,
    >
{
    #[inline]
    fn handle_row(
        &self,
        y_plane: &[u16],
        u_plane: &[u16],
        v_plane: &[u16],
        rgba: &mut [f16],
        width: u32,
        yuv_chroma_range: YuvChromaRange,
        transform: &CbCrInverseTransform<i32>,
    ) -> ProcessedOffset {
        if let Some(handler) = self.handler {
            unsafe {
                return handler(
                    y_plane,
                    u_plane,
                    v_plane,
                    rgba,
                    width,
                    &yuv_chroma_range,
                    transform,
                    0,
                    0,
                );
            }
        }
        ProcessedOffset { cx: 0, ux: 0 }
    }
}

fn yuv_p16_to_image_p16_ant<
    const DESTINATION_CHANNELS: u8,
    const SAMPLING: u8,
    const ENDIANNESS: u8,
    const BYTES_POSITION: u8,
    const BIT_DEPTH: usize,
>(
    image: &YuvPlanarImage<u16>,
    rgba16: &mut [f16],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    let dst_chans: YuvSourceChannels = DESTINATION_CHANNELS.into();
    let channels = dst_chans.get_channels_count();

    let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();
    let chroma_range = get_yuv_range(BIT_DEPTH as u32, range);

    image.check_constraints(chroma_subsampling)?;
    check_rgba_destination(rgba16, rgba_stride, image.width, image.height, channels)?;

    let kr_kb = matrix.get_kr_kb();
    let max_range_p16 = ((1u32 << BIT_DEPTH as u32) - 1) as i32;

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
    let wide_row_handler = WideRowAnyHandler::<
        DESTINATION_CHANNELS,
        SAMPLING,
        ENDIANNESS,
        BYTES_POSITION,
        PRECISION,
        BIT_DEPTH,
    >::default();

    let default_scale = (1f32 / max_range_p16 as f32) as f16;

    let process_halved_chroma_row = |y_plane: &[u16],
                                     u_plane: &[u16],
                                     v_plane: &[u16],
                                     rgba: &mut [f16]| {
        let cx = wide_row_handler
            .handle_row(
                y_plane,
                u_plane,
                v_plane,
                rgba,
                image.width,
                chroma_range,
                &i_transform,
            )
            .cx;

        if cx != image.width as usize {
            for (((rgba, y_src), &u_src), &v_src) in rgba
                .chunks_exact_mut(channels * 2)
                .zip(y_plane.chunks_exact(2))
                .zip(u_plane.iter())
                .zip(v_plane.iter())
                .skip(cx / 2)
            {
                let y_value0 = (to_ne::<ENDIANNESS, BYTES_POSITION>(y_src[0], msb_shift) as i32
                    - bias_y)
                    * y_coef;
                let cb_value =
                    to_ne::<ENDIANNESS, BYTES_POSITION>(u_src, msb_shift) as i32 - bias_uv;
                let cr_value =
                    to_ne::<ENDIANNESS, BYTES_POSITION>(v_src, msb_shift) as i32 - bias_uv;

                let r0 = qrshr::<PRECISION, BIT_DEPTH>(y_value0 + cr_coef * cr_value) as f16
                    * default_scale;
                let b0 = qrshr::<PRECISION, BIT_DEPTH>(y_value0 + cb_coef * cb_value) as f16
                    * default_scale;
                let g0 = qrshr::<PRECISION, BIT_DEPTH>(
                    y_value0 - g_coef_1 * cr_value - g_coef_2 * cb_value,
                ) as f16
                    * default_scale;

                let rgba0 = &mut rgba[..channels];

                rgba0[dst_chans.get_r_channel_offset()] = r0;
                rgba0[dst_chans.get_g_channel_offset()] = g0;
                rgba0[dst_chans.get_b_channel_offset()] = b0;
                if dst_chans.has_alpha() {
                    rgba0[dst_chans.get_a_channel_offset()] = 1.;
                }

                let y_value1 = (to_ne::<ENDIANNESS, BYTES_POSITION>(y_src[1], msb_shift) as i32
                    - bias_y)
                    * y_coef;

                let r1 = qrshr::<PRECISION, BIT_DEPTH>(y_value1 + cr_coef * cr_value) as f16
                    * default_scale;
                let b1 = qrshr::<PRECISION, BIT_DEPTH>(y_value1 + cb_coef * cb_value) as f16
                    * default_scale;
                let g1 = qrshr::<PRECISION, BIT_DEPTH>(
                    y_value1 - g_coef_1 * cr_value - g_coef_2 * cb_value,
                ) as f16
                    * default_scale;

                let rgba1 = &mut rgba[channels..channels * 2];

                rgba1[dst_chans.get_r_channel_offset()] = r1;
                rgba1[dst_chans.get_g_channel_offset()] = g1;
                rgba1[dst_chans.get_b_channel_offset()] = b1;
                if dst_chans.has_alpha() {
                    rgba1[dst_chans.get_a_channel_offset()] = 1.;
                }
            }

            if image.width & 1 != 0 {
                let y_value0 =
                    (to_ne::<ENDIANNESS, BYTES_POSITION>(*y_plane.last().unwrap(), msb_shift)
                        as i32
                        - bias_y)
                        * y_coef;
                let cb_value =
                    to_ne::<ENDIANNESS, BYTES_POSITION>(*u_plane.last().unwrap(), msb_shift) as i32
                        - bias_uv;
                let cr_value =
                    to_ne::<ENDIANNESS, BYTES_POSITION>(*v_plane.last().unwrap(), msb_shift) as i32
                        - bias_uv;
                let rgba = rgba.chunks_exact_mut(channels).last().unwrap();
                let rgba0 = &mut rgba[..channels];

                let r0 = qrshr::<PRECISION, BIT_DEPTH>(y_value0 + cr_coef * cr_value) as f16
                    * default_scale;
                let b0 = qrshr::<PRECISION, BIT_DEPTH>(y_value0 + cb_coef * cb_value) as f16
                    * default_scale;
                let g0 = qrshr::<PRECISION, BIT_DEPTH>(
                    y_value0 - g_coef_1 * cr_value - g_coef_2 * cb_value,
                ) as f16
                    * default_scale;
                rgba0[dst_chans.get_r_channel_offset()] = r0;
                rgba0[dst_chans.get_g_channel_offset()] = g0;
                rgba0[dst_chans.get_b_channel_offset()] = b0;
                if dst_chans.has_alpha() {
                    rgba0[dst_chans.get_a_channel_offset()] = 1.;
                }
            }
        }
    };

    if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
        let iter;
        #[cfg(feature = "rayon")]
        {
            iter = rgba16
                .par_chunks_exact_mut(rgba_stride as usize)
                .zip(image.y_plane.par_chunks_exact(image.y_stride as usize))
                .zip(image.u_plane.par_chunks_exact(image.u_stride as usize))
                .zip(image.v_plane.par_chunks_exact(image.v_stride as usize));
        }
        #[cfg(not(feature = "rayon"))]
        {
            iter = rgba16
                .chunks_exact_mut(rgba_stride as usize)
                .zip(image.y_plane.chunks_exact(image.y_stride as usize))
                .zip(image.u_plane.chunks_exact(image.u_stride as usize))
                .zip(image.v_plane.chunks_exact(image.v_stride as usize));
        }
        iter.for_each(|(((rgba, y_plane), u_plane), v_plane)| {
            let y_plane = &y_plane[..image.width as usize];
            let cx = wide_row_handler
                .handle_row(
                    y_plane,
                    u_plane,
                    v_plane,
                    rgba,
                    image.width,
                    chroma_range,
                    &i_transform,
                )
                .cx;
            if cx != image.width as usize {
                for (((rgba, &y_src), &u_src), &v_src) in rgba
                    .chunks_exact_mut(channels)
                    .zip(y_plane.iter())
                    .zip(u_plane.iter())
                    .zip(v_plane.iter())
                    .skip(cx)
                {
                    let y_value = (to_ne::<ENDIANNESS, BYTES_POSITION>(y_src, msb_shift) as i32
                        - bias_y)
                        * y_coef;
                    let cb_value =
                        to_ne::<ENDIANNESS, BYTES_POSITION>(u_src, msb_shift) as i32 - bias_uv;
                    let cr_value =
                        to_ne::<ENDIANNESS, BYTES_POSITION>(v_src, msb_shift) as i32 - bias_uv;

                    let r = qrshr::<PRECISION, BIT_DEPTH>(y_value + cr_coef * cr_value) as f16
                        * default_scale;
                    let b = qrshr::<PRECISION, BIT_DEPTH>(y_value + cb_coef * cb_value) as f16
                        * default_scale;
                    let g = qrshr::<PRECISION, BIT_DEPTH>(
                        y_value - g_coef_1 * cr_value - g_coef_2 * cb_value,
                    ) as f16
                        * default_scale;

                    rgba[dst_chans.get_r_channel_offset()] = r;
                    rgba[dst_chans.get_g_channel_offset()] = g;
                    rgba[dst_chans.get_b_channel_offset()] = b;
                    if dst_chans.has_alpha() {
                        rgba[dst_chans.get_a_channel_offset()] = 1.;
                    }
                }
            }
        });
    } else if chroma_subsampling == YuvChromaSubsampling::Yuv422 {
        let iter;
        #[cfg(feature = "rayon")]
        {
            iter = rgba16
                .par_chunks_exact_mut(rgba_stride as usize)
                .zip(image.y_plane.par_chunks_exact(image.y_stride as usize))
                .zip(image.u_plane.par_chunks_exact(image.u_stride as usize))
                .zip(image.v_plane.par_chunks_exact(image.v_stride as usize));
        }
        #[cfg(not(feature = "rayon"))]
        {
            iter = rgba16
                .chunks_exact_mut(rgba_stride as usize)
                .zip(image.y_plane.chunks_exact(image.y_stride as usize))
                .zip(image.u_plane.chunks_exact(image.u_stride as usize))
                .zip(image.v_plane.chunks_exact(image.v_stride as usize));
        }
        iter.for_each(|(((rgba, y_plane), u_plane), v_plane)| {
            process_halved_chroma_row(
                &y_plane[..image.width as usize],
                &u_plane[..(image.width as usize).div_ceil(2)],
                &v_plane[..(image.width as usize).div_ceil(2)],
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
                .zip(image.u_plane.par_chunks_exact(image.u_stride as usize))
                .zip(image.v_plane.par_chunks_exact(image.v_stride as usize));
        }
        #[cfg(not(feature = "rayon"))]
        {
            iter = rgba16
                .chunks_exact_mut(rgba_stride as usize * 2)
                .zip(image.y_plane.chunks_exact(image.y_stride as usize * 2))
                .zip(image.u_plane.chunks_exact(image.u_stride as usize))
                .zip(image.v_plane.chunks_exact(image.v_stride as usize));
        }
        iter.for_each(|(((rgba, y_plane), u_plane), v_plane)| {
            for (rgba, y_plane) in rgba
                .chunks_exact_mut(rgba_stride as usize)
                .zip(y_plane.chunks_exact(image.y_stride as usize))
            {
                process_halved_chroma_row(
                    &y_plane[..image.width as usize],
                    &u_plane[..(image.width as usize).div_ceil(2)],
                    &v_plane[..(image.width as usize).div_ceil(2)],
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
            let y_plane = image
                .y_plane
                .chunks_exact(image.y_stride as usize)
                .last()
                .unwrap();
            process_halved_chroma_row(
                &y_plane[..image.width as usize],
                &u_plane[..(image.width as usize).div_ceil(2)],
                &v_plane[..(image.width as usize).div_ceil(2)],
                &mut rgba[..image.width as usize * channels],
            );
        }
    } else {
        unreachable!();
    }

    Ok(())
}

macro_rules! build_cnv {
    ($method: ident, $px_fmt: expr, $sampling: expr, $bit_depth: expr, $sampling_written: expr, $px_written: expr, $px_written_small: expr) => {
        #[doc = concat!("
Convert ",$sampling_written, " planar format with ", $bit_depth," bit pixel format to ", $px_written," float16 format.

This function takes ", $sampling_written, " planar data with ",$bit_depth," bit precision.
and converts it to ", $px_written," format with float16 image.

# Arguments

* `planar_image` - Source ",$sampling_written," planar image.
* `", $px_written_small, "` - A mutable slice to store the converted ", $px_written," float16 format.
* `", $px_written_small, "_stride` - The stride (components per row) for ", $px_written," float16 format.
* `range` - The YUV range (limited or full).
* `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).

# Panics

This function panics if the lengths of the planes or the input ", $px_written," data are not valid based
on the specified width, height, and strides, or if invalid YUV range or matrix is provided.")]
        pub fn $method(
            planar_image: &YuvPlanarImage<u16>,
            dst: &mut [f16],
            dst_stride: u32,
            range: YuvRange,
            matrix: YuvStandardMatrix,
        ) -> Result<(), YuvError> {
            yuv_p16_to_image_p16_ant::<
                            { $px_fmt as u8 },
                            { $sampling as u8 },
                            { YuvEndianness::LittleEndian as u8 },
                            { YuvBytesPacking::LeastSignificantBytes as u8 },
            $bit_depth>(planar_image, dst, dst_stride, range, matrix)
        }
    };
}

build_cnv!(
    i010_to_rgba_f16,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv420,
    10,
    "I010",
    "RGBA",
    "rgba"
);

build_cnv!(
    i010_to_rgb_f16,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv420,
    10,
    "YUV 420",
    "RGB",
    "rgb"
);

build_cnv!(
    i012_to_rgba_f16,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv420,
    12,
    "I010",
    "RGBA",
    "rgba"
);

build_cnv!(
    i012_to_rgb_f16,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv420,
    12,
    "I012",
    "RGB",
    "rgb"
);

build_cnv!(
    i014_to_rgba_f16,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv420,
    14,
    "I014",
    "RGBA",
    "rgba"
);

build_cnv!(
    i014_to_rgb_f16,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv420,
    14,
    "I014",
    "RGB",
    "rgb"
);

build_cnv!(
    i210_to_rgba_f16,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv422,
    10,
    "I210",
    "RGBA",
    "rgba"
);

build_cnv!(
    i210_to_rgb_f16,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv422,
    10,
    "I210",
    "RGB",
    "rgb"
);

build_cnv!(
    i212_to_rgba_f16,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv422,
    12,
    "I212",
    "RGBA",
    "rgba"
);

build_cnv!(
    i212_to_rgb_f16,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv422,
    12,
    "I212",
    "RGB",
    "rgb"
);

build_cnv!(
    i214_to_rgba_f16,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv422,
    14,
    "I214",
    "RGBA",
    "rgba"
);

build_cnv!(
    i214_to_rgb_f16,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv422,
    14,
    "I214",
    "RGB",
    "rgb"
);

build_cnv!(
    i410_to_rgba_f16,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv444,
    10,
    "I410",
    "RGBA",
    "rgba"
);

build_cnv!(
    i410_to_rgb_f16,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv444,
    10,
    "I410",
    "RGB",
    "rgb"
);

build_cnv!(
    i412_to_rgba_f16,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv444,
    12,
    "I412",
    "RGBA",
    "rgba"
);

build_cnv!(
    i412_to_rgb_f16,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv444,
    12,
    "I412",
    "RGB",
    "rgb"
);

build_cnv!(
    i414_to_rgba_f16,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv444,
    14,
    "I414",
    "RGBA",
    "rgba"
);

build_cnv!(
    i414_to_rgb_f16,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv444,
    14,
    "I414",
    "RGB",
    "rgb"
);

#[cfg(test)]
#[cfg(feature = "nightly_f16")]
mod tests {
    use super::*;
    use crate::{rgb10_to_i210, rgb10_to_i410, YuvPlanarImageMut};
    use rand::RngExt;

    #[test]
    fn test_yuv444_f16_round_trip_full_range() {
        let image_width = 256usize;
        let image_height = 256usize;

        let random_point_x = rand::rng().random_range(0..image_width);
        let random_point_y = rand::rng().random_range(0..image_height);

        const CHANNELS: usize = 3;

        let pixel_points = [
            [0, 0],
            [image_width - 1, image_height - 1],
            [image_width - 1, 0],
            [0, image_height - 1],
            [(image_width - 1) / 2, (image_height - 1) / 2],
            [image_width / 5, image_height / 5],
            [0, image_height / 5],
            [image_width / 5, 0],
            [image_width / 5 * 3, image_height / 5],
            [image_width / 5 * 3, image_height / 5 * 3],
            [image_width / 5, image_height / 5 * 3],
            [random_point_x, random_point_y],
        ];
        let mut image_rgb = vec![0u16; image_width * image_height * 3];

        let or = rand::rng().random_range(0..1024) as u16;
        let og = rand::rng().random_range(0..1024) as u16;
        let ob = rand::rng().random_range(0..1024) as u16;

        for point in &pixel_points {
            image_rgb[point[0] * CHANNELS + point[1] * image_width * CHANNELS] = or;
            image_rgb[point[0] * CHANNELS + point[1] * image_width * CHANNELS + 1] = og;
            image_rgb[point[0] * CHANNELS + point[1] * image_width * CHANNELS + 2] = ob;
        }

        let mut planar_image = YuvPlanarImageMut::<u16>::alloc(
            image_width as u32,
            image_height as u32,
            YuvChromaSubsampling::Yuv444,
        );

        rgb10_to_i410(
            &mut planar_image,
            &image_rgb,
            image_width as u32 * CHANNELS as u32,
            YuvRange::Full,
            YuvStandardMatrix::Bt709,
        )
        .unwrap();

        let mut image_rgb: Vec<f16> = vec![0.; image_width * image_height * 3];

        let fixed_planar = planar_image.to_fixed();

        i410_to_rgb_f16(
            &fixed_planar,
            &mut image_rgb,
            image_width as u32 * CHANNELS as u32,
            YuvRange::Full,
            YuvStandardMatrix::Bt709,
        )
        .unwrap();

        for point in &pixel_points {
            let x = point[0];
            let y = point[1];
            let r = (image_rgb[x * CHANNELS + y * image_width * CHANNELS] as f32 * 1023.).round();
            let g =
                (image_rgb[x * CHANNELS + y * image_width * CHANNELS + 1] as f32 * 1023.).round();
            let b =
                (image_rgb[x * CHANNELS + y * image_width * CHANNELS + 2] as f32 * 1023.).round();

            let diff_r = (r as i32 - or as i32).abs();
            let diff_g = (g as i32 - og as i32).abs();
            let diff_b = (b as i32 - ob as i32).abs();

            assert!(
                diff_r <= 150,
                "Actual diff {}, Original RGB {:?}, Round-tripped RGB {:?}",
                diff_r,
                [or, og, ob],
                [r, g, b]
            );
            assert!(
                diff_g <= 150,
                "Actual diff {}, Original RGB {:?}, Round-tripped RGB {:?}",
                diff_g,
                [or, og, ob],
                [r, g, b]
            );
            assert!(
                diff_b <= 150,
                "Actual diff {}, Original RGB {:?}, Round-tripped RGB {:?}",
                diff_b,
                [or, og, ob],
                [r, g, b]
            );
        }
    }

    #[test]
    fn test_yuv422_f16_round_trip_limited_range() {
        let image_width = 256usize;
        let image_height = 256usize;

        let random_point_x = rand::rng().random_range(0..image_width);
        let random_point_y = rand::rng().random_range(0..image_height);

        const CHANNELS: usize = 3;

        let pixel_points = [
            [0, 0],
            [image_width - 1, image_height - 1],
            [image_width - 1, 0],
            [0, image_height - 1],
            [(image_width - 1) / 2, (image_height - 1) / 2],
            [image_width / 5, image_height / 5],
            [0, image_height / 5],
            [image_width / 5, 0],
            [image_width / 5 * 3, image_height / 5],
            [image_width / 5 * 3, image_height / 5 * 3],
            [image_width / 5, image_height / 5 * 3],
            [random_point_x, random_point_y],
        ];

        let mut source_rgb = vec![0u16; image_width * image_height * CHANNELS];

        let or = rand::rng().random_range(0..1024) as u16;
        let og = rand::rng().random_range(0..1024) as u16;
        let ob = rand::rng().random_range(0..1024) as u16;

        for point in &pixel_points {
            source_rgb[point[0] * CHANNELS + point[1] * image_width * CHANNELS] = or;
            source_rgb[point[0] * CHANNELS + point[1] * image_width * CHANNELS + 1] = og;
            source_rgb[point[0] * CHANNELS + point[1] * image_width * CHANNELS + 2] = ob;

            let nx = (point[0] + 1).min(image_width - 1);
            let ny = point[1].min(image_height - 1);

            source_rgb[nx * CHANNELS + ny * image_width * CHANNELS] = or;
            source_rgb[nx * CHANNELS + ny * image_width * CHANNELS + 1] = og;
            source_rgb[nx * CHANNELS + ny * image_width * CHANNELS + 2] = ob;

            let nx = point[0].saturating_sub(1).min(image_width - 1);
            let ny = point[1].min(image_height - 1);

            source_rgb[nx * CHANNELS + ny * image_width * CHANNELS] = or;
            source_rgb[nx * CHANNELS + ny * image_width * CHANNELS + 1] = og;
            source_rgb[nx * CHANNELS + ny * image_width * CHANNELS + 2] = ob;
        }

        let mut planar_image = YuvPlanarImageMut::<u16>::alloc(
            image_width as u32,
            image_height as u32,
            YuvChromaSubsampling::Yuv422,
        );

        rgb10_to_i210(
            &mut planar_image,
            &source_rgb,
            image_width as u32 * CHANNELS as u32,
            YuvRange::Limited,
            YuvStandardMatrix::Bt709,
        )
        .unwrap();

        let mut dest_rgb: Vec<f16> = vec![0.; image_width * image_height * CHANNELS];

        let fixed_planar = planar_image.to_fixed();

        i210_to_rgb_f16(
            &fixed_planar,
            &mut dest_rgb,
            image_width as u32 * CHANNELS as u32,
            YuvRange::Limited,
            YuvStandardMatrix::Bt709,
        )
        .unwrap();

        for point in &pixel_points {
            let x = point[0];
            let y = point[1];
            let px = x * CHANNELS + y * image_width * CHANNELS;

            let r = (dest_rgb[px] as f32 * 1023.).round();
            let g = (dest_rgb[px + 1] as f32 * 1023.).round();
            let b = (dest_rgb[px + 2] as f32 * 1023.).round();

            let diff_r = r as i32 - or as i32;
            let diff_g = g as i32 - og as i32;
            let diff_b = b as i32 - ob as i32;

            assert!(
                diff_r <= 264,
                "Actual diff {}, Original RGB {:?}, Round-tripped RGB {:?}",
                diff_r,
                [or, og, ob],
                [r, g, b]
            );
            assert!(
                diff_g <= 264,
                "Actual diff {}, Original RGB {:?}, Round-tripped RGB {:?}",
                diff_g,
                [or, og, ob],
                [r, g, b]
            );
            assert!(
                diff_b <= 264,
                "Actual diff {}, Original RGB {:?}, Round-tripped RGB {:?}",
                diff_b,
                [or, og, ob],
                [r, g, b]
            );
        }
    }
}
