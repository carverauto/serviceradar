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
use crate::yuv_support::{
    get_forward_transform, get_yuv_range, ToIntegerTransform, YuvChromaSubsampling, YuvNVOrder,
    YuvSourceChannels,
};
use crate::{
    YuvBiPlanarImageMut, YuvBytesPacking, YuvEndianness, YuvError, YuvRange, YuvStandardMatrix,
};
use num_traits::AsPrimitive;
#[cfg(feature = "rayon")]
use rayon::iter::{IndexedParallelIterator, ParallelIterator};
#[cfg(feature = "rayon")]
use rayon::prelude::{ParallelSlice, ParallelSliceMut};

#[inline(always)]
fn transform_integer<const ENDIANNESS: u8, const BYTES_POSITION: u8, const BIT_DEPTH: u8>(
    v: i32,
) -> u16 {
    let endianness: YuvEndianness = ENDIANNESS.into();
    let bytes_position: YuvBytesPacking = BYTES_POSITION.into();
    let packing: i32 = 16 - BIT_DEPTH as i32;
    let packed_bytes = match bytes_position {
        YuvBytesPacking::MostSignificantBytes => v << packing,
        YuvBytesPacking::LeastSignificantBytes => v,
    } as u16;
    match endianness {
        #[cfg(feature = "big_endian")]
        YuvEndianness::BigEndian => packed_bytes.to_be(),
        YuvEndianness::LittleEndian => packed_bytes.to_le(),
    }
}

fn rgbx_to_yuv_bi_planar_10_impl<
    J: AsPrimitive<i32> + Copy + Send + Sync,
    const ORIGIN_CHANNELS: u8,
    const NV_ORDER: u8,
    const SAMPLING: u8,
    const ENDIANNESS: u8,
    const BYTES_POSITION: u8,
    const BIT_DEPTH: u8,
