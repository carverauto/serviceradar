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
use crate::internals::{ProcessedOffset, WideRowForward420Handler, WideRowForwardHandler};

use crate::images::projected_rgba_plane;
use crate::yuv_error::check_rgba_destination;
use crate::yuv_support::{
    get_forward_transform, get_yuv_range, CbCrForwardTransform, ToIntegerTransform, YuvChromaRange,
    YuvChromaSubsampling, YuvSourceChannels,
};
use crate::{
    YuvBytesPacking, YuvEndianness, YuvError, YuvPlanarImageMut, YuvRange, YuvStandardMatrix,
};
#[cfg(feature = "rayon")]
use rayon::iter::{IndexedParallelIterator, ParallelIterator};
#[cfg(feature = "rayon")]
use rayon::prelude::{ParallelSlice, ParallelSliceMut};

#[inline(always)]
fn transform_integer<const ENDIANNESS: u8, const BYTES_POSITION: u8, const BIT_DEPTH: usize>(
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

type RgbEncoderHandler = Option<
    unsafe fn(
        transform: &CbCrForwardTransform<i32>,
        range: &YuvChromaRange,
        y_plane: &mut [u16],
        u_plane: &mut [u16],
        v_plane: &mut [u16],
        rgba: &[u16],
        start_cx: usize,
        start_ux: usize,
        width: usize,
    ) -> ProcessedOffset,
>;

type RgbEncoder420Handler = Option<
    unsafe fn(
        transform: &CbCrForwardTransform<i32>,
        range: &YuvChromaRange,
        y_plane0: &mut [u16],
        y_plane1: &mut [u16],
        u_plane: &mut [u16],
        v_plane: &mut [u16],
        rgba0: &[u16],
        rgba1: &[u16],
        start_cx: usize,
        start_ux: usize,
        width: usize,
    ) -> ProcessedOffset,
>;

struct RgbEncoder<
    const ORIGIN_CHANNELS: u8,
    const SAMPLING: u8,
    const ENDIANNESS: u8,
    const BYTES_POSITION: u8,
    const BIT_DEPTH: usize,
    const PRECISION: i32,
> {
    handler: RgbEncoderHandler,
}

struct RgbEncoder420<
    const ORIGIN_CHANNELS: u8,
    const SAMPLING: u8,
    const ENDIANNESS: u8,
    const BYTES_POSITION: u8,
    const BIT_DEPTH: usize,
    const PRECISION: i32,
> {
    handler: RgbEncoder420Handler,
}

impl<
        const ORIGIN_CHANNELS: u8,
        const SAMPLING: u8,
        const ENDIANNESS: u8,
        const BYTES_POSITION: u8,
        const BIT_DEPTH: usize,
        const PRECISION: i32,
    > Default
    for RgbEncoder<ORIGIN_CHANNELS, SAMPLING, ENDIANNESS, BYTES_POSITION, BIT_DEPTH, PRECISION>
{
    fn default() -> Self {
        if PRECISION != 15 {
            return RgbEncoder { handler: None };
        }
        #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
        {
            #[cfg(feature = "rdm")]
            if BIT_DEPTH == 10 {
                let is_rdm_available = std::arch::is_aarch64_feature_detected!("rdm");
                if is_rdm_available {
                    use crate::neon::neon_rgba_to_yuv_p16_rdm;
                    return RgbEncoder {
                        handler: Some(
                            neon_rgba_to_yuv_p16_rdm::<
                                ORIGIN_CHANNELS,
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

            use crate::neon::neon_rgba_to_yuv_p16;
            RgbEncoder {
                handler: Some(
                    neon_rgba_to_yuv_p16::<
                        ORIGIN_CHANNELS,
                        SAMPLING,
                        ENDIANNESS,
                        BYTES_POSITION,
                        PRECISION,
                        BIT_DEPTH,
                    >,
                ),
            }
        }
        #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
        {
            #[cfg(feature = "nightly_avx512")]
            {
                let use_avx512 = std::arch::is_x86_feature_detected!("avx512bw");
                if use_avx512 && BIT_DEPTH <= 15 {
                    use crate::avx512bw::avx512_rgba_to_yuv_p16;
                    return RgbEncoder {
                        handler: Some(
                            avx512_rgba_to_yuv_p16::<
                                ORIGIN_CHANNELS,
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
            #[cfg(feature = "avx")]
            {
                let use_avx = std::arch::is_x86_feature_detected!("avx2");
                if use_avx {
                    if BIT_DEPTH <= 15 {
                        use crate::avx2::avx_rgba_to_yuv_p16;
                        return RgbEncoder {
                            handler: Some(
                                avx_rgba_to_yuv_p16::<
                                    ORIGIN_CHANNELS,
                                    SAMPLING,
                                    ENDIANNESS,
                                    BYTES_POSITION,
                                    PRECISION,
                                    BIT_DEPTH,
                                >,
                            ),
                        };
                    } else {
                        use crate::avx2::avx_rgba_to_yuv_p16_d16;
                        return RgbEncoder {
                            handler: Some(
                                avx_rgba_to_yuv_p16_d16::<
                                    ORIGIN_CHANNELS,
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
            }
            #[cfg(feature = "sse")]
            {
                let use_sse = std::arch::is_x86_feature_detected!("sse4.1");
                if use_sse && BIT_DEPTH <= 15 {
                    use crate::sse::sse_rgba_to_yuv_p16;
                    return RgbEncoder {
                        handler: Some(
                            sse_rgba_to_yuv_p16::<
                                ORIGIN_CHANNELS,
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
        }
        #[cfg(not(all(target_arch = "aarch64", target_feature = "neon")))]
        RgbEncoder { handler: None }
    }
}

macro_rules! define_handler_impl {
    ($struct_name:ident) => {
        impl<
                const ORIGIN_CHANNELS: u8,
                const SAMPLING: u8,
                const ENDIANNESS: u8,
                const BYTES_POSITION: u8,
                const BIT_DEPTH: usize,
                const PRECISION: i32,
            > WideRowForwardHandler<u16, i32>
            for $struct_name<
                ORIGIN_CHANNELS,
                SAMPLING,
                ENDIANNESS,
                BYTES_POSITION,
                BIT_DEPTH,
                PRECISION,
            >
        {
            fn handle_row(
                &self,
                y_plane: &mut [u16],
                u_plane: &mut [u16],
                v_plane: &mut [u16],
                rgba: &[u16],
                width: u32,
                chroma: YuvChromaRange,
                transform: &CbCrForwardTransform<i32>,
            ) -> ProcessedOffset {
                if let Some(handler) = self.handler {
                    unsafe {
                        return handler(
                            transform,
                            &chroma,
                            y_plane,
                            u_plane,
                            v_plane,
                            rgba,
                            0,
                            0,
                            width as usize,
                        );
                    }
                }
                ProcessedOffset { cx: 0, ux: 0 }
            }
        }
    };
}

define_handler_impl!(RgbEncoder);

impl<
        const ORIGIN_CHANNELS: u8,
        const SAMPLING: u8,
        const ENDIANNESS: u8,
        const BYTES_POSITION: u8,
        const BIT_DEPTH: usize,
        const PRECISION: i32,
    > Default
    for RgbEncoder420<ORIGIN_CHANNELS, SAMPLING, ENDIANNESS, BYTES_POSITION, BIT_DEPTH, PRECISION>
{
    fn default() -> Self {
        if PRECISION != 15 {
            return RgbEncoder420 { handler: None };
        }
        assert_eq!(PRECISION, 15);
        let sampling: YuvChromaSubsampling = SAMPLING.into();
        if sampling != YuvChromaSubsampling::Yuv420 {
            return RgbEncoder420 { handler: None };
        }
        assert_eq!(sampling, YuvChromaSubsampling::Yuv420);
        #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
        {
            #[cfg(feature = "rdm")]
            {
                let is_rdm_available = std::arch::is_aarch64_feature_detected!("rdm");
                if is_rdm_available && BIT_DEPTH == 10 {
                    use crate::neon::neon_rgba_to_yuv_p16_rdm_420;
                    return RgbEncoder420 {
                        handler: Some(
                            neon_rgba_to_yuv_p16_rdm_420::<
                                ORIGIN_CHANNELS,
                                ENDIANNESS,
                                BYTES_POSITION,
                                PRECISION,
                                BIT_DEPTH,
                            >,
                        ),
                    };
                }
            }
            use crate::neon::neon_rgba_to_yuv_p16_420;
            RgbEncoder420 {
                handler: Some(
                    neon_rgba_to_yuv_p16_420::<
                        ORIGIN_CHANNELS,
                        ENDIANNESS,
                        BYTES_POSITION,
                        PRECISION,
                        BIT_DEPTH,
                    >,
                ),
            }
        }
        #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
        {
            #[cfg(feature = "nightly_avx512")]
            {
                let use_avx512 = std::arch::is_x86_feature_detected!("avx512bw");
                if use_avx512 && BIT_DEPTH <= 15 {
                    use crate::avx512bw::avx512_rgba_to_yuv_p16_420;
                    return RgbEncoder420 {
                        handler: Some(
                            avx512_rgba_to_yuv_p16_420::<
                                ORIGIN_CHANNELS,
                                ENDIANNESS,
                                BYTES_POSITION,
                                PRECISION,
                                BIT_DEPTH,
                            >,
                        ),
                    };
                }
            }
            #[cfg(feature = "avx")]
            {
                let use_avx = std::arch::is_x86_feature_detected!("avx2");
                if use_avx {
                    if BIT_DEPTH <= 15 {
                        use crate::avx2::avx_rgba_to_yuv_p16_420;
                        return RgbEncoder420 {
                            handler: Some(
                                avx_rgba_to_yuv_p16_420::<
                                    ORIGIN_CHANNELS,
                                    ENDIANNESS,
                                    BYTES_POSITION,
                                    PRECISION,
                                    BIT_DEPTH,
                                >,
                            ),
                        };
                    } else if BIT_DEPTH <= 16 {
                        use crate::avx2::avx_rgba_to_yuv_p16_420_d16;
                        return RgbEncoder420 {
                            handler: Some(
                                avx_rgba_to_yuv_p16_420_d16::<
                                    ORIGIN_CHANNELS,
                                    ENDIANNESS,
                                    BYTES_POSITION,
                                    PRECISION,
                                    BIT_DEPTH,
                                >,
                            ),
                        };
                    }
                }
            }
            #[cfg(feature = "sse")]
            {
                let use_sse = std::arch::is_x86_feature_detected!("sse4.1");
                if use_sse && BIT_DEPTH <= 15 {
                    use crate::sse::sse_rgba_to_yuv_p16_420;
                    return RgbEncoder420 {
                        handler: Some(
                            sse_rgba_to_yuv_p16_420::<
                                ORIGIN_CHANNELS,
                                ENDIANNESS,
                                BYTES_POSITION,
                                PRECISION,
                                BIT_DEPTH,
                            >,
                        ),
                    };
                }
            }
        }
        #[cfg(not(all(target_arch = "aarch64", target_feature = "neon")))]
        RgbEncoder420 { handler: None }
    }
}

macro_rules! impl_wide_row_forward_handler {
    ($struct_name:ident) => {
        impl<
                const ORIGIN_CHANNELS: u8,
                const SAMPLING: u8,
                const ENDIANNESS: u8,
                const BYTES_POSITION: u8,
                const BIT_DEPTH: usize,
                const PRECISION: i32,
            > WideRowForward420Handler<u16, i32>
            for $struct_name<
                ORIGIN_CHANNELS,
                SAMPLING,
                ENDIANNESS,
                BYTES_POSITION,
                BIT_DEPTH,
                PRECISION,
            >
        {
            fn handle_row(
                &self,
                y_plane0: &mut [u16],
                y_plane1: &mut [u16],
                u_plane: &mut [u16],
                v_plane: &mut [u16],
                rgba0: &[u16],
                rgba1: &[u16],
                width: u32,
                chroma: YuvChromaRange,
                transform: &CbCrForwardTransform<i32>,
            ) -> ProcessedOffset {
                if let Some(handler) = self.handler {
                    unsafe {
                        return handler(
                            transform,
                            &chroma,
                            y_plane0,
                            y_plane1,
                            u_plane,
                            v_plane,
                            rgba0,
                            rgba1,
                            0,
                            0,
                            width as usize,
                        );
                    }
                }
                ProcessedOffset { cx: 0, ux: 0 }
            }
        }
    };
}

impl_wide_row_forward_handler!(RgbEncoder420);

fn rgbx_to_yuv_ant<
    const ORIGIN_CHANNELS: u8,
    const SAMPLING: u8,
    const ENDIANNESS: u8,
    const BYTES_POSITION: u8,
    const BIT_DEPTH: usize,
    const PRECISION: i32,
>(
    image: &mut YuvPlanarImageMut<u16>,
    rgba: &[u16],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    handler: impl WideRowForwardHandler<u16, i32> + Send + Sync,
    handler420: impl WideRowForward420Handler<u16, i32> + Send + Sync,
) -> Result<(), YuvError> {
    let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();
    let src_chans: YuvSourceChannels = ORIGIN_CHANNELS.into();
    let channels = src_chans.get_channels_count();

    image.check_constraints(chroma_subsampling)?;
    check_rgba_destination(rgba, rgba_stride, image.width, image.height, channels)?;

    let range = get_yuv_range(BIT_DEPTH as u32, range);
    let kr_kb = matrix.get_kr_kb();
    let max_range = (1u32 << BIT_DEPTH) - 1u32;
    let transform_precise =
        get_forward_transform(max_range, range.range_y, range.range_uv, kr_kb.kr, kr_kb.kb);

    let transform = transform_precise.to_integers(PRECISION as u32);
    let rnd_const: i32 = (1 << (PRECISION - 1)) - 1;
    let bias_y = range.bias_y as i32 * (1 << PRECISION) + rnd_const;
    let bias_uv = range.bias_uv as i32 * (1 << PRECISION) + rnd_const;

    let width = image.width;
    let height = image.height;

    let process_halved_chroma_row = |y_plane: &mut [u16],
                                     u_plane: &mut [u16],
                                     v_plane: &mut [u16],
                                     rgba| {
        let processed_offset =
            handler.handle_row(y_plane, u_plane, v_plane, rgba, width, range, &transform);
        let cx = processed_offset.cx;
        if cx != width as usize {
            for (((y_dst, u_dst), v_dst), rgba) in y_plane
                .chunks_exact_mut(2)
                .zip(u_plane.iter_mut())
                .zip(v_plane.iter_mut())
                .zip(rgba.chunks_exact(channels * 2))
                .skip(cx / 2)
            {
                let r0 = rgba[src_chans.get_r_channel_offset()] as i32;
                let g0 = rgba[src_chans.get_g_channel_offset()] as i32;
                let b0 = rgba[src_chans.get_b_channel_offset()] as i32;
                let y_0 = (r0 * transform.yr + g0 * transform.yg + b0 * transform.yb + bias_y)
                    >> PRECISION;
                y_dst[0] = transform_integer::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(y_0);

                let r1 = rgba[channels + src_chans.get_r_channel_offset()] as i32;
                let g1 = rgba[channels + src_chans.get_g_channel_offset()] as i32;
                let b1 = rgba[channels + src_chans.get_b_channel_offset()] as i32;
                let y_1 = (r1 * transform.yr + g1 * transform.yg + b1 * transform.yb + bias_y)
                    >> PRECISION;
                y_dst[1] = transform_integer::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(y_1);

                let r = (r0 + r1 + 1) >> 1;
                let g = (g0 + g1 + 1) >> 1;
                let b = (b0 + b1 + 1) >> 1;

                let cb = (r * transform.cb_r + g * transform.cb_g + b * transform.cb_b + bias_uv)
                    >> PRECISION;
                let cr = (r * transform.cr_r + g * transform.cr_g + b * transform.cr_b + bias_uv)
                    >> PRECISION;
                *u_dst = transform_integer::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(cb);
                *v_dst = transform_integer::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(cr);
            }

            if width & 1 != 0 {
                let rgb_last = rgba.chunks_exact(channels * 2).remainder();
                let r0 = rgb_last[src_chans.get_r_channel_offset()] as i32;
                let g0 = rgb_last[src_chans.get_g_channel_offset()] as i32;
                let b0 = rgb_last[src_chans.get_b_channel_offset()] as i32;

                let y_last = y_plane.last_mut().unwrap();
                let u_last = u_plane.last_mut().unwrap();
                let v_last = v_plane.last_mut().unwrap();

                let y_0 = (r0 * transform.yr + g0 * transform.yg + b0 * transform.yb + bias_y)
                    >> PRECISION;
                *y_last = transform_integer::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(y_0);

                let cb =
                    (r0 * transform.cb_r + g0 * transform.cb_g + b0 * transform.cb_b + bias_uv)
                        >> PRECISION;
                let cr =
                    (r0 * transform.cr_r + g0 * transform.cr_g + b0 * transform.cr_b + bias_uv)
                        >> PRECISION;
                *u_last = transform_integer::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(cb);
                *v_last = transform_integer::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(cr);
            }
        }
    };

    let process_double_chroma_row = |y_plane0: &mut [u16],
                                     y_plane1: &mut [u16],
                                     u_plane: &mut [u16],
                                     v_plane: &mut [u16],
                                     rgba0: &[u16],
                                     rgba1: &[u16]| {
        let processed_offset = handler420.handle_row(
            y_plane0, y_plane1, u_plane, v_plane, rgba0, rgba1, width, range, &transform,
        );
        let cx = processed_offset.cx;

        for (((((y_dst0, y_dst1), u_dst), v_dst), rgba0), rgba1) in y_plane0
            .chunks_exact_mut(2)
            .zip(y_plane1.chunks_exact_mut(2))
            .zip(u_plane.iter_mut())
            .zip(v_plane.iter_mut())
            .zip(rgba0.chunks_exact(channels * 2))
            .zip(rgba1.chunks_exact(channels * 2))
            .skip(cx / 2)
        {
            let r00 = rgba0[src_chans.get_r_channel_offset()] as i32;
            let g00 = rgba0[src_chans.get_g_channel_offset()] as i32;
            let b00 = rgba0[src_chans.get_b_channel_offset()] as i32;
            let y_00 = (r00 * transform.yr + g00 * transform.yg + b00 * transform.yb + bias_y)
                >> PRECISION;
            y_dst0[0] = transform_integer::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(y_00);

            let rgba01 = &rgba0[channels..channels * 2];
            let r01 = rgba01[src_chans.get_r_channel_offset()] as i32;
            let g01 = rgba01[src_chans.get_g_channel_offset()] as i32;
            let b01 = rgba01[src_chans.get_b_channel_offset()] as i32;
            let y_01 = (r01 * transform.yr + g01 * transform.yg + b01 * transform.yb + bias_y)
                >> PRECISION;
            y_dst0[1] = transform_integer::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(y_01);

            let r10 = rgba1[src_chans.get_r_channel_offset()] as i32;
            let g10 = rgba1[src_chans.get_g_channel_offset()] as i32;
            let b10 = rgba1[src_chans.get_b_channel_offset()] as i32;
            let y_10 = (r10 * transform.yr + g10 * transform.yg + b10 * transform.yb + bias_y)
                >> PRECISION;
            y_dst1[0] = transform_integer::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(y_10);

            let rgba11 = &rgba1[channels..channels * 2];
            let r11 = rgba11[src_chans.get_r_channel_offset()] as i32;
            let g11 = rgba11[src_chans.get_g_channel_offset()] as i32;
            let b11 = rgba11[src_chans.get_b_channel_offset()] as i32;
            let y_11 = (r01 * transform.yr + g01 * transform.yg + b01 * transform.yb + bias_y)
                >> PRECISION;
            y_dst1[1] = transform_integer::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(y_11);

            let r = (r00 + r01 + r10 + r11 + 2) >> 2;
            let g = (g00 + g01 + g10 + g11 + 2) >> 2;
            let b = (b00 + b01 + b10 + b11 + 2) >> 2;

            let cb = (r * transform.cb_r + g * transform.cb_g + b * transform.cb_b + bias_uv)
                >> PRECISION;
            let cr = (r * transform.cr_r + g * transform.cr_g + b * transform.cr_b + bias_uv)
                >> PRECISION;
            *u_dst = transform_integer::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(cb);
            *v_dst = transform_integer::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(cr);
        }

        if width & 1 != 0 {
            let rgb_last0 = rgba0.chunks_exact(channels * 2).remainder();
            let r0 = rgb_last0[src_chans.get_r_channel_offset()] as i32;
            let g0 = rgb_last0[src_chans.get_g_channel_offset()] as i32;
            let b0 = rgb_last0[src_chans.get_b_channel_offset()] as i32;

            let rgb_last1 = rgba1.chunks_exact(channels * 2).remainder();
            let r1 = rgb_last1[src_chans.get_r_channel_offset()] as i32;
            let g1 = rgb_last1[src_chans.get_g_channel_offset()] as i32;
            let b1 = rgb_last1[src_chans.get_b_channel_offset()] as i32;

            let y0_last = y_plane0.last_mut().unwrap();
            let y1_last = y_plane1.last_mut().unwrap();
            let u_last = u_plane.last_mut().unwrap();
            let v_last = v_plane.last_mut().unwrap();

            let y_0 =
                (r0 * transform.yr + g0 * transform.yg + b0 * transform.yb + bias_y) >> PRECISION;
            *y0_last = transform_integer::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(y_0);

            let y_1 =
                (r1 * transform.yr + g1 * transform.yg + b1 * transform.yb + bias_y) >> PRECISION;
            *y1_last = transform_integer::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(y_1);

            let r = (r0 + r1 + 1) >> 1;
            let g = (g0 + g1 + 1) >> 1;
            let b = (b0 + b1 + 1) >> 1;

            let cb = (r * transform.cb_r + g * transform.cb_g + b * transform.cb_b + bias_uv)
                >> PRECISION;
            let cr = (r * transform.cr_r + g * transform.cr_g + b * transform.cr_b + bias_uv)
                >> PRECISION;
            *u_last = transform_integer::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(cb);
            *v_last = transform_integer::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(cr);
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
            let processed_offset =
                handler.handle_row(y_dst, u_plane, v_plane, rgba, width, range, &transform);

            let cx = processed_offset.cx;

            if cx != width as usize {
                for (((y_dst, u_dst), v_dst), rgba) in y_dst
                    .iter_mut()
                    .zip(u_plane.iter_mut())
                    .zip(v_plane.iter_mut())
                    .zip(rgba.chunks_exact(channels))
                    .skip(cx)
                {
                    let r0 = rgba[src_chans.get_r_channel_offset()] as i32;
                    let g0 = rgba[src_chans.get_g_channel_offset()] as i32;
                    let b0 = rgba[src_chans.get_b_channel_offset()] as i32;
                    let y_0 = (r0 * transform.yr + g0 * transform.yg + b0 * transform.yb + bias_y)
                        >> PRECISION;
                    *y_dst = transform_integer::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(y_0);

                    let cb =
                        (r0 * transform.cb_r + g0 * transform.cb_g + b0 * transform.cb_b + bias_uv)
                            >> PRECISION;
                    let cr =
                        (r0 * transform.cr_r + g0 * transform.cr_g + b0 * transform.cr_b + bias_uv)
                            >> PRECISION;
                    *u_dst = transform_integer::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(cb);
                    *v_dst = transform_integer::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(cr);
                }
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
            process_halved_chroma_row(y_plane, u_plane, v_plane, rgba);
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
                let (y_plane0, y_plane1) = y_plane.split_at_mut(y_stride);
                let (rgba0, rgba1) = rgba.split_at(rgba_stride as usize);
                process_double_chroma_row(
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

macro_rules! d_cvn {
    ($method: ident, $px_fmt: expr,
    $sampling: expr,
    $yuv_name: expr, $rgb_name: expr,
    $rgb_small: expr, $bit_depth: expr,
    $endianness: expr) => {
        #[doc = concat!("Convert ", $rgb_name, " image data to ", $yuv_name, " format with ", $bit_depth, " bit depth.

This function performs ", $rgb_name, stringify!($bit_depth), " to ",$yuv_name," conversion and stores the result in ", $yuv_name," format,
with separate planes for Y (luminance), U (chrominance), and V (chrominance) components.

# Arguments

* `planar_image` - Target planar image.
* `",$rgb_small,"` - The input ", $rgb_name," image data slice.
* `",$rgb_small,"_stride` - The stride (components per row) for the ", $rgb_name ," image data.
* `range` - The YUV range (limited or full).
* `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).

# Panics

This function panics if the lengths of the planes or the input RGBA data are not valid based
on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
")]
        pub fn $method(
            planar_image: &mut YuvPlanarImageMut<u16>,
            rgba: &[u16],
            rgba_stride: u32,
            range: YuvRange,
            matrix: YuvStandardMatrix,
        ) -> Result<(), YuvError> {
            rgbx_to_yuv_ant::<
                { $px_fmt as u8 },
                { $sampling as u8 },
                { $endianness as u8 },
                { YuvBytesPacking::LeastSignificantBytes as u8 },
                $bit_depth,
                15,
            >(planar_image, rgba, rgba_stride, range, matrix,
              RgbEncoder::<{ $px_fmt as u8 }, { $sampling as u8 }, { $endianness as u8 },
                            { YuvBytesPacking::LeastSignificantBytes as u8 }, $bit_depth, 15>::default(),
              RgbEncoder420::<{ $px_fmt as u8 }, { $sampling as u8 }, { $endianness as u8 },
                            { YuvBytesPacking::LeastSignificantBytes as u8 }, $bit_depth, 15>::default())
        }
    };
}

d_cvn!(
    rgba10_to_i010,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv420,
    "I010",
    "RGBA10",
    "rgba10",
    10,
    YuvEndianness::LittleEndian
);
#[cfg(feature = "big_endian")]
d_cvn!(
    rgba10_to_i010_be,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv420,
    "I010",
    "RGBA10",
    "rgba10",
    10,
    YuvEndianness::BigEndian
);

d_cvn!(
    rgb10_to_i010,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv420,
    "I010",
    "RGB10",
    "rgb10",
    10,
    YuvEndianness::LittleEndian
);
#[cfg(feature = "big_endian")]
d_cvn!(
    rgb10_to_i010_be,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv420,
    "I010",
    "RGB10",
    "rgb10",
    10,
    YuvEndianness::BigEndian
);

d_cvn!(
    rgba10_to_i210,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv422,
    "I210",
    "RGBA10",
    "rgba10",
    10,
    YuvEndianness::LittleEndian
);
#[cfg(feature = "big_endian")]
d_cvn!(
    rgba10_to_i210_be,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv422,
    "I210",
    "RGBA10",
    "rgba10",
    10,
    YuvEndianness::BigEndian
);

d_cvn!(
    rgb10_to_i210,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv422,
    "I210",
    "RGB10",
    "rgb10",
    10,
    YuvEndianness::LittleEndian
);
#[cfg(feature = "big_endian")]
d_cvn!(
    rgb10_to_i210_be,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv422,
    "I210",
    "RGB10",
    "rgb10",
    10,
    YuvEndianness::BigEndian
);

d_cvn!(
    rgba10_to_i410,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv444,
    "I410",
    "RGBA10",
    "rgba10",
    10,
    YuvEndianness::LittleEndian
);
#[cfg(feature = "big_endian")]
d_cvn!(
    rgba10_to_i410_be,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv444,
    "I410",
    "RGBA10",
    "rgba10",
    10,
    YuvEndianness::BigEndian
);

d_cvn!(
    rgb10_to_i410,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv444,
    "I410",
    "RGB10",
    "rgb10",
    10,
    YuvEndianness::LittleEndian
);
#[cfg(feature = "big_endian")]
d_cvn!(
    rgb10_to_i410_be,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv444,
    "I410",
    "RGB10",
    "rgb10",
    10,
    YuvEndianness::BigEndian
);

d_cvn!(
    rgba12_to_i012,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv420,
    "I012",
    "RGBA12",
    "rgba12",
    12,
    YuvEndianness::LittleEndian
);
#[cfg(feature = "big_endian")]
d_cvn!(
    rgba12_to_i012_be,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv420,
    "I012",
    "RGBA12",
    "rgba12",
    12,
    YuvEndianness::BigEndian
);

d_cvn!(
    rgb12_to_i012,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv420,
    "I012",
    "RGB12",
    "rgb12",
    12,
    YuvEndianness::LittleEndian
);
#[cfg(feature = "big_endian")]
d_cvn!(
    rgb12_to_i012_be,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv420,
    "I012",
    "RGB12",
    "rgb12",
    12,
    YuvEndianness::BigEndian
);

d_cvn!(
    rgba12_to_i212,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv422,
    "I212",
    "RGBA12",
    "rgba12",
    12,
    YuvEndianness::LittleEndian
);
#[cfg(feature = "big_endian")]
d_cvn!(
    rgba12_to_i212_be,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv420,
    "I212",
    "RGBA12",
    "rgba12",
    12,
    YuvEndianness::BigEndian
);

d_cvn!(
    rgb12_to_i212,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv422,
    "I212",
    "RGB12",
    "rgb12",
    12,
    YuvEndianness::LittleEndian
);
#[cfg(feature = "big_endian")]
d_cvn!(
    rgb12_to_i212_be,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv422,
    "I212",
    "RGB12",
    "rgb12",
    12,
    YuvEndianness::BigEndian
);

d_cvn!(
    rgba12_to_i412,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv444,
    "I412",
    "RGBA12",
    "rgba12",
    12,
    YuvEndianness::LittleEndian
);
#[cfg(feature = "big_endian")]
d_cvn!(
    rgba12_to_i412_be,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv444,
    "I412",
    "RGBA12",
    "rgba12",
    12,
    YuvEndianness::BigEndian
);

d_cvn!(
    rgb12_to_i412,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv444,
    "I412",
    "RGB12",
    "rgb12",
    12,
    YuvEndianness::LittleEndian
);
#[cfg(feature = "big_endian")]
d_cvn!(
    rgb12_to_i412_be,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv444,
    "I412",
    "RGB12",
    "rgb12",
    12,
    YuvEndianness::BigEndian
);
// 14-bit
d_cvn!(
    rgba14_to_i014,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv420,
    "I014",
    "RGBA14",
    "rgba14",
    14,
    YuvEndianness::LittleEndian
);
#[cfg(feature = "big_endian")]
d_cvn!(
    rgba14_to_i014_be,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv420,
    "I014",
    "RGBA14",
    "rgba14",
    14,
    YuvEndianness::BigEndian
);

d_cvn!(
    rgb14_to_i014,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv420,
    "I014",
    "RGB14",
    "rgb14",
    14,
    YuvEndianness::LittleEndian
);
#[cfg(feature = "big_endian")]
d_cvn!(
    rgb14_to_i014_be,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv420,
    "I014",
    "RGB14",
    "rgb14",
    14,
    YuvEndianness::BigEndian
);

d_cvn!(
    rgba14_to_i214,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv422,
    "I214",
    "RGBA14",
    "rgba14",
    14,
    YuvEndianness::LittleEndian
);
#[cfg(feature = "big_endian")]
d_cvn!(
    rgba14_to_i214_be,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv422,
    "I214",
    "RGBA14",
    "rgba14",
    14,
    YuvEndianness::BigEndian
);
d_cvn!(
    rgb14_to_i214,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv422,
    "I214",
    "RGB14",
    "rgb14",
    14,
    YuvEndianness::LittleEndian
);
#[cfg(feature = "big_endian")]
d_cvn!(
    rgb14_to_i214_be,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv422,
    "I214",
    "RGB14",
    "rgb14",
    14,
    YuvEndianness::BigEndian
);

d_cvn!(
    rgba14_to_i414,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv444,
    "I414",
    "RGBA14",
    "rgba14",
    14,
    YuvEndianness::LittleEndian
);
#[cfg(feature = "big_endian")]
d_cvn!(
    rgba14_to_i414_be,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv444,
    "I414",
    "RGBA14",
    "rgba14",
    14,
    YuvEndianness::BigEndian
);

d_cvn!(
    rgb14_to_i414,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv444,
    "I414",
    "RGB14",
    "rgb14",
    14,
    YuvEndianness::LittleEndian
);
#[cfg(feature = "big_endian")]
d_cvn!(
    rgb14_to_i414_be,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv444,
    "I414",
    "RGB14",
    "rgb14",
    14,
    YuvEndianness::BigEndian
);
//16-bit
d_cvn!(
    rgba16_to_i016,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv420,
    "I016",
    "RGBA16",
    "rgba16",
    16,
    YuvEndianness::LittleEndian
);
#[cfg(feature = "big_endian")]
d_cvn!(
    rgba16_to_i016_be,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv420,
    "I016",
    "RGBA16",
    "rgba16",
    16,
    YuvEndianness::BigEndian
);

d_cvn!(
    rgb16_to_i016,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv420,
    "I016",
    "RGB16",
    "rgb16",
    16,
    YuvEndianness::LittleEndian
);
#[cfg(feature = "big_endian")]
d_cvn!(
    rgb16_to_i016_be,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv420,
    "I016",
    "RGB16",
    "rgb16",
    16,
    YuvEndianness::BigEndian
);

d_cvn!(
    rgba16_to_i216,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv422,
    "I216",
    "RGBA16",
    "rgba16",
    16,
    YuvEndianness::LittleEndian
);
#[cfg(feature = "big_endian")]
d_cvn!(
    rgba16_to_i216_be,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv422,
    "I216",
    "RGBA16",
    "rgba16",
    16,
    YuvEndianness::BigEndian
);
d_cvn!(
    rgb16_to_i216,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv422,
    "I216",
    "RGB16",
    "rgb16",
    16,
    YuvEndianness::LittleEndian
);
#[cfg(feature = "big_endian")]
d_cvn!(
    rgb16_to_i216_be,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv422,
    "I216",
    "RGB16",
    "rgb16",
    16,
    YuvEndianness::BigEndian
);

d_cvn!(
    rgba16_to_i416,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv444,
    "I416",
    "RGBA16",
    "rgba16",
    16,
    YuvEndianness::LittleEndian
);
#[cfg(feature = "big_endian")]
d_cvn!(
    rgba16_to_i416_be,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv444,
    "I416",
    "RGBA16",
    "rgba16",
    16,
    YuvEndianness::BigEndian
);

d_cvn!(
    rgb16_to_i416,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv444,
    "I416",
    "RGB16",
    "rgb16",
    16,
    YuvEndianness::LittleEndian
);
#[cfg(feature = "big_endian")]
d_cvn!(
    rgb16_to_i416_be,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv444,
    "I416",
    "RGB16",
    "rgb16",
    16,
    YuvEndianness::BigEndian
);
