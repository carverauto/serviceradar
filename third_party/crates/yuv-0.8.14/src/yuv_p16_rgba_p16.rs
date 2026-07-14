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
use crate::images::projected_rgba_plane_mut;
#[allow(unused_imports)]
use crate::internals::ProcessedOffset;
use crate::numerics::{qrshr, to_ne};
use crate::yuv_error::check_rgba_destination;
use crate::yuv_support::{
    get_yuv_range, search_inverse_transform, CbCrInverseTransform, YuvBytesPacking, YuvChromaRange,
    YuvChromaSubsampling, YuvEndianness, YuvRange, YuvSourceChannels, YuvStandardMatrix,
};
use crate::{YuvError, YuvPlanarImage};
#[cfg(feature = "rayon")]
use rayon::iter::{IndexedParallelIterator, ParallelIterator};
#[cfg(feature = "rayon")]
use rayon::prelude::{ParallelSlice, ParallelSliceMut};

trait WideRowInversionHandler<V, K> {
    fn handle_row(
        &self,
        y_plane: &[V],
        u_plane: &[V],
        v_plane: &[V],
        rgba: &mut [V],
        width: u32,
        chroma: YuvChromaRange,
        transform: &CbCrInverseTransform<K>,
    ) -> bool;
}

pub(crate) struct WideRow420InversionHandler<
    const DESTINATION_CHANNELS: u8,
    const ENDIANNESS: u8,
    const BYTES_POSITION: u8,
    const PRECISION: i32,
    const BIT_DEPTH: usize,
> {
    handler: Option<
        fn(
            y0_plane: &[u16],
            y1_plane: &[u16],
            u_plane: &[u16],
            v_plane: &[u16],
            rgba0: &mut [u16],
            rgba1: &mut [u16],
            width: u32,
            chroma: &YuvChromaRange,
            transform: &CbCrInverseTransform<i32>,
        ),
    >,
}