>(
    image: &mut YuvBiPlanarImageMut<u16>,
    rgba: &[u16],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError>
where
    i32: AsPrimitive<J>,
{
    let nv_order: YuvNVOrder = NV_ORDER.into();
    let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();
    let src_chans: YuvSourceChannels = ORIGIN_CHANNELS.into();
    let channels = src_chans.get_channels_count();

    image.check_constraints(chroma_subsampling)?;
    check_rgba_destination(rgba, rgba_stride, image.width, image.height, channels)?;

    let range = get_yuv_range(BIT_DEPTH as u32, range);
    let kr_kb = matrix.get_kr_kb();
    let max_range = (1u32 << BIT_DEPTH as u32) - 1u32;

    const PRECISION: i32 = 15;

    let transform_precise =
        get_forward_transform(max_range, range.range_y, range.range_uv, kr_kb.kr, kr_kb.kb);
    let transform = transform_precise.to_integers(PRECISION as u32).cast::<J>();
    const ROUNDING_CONST_BIAS: i32 = (1 << (PRECISION - 1)) - 1;
    let bias_y = range.bias_y as i32 * (1 << PRECISION) + ROUNDING_CONST_BIAS;
    let bias_uv = range.bias_uv as i32 * (1 << PRECISION) + ROUNDING_CONST_BIAS;

    let width = image.width;

    let process_double_row = |y_dst0: &mut [u16],
                              y_dst1: &mut [u16],
                              uv_dst: &mut [u16],
                              rgba0: &[u16],
                              rgba1: &[u16]| {
        for ((((y_dst0, y_dst1), uv_dst), rgba0), rgba1) in y_dst0
            .chunks_exact_mut(2)
            .zip(y_dst1.chunks_exact_mut(2))
            .zip(uv_dst.chunks_exact_mut(2))
            .zip(rgba0.chunks_exact(channels * 2))
            .zip(rgba1.chunks_exact(channels * 2))
        {
            let rgba00 = &rgba0[0..channels];

            let r00 = rgba00[src_chans.get_r_channel_offset()] as i32;
            let g00 = rgba00[src_chans.get_g_channel_offset()] as i32;
            let b00 = rgba00[src_chans.get_b_channel_offset()] as i32;

            let y_00 = (r00 * transform.yr.as_()
                + g00 * transform.yg.as_()
                + b00 * transform.yb.as_()
                + bias_y)
                >> PRECISION;
            y_dst0[0] = transform_integer::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(y_00);

            let rgba01 = &rgba0[channels..channels * 2];

            let r01 = rgba01[src_chans.get_r_channel_offset()] as i32;
            let g01 = rgba01[src_chans.get_g_channel_offset()] as i32;
            let b01 = rgba01[src_chans.get_b_channel_offset()] as i32;

            let y_01 = (r01 * transform.yr.as_()
                + g01 * transform.yg.as_()
                + b01 * transform.yb.as_()
                + bias_y)
                >> PRECISION;
            y_dst0[1] = transform_integer::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(y_01);

            let rgba01 = &rgba1[0..channels];
            let r10 = rgba01[src_chans.get_r_channel_offset()] as i32;
            let g10 = rgba01[src_chans.get_g_channel_offset()] as i32;
            let b10 = rgba01[src_chans.get_b_channel_offset()] as i32;

            let y_10 = (r10 * transform.yr.as_()
                + g10 * transform.yg.as_()
                + b10 * transform.yb.as_()
                + bias_y)
                >> PRECISION;
            y_dst1[0] = transform_integer::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(y_10);

            let rgba11 = &rgba1[channels..channels * 2];

            let r11 = rgba11[src_chans.get_r_channel_offset()] as i32;
            let g11 = rgba11[src_chans.get_g_channel_offset()] as i32;
            let b11 = rgba11[src_chans.get_b_channel_offset()] as i32;

            let y_11 = (r11 * transform.yr.as_()
                + g11 * transform.yg.as_()
                + b11 * transform.yb.as_()
                + bias_y)
                >> PRECISION;
            y_dst1[1] = transform_integer::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(y_11);

            let r = (r00 + r01 + r10 + r11 + 2) >> 2;
            let g = (g00 + g01 + g10 + g11 + 2) >> 2;
            let b = (b00 + b01 + b10 + b11 + 2) >> 2;

            let cb = (r * transform.cb_r.as_()
                + g * transform.cb_g.as_()
                + b * transform.cb_b.as_()
                + bias_uv)
                >> PRECISION;
            let cr = (r * transform.cr_r.as_()
                + g * transform.cr_g.as_()
                + b * transform.cr_b.as_()
                + bias_uv)
                >> PRECISION;
            uv_dst[nv_order.get_u_position()] =
                transform_integer::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(cb);
            uv_dst[nv_order.get_v_position()] =
                transform_integer::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(cr);
        }

        if width & 1 != 0 {
            let rgba0 = rgba0.chunks_exact(channels * 2).remainder();
            let rgba0 = &rgba0[..channels];
            let rgba1 = rgba1.chunks_exact(channels * 2).remainder();
            let rgba1 = &rgba1[..channels];
            let uv_dst = uv_dst.chunks_exact_mut(2).last().unwrap();
            let y_dst0 = y_dst0.chunks_exact_mut(2).into_remainder();

            let r0 = rgba0[src_chans.get_r_channel_offset()] as i32;
            let g0 = rgba0[src_chans.get_g_channel_offset()] as i32;
            let b0 = rgba0[src_chans.get_b_channel_offset()] as i32;

            let r1 = rgba1[src_chans.get_r_channel_offset()] as i32;
            let g1 = rgba1[src_chans.get_g_channel_offset()] as i32;
            let b1 = rgba1[src_chans.get_b_channel_offset()] as i32;

            let r = (r0 + r1 + 1) >> 1;
            let g = (g0 + g1 + 1) >> 1;
            let b = (b0 + b1 + 1) >> 1;

            let y_0 = (r0 * transform.yr.as_()
                + g0 * transform.yg.as_()
                + b0 * transform.yb.as_()
                + bias_y)
                >> PRECISION;
            y_dst0[0] = transform_integer::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(y_0);

            let y_1 = (r1 * transform.yr.as_()
                + g1 * transform.yg.as_()
                + b1 * transform.yb.as_()
                + bias_y)
                >> PRECISION;
            y_dst1[0] = transform_integer::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(y_1);

            let cb = (r * transform.cb_r.as_()
                + g * transform.cb_g.as_()
                + b * transform.cb_b.as_()
                + bias_uv)
                >> PRECISION;
            let cr = (r * transform.cr_r.as_()
                + g * transform.cr_g.as_()
                + b * transform.cr_b.as_()
                + bias_uv)
                >> PRECISION;
            uv_dst[nv_order.get_u_position()] =
                transform_integer::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(cb);
            uv_dst[nv_order.get_v_position()] =
                transform_integer::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(cr);
        }
    };

    let process_halved_row = |y_dst: &mut [u16], uv_dst: &mut [u16], rgba: &[u16]| {
        for ((y_dst, uv_dst), rgba) in y_dst
            .chunks_exact_mut(2)
            .zip(uv_dst.chunks_exact_mut(2))
            .zip(rgba.chunks_exact(channels * 2))
        {
            let rgba0 = &rgba[..channels];
            let r0 = rgba0[src_chans.get_r_channel_offset()] as i32;
            let g0 = rgba0[src_chans.get_g_channel_offset()] as i32;
            let b0 = rgba0[src_chans.get_b_channel_offset()] as i32;
            let y_0 = (r0 * transform.yr.as_()
                + g0 * transform.yg.as_()
                + b0 * transform.yb.as_()
                + bias_y)
                >> PRECISION;
            y_dst[0] = transform_integer::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(y_0);

            let rgba1 = &rgba[channels..channels * 2];

            let r1 = rgba1[src_chans.get_r_channel_offset()] as i32;
            let g1 = rgba1[src_chans.get_g_channel_offset()] as i32;
            let b1 = rgba1[src_chans.get_b_channel_offset()] as i32;

            let y_1 = (r1 * transform.yr.as_()
                + g1 * transform.yg.as_()
                + b1 * transform.yb.as_()
                + bias_y)
                >> PRECISION;
            y_dst[1] = transform_integer::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(y_1);

            let r = (r0 + r1 + 1) >> 1;
            let g = (g0 + g1 + 1) >> 1;
            let b = (b0 + b1 + 1) >> 1;

            let cb = (r * transform.cb_r.as_()
                + g * transform.cb_g.as_()
                + b * transform.cb_b.as_()
                + bias_uv)
                >> PRECISION;
            let cr = (r * transform.cr_r.as_()
                + g * transform.cr_g.as_()
                + b * transform.cr_b.as_()
                + bias_uv)
                >> PRECISION;
            uv_dst[nv_order.get_u_position()] =
                transform_integer::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(cb);
            uv_dst[nv_order.get_v_position()] =
                transform_integer::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(cr);
        }

        if width & 1 != 0 {
            let rgba = rgba.chunks_exact(channels * 2).remainder();
            let rgba = &rgba[0..channels];
            let uv_dst = uv_dst.chunks_exact_mut(2).last().unwrap();
            let y_dst = y_dst.chunks_exact_mut(2).into_remainder();

            let r0 = rgba[src_chans.get_r_channel_offset()] as i32;
            let g0 = rgba[src_chans.get_g_channel_offset()] as i32;
            let b0 = rgba[src_chans.get_b_channel_offset()] as i32;
            let y_0 = (r0 * transform.yr.as_()
                + g0 * transform.yg.as_()
                + b0 * transform.yb.as_()
                + bias_y)
                >> PRECISION;
            y_dst[0] = transform_integer::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(y_0);

            let cb = (r0 * transform.cb_r.as_()
                + g0 * transform.cb_g.as_()
                + b0 * transform.cb_b.as_()
                + bias_uv)
                >> PRECISION;
            let cr = (r0 * transform.cr_r.as_()
                + g0 * transform.cr_g.as_()
                + b0 * transform.cr_b.as_()
                + bias_uv)
                >> PRECISION;
            uv_dst[nv_order.get_u_position()] =
                transform_integer::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(cb);
            uv_dst[nv_order.get_v_position()] =
                transform_integer::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(cr);
        }
    };

    let y_plane = image.y_plane.borrow_mut();
    let uv_plane = image.uv_plane.borrow_mut();
    let y_stride = image.y_stride;
    let uv_stride = image.uv_stride;

    if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
        let iter;
        #[cfg(feature = "rayon")]
        {
            iter = y_plane
                .par_chunks_exact_mut(y_stride as usize)
                .zip(uv_plane.par_chunks_exact_mut(uv_stride as usize))
                .zip(rgba.par_chunks_exact(rgba_stride as usize));
        }
        #[cfg(not(feature = "rayon"))]
        {
            iter = y_plane
                .chunks_exact_mut(y_stride as usize)
                .zip(uv_plane.chunks_exact_mut(uv_stride as usize))
                .zip(rgba.chunks_exact(rgba_stride as usize));
        }
        iter.for_each(|((y_dst, uv_dst), rgba)| {
            let y_dst = &mut y_dst[0..image.width as usize];
            for ((y_dst, uv_dst), rgba) in y_dst
                .iter_mut()
                .zip(uv_dst.chunks_exact_mut(2))
                .zip(rgba.chunks_exact(channels))
            {
                let r0 = rgba[src_chans.get_r_channel_offset()] as i32;
                let g0 = rgba[src_chans.get_g_channel_offset()] as i32;
                let b0 = rgba[src_chans.get_b_channel_offset()] as i32;
                let y_0 = (r0 * transform.yr.as_()
                    + g0 * transform.yg.as_()
                    + b0 * transform.yb.as_()
                    + bias_y)
                    >> PRECISION;
                *y_dst = transform_integer::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(y_0);
                let cb = (r0 * transform.cb_r.as_()
                    + g0 * transform.cb_g.as_()
                    + b0 * transform.cb_b.as_()
                    + bias_uv)
                    >> PRECISION;
                let cr = (r0 * transform.cr_r.as_()
                    + g0 * transform.cr_g.as_()
                    + b0 * transform.cr_b.as_()
                    + bias_uv)
                    >> PRECISION;
                uv_dst[nv_order.get_u_position()] =
                    transform_integer::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(cb);
                uv_dst[nv_order.get_v_position()] =
                    transform_integer::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(cr);
            }
        });
    } else if chroma_subsampling == YuvChromaSubsampling::Yuv422 {
        let iter;
        #[cfg(feature = "rayon")]
        {
            iter = y_plane
                .par_chunks_exact_mut(y_stride as usize)
                .zip(uv_plane.par_chunks_exact_mut(uv_stride as usize))
                .zip(rgba.par_chunks_exact(rgba_stride as usize));
        }
        #[cfg(not(feature = "rayon"))]
        {
            iter = y_plane
                .chunks_exact_mut(y_stride as usize)
                .zip(uv_plane.chunks_exact_mut(uv_stride as usize))
                .zip(rgba.chunks_exact(rgba_stride as usize));
        }
        iter.for_each(|((y_dst, uv_dst), rgba)| {
            process_halved_row(
                &mut y_dst[0..image.width as usize],
                &mut uv_dst[0..(image.width as usize).div_ceil(2) * 2],
                &rgba[0..image.width as usize * channels],
            );
        });
    } else {
        let iter;
        #[cfg(feature = "rayon")]
        {
            iter = y_plane
                .par_chunks_exact_mut(y_stride as usize * 2)
                .zip(uv_plane.par_chunks_exact_mut(uv_stride as usize))
                .zip(rgba.par_chunks_exact(rgba_stride as usize * 2));
        }
        #[cfg(not(feature = "rayon"))]
        {
            iter = y_plane
                .chunks_exact_mut(y_stride as usize * 2)
                .zip(uv_plane.chunks_exact_mut(uv_stride as usize))
                .zip(rgba.chunks_exact(rgba_stride as usize * 2));
        }
        iter.for_each(|((y_dst, uv_dst), rgba)| {
            let (y_dst0, y_dst1) = y_dst.split_at_mut(y_stride as usize);
            let (rgba0, rgba1) = rgba.split_at(rgba_stride as usize);
            process_double_row(
                &mut y_dst0[0..image.width as usize],
                &mut y_dst1[0..image.width as usize],
                &mut uv_dst[0..(image.width as usize).div_ceil(2) * 2],
                &rgba0[0..image.width as usize * channels],
                &rgba1[0..image.width as usize * channels],
            );
        });

        if image.height & 1 != 0 {
            let y_dst = y_plane
                .chunks_exact_mut(y_stride as usize * 2)
                .into_remainder();
            let uv_dst = uv_plane
                .chunks_exact_mut(uv_stride as usize)
                .last()
                .unwrap();
            let rgba = rgba.chunks_exact(rgba_stride as usize * 2).remainder();
            process_halved_row(
                &mut y_dst[0..image.width as usize],
                &mut uv_dst[0..(image.width as usize).div_ceil(2) * 2],
                &rgba[0..image.width as usize * channels],
            );
        }
    }

    Ok(())
}

macro_rules! d_cnv {
    ($method:ident, $px_fmt: expr, $subsampling: expr, $yuv_name: expr, $rgb_name: expr, $bit_depth: expr, $intermediate: ident) => {
        #[doc = concat!("Convert ",$rgb_name, stringify!($bit_depth)," image data to ", $yuv_name, " format.

This function performs ",$rgb_name, stringify!($bit_depth)," to ",$yuv_name," conversion and stores the result in ", $yuv_name, " format,
with separate planes for Y (luminance), UV (chrominance) components.

# Arguments

* `bi_planar_image` - Target Bi-Planar ", $yuv_name," image.
* `dst` - The input ", $rgb_name, stringify!($bit_depth)," image data slice.
* `dst_stride` - The stride (components per row) for the ", $rgb_name, stringify!($bit_depth)," image data.
* `range` - The YUV range (limited or full).
* `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).

# Panics

This function panics if the lengths of the planes or the input ", $rgb_name," data are not valid based
on the specified width, height, and strides, or if invalid YUV range or matrix is provided.")]
        pub fn $method(
            bi_planar_image: &mut YuvBiPlanarImageMut<u16>,
            dst: &[u16],
            dst_stride: u32,
            range: YuvRange,
            matrix: YuvStandardMatrix,
        ) -> Result<(), YuvError> {
            rgbx_to_yuv_bi_planar_10_impl::<
                $intermediate,
                { $px_fmt as u8 },
                { YuvNVOrder::UV as u8 },
                { $subsampling as u8 },
                { YuvEndianness::LittleEndian as u8 },
                { YuvBytesPacking::MostSignificantBytes as u8 },
                $bit_depth,
            >(bi_planar_image, dst, dst_stride, range, matrix)
        }
    };
}

d_cnv!(
    rgba10_to_p010,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv420,
    "P010",
    "RGBA",
    10,
    i16
);
d_cnv!(
    rgb10_to_p010,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv420,
    "P010",
    "RGB",
    10,
    i16
);
d_cnv!(
    rgba10_to_p210,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv422,
    "P210",
    "RGBA",
    10,
    i16
);
d_cnv!(
    rgb10_to_p210,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv422,
    "P210",
    "RGB",
    10,
    i16
);
d_cnv!(
    rgba10_to_p410,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv444,
    "P410",
    "RGBA",
    10,
    i16
);
d_cnv!(
    rgb10_to_p410,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv444,
    "P410",
    "RGB",
    10,
    i16
);

d_cnv!(
    rgba12_to_p012,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv420,
    "P012",
    "RGBA",
    12,
    i16
);
d_cnv!(
    rgb12_to_p012,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv420,
    "P012",
    "RGB",
    12,
    i16
);
d_cnv!(
    rgba12_to_p212,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv422,
    "P212",
    "RGBA",
    12,
    i16
);
d_cnv!(
    rgb12_to_p212,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv422,
    "P212",
    "RGB",
    12,
    i16
);
d_cnv!(
    rgba12_to_p412,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv444,
    "P412",
    "RGBA",
    12,
    i16
);
d_cnv!(
    rgb12_to_p412,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv444,
    "P412",
    "RGB",
    12,
    i16
);

d_cnv!(
    rgba16_to_p016,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv420,
    "P016",
    "RGBA",
    16,
    i32
);
d_cnv!(
    rgb16_to_p016,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv420,
    "P016",
    "RGB",
    16,
    i32
);

d_cnv!(
    rgba16_to_p216,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv420,
    "P216",
    "RGBA",
    16,
    i32
);
d_cnv!(
    rgb16_to_p216,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv420,
    "P216",
    "RGB",
    16,
    i32
);