impl<
        const DESTINATION_CHANNELS: u8,
        const ENDIANNESS: u8,
        const BYTES_POSITION: u8,
        const PRECISION: i32,
        const BIT_DEPTH: usize,
    > Default
    for WideRow420InversionHandler<
        DESTINATION_CHANNELS,
        ENDIANNESS,
        BYTES_POSITION,
        PRECISION,
        BIT_DEPTH,
    >
{
    fn default() -> Self {
        #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
        {
            #[cfg(feature = "rdm")]
            {
                let is_rdm_available = std::arch::is_aarch64_feature_detected!("rdm");
                if is_rdm_available && BIT_DEPTH == 10 {
                    use crate::neon::neon_yuv_p16_to_rgba16_row420_rdm;
                    return WideRow420InversionHandler {
                        handler: Some(
                            neon_yuv_p16_to_rgba16_row420_rdm::<
                                DESTINATION_CHANNELS,
                                ENDIANNESS,
                                BYTES_POSITION,
                                PRECISION,
                                BIT_DEPTH,
                            >,
                        ),
                    };
                }
            }
            if BIT_DEPTH <= 16 {
                use crate::neon::neon_yuv_p16_to_rgba16_row420;
                return WideRow420InversionHandler {
                    handler: Some(
                        neon_yuv_p16_to_rgba16_row420::<
                            DESTINATION_CHANNELS,
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
                if std::arch::is_x86_feature_detected!("avx2") {
                    return if BIT_DEPTH == 10 {
                        assert_eq!(BIT_DEPTH, 10);
                        use crate::avx2::avx_yuv_p16_to_rgba_row420;
                        WideRow420InversionHandler {
                            handler: Some(
                                avx_yuv_p16_to_rgba_row420::<
                                    DESTINATION_CHANNELS,
                                    ENDIANNESS,
                                    BYTES_POSITION,
                                    BIT_DEPTH,
                                    PRECISION,
                                >,
                            ),
                        }
                    } else {
                        use crate::avx2::avx_yuv_p16_to_rgba_d16_row420;
                        WideRow420InversionHandler {
                            handler: Some(
                                avx_yuv_p16_to_rgba_d16_row420::<
                                    DESTINATION_CHANNELS,
                                    ENDIANNESS,
                                    BYTES_POSITION,
                                    BIT_DEPTH,
                                    PRECISION,
                                >,
                            ),
                        }
                    };
                }
            }
            #[cfg(feature = "sse")]
            {
                if BIT_DEPTH == 10 && std::arch::is_x86_feature_detected!("sse4.1") {
                    use crate::sse::sse_yuv_p16_to_rgba_row420;
                    return WideRow420InversionHandler {
                        handler: Some(
                            sse_yuv_p16_to_rgba_row420::<
                                DESTINATION_CHANNELS,
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
        WideRow420InversionHandler { handler: None }
    }
}

struct WideRowAnyHandler<
    const DESTINATION_CHANNELS: u8,
    const SAMPLING: u8,
    const ENDIANNESS: u8,
    const BYTES_POSITION: u8,
    const PRECISION: i32,
    const BIT_DEPTH: usize,
> {
    handler: Option<
        fn(
            y_ld_ptr: &[u16],
            u_ld_ptr: &[u16],
            v_ld_ptr: &[u16],
            rgba: &mut [u16],
            width: u32,
            range: &YuvChromaRange,
            transform: &CbCrInverseTransform<i32>,
        ),
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
        #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
        {
            #[cfg(feature = "rdm")]
            {
                let is_rdm_available = std::arch::is_aarch64_feature_detected!("rdm");
                if is_rdm_available && BIT_DEPTH == 10 {
                    use crate::neon::neon_yuv_p16_to_rgba16_row_rdm;
                    return WideRowAnyHandler {
                        handler: Some(
                            neon_yuv_p16_to_rgba16_row_rdm::<
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
            if BIT_DEPTH <= 16 {
                use crate::neon::neon_yuv_p16_to_rgba16_row;
                return WideRowAnyHandler {
                    handler: Some(
                        neon_yuv_p16_to_rgba16_row::<
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
            #[cfg(feature = "sse")]
            let use_sse = std::arch::is_x86_feature_detected!("sse4.1");
            #[cfg(feature = "avx")]
            let use_avx = std::arch::is_x86_feature_detected!("avx2");
            #[cfg(feature = "nightly_avx512")]
            let use_avx512 = std::arch::is_x86_feature_detected!("avx512bw");
            #[cfg(feature = "nightly_avx512")]
            if use_avx512 && BIT_DEPTH <= 12 {
                use crate::avx512bw::avx512_yuv_p16_to_rgba16_row;
                return WideRowAnyHandler {
                    handler: Some(
                        avx512_yuv_p16_to_rgba16_row::<
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
            #[cfg(feature = "avx")]
            {
                if use_avx {
                    return if BIT_DEPTH == 10 {
                        assert_eq!(BIT_DEPTH, 10);
                        use crate::avx2::avx_yuv_p16_to_rgba_row;
                        WideRowAnyHandler {
                            handler: Some(
                                avx_yuv_p16_to_rgba_row::<
                                    DESTINATION_CHANNELS,
                                    SAMPLING,
                                    ENDIANNESS,
                                    BYTES_POSITION,
                                    BIT_DEPTH,
                                    PRECISION,
                                >,
                            ),
                        }
                    } else {
                        use crate::avx2::avx_yuv_p16_to_rgba_d16_row;
                        WideRowAnyHandler {
                            handler: Some(
                                avx_yuv_p16_to_rgba_d16_row::<
                                    DESTINATION_CHANNELS,
                                    SAMPLING,
                                    ENDIANNESS,
                                    BYTES_POSITION,
                                    BIT_DEPTH,
                                    PRECISION,
                                >,
                            ),
                        }
                    };
                }
            }
            #[cfg(feature = "sse")]
            if use_sse && BIT_DEPTH <= 12 {
                use crate::sse::sse_yuv_p16_to_rgba_row;
                return WideRowAnyHandler {
                    handler: Some(
                        sse_yuv_p16_to_rgba_row::<
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
    > WideRowInversionHandler<u16, i32>
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
        rgba: &mut [u16],
        width: u32,
        yuv_chroma_range: YuvChromaRange,
        transform: &CbCrInverseTransform<i32>,
    ) -> bool {
        if let Some(handler) = self.handler {
            handler(
                y_plane,
                u_plane,
                v_plane,
                rgba,
                width,
                &yuv_chroma_range,
                transform,
            );
            return true;
        }
        false
    }
}

fn process_halved_row<
    const DESTINATION_CHANNELS: u8,
    const SAMPLING: u8,
    const ENDIANNESS: u8,
    const BYTES_POSITION: u8,
    const BIT_DEPTH: usize,
    const PRECISION: i32,
>(
    y_plane: &[u16],
    u_plane: &[u16],
    v_plane: &[u16],
    rgba: &mut [u16],
    wide_row_handler: &WideRowAnyHandler<
        DESTINATION_CHANNELS,
        SAMPLING,
        ENDIANNESS,
        BYTES_POSITION,
        PRECISION,
        BIT_DEPTH,
    >,
    width: u32,
    chroma_range: YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
) {
    if wide_row_handler.handle_row(
        y_plane,
        u_plane,
        v_plane,
        rgba,
        width,
        chroma_range,
        transform,
    ) {
        return;
    }

    let max_range_p16 = ((1u32 << BIT_DEPTH as u32) - 1) as i32;
    let dst_chans: YuvSourceChannels = DESTINATION_CHANNELS.into();
    let channels = dst_chans.get_channels_count();

    let msb_shift = (16 - BIT_DEPTH) as i32;

    let cr_coef = transform.cr_coef;
    let cb_coef = transform.cb_coef;
    let y_coef = transform.y_coef;
    let g_coef_1 = transform.g_coeff_1;
    let g_coef_2 = transform.g_coeff_2;

    let bias_y = chroma_range.bias_y as i32;
    let bias_uv = chroma_range.bias_uv as i32;

    for (((rgba, y_src), &u_src), &v_src) in rgba
        .chunks_exact_mut(channels * 2)
        .zip(y_plane.chunks_exact(2))
        .zip(u_plane.iter())
        .zip(v_plane.iter())
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
        if dst_chans.has_alpha() {
            rgba0[dst_chans.get_a_channel_offset()] = max_range_p16 as u16;
        }

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
        if dst_chans.has_alpha() {
            rgba1[dst_chans.get_a_channel_offset()] = max_range_p16 as u16;
        }
    }

    if width & 1 != 0 {
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
        let rgba = rgba.chunks_exact_mut(channels).last().unwrap();
        let rgba0 = &mut rgba[..channels];

        let r0 = qrshr::<PRECISION, BIT_DEPTH>(y_value0 + cr_coef * cr_value);
        let b0 = qrshr::<PRECISION, BIT_DEPTH>(y_value0 + cb_coef * cb_value);
        let g0 =
            qrshr::<PRECISION, BIT_DEPTH>(y_value0 - g_coef_1 * cr_value - g_coef_2 * cb_value);
        rgba0[dst_chans.get_r_channel_offset()] = r0 as u16;
        rgba0[dst_chans.get_g_channel_offset()] = g0 as u16;
        rgba0[dst_chans.get_b_channel_offset()] = b0 as u16;
        if dst_chans.has_alpha() {
            rgba0[dst_chans.get_a_channel_offset()] = max_range_p16 as u16;
        }
    }
}

fn process_double_rows<
    const DESTINATION_CHANNELS: u8,
    const ENDIANNESS: u8,
    const BYTES_POSITION: u8,
    const BIT_DEPTH: usize,
    const PRECISION: i32,
>(
    y_plane0: &[u16],
    y_plane1: &[u16],
    u_plane: &[u16],
    v_plane: &[u16],
    rgba0: &mut [u16],
    rgba1: &mut [u16],
    wide_row_handler: &WideRow420InversionHandler<
        DESTINATION_CHANNELS,
        ENDIANNESS,
        BYTES_POSITION,
        PRECISION,
        BIT_DEPTH,
    >,
    width: u32,
    chroma_range: YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
) {
    if let Some(handler) = wide_row_handler.handler.as_ref() {
        handler(
            y_plane0,
            y_plane1,
            u_plane,
            v_plane,
            rgba0,
            rgba1,
            width,
            &chroma_range,
            transform,
        );
        return;
    }
    let max_range_p16 = ((1u32 << BIT_DEPTH as u32) - 1) as i32;
    let dst_chans: YuvSourceChannels = DESTINATION_CHANNELS.into();
    let channels = dst_chans.get_channels_count();

    let msb_shift = (16 - BIT_DEPTH) as i32;

    let cr_coef = transform.cr_coef;
    let cb_coef = transform.cb_coef;
    let y_coef = transform.y_coef;
    let g_coef_1 = transform.g_coeff_1;
    let g_coef_2 = transform.g_coeff_2;

    let bias_y = chroma_range.bias_y as i32;
    let bias_uv = chroma_range.bias_uv as i32;

    for (((((rgba_row0, rgba_row1), y_src0), y_src1), &u_src), &v_src) in rgba0
        .chunks_exact_mut(channels * 2)
        .zip(rgba1.chunks_exact_mut(channels * 2))
        .zip(y_plane0.chunks_exact(2))
        .zip(y_plane1.chunks_exact(2))
        .zip(u_plane.iter())
        .zip(v_plane.iter())
    {
        let cb_value = to_ne::<ENDIANNESS, BYTES_POSITION>(u_src, msb_shift) as i32 - bias_uv;
        let cr_value = to_ne::<ENDIANNESS, BYTES_POSITION>(v_src, msb_shift) as i32 - bias_uv;

        let cr_r = cr_coef * cr_value;
        let cb_b = cb_coef * cb_value;
        let g_uv = g_coef_1 * cr_value + g_coef_2 * cb_value;

        // row 0, pixel 0
        let y_value00 =
            (to_ne::<ENDIANNESS, BYTES_POSITION>(y_src0[0], msb_shift) as i32 - bias_y) * y_coef;
        let dst00 = &mut rgba_row0[..channels];
        dst00[dst_chans.get_r_channel_offset()] =
            qrshr::<PRECISION, BIT_DEPTH>(y_value00 + cr_r) as u16;
        dst00[dst_chans.get_g_channel_offset()] =
            qrshr::<PRECISION, BIT_DEPTH>(y_value00 - g_uv) as u16;
        dst00[dst_chans.get_b_channel_offset()] =
            qrshr::<PRECISION, BIT_DEPTH>(y_value00 + cb_b) as u16;
        if dst_chans.has_alpha() {
            dst00[dst_chans.get_a_channel_offset()] = max_range_p16 as u16;
        }

        // row 0, pixel 1
        let y_value01 =
            (to_ne::<ENDIANNESS, BYTES_POSITION>(y_src0[1], msb_shift) as i32 - bias_y) * y_coef;
        let dst01 = &mut rgba_row0[channels..channels * 2];
        dst01[dst_chans.get_r_channel_offset()] =
            qrshr::<PRECISION, BIT_DEPTH>(y_value01 + cr_r) as u16;
        dst01[dst_chans.get_g_channel_offset()] =
            qrshr::<PRECISION, BIT_DEPTH>(y_value01 - g_uv) as u16;
        dst01[dst_chans.get_b_channel_offset()] =
            qrshr::<PRECISION, BIT_DEPTH>(y_value01 + cb_b) as u16;
        if dst_chans.has_alpha() {
            dst01[dst_chans.get_a_channel_offset()] = max_range_p16 as u16;
        }

        // row 1, pixel 0
        let y_value10 =
            (to_ne::<ENDIANNESS, BYTES_POSITION>(y_src1[0], msb_shift) as i32 - bias_y) * y_coef;
        let dst10 = &mut rgba_row1[..channels];
        dst10[dst_chans.get_r_channel_offset()] =
            qrshr::<PRECISION, BIT_DEPTH>(y_value10 + cr_r) as u16;
        dst10[dst_chans.get_g_channel_offset()] =
            qrshr::<PRECISION, BIT_DEPTH>(y_value10 - g_uv) as u16;
        dst10[dst_chans.get_b_channel_offset()] =
            qrshr::<PRECISION, BIT_DEPTH>(y_value10 + cb_b) as u16;
        if dst_chans.has_alpha() {
            dst10[dst_chans.get_a_channel_offset()] = max_range_p16 as u16;
        }

        // row 1, pixel 1
        let y_value11 =
            (to_ne::<ENDIANNESS, BYTES_POSITION>(y_src1[1], msb_shift) as i32 - bias_y) * y_coef;
        let dst11 = &mut rgba_row1[channels..channels * 2];
        dst11[dst_chans.get_r_channel_offset()] =
            qrshr::<PRECISION, BIT_DEPTH>(y_value11 + cr_r) as u16;
        dst11[dst_chans.get_g_channel_offset()] =
            qrshr::<PRECISION, BIT_DEPTH>(y_value11 - g_uv) as u16;
        dst11[dst_chans.get_b_channel_offset()] =
            qrshr::<PRECISION, BIT_DEPTH>(y_value11 + cb_b) as u16;
        if dst_chans.has_alpha() {
            dst11[dst_chans.get_a_channel_offset()] = max_range_p16 as u16;
        }
    }

    // odd width tail — shared chroma from last u/v sample
    if width & 1 != 0 {
        let cb_value = to_ne::<ENDIANNESS, BYTES_POSITION>(*u_plane.last().unwrap(), msb_shift)
            as i32
            - bias_uv;
        let cr_value = to_ne::<ENDIANNESS, BYTES_POSITION>(*v_plane.last().unwrap(), msb_shift)
            as i32
            - bias_uv;

        let cr_r = cr_coef * cr_value;
        let cb_b = cb_coef * cb_value;
        let g_uv = g_coef_1 * cr_value + g_coef_2 * cb_value;

        for (y_plane, rgba_row) in [(y_plane0, &mut *rgba0), (y_plane1, &mut *rgba1)] {
            let y_value = (to_ne::<ENDIANNESS, BYTES_POSITION>(*y_plane.last().unwrap(), msb_shift)
                as i32
                - bias_y)
                * y_coef;
            let dst = rgba_row.chunks_exact_mut(channels).last().unwrap();
            dst[dst_chans.get_r_channel_offset()] =
                qrshr::<PRECISION, BIT_DEPTH>(y_value + cr_r) as u16;
            dst[dst_chans.get_g_channel_offset()] =
                qrshr::<PRECISION, BIT_DEPTH>(y_value - g_uv) as u16;
            dst[dst_chans.get_b_channel_offset()] =
                qrshr::<PRECISION, BIT_DEPTH>(y_value + cb_b) as u16;
            if dst_chans.has_alpha() {
                dst[dst_chans.get_a_channel_offset()] = max_range_p16 as u16;
            }
        }
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
    rgba16: &mut [u16],
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

    let transform = search_inverse_transform(
        PRECISION,
        BIT_DEPTH as u32,
        range,
        matrix,
        chroma_range,
        kr_kb,
    );

    let cr_coef = transform.cr_coef;
    let cb_coef = transform.cb_coef;
    let y_coef = transform.y_coef;
    let g_coef_1 = transform.g_coeff_1;
    let g_coef_2 = transform.g_coeff_2;

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

    let (y_plane, u_plane, v_plane) = image.projected_planes(chroma_subsampling);
    let rgba16 =
        projected_rgba_plane_mut(rgba16, image.width, image.height, rgba_stride, dst_chans);

    if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
        let iter;
        #[cfg(feature = "rayon")]
        {
            iter = rgba16
                .par_chunks_mut(rgba_stride as usize)
                .zip(y_plane.par_chunks(image.y_stride as usize))
                .zip(u_plane.par_chunks(image.u_stride as usize))
                .zip(v_plane.par_chunks(image.v_stride as usize));
        }
        #[cfg(not(feature = "rayon"))]
        {
            iter = rgba16
                .chunks_mut(rgba_stride as usize)
                .zip(y_plane.chunks(image.y_stride as usize))
                .zip(u_plane.chunks(image.u_stride as usize))
                .zip(v_plane.chunks(image.v_stride as usize));
        }
        iter.for_each(|(((rgba, y_plane), u_plane), v_plane)| {
            let y_plane = &y_plane[..image.width as usize];
            let u_plane = &u_plane[..image.width as usize];
            let v_plane = &v_plane[..image.width as usize];
            if wide_row_handler.handle_row(
                y_plane,
                u_plane,
                v_plane,
                rgba,
                image.width,
                chroma_range,
                &transform,
            ) {
                return;
            }
            for (((rgba, &y_src), &u_src), &v_src) in rgba
                .chunks_exact_mut(channels)
                .zip(y_plane.iter())
                .zip(u_plane.iter())
                .zip(v_plane.iter())
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
                if dst_chans.has_alpha() {
                    rgba[dst_chans.get_a_channel_offset()] = max_range_p16 as u16;
                }
            }
        });
    } else if chroma_subsampling == YuvChromaSubsampling::Yuv422 {
        let iter;
        #[cfg(feature = "rayon")]
        {
            iter = rgba16
                .par_chunks_mut(rgba_stride as usize)
                .zip(y_plane.par_chunks(image.y_stride as usize))
                .zip(u_plane.par_chunks(image.u_stride as usize))
                .zip(v_plane.par_chunks(image.v_stride as usize));
        }
        #[cfg(not(feature = "rayon"))]
        {
            iter = rgba16
                .chunks_mut(rgba_stride as usize)
                .zip(y_plane.chunks(image.y_stride as usize))
                .zip(u_plane.chunks(image.u_stride as usize))
                .zip(v_plane.chunks(image.v_stride as usize));
        }
        iter.for_each(|(((rgba, y_plane), u_plane), v_plane)| {
            process_halved_row::<
                DESTINATION_CHANNELS,
                SAMPLING,
                ENDIANNESS,
                BYTES_POSITION,
                BIT_DEPTH,
                PRECISION,
            >(
                &y_plane[..image.width as usize],
                &u_plane[..(image.width as usize).div_ceil(2)],
                &v_plane[..(image.width as usize).div_ceil(2)],
                &mut rgba[..image.width as usize * channels],
                &wide_row_handler,
                image.width,
                chroma_range,
                &transform,
            );
        });
    } else if chroma_subsampling == YuvChromaSubsampling::Yuv420 {
        let wide_row420_handler = WideRow420InversionHandler::<
            DESTINATION_CHANNELS,
            ENDIANNESS,
            BYTES_POSITION,
            PRECISION,
            BIT_DEPTH,
        >::default();
        let iter;
        #[cfg(feature = "rayon")]
        {
            iter = rgba16
                .par_chunks_mut(rgba_stride as usize * 2)
                .zip(y_plane.par_chunks(image.y_stride as usize * 2))
                .zip(u_plane.par_chunks(image.u_stride as usize))
                .zip(v_plane.par_chunks(image.v_stride as usize));
        }
        #[cfg(not(feature = "rayon"))]
        {
            iter = rgba16
                .chunks_mut(rgba_stride as usize * 2)
                .zip(y_plane.chunks(image.y_stride as usize * 2))
                .zip(u_plane.chunks(image.u_stride as usize))
                .zip(v_plane.chunks(image.v_stride as usize));
        }
        iter.take(image.height as usize / 2)
            .for_each(|(((rgba, y_plane), u_plane), v_plane)| {
                let (y0, y1) = y_plane.split_at(image.y_stride as usize);
                let (rgba0, rgba1) = rgba.split_at_mut(rgba_stride as usize);
                process_double_rows::<
                    DESTINATION_CHANNELS,
                    ENDIANNESS,
                    BYTES_POSITION,
                    BIT_DEPTH,
                    PRECISION,
                >(
                    &y0[..image.width as usize],
                    &y1[..image.width as usize],
                    &u_plane[..(image.width as usize).div_ceil(2)],
                    &v_plane[..(image.width as usize).div_ceil(2)],
                    &mut rgba0[..image.width as usize * channels],
                    &mut rgba1[..image.width as usize * channels],
                    &wide_row420_handler,
                    image.width,
                    chroma_range,
                    &transform,
                );
            });

        if image.height & 1 != 0 {
            let rgba = rgba16.chunks_mut(rgba_stride as usize).last().unwrap();
            let u_plane = u_plane.chunks(image.u_stride as usize).last().unwrap();
            let v_plane = v_plane.chunks(image.v_stride as usize).last().unwrap();
            let y_plane = y_plane.chunks(image.y_stride as usize).last().unwrap();
            process_halved_row::<
                DESTINATION_CHANNELS,
                SAMPLING,
                ENDIANNESS,
                BYTES_POSITION,
                BIT_DEPTH,
                PRECISION,
            >(
                &y_plane[..image.width as usize],
                &u_plane[..(image.width as usize).div_ceil(2)],
                &v_plane[..(image.width as usize).div_ceil(2)],
                &mut rgba[..image.width as usize * channels],
                &wide_row_handler,
                image.width,
                chroma_range,
                &transform,
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
Convert ",$sampling_written, " planar format with ", stringify!($bit_depth), " bit pixel format to ", $px_written," ", stringify!($bit_depth), " bit-depth format.

This function takes ", $sampling_written, " planar data with ", stringify!($bit_depth), " bit precision.
and converts it to ", $px_written," format with ", stringify!($bit_depth), " bit-depth precision per channel

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
            yuv_p16_to_image_p16_ant::<{ $px_fmt as u8 },
                            { $sampling as u8 },
                            { $endian as u8 },
                            { YuvBytesPacking::LeastSignificantBytes as u8 }, $bit_depth>(
                planar_image, dst, dst_stride, range, matrix)
        }
    };
}

d_cnv!(
    i010_to_rgba10,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv420,
    YuvEndianness::LittleEndian,
    "I010",
    "RGBA",
    "rgba",
    10
);
#[cfg(feature = "big_endian")]
d_cnv!(
    i010_be_to_rgba10,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv420,
    YuvEndianness::BigEndian,
    "I010BE",
    "RGBA",
    "rgba",
    10
);
d_cnv!(
    i010_to_rgb10,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv420,
    YuvEndianness::LittleEndian,
    "I010",
    "RGB",
    "rgb",
    10
);
#[cfg(feature = "big_endian")]
d_cnv!(
    i010_be_to_rgb10,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv420,
    YuvEndianness::BigEndian,
    "I010BE",
    "RGB",
    "rgb",
    10
);
d_cnv!(
    i210_to_rgba10,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv422,
    YuvEndianness::LittleEndian,
    "I210",
    "RGBA",
    "rgba",
    10
);
#[cfg(feature = "big_endian")]
d_cnv!(
    i210_be_to_rgba10,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv422,
    YuvEndianness::BigEndian,
    "I210BE",
    "RGBA",
    "rgba",
    10
);
d_cnv!(
    i210_to_rgb10,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv422,
    YuvEndianness::LittleEndian,
    "I210",
    "RGB",
    "rgb",
    10
);
#[cfg(feature = "big_endian")]
d_cnv!(
    i210_be_to_rgb10,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv422,
    YuvEndianness::BigEndian,
    "I210BE",
    "RGB",
    "rgb",
    10
);
d_cnv!(
    i410_to_rgba10,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv444,
    YuvEndianness::LittleEndian,
    "I410",
    "RGBA",
    "rgba",
    10
);
#[cfg(feature = "big_endian")]
d_cnv!(
    i410_be_to_rgba10,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv444,
    YuvEndianness::BigEndian,
    "I410BE",
    "RGBA",
    "rgba",
    10
);
d_cnv!(
    i410_to_rgb10,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv444,
    YuvEndianness::LittleEndian,
    "I410",
    "RGB",
    "rgb",
    10
);
#[cfg(feature = "big_endian")]
d_cnv!(
    i410_be_to_rgb10,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv444,
    YuvEndianness::BigEndian,
    "I410BE",
    "RGB",
    "rgb",
    10
);

d_cnv!(
    i012_to_rgba12,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv420,
    YuvEndianness::LittleEndian,
    "I012",
    "RGBA",
    "rgba",
    12
);
#[cfg(feature = "big_endian")]
d_cnv!(
    i012_be_to_rgba12,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv420,
    YuvEndianness::BigEndian,
    "I012BE",
    "RGBA",
    "rgba",
    12
);
d_cnv!(
    i012_to_rgb12,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv420,
    YuvEndianness::LittleEndian,
    "I012",
    "RGB",
    "rgb",
    12
);
#[cfg(feature = "big_endian")]
d_cnv!(
    i012_be_to_rgb12,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv420,
    YuvEndianness::BigEndian,
    "I012BE",
    "RGB",
    "rgb",
    12
);
d_cnv!(
    i212_to_rgba12,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv422,
    YuvEndianness::LittleEndian,
    "I212",
    "RGBA",
    "rgba",
    12
);
#[cfg(feature = "big_endian")]
d_cnv!(
    i212_be_to_rgba12,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv422,
    YuvEndianness::BigEndian,
    "I212BE",
    "RGBA",
    "rgba",
    12
);
d_cnv!(
    i212_to_rgb12,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv422,
    YuvEndianness::LittleEndian,
    "I212",
    "RGB",
    "rgb",
    12
);
#[cfg(feature = "big_endian")]
d_cnv!(
    i212_be_to_rgb12,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv422,
    YuvEndianness::BigEndian,
    "I212BE",
    "RGB",
    "rgb",
    12
);
d_cnv!(
    i412_to_rgba12,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv444,
    YuvEndianness::LittleEndian,
    "I412",
    "RGBA",
    "rgba",
    12
);
#[cfg(feature = "big_endian")]
d_cnv!(
    i412_be_to_rgba12,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv444,
    YuvEndianness::BigEndian,
    "I412BE",
    "RGBA",
    "rgba",
    12
);
d_cnv!(
    i412_to_rgb12,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv444,
    YuvEndianness::LittleEndian,
    "I412",
    "RGB",
    "rgb",
    12
);
#[cfg(feature = "big_endian")]
d_cnv!(
    i412_be_to_rgb12,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv444,
    YuvEndianness::BigEndian,
    "I412BE",
    "RGB",
    "rgb",
    12
);

// 4:2:0, 14 bit

d_cnv!(
    i014_to_rgba14,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv420,
    YuvEndianness::LittleEndian,
    "I014",
    "RGBA",
    "rgba",
    14
);
#[cfg(feature = "big_endian")]
d_cnv!(
    i014_be_to_rgba14,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv420,
    YuvEndianness::BigEndian,
    "I014BE",
    "RGBA",
    "rgba",
    14
);
d_cnv!(
    i014_to_rgb14,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv420,
    YuvEndianness::LittleEndian,
    "I014",
    "RGB",
    "rgb",
    14
);
#[cfg(feature = "big_endian")]
d_cnv!(
    i014_be_to_rgb14,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv420,
    YuvEndianness::BigEndian,
    "I014BE",
    "RGB",
    "rgb",
    14
);

// 14-bit, 4:2:2

d_cnv!(
    i214_to_rgba14,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv422,
    YuvEndianness::LittleEndian,
    "I214",
    "RGBA",
    "rgba",
    14
);
#[cfg(feature = "big_endian")]
d_cnv!(
    i214_be_to_rgba14,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv422,
    YuvEndianness::BigEndian,
    "I214BE",
    "RGBA",
    "rgba",
    14
);
d_cnv!(
    i214_to_rgb14,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv422,
    YuvEndianness::LittleEndian,
    "I214",
    "RGB",
    "rgb",
    14
);
#[cfg(feature = "big_endian")]
d_cnv!(
    i214_be_to_rgb14,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv422,
    YuvEndianness::BigEndian,
    "I214BE",
    "RGB",
    "rgb",
    14
);

// 14-bit, 4:4:4

d_cnv!(
    i414_to_rgba14,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv444,
    YuvEndianness::LittleEndian,
    "I414",
    "RGBA",
    "rgba",
    14
);
#[cfg(feature = "big_endian")]
d_cnv!(
    i414_be_to_rgba14,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv444,
    YuvEndianness::BigEndian,
    "I414BE",
    "RGBA",
    "rgba",
    14
);
d_cnv!(
    i414_to_rgb14,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv444,
    YuvEndianness::LittleEndian,
    "I414",
    "RGB",
    "rgb",
    14
);
#[cfg(feature = "big_endian")]
d_cnv!(
    i414_be_to_rgb14,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv444,
    YuvEndianness::BigEndian,
    "I414BE",
    "RGB",
    "rgb",
    14
);

// 4:2:0, 16 bit

d_cnv!(
    i016_to_rgba16,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv420,
    YuvEndianness::LittleEndian,
    "I016",
    "RGBA",
    "rgba",
    16
);
#[cfg(feature = "big_endian")]
d_cnv!(
    i016_be_to_rgba16,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv420,
    YuvEndianness::BigEndian,
    "I016BE",
    "RGBA",
    "rgba",
    16
);
d_cnv!(
    i016_to_rgb16,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv420,
    YuvEndianness::LittleEndian,
    "I016",
    "RGB",
    "rgb",
    16
);
#[cfg(feature = "big_endian")]
d_cnv!(
    i016_be_to_rgb16,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv420,
    YuvEndianness::BigEndian,
    "I016BE",
    "RGB",
    "rgb",
    16
);

// 16-bit, 4:2:2

d_cnv!(
    i216_to_rgba16,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv422,
    YuvEndianness::LittleEndian,
    "I216",
    "RGBA",
    "rgba",
    16
);
#[cfg(feature = "big_endian")]
d_cnv!(
    i216_be_to_rgba16,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv422,
    YuvEndianness::BigEndian,
    "I216BE",
    "RGBA",
    "rgba",
    16
);
d_cnv!(
    i216_to_rgb16,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv422,
    YuvEndianness::LittleEndian,
    "I216",
    "RGB",
    "rgb",
    16
);
#[cfg(feature = "big_endian")]
d_cnv!(
    i216_be_to_rgb16,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv422,
    YuvEndianness::BigEndian,
    "I216BE",
    "RGB",
    "rgb",
    16
);

// 16-bit, 4:4:4

d_cnv!(
    i416_to_rgba16,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv444,
    YuvEndianness::LittleEndian,
    "I416",
    "RGBA",
    "rgba",
    16
);
#[cfg(feature = "big_endian")]
d_cnv!(
    i416_be_to_rgba16,
    YuvSourceChannels::Rgba,
    YuvChromaSubsampling::Yuv444,
    YuvEndianness::BigEndian,
    "I416BE",
    "RGBA",
    "rgba",
    16
);
d_cnv!(
    i416_to_rgb16,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv444,
    YuvEndianness::LittleEndian,
    "I416",
    "RGB",
    "rgb",
    16
);
#[cfg(feature = "big_endian")]
d_cnv!(
    i416_be_to_rgb16,
    YuvSourceChannels::Rgb,
    YuvChromaSubsampling::Yuv444,
    YuvEndianness::BigEndian,
    "I416BE",
    "RGB",
    "rgb",
    16
);

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{rgb10_to_i010, rgb10_to_i210, rgb10_to_i410, YuvPlanarImageMut};
    use rand::RngExt;

    #[test]
    fn test_yuv444_p16_round_trip_full_range() {
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

        image_rgb.fill(0);

        let fixed_planar = planar_image.to_fixed();

        i410_to_rgb10(
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
            let r = image_rgb[x * CHANNELS + y * image_width * CHANNELS];
            let g = image_rgb[x * CHANNELS + y * image_width * CHANNELS + 1];
            let b = image_rgb[x * CHANNELS + y * image_width * CHANNELS + 2];

            let diff_r = (r as i32 - or as i32).abs();
            let diff_g = (g as i32 - og as i32).abs();
            let diff_b = (b as i32 - ob as i32).abs();

            assert!(
                diff_r <= 4,
                "Original RGB {:?}, Round-tripped RGB {:?}",
                [or, og, ob],
                [r, g, b]
            );
            assert!(
                diff_g <= 4,
                "Original RGB {:?}, Round-tripped RGB {:?}",
                [or, og, ob],
                [r, g, b]
            );
            assert!(
                diff_b <= 4,
                "Original RGB {:?}, Round-tripped RGB {:?}",
                [or, og, ob],
                [r, g, b]
            );
        }
    }

    #[test]
    fn test_yuv444_p10_round_trip_limited_range() {
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
            YuvRange::Limited,
            YuvStandardMatrix::Bt709,
        )
        .unwrap();

        image_rgb.fill(0);

        let fixed_planar = planar_image.to_fixed();

        i410_to_rgb10(
            &fixed_planar,
            &mut image_rgb,
            image_width as u32 * CHANNELS as u32,
            YuvRange::Limited,
            YuvStandardMatrix::Bt709,
        )
        .unwrap();

        for point in &pixel_points {
            let x = point[0];
            let y = point[1];
            let r = image_rgb[x * CHANNELS + y * image_width * CHANNELS];
            let g = image_rgb[x * CHANNELS + y * image_width * CHANNELS + 1];
            let b = image_rgb[x * CHANNELS + y * image_width * CHANNELS + 2];

            let diff_r = (r as i32 - or as i32).abs();
            let diff_g = (g as i32 - og as i32).abs();
            let diff_b = (b as i32 - ob as i32).abs();

            assert!(
                diff_r <= 280,
                "Diff {}, Original RGB {:?}, Round-tripped RGB {:?}",
                diff_r,
                [or, og, ob],
                [r, g, b]
            );
            assert!(
                diff_g <= 280,
                "Diff {}, Original RGB {:?}, Round-tripped RGB {:?}",
                diff_g,
                [or, og, ob],
                [r, g, b]
            );
            assert!(
                diff_b <= 280,
                "Diff {}, Original RGB {:?}, Round-tripped RGB {:?}",
                diff_b,
                [or, og, ob],
                [r, g, b]
            );
        }
    }

    #[test]
    fn test_yuv422_p16_round_trip_limited_range() {
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

        let mut dest_rgb = vec![0u16; image_width * image_height * CHANNELS];

        let fixed_planar = planar_image.to_fixed();

        i210_to_rgb10(
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

            let r = dest_rgb[px];
            let g = dest_rgb[px + 1];
            let b = dest_rgb[px + 2];

            let diff_r = r as i32 - or as i32;
            let diff_g = g as i32 - og as i32;
            let diff_b = b as i32 - ob as i32;

            assert!(
                diff_r <= 275,
                "Actual diff {}, Original RGB {:?}, Round-tripped RGB {:?}",
                diff_r,
                [or, og, ob],
                [r, g, b]
            );
            assert!(
                diff_g <= 275,
                "Actual diff {}, Original RGB {:?}, Round-tripped RGB {:?}",
                diff_g,
                [or, og, ob],
                [r, g, b]
            );
            assert!(
                diff_b <= 275,
                "Actual diff {}, Original RGB {:?}, Round-tripped RGB {:?}",
                diff_b,
                [or, og, ob],
                [r, g, b]
            );
        }
    }

    #[test]
    fn test_yuv420_p16_round_trip_limited_range() {
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

            let nx = (point[0] + 1).min(image_width - 1);
            let ny = (point[1] + 1).min(image_height - 1);

            source_rgb[nx * CHANNELS + ny * image_width * CHANNELS] = or;
            source_rgb[nx * CHANNELS + ny * image_width * CHANNELS + 1] = og;
            source_rgb[nx * CHANNELS + ny * image_width * CHANNELS + 2] = ob;

            let nx = point[0].min(image_width - 1);
            let ny = (point[1] + 1).min(image_height - 1);

            source_rgb[nx * CHANNELS + ny * image_width * CHANNELS] = or;
            source_rgb[nx * CHANNELS + ny * image_width * CHANNELS + 1] = og;
            source_rgb[nx * CHANNELS + ny * image_width * CHANNELS + 2] = ob;

            let nx = point[0].saturating_sub(1).min(image_width - 1);
            let ny = point[1].saturating_sub(1).min(image_height - 1);

            source_rgb[nx * CHANNELS + ny * image_width * CHANNELS] = or;
            source_rgb[nx * CHANNELS + ny * image_width * CHANNELS + 1] = og;
            source_rgb[nx * CHANNELS + ny * image_width * CHANNELS + 2] = ob;

            let nx = point[0].min(image_width - 1);
            let ny = point[1].saturating_sub(1).min(image_height - 1);

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
            YuvChromaSubsampling::Yuv420,
        );

        rgb10_to_i010(
            &mut planar_image,
            &source_rgb,
            image_width as u32 * CHANNELS as u32,
            YuvRange::Limited,
            YuvStandardMatrix::Bt709,
        )
        .unwrap();

        let mut dest_rgb = vec![0u16; image_width * image_height * CHANNELS];

        let fixed_planar = planar_image.to_fixed();

        i010_to_rgb10(
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

            let r = dest_rgb[px];
            let g = dest_rgb[px + 1];
            let b = dest_rgb[px + 2];

            let diff_r = r as i32 - or as i32;
            let diff_g = g as i32 - og as i32;
            let diff_b = b as i32 - ob as i32;

            assert!(
                diff_r <= 310,
                "Actual diff {}, Original RGB {:?}, Round-tripped RGB {:?}",
                diff_r,
                [or, og, ob],
                [r, g, b]
            );
            assert!(
                diff_g <= 310,
                "Actual diff {}, Original RGB {:?}, Round-tripped RGB {:?}",
                diff_g,
                [or, og, ob],
                [r, g, b]
            );
            assert!(
                diff_b <= 310,
                "Actual diff {}, Original RGB {:?}, Round-tripped RGB {:?}",
                diff_b,
                [or, og, ob],
                [r, g, b]
            );
        }
    }
}
