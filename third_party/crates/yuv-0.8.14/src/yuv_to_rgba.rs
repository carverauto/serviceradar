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
use crate::internals::{ProcessedOffset, WideRow420InversionHandler, WideRowInversionHandler};
use crate::numerics::qrshr;
use crate::yuv_error::{check_rgba_destination, split_rgba_destination};
use crate::yuv_support::*;
use crate::{YuvError, YuvPlanarImage};
#[cfg(feature = "rayon")]
use rayon::iter::{IndexedParallelIterator, ParallelIterator};
#[cfg(feature = "rayon")]
use rayon::prelude::{ParallelSlice, ParallelSliceMut};

type RowHandle = Option<
    unsafe fn(
        range: &YuvChromaRange,
        transform: &CbCrInverseTransform<i32>,
        y_plane: &[u8],
        u_plane: &[u8],
        v_plane: &[u8],
        rgba: &mut [u8],
        start_cx: usize,
        start_ux: usize,
        width: usize,
    ) -> ProcessedOffset,
>;

type RowHandle420 = Option<
    unsafe fn(
        range: &YuvChromaRange,
        transform: &CbCrInverseTransform<i32>,
        y_plane0: &[u8],
        y_plane1: &[u8],
        u_plane: &[u8],
        v_plane: &[u8],
        rgba0: &mut [u8],
        rgba1: &mut [u8],
        start_cx: usize,
        start_ux: usize,
        width: usize,
    ) -> ProcessedOffset,
>;

struct RowHandler<const DESTINATION_CHANNELS: u8, const SAMPLING: u8, const PRECISION: i32> {
    handler: RowHandle,
}

macro_rules! impl_row_inversion_handler {
    ($struct_name:ident) => {
        impl<const DESTINATION_CHANNELS: u8, const SAMPLING: u8, const PRECISION: i32>
            WideRowInversionHandler<u8, i32>
            for $struct_name<DESTINATION_CHANNELS, SAMPLING, PRECISION>
        {
            fn handle_row(
                &self,
                y_plane: &[u8],
                u_plane: &[u8],
                v_plane: &[u8],
                rgba: &mut [u8],
                width: u32,
                chroma: YuvChromaRange,
                transform: &CbCrInverseTransform<i32>,
            ) -> ProcessedOffset {
                if let Some(handler) = self.handler {
                    unsafe {
                        return handler(
                            &chroma,
                            transform,
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

impl_row_inversion_handler!(RowHandler);

impl<const DESTINATION_CHANNELS: u8, const SAMPLING: u8, const PRECISION: i32> Default
    for RowHandler<DESTINATION_CHANNELS, SAMPLING, PRECISION>
{
    fn default() -> Self {
        if PRECISION != 13 {
            return RowHandler { handler: None };
        }
        assert_eq!(PRECISION, 13);
        #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
        {
            #[cfg(feature = "rdm")]
            {
                let is_rdm_available = std::arch::is_aarch64_feature_detected!("rdm");
                if is_rdm_available {
                    use crate::neon::neon_yuv_to_rgba_row_rdm;

                    return RowHandler {
                        handler: Some(neon_yuv_to_rgba_row_rdm::<DESTINATION_CHANNELS, SAMPLING>),
                    };
                }
            }
            use crate::neon::neon_yuv_to_rgba_row;
            RowHandler {
                handler: Some(neon_yuv_to_rgba_row::<DESTINATION_CHANNELS, SAMPLING>),
            }
        }
        #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
        {
            #[cfg(feature = "nightly_avx512")]
            {
                let use_avx512 = std::arch::is_x86_feature_detected!("avx512bw");
                let use_vbmi = std::arch::is_x86_feature_detected!("avx512vbmi");
                let sampling: YuvChromaSubsampling = SAMPLING.into();
                if use_avx512 {
                    return if sampling == YuvChromaSubsampling::Yuv420
                        || sampling == YuvChromaSubsampling::Yuv422
                    {
                        assert!(
                            sampling == YuvChromaSubsampling::Yuv420
                                || sampling == YuvChromaSubsampling::Yuv422
                        );
                        use crate::avx512bw::avx512_yuv_to_rgba422;
                        RowHandler {
                            handler: Some(if use_vbmi {
                                avx512_yuv_to_rgba422::<DESTINATION_CHANNELS, true>
                            } else {
                                avx512_yuv_to_rgba422::<DESTINATION_CHANNELS, false>
                            }),
                        }
                    } else {
                        use crate::avx512bw::avx512_yuv_to_rgba;
                        RowHandler {
                            handler: Some(if use_vbmi {
                                avx512_yuv_to_rgba::<DESTINATION_CHANNELS, SAMPLING, true>
                            } else {
                                avx512_yuv_to_rgba::<DESTINATION_CHANNELS, SAMPLING, false>
                            }),
                        }
                    };
                }
            }

            #[cfg(feature = "avx")]
            {
                let use_avx2 = std::arch::is_x86_feature_detected!("avx2");
                if use_avx2 {
                    let sampling: YuvChromaSubsampling = SAMPLING.into();
                    return if sampling == YuvChromaSubsampling::Yuv420
                        || sampling == YuvChromaSubsampling::Yuv422
                    {
                        assert!(
                            sampling == YuvChromaSubsampling::Yuv420
                                || sampling == YuvChromaSubsampling::Yuv422
                        );
                        use crate::avx2::avx2_yuv_to_rgba_row422;
                        RowHandler {
                            handler: Some(avx2_yuv_to_rgba_row422::<DESTINATION_CHANNELS>),
                        }
                    } else {
                        use crate::avx2::avx2_yuv_to_rgba_row;
                        RowHandler {
                            handler: Some(avx2_yuv_to_rgba_row::<DESTINATION_CHANNELS, SAMPLING>),
                        }
                    };
                }
            }

            #[cfg(feature = "sse")]
            {
                let use_sse = std::arch::is_x86_feature_detected!("sse4.1");
                if use_sse {
                    let sampling: YuvChromaSubsampling = SAMPLING.into();
                    if sampling == YuvChromaSubsampling::Yuv420
                        || sampling == YuvChromaSubsampling::Yuv422
                    {
                        assert!(
                            sampling == YuvChromaSubsampling::Yuv420
                                || sampling == YuvChromaSubsampling::Yuv422
                        );
                        use crate::sse::sse_yuv_to_rgba_row422;
                        return RowHandler {
                            handler: Some(sse_yuv_to_rgba_row422::<DESTINATION_CHANNELS>),
                        };
                    } else {
                        use crate::sse::sse_yuv_to_rgba_row;
                        return RowHandler {
                            handler: Some(sse_yuv_to_rgba_row::<DESTINATION_CHANNELS, SAMPLING>),
                        };
                    }
                }
            }
        }
        #[cfg(all(target_arch = "wasm32", target_feature = "simd128"))]
        {
            use crate::wasm32::wasm_yuv_to_rgba_row;
            return RowHandler {
                handler: Some(wasm_yuv_to_rgba_row::<DESTINATION_CHANNELS, SAMPLING>),
            };
        }
        #[cfg(not(any(
            all(target_arch = "aarch64", target_feature = "neon"),
            all(target_arch = "wasm32", target_feature = "simd128")
        )))]
        {
            RowHandler { handler: None }
        }
    }
}

struct RowHandler420<const DESTINATION_CHANNELS: u8, const SAMPLING: u8, const PRECISION: i32> {
    handler: RowHandle420,
}

impl<const DESTINATION_CHANNELS: u8, const SAMPLING: u8, const PRECISION: i32> Default
    for RowHandler420<DESTINATION_CHANNELS, SAMPLING, PRECISION>
{
    fn default() -> Self {
        if PRECISION != 13 {
            return RowHandler420 { handler: None };
        }
        assert_eq!(PRECISION, 13);
        let sampling: YuvChromaSubsampling = SAMPLING.into();
        if sampling != YuvChromaSubsampling::Yuv420 {
            return RowHandler420 { handler: None };
        }
        assert_eq!(sampling, YuvChromaSubsampling::Yuv420);
        #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
        {
            #[cfg(feature = "rdm")]
            {
                let is_rdm_available = std::arch::is_aarch64_feature_detected!("rdm");
                if is_rdm_available {
                    use crate::neon::neon_yuv_to_rgba_row_rdm420;
                    return RowHandler420 {
                        handler: Some(neon_yuv_to_rgba_row_rdm420::<DESTINATION_CHANNELS>),
                    };
                }
            }
            use crate::neon::neon_yuv_to_rgba_row420;
            RowHandler420 {
                handler: Some(neon_yuv_to_rgba_row420::<DESTINATION_CHANNELS>),
            }
        }
        #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
        {
            #[cfg(feature = "nightly_avx512")]
            {
                let use_avx512 = std::arch::is_x86_feature_detected!("avx512bw");
                let use_vbmi = std::arch::is_x86_feature_detected!("avx512vbmi");
                if use_avx512 {
                    use crate::avx512bw::avx512_yuv_to_rgba420;
                    return RowHandler420 {
                        handler: Some(if use_vbmi {
                            avx512_yuv_to_rgba420::<DESTINATION_CHANNELS, true>
                        } else {
                            avx512_yuv_to_rgba420::<DESTINATION_CHANNELS, false>
                        }),
                    };
                }
            }
            #[cfg(feature = "avx")]
            {
                let use_avx2 = std::arch::is_x86_feature_detected!("avx2");
                if use_avx2 {
                    use crate::avx2::avx2_yuv_to_rgba_row420;
                    return RowHandler420 {
                        handler: Some(avx2_yuv_to_rgba_row420::<DESTINATION_CHANNELS>),
                    };
                }
            }
            #[cfg(feature = "sse")]
            {
                let use_sse = std::arch::is_x86_feature_detected!("sse4.1");
                if use_sse {
                    use crate::sse::sse_yuv_to_rgba_row420;
                    return RowHandler420 {
                        handler: Some(sse_yuv_to_rgba_row420::<DESTINATION_CHANNELS>),
                    };
                }
            }
        }
        #[cfg(all(target_arch = "wasm32", target_feature = "simd128"))]
        {
            use crate::wasm32::wasm_yuv_to_rgba_row420;
            return RowHandler420 {
                handler: Some(wasm_yuv_to_rgba_row420::<DESTINATION_CHANNELS, SAMPLING>),
            };
        }
        #[cfg(not(any(
            all(target_arch = "aarch64", target_feature = "neon"),
            all(target_arch = "wasm32", target_feature = "simd128")
        )))]
        {
            RowHandler420 { handler: None }
        }
    }
}

macro_rules! impl_row_420_inversion_handler {
    ($struct_name:ident) => {
        impl<const DESTINATION_CHANNELS: u8, const SAMPLING: u8, const PRECISION: i32>
            WideRow420InversionHandler<u8, i32>
            for $struct_name<DESTINATION_CHANNELS, SAMPLING, PRECISION>
        {
            fn handle_row(
                &self,
                y0_plane: &[u8],
                y1_plane: &[u8],
                u_plane: &[u8],
                v_plane: &[u8],
                rgba0: &mut [u8],
                rgba1: &mut [u8],
                width: u32,
                chroma: YuvChromaRange,
                transform: &CbCrInverseTransform<i32>,
            ) -> ProcessedOffset {
                if let Some(handler) = self.handler {
                    unsafe {
                        return handler(
                            &chroma,
                            transform,
                            y0_plane,
                            y1_plane,
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

impl_row_420_inversion_handler!(RowHandler420);

fn yuv_to_rgbx_impl<const DESTINATION_CHANNELS: u8, const SAMPLING: u8, const PRECISION: i32>(
    image: &YuvPlanarImage<u8>,
    rgba: &mut [u8],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    row_handler: impl WideRowInversionHandler<u8, i32> + Send + Sync,
    row_handler420: impl WideRow420InversionHandler<u8, i32> + Send + Sync,
) -> Result<(), YuvError> {
    let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();
    let dst_chans: YuvSourceChannels = DESTINATION_CHANNELS.into();
    let channels = dst_chans.get_channels_count();

    check_rgba_destination(rgba, rgba_stride, image.width, image.height, channels)?;
    image.check_constraints(chroma_subsampling)?;

    let rgba = split_rgba_destination(rgba, rgba_stride, image.width, image.height, channels);

    let chroma_range = get_yuv_range(8, range);
    let kr_kb = matrix.get_kr_kb();

    let inverse_transform =
        search_inverse_transform(PRECISION, 8, range, matrix, chroma_range, kr_kb);
    let cr_coef = inverse_transform.cr_coef;
    let cb_coef = inverse_transform.cb_coef;
    let y_coef = inverse_transform.y_coef;
    let g_coef_1 = inverse_transform.g_coeff_1;
    let g_coef_2 = inverse_transform.g_coeff_2;

    let bias_y = chroma_range.bias_y as i32;
    let bias_uv = chroma_range.bias_uv as i32;

    const BIT_DEPTH: usize = 8;

    let process_halved_chroma_row =
        |y_plane: &[u8], u_plane: &[u8], v_plane: &[u8], rgba: &mut [u8]| {
            let cx = row_handler
                .handle_row(
                    y_plane,
                    u_plane,
                    v_plane,
                    rgba,
                    image.width,
                    chroma_range,
                    &inverse_transform,
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
                    let y_value0 = (y_src[0] as i32 - bias_y) * y_coef;
                    let cb_value = u_src as i32 - bias_uv;
                    let cr_value = v_src as i32 - bias_uv;

                    let r0 = qrshr::<PRECISION, BIT_DEPTH>(y_value0 + cr_coef * cr_value);
                    let b0 = qrshr::<PRECISION, BIT_DEPTH>(y_value0 + cb_coef * cb_value);
                    let g0 = qrshr::<PRECISION, BIT_DEPTH>(
                        y_value0 - g_coef_1 * cr_value - g_coef_2 * cb_value,
                    );

                    let rgba0 = &mut rgba[..channels];

                    rgba0[dst_chans.get_r_channel_offset()] = r0 as u8;
                    rgba0[dst_chans.get_g_channel_offset()] = g0 as u8;
                    rgba0[dst_chans.get_b_channel_offset()] = b0 as u8;
                    if dst_chans.has_alpha() {
                        rgba0[dst_chans.get_a_channel_offset()] = 255u8;
                    }

                    let y_value1 = (y_src[1] as i32 - bias_y) * y_coef;

                    let r1 = qrshr::<PRECISION, BIT_DEPTH>(y_value1 + cr_coef * cr_value);
                    let b1 = qrshr::<PRECISION, BIT_DEPTH>(y_value1 + cb_coef * cb_value);
                    let g1 = qrshr::<PRECISION, BIT_DEPTH>(
                        y_value1 - g_coef_1 * cr_value - g_coef_2 * cb_value,
                    );

                    let rgba1 = &mut rgba[channels..channels * 2];

                    rgba1[dst_chans.get_r_channel_offset()] = r1 as u8;
                    rgba1[dst_chans.get_g_channel_offset()] = g1 as u8;
                    rgba1[dst_chans.get_b_channel_offset()] = b1 as u8;
                    if dst_chans.has_alpha() {
                        rgba1[dst_chans.get_a_channel_offset()] = 255u8;
                    }
                }

                if image.width & 1 != 0 {
                    let y_value0 = (*y_plane.last().unwrap() as i32 - bias_y) * y_coef;
                    let cb_value = *u_plane.last().unwrap() as i32 - bias_uv;
                    let cr_value = *v_plane.last().unwrap() as i32 - bias_uv;
                    let rgba = rgba.chunks_exact_mut(channels).last().unwrap();
                    let rgba0 = &mut rgba[..channels];

                    let r0 = qrshr::<PRECISION, BIT_DEPTH>(y_value0 + cr_coef * cr_value);
                    let b0 = qrshr::<PRECISION, BIT_DEPTH>(y_value0 + cb_coef * cb_value);
                    let g0 = qrshr::<PRECISION, BIT_DEPTH>(
                        y_value0 - g_coef_1 * cr_value - g_coef_2 * cb_value,
                    );
                    rgba0[dst_chans.get_r_channel_offset()] = r0 as u8;
                    rgba0[dst_chans.get_g_channel_offset()] = g0 as u8;
                    rgba0[dst_chans.get_b_channel_offset()] = b0 as u8;
                    if dst_chans.has_alpha() {
                        rgba0[dst_chans.get_a_channel_offset()] = 255;
                    }
                }
            }
        };

    let process_doubled_chroma_row = |y_plane0: &[u8],
                                      y_plane1: &[u8],
                                      u_plane: &[u8],
                                      v_plane: &[u8],
                                      rgba0: &mut [u8],
                                      rgba1: &mut [u8]| {
        let cx = row_handler420
            .handle_row(
                y_plane0,
                y_plane1,
                u_plane,
                v_plane,
                rgba0,
                rgba1,
                image.width,
                chroma_range,
                &inverse_transform,
            )
            .cx;

        if cx != image.width as usize {
            for (((((rgba0, rgba1), y_src0), y_src1), &u_src), &v_src) in rgba0
                .chunks_exact_mut(channels * 2)
                .zip(rgba1.chunks_exact_mut(channels * 2))
                .zip(y_plane0.chunks_exact(2))
                .zip(y_plane1.chunks_exact(2))
                .zip(u_plane.iter())
                .zip(v_plane.iter())
                .skip(cx / 2)
            {
                let y_value0 = (y_src0[0] as i32 - bias_y) * y_coef;
                let cb_value = u_src as i32 - bias_uv;
                let cr_value = v_src as i32 - bias_uv;

                let g_built_coeff = -g_coef_1 * cr_value - g_coef_2 * cb_value;

                let r0 = qrshr::<PRECISION, BIT_DEPTH>(y_value0 + cr_coef * cr_value);
                let b0 = qrshr::<PRECISION, BIT_DEPTH>(y_value0 + cb_coef * cb_value);
                let g0 = qrshr::<PRECISION, BIT_DEPTH>(y_value0 + g_built_coeff);

                let rgba00 = &mut rgba0[..channels];

                rgba00[dst_chans.get_r_channel_offset()] = r0 as u8;
                rgba00[dst_chans.get_g_channel_offset()] = g0 as u8;
                rgba00[dst_chans.get_b_channel_offset()] = b0 as u8;
                if dst_chans.has_alpha() {
                    rgba00[dst_chans.get_a_channel_offset()] = 255u8;
                }

                let y_value1 = (y_src0[1] as i32 - bias_y) * y_coef;

                let r1 = qrshr::<PRECISION, BIT_DEPTH>(y_value1 + cr_coef * cr_value);
                let b1 = qrshr::<PRECISION, BIT_DEPTH>(y_value1 + cb_coef * cb_value);
                let g1 = qrshr::<PRECISION, BIT_DEPTH>(y_value1 + g_built_coeff);

                let rgba01 = &mut rgba0[channels..channels * 2];

                rgba01[dst_chans.get_r_channel_offset()] = r1 as u8;
                rgba01[dst_chans.get_g_channel_offset()] = g1 as u8;
                rgba01[dst_chans.get_b_channel_offset()] = b1 as u8;
                if dst_chans.has_alpha() {
                    rgba01[dst_chans.get_a_channel_offset()] = 255u8;
                }

                let y_value10 = (y_src1[0] as i32 - bias_y) * y_coef;

                let r10 = qrshr::<PRECISION, BIT_DEPTH>(y_value10 + cr_coef * cr_value);
                let b10 = qrshr::<PRECISION, BIT_DEPTH>(y_value10 + cb_coef * cb_value);
                let g10 = qrshr::<PRECISION, BIT_DEPTH>(y_value10 + g_built_coeff);

                let rgba10 = &mut rgba1[..channels];

                rgba10[dst_chans.get_r_channel_offset()] = r10 as u8;
                rgba10[dst_chans.get_g_channel_offset()] = g10 as u8;
                rgba10[dst_chans.get_b_channel_offset()] = b10 as u8;
                if dst_chans.has_alpha() {
                    rgba10[dst_chans.get_a_channel_offset()] = 255u8;
                }

                let y_value11 = (y_src1[1] as i32 - bias_y) * y_coef;

                let r11 = qrshr::<PRECISION, BIT_DEPTH>(y_value11 + cr_coef * cr_value);
                let b11 = qrshr::<PRECISION, BIT_DEPTH>(y_value11 + cb_coef * cb_value);
                let g11 = qrshr::<PRECISION, BIT_DEPTH>(y_value11 + g_built_coeff);

                let rgba11 = &mut rgba1[channels..channels * 2];

                rgba11[dst_chans.get_r_channel_offset()] = r11 as u8;
                rgba11[dst_chans.get_g_channel_offset()] = g11 as u8;
                rgba11[dst_chans.get_b_channel_offset()] = b11 as u8;
                if dst_chans.has_alpha() {
                    rgba11[dst_chans.get_a_channel_offset()] = 255u8;
                }
            }

            if image.width & 1 != 0 {
                let y_value0 = (*y_plane0.last().unwrap() as i32 - bias_y) * y_coef;
                let y_value1 = (*y_plane1.last().unwrap() as i32 - bias_y) * y_coef;
                let cb_value = *u_plane.last().unwrap() as i32 - bias_uv;
                let cr_value = *v_plane.last().unwrap() as i32 - bias_uv;
                let rgba = rgba0.chunks_exact_mut(channels).last().unwrap();
                let rgba0 = &mut rgba[..channels];

                let g_built_coeff = -g_coef_1 * cr_value - g_coef_2 * cb_value;

                let r0 = qrshr::<PRECISION, BIT_DEPTH>(y_value0 + cr_coef * cr_value);
                let b0 = qrshr::<PRECISION, BIT_DEPTH>(y_value0 + cb_coef * cb_value);
                let g0 = qrshr::<PRECISION, BIT_DEPTH>(y_value0 + g_built_coeff);

                rgba0[dst_chans.get_r_channel_offset()] = r0 as u8;
                rgba0[dst_chans.get_g_channel_offset()] = g0 as u8;
                rgba0[dst_chans.get_b_channel_offset()] = b0 as u8;
                if dst_chans.has_alpha() {
                    rgba0[dst_chans.get_a_channel_offset()] = 255;
                }

                let r1 = qrshr::<PRECISION, BIT_DEPTH>(y_value1 + cr_coef * cr_value);
                let b1 = qrshr::<PRECISION, BIT_DEPTH>(y_value1 + cb_coef * cb_value);
                let g1 = qrshr::<PRECISION, BIT_DEPTH>(y_value1 + g_built_coeff);

                let rgba = rgba1.chunks_exact_mut(channels).last().unwrap();
                let rgba1 = &mut rgba[..channels];
                rgba1[dst_chans.get_r_channel_offset()] = r1 as u8;
                rgba1[dst_chans.get_g_channel_offset()] = g1 as u8;
                rgba1[dst_chans.get_b_channel_offset()] = b1 as u8;
                if dst_chans.has_alpha() {
                    rgba1[dst_chans.get_a_channel_offset()] = 255;
                }
            }
        }
    };

    let (y_plane, u_plane, v_plane) = image.projected_planes(chroma_subsampling);
    let rgba = projected_rgba_plane_mut(rgba, image.width, image.height, rgba_stride, dst_chans);

    if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
        let iter;
        #[cfg(feature = "rayon")]
        {
            iter = rgba
                .par_chunks_mut(rgba_stride as usize)
                .zip(y_plane.par_chunks(image.y_stride as usize))
                .zip(u_plane.par_chunks(image.u_stride as usize))
                .zip(v_plane.par_chunks(image.v_stride as usize));
        }
        #[cfg(not(feature = "rayon"))]
        {
            iter = rgba
                .chunks_mut(rgba_stride as usize)
                .zip(y_plane.chunks(image.y_stride as usize))
                .zip(u_plane.chunks(image.u_stride as usize))
                .zip(v_plane.chunks(image.v_stride as usize));
        }
        iter.for_each(|(((rgba, y_plane), u_plane), v_plane)| {
            let y_plane = &y_plane[..image.width as usize];
            let u_plane = &u_plane[..image.width as usize];
            let v_plane = &v_plane[..image.width as usize];
            let cx = row_handler
                .handle_row(
                    y_plane,
                    u_plane,
                    v_plane,
                    rgba,
                    image.width,
                    chroma_range,
                    &inverse_transform,
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
                    let y_value = (y_src as i32 - bias_y) * y_coef;
                    let cb_value = u_src as i32 - bias_uv;
                    let cr_value = v_src as i32 - bias_uv;

                    let r = qrshr::<PRECISION, BIT_DEPTH>(y_value + cr_coef * cr_value);
                    let b = qrshr::<PRECISION, BIT_DEPTH>(y_value + cb_coef * cb_value);
                    let g = qrshr::<PRECISION, BIT_DEPTH>(
                        y_value - g_coef_1 * cr_value - g_coef_2 * cb_value,
                    );

                    rgba[dst_chans.get_r_channel_offset()] = r as u8;
                    rgba[dst_chans.get_g_channel_offset()] = g as u8;
                    rgba[dst_chans.get_b_channel_offset()] = b as u8;
                    if dst_chans.has_alpha() {
                        rgba[dst_chans.get_a_channel_offset()] = 255;
                    }
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
                .zip(v_plane.par_chunks(image.v_stride as usize));
        }
        #[cfg(not(feature = "rayon"))]
        {
            iter = rgba
                .chunks_mut(rgba_stride as usize)
                .zip(y_plane.chunks(image.y_stride as usize))
                .zip(u_plane.chunks(image.u_stride as usize))
                .zip(v_plane.chunks(image.v_stride as usize));
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
            iter = rgba
                .par_chunks_mut(rgba_stride as usize * 2)
                .zip(y_plane.par_chunks(image.y_stride as usize * 2))
                .zip(u_plane.par_chunks(image.u_stride as usize))
                .zip(v_plane.par_chunks(image.v_stride as usize));
        }
        #[cfg(not(feature = "rayon"))]
        {
            iter = rgba
                .chunks_mut(rgba_stride as usize * 2)
                .zip(y_plane.chunks(image.y_stride as usize * 2))
                .zip(u_plane.chunks(image.u_stride as usize))
                .zip(v_plane.chunks(image.v_stride as usize));
        }
        iter.take(image.height as usize / 2)
            .for_each(|(((rgba, y_plane), u_plane), v_plane)| {
                let (rgba0, rgba1) = rgba.split_at_mut(rgba_stride as usize);
                let (y_plane0, y_plane1) = y_plane.split_at(image.y_stride as usize);
                process_doubled_chroma_row(
                    &y_plane0[..image.width as usize],
                    &y_plane1[..image.width as usize],
                    &u_plane[..(image.width as usize).div_ceil(2)],
                    &v_plane[..(image.width as usize).div_ceil(2)],
                    &mut rgba0[..image.width as usize * channels],
                    &mut rgba1[..image.width as usize * channels],
                );
            });

        if image.height & 1 != 0 {
            let rgba = rgba.chunks_mut(rgba_stride as usize).last().unwrap();
            let u_plane = u_plane.chunks(image.u_stride as usize).last().unwrap();
            let v_plane = v_plane.chunks(image.v_stride as usize).last().unwrap();
            let y_plane = y_plane.chunks(image.y_stride as usize).last().unwrap();
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

fn yuv_to_rgbx<const DESTINATION_CHANNELS: u8, const SAMPLING: u8>(
    image: &YuvPlanarImage<u8>,
    rgba: &mut [u8],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuv_to_rgbx_impl::<DESTINATION_CHANNELS, SAMPLING, 13>(
        image,
        rgba,
        rgba_stride,
        range,
        matrix,
        RowHandler::<DESTINATION_CHANNELS, SAMPLING, 13>::default(),
        RowHandler420::<DESTINATION_CHANNELS, SAMPLING, 13>::default(),
    )
}

/// Convert YUV 420 planar format to RGB format.
///
/// This function takes YUV 420 planar format data with 8-bit precision,
/// and converts it to RGB format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `planar_image` - Source planar image.
/// * `rgb` - A mutable slice to store the converted RGB data.
/// * `rgb_stride` - The stride (components per row) for the RGB image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input RGB data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv420_to_rgb(
    planar_image: &YuvPlanarImage<u8>,
    rgb: &mut [u8],
    rgb_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuv_to_rgbx::<{ YuvSourceChannels::Rgb as u8 }, { YuvChromaSubsampling::Yuv420 as u8 }>(
        planar_image,
        rgb,
        rgb_stride,
        range,
        matrix,
    )
}

/// Convert YUV 420 planar format to BGR format.
///
/// This function takes YUV 420 planar format data with 8-bit precision,
/// and converts it to BGR format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `planar_image` - Source planar image.
/// * `rgb` - A mutable slice to store the converted BGR data.
/// * `rgb_stride` - The stride (components per row) for the BGR image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGR data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv420_to_bgr(
    planar_image: &YuvPlanarImage<u8>,
    bgr: &mut [u8],
    bgr_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuv_to_rgbx::<{ YuvSourceChannels::Bgr as u8 }, { YuvChromaSubsampling::Yuv420 as u8 }>(
        planar_image,
        bgr,
        bgr_stride,
        range,
        matrix,
    )
}

/// Convert YUV 420 planar format to RGBA format.
///
/// This function takes YUV 420 planar format data with 8-bit precision,
/// and converts it to RGBA format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `planar_image` - Source planar image.
/// * `rgba` - A mutable slice to store the converted RGBA data.
/// * `rgba_stride` - Elements per row.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input RGBA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv420_to_rgba(
    planar_image: &YuvPlanarImage<u8>,
    rgba: &mut [u8],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuv_to_rgbx::<{ YuvSourceChannels::Rgba as u8 }, { YuvChromaSubsampling::Yuv420 as u8 }>(
        planar_image,
        rgba,
        rgba_stride,
        range,
        matrix,
    )
}

/// Convert YUV 420 planar format to BGRA format.
///
/// This function takes YUV 420 planar format data with 8-bit precision,
/// and converts it to BGRA format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `planar_image` - Source planar image.
/// * `bgra` - A mutable slice to store the converted BGRA data.
/// * `bgra_stride` - Elements per BGRA row.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGRA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv420_to_bgra(
    planar_image: &YuvPlanarImage<u8>,
    bgra: &mut [u8],
    bgra_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuv_to_rgbx::<{ YuvSourceChannels::Bgra as u8 }, { YuvChromaSubsampling::Yuv420 as u8 }>(
        planar_image,
        bgra,
        bgra_stride,
        range,
        matrix,
    )
}

/// Convert YUV 422 planar format to RGB format.
///
/// This function takes YUV 422 data with 8-bit precision,
/// and converts it to RGB format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `planar_image` - Source planar image.
/// * `rgb` - A mutable slice to store the converted RGB data.
/// * `rgb_stride` - The stride (components per row) for the RGB image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input RGB data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv422_to_rgb(
    planar_image: &YuvPlanarImage<u8>,
    rgb: &mut [u8],
    rgb_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuv_to_rgbx::<{ YuvSourceChannels::Rgb as u8 }, { YuvChromaSubsampling::Yuv422 as u8 }>(
        planar_image,
        rgb,
        rgb_stride,
        range,
        matrix,
    )
}

/// Convert YUV 422 planar format to BGR format.
///
/// This function takes YUV 422 data with 8-bit precision,
/// and converts it to BGR format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `planar_image` - Source planar image.
/// * `bgr` - A mutable slice to store the converted BGR data.
/// * `bgr_stride` - The stride (components per row) for the BGR image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGR data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv422_to_bgr(
    planar_image: &YuvPlanarImage<u8>,
    bgr: &mut [u8],
    bgr_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuv_to_rgbx::<{ YuvSourceChannels::Bgr as u8 }, { YuvChromaSubsampling::Yuv422 as u8 }>(
        planar_image,
        bgr,
        bgr_stride,
        range,
        matrix,
    )
}

/// Convert YUV 422 planar format to RGBA format.
///
/// This function takes YUV 422 data with 8-bit precision,
/// and converts it to RGBA format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `planar_image` - Source planar image.
/// * `rgba` - A mutable slice to store the converted RGBA data.
/// * `rgba_stride` - Elements per RGBA data row.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGRA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv422_to_rgba(
    planar_image: &YuvPlanarImage<u8>,
    rgba: &mut [u8],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuv_to_rgbx::<{ YuvSourceChannels::Rgba as u8 }, { YuvChromaSubsampling::Yuv422 as u8 }>(
        planar_image,
        rgba,
        rgba_stride,
        range,
        matrix,
    )
}

/// Convert YUV 422 planar format to BGRA format.
///
/// This function takes YUV 422 data with 8-bit precision,
/// and converts it to BGRA format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `planar_image` - Source planar image.
/// * `bgra` - A mutable slice to store the converted BGRA data.
/// * `bgra_stride` - Elements per RGBA data row.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGRA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv422_to_bgra(
    planar_image: &YuvPlanarImage<u8>,
    bgra: &mut [u8],
    bgra_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuv_to_rgbx::<{ YuvSourceChannels::Bgra as u8 }, { YuvChromaSubsampling::Yuv422 as u8 }>(
        planar_image,
        bgra,
        bgra_stride,
        range,
        matrix,
    )
}

/// Convert YUV 444 planar format to RGBA format.
///
/// This function takes YUV 444 data with 8-bit precision,
/// and converts it to RGBA format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `planar_image` - Source planar image.
/// * `rgba` - A mutable slice to store the converted RGBA data.
/// * `rgba_stride` - Elements per RGBA data row.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGRA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv444_to_rgba(
    planar_image: &YuvPlanarImage<u8>,
    rgba: &mut [u8],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuv_to_rgbx::<{ YuvSourceChannels::Rgba as u8 }, { YuvChromaSubsampling::Yuv444 as u8 }>(
        planar_image,
        rgba,
        rgba_stride,
        range,
        matrix,
    )
}

/// Convert YUV 444 planar format to BGRA format.
///
/// This function takes YUV 444 data with 8-bit precision,
/// and converts it to BGRA format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `planar_image` - Source planar image.
/// * `height` - The height of the YUV image.
/// * `bgra` - A mutable slice to store the converted BGRA data.
/// * `bgra_stride` - Elements per BGRA data row.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGRA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv444_to_bgra(
    planar_image: &YuvPlanarImage<u8>,
    bgra: &mut [u8],
    bgra_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuv_to_rgbx::<{ YuvSourceChannels::Bgra as u8 }, { YuvChromaSubsampling::Yuv444 as u8 }>(
        planar_image,
        bgra,
        bgra_stride,
        range,
        matrix,
    )
}

/// Convert YUV 444 planar format to RGB format.
///
/// This function takes YUV 444 data with 8-bit precision,
/// and converts it to RGB format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `planar_image` - Source planar image.
/// * `rgb` - A mutable slice to store the converted RGB data.
/// * `rgb_stride` - The stride (components per row) for the RGB image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input RGB data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv444_to_rgb(
    planar_image: &YuvPlanarImage<u8>,
    rgb: &mut [u8],
    rgb_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuv_to_rgbx::<{ YuvSourceChannels::Rgb as u8 }, { YuvChromaSubsampling::Yuv444 as u8 }>(
        planar_image,
        rgb,
        rgb_stride,
        range,
        matrix,
    )
}

/// Convert YUV 444 planar format to BGR format.
///
/// This function takes YUV 444 data with 8-bit precision,
/// and converts it to BGR format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `planar_image` - Source planar image.
/// * `bgr` - A mutable slice to store the converted BGR data.
/// * `bgr_stride` - The stride (components per row) for the BGR image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGR data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv444_to_bgr(
    planar_image: &YuvPlanarImage<u8>,
    bgr: &mut [u8],
    bgr_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuv_to_rgbx::<{ YuvSourceChannels::Bgr as u8 }, { YuvChromaSubsampling::Yuv444 as u8 }>(
        planar_image,
        bgr,
        bgr_stride,
        range,
        matrix,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{rgb_to_yuv420, rgb_to_yuv422, rgb_to_yuv444, yuv444_to_rgb, YuvPlanarImageMut};
    use rand::RngExt;

    #[test]
    fn test_yuv444_round_trip_full_range() {
        fn matrix(yuv_accuracy: YuvConversionMode, max_diff: i32) {
            let image_width = 256usize;
            let image_height = 256usize;

            let random_point_x = rand::rng().random_range(0..image_width);
            let random_point_y = rand::rng().random_range(0..image_height);

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
            let mut image_rgb = vec![0u8; image_width * image_height * 3];

            let or = rand::rng().random_range(0..256) as u8;
            let og = rand::rng().random_range(0..256) as u8;
            let ob = rand::rng().random_range(0..256) as u8;

            for point in &pixel_points {
                image_rgb[point[0] * 3 + point[1] * image_width * 3] = or;
                image_rgb[point[0] * 3 + point[1] * image_width * 3 + 1] = og;
                image_rgb[point[0] * 3 + point[1] * image_width * 3 + 2] = ob;
            }

            let mut planar_image = YuvPlanarImageMut::<u8>::alloc(
                image_width as u32,
                image_height as u32,
                YuvChromaSubsampling::Yuv444,
            );

            rgb_to_yuv444(
                &mut planar_image,
                &image_rgb,
                image_width as u32 * 3,
                YuvRange::Full,
                YuvStandardMatrix::Bt709,
                yuv_accuracy,
            )
            .unwrap();

            image_rgb.fill(0);

            let fixed_planar = planar_image.to_fixed();

            yuv444_to_rgb(
                &fixed_planar,
                &mut image_rgb,
                image_width as u32 * 3,
                YuvRange::Full,
                YuvStandardMatrix::Bt709,
            )
            .unwrap();

            for point in &pixel_points {
                let x = point[0];
                let y = point[1];
                let r = image_rgb[x * 3 + y * image_width * 3];
                let g = image_rgb[x * 3 + y * image_width * 3 + 1];
                let b = image_rgb[x * 3 + y * image_width * 3 + 2];

                let diff_r = (r as i32 - or as i32).abs();
                let diff_g = (g as i32 - og as i32).abs();
                let diff_b = (b as i32 - ob as i32).abs();

                assert!(
                    diff_r <= max_diff,
                    "Matrix {}, diff {}, Original RGB {:?}, Round-tripped RGB {:?}",
                    diff_r,
                    yuv_accuracy,
                    [or, og, ob],
                    [r, g, b]
                );
                assert!(
                    diff_g <= max_diff,
                    "Matrix {}, diff {}, Original RGB {:?}, Round-tripped RGB {:?}",
                    diff_g,
                    yuv_accuracy,
                    [or, og, ob],
                    [r, g, b]
                );
                assert!(
                    diff_b <= max_diff,
                    "Matrix {}, diff {}, Original RGB {:?}, Round-tripped RGB {:?}",
                    diff_b,
                    yuv_accuracy,
                    [or, og, ob],
                    [r, g, b]
                );
            }
        }
        matrix(YuvConversionMode::Balanced, 3);
        #[cfg(feature = "fast_mode")]
        matrix(YuvConversionMode::Fast, 6);
        #[cfg(feature = "professional_mode")]
        matrix(YuvConversionMode::Professional, 3);
    }

    #[test]
    fn test_yuv444_round_trip_limited_range() {
        fn matrix(yuv_accuracy: YuvConversionMode, max_diff: i32) {
            let image_width = 256usize;
            let image_height = 256usize;

            let random_point_x = rand::rng().random_range(0..image_width);
            let random_point_y = rand::rng().random_range(0..image_height);

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
            let mut image_rgb = vec![0u8; image_width * image_height * 3];

            let or = rand::rng().random_range(0..256) as u8;
            let og = rand::rng().random_range(0..256) as u8;
            let ob = rand::rng().random_range(0..256) as u8;

            for point in &pixel_points {
                image_rgb[point[0] * 3 + point[1] * image_width * 3] = or;
                image_rgb[point[0] * 3 + point[1] * image_width * 3 + 1] = og;
                image_rgb[point[0] * 3 + point[1] * image_width * 3 + 2] = ob;
            }

            let mut planar_image = YuvPlanarImageMut::<u8>::alloc(
                image_width as u32,
                image_height as u32,
                YuvChromaSubsampling::Yuv444,
            );

            rgb_to_yuv444(
                &mut planar_image,
                &image_rgb,
                image_width as u32 * 3,
                YuvRange::Limited,
                YuvStandardMatrix::Bt709,
                yuv_accuracy,
            )
            .unwrap();

            image_rgb.fill(0);

            let fixed_planar = planar_image.to_fixed();

            yuv444_to_rgb(
                &fixed_planar,
                &mut image_rgb,
                image_width as u32 * 3,
                YuvRange::Limited,
                YuvStandardMatrix::Bt709,
            )
            .unwrap();

            for point in &pixel_points {
                let x = point[0];
                let y = point[1];
                let r = image_rgb[x * 3 + y * image_width * 3];
                let g = image_rgb[x * 3 + y * image_width * 3 + 1];
                let b = image_rgb[x * 3 + y * image_width * 3 + 2];

                let diff_r = (r as i32 - or as i32).abs();
                let diff_g = (g as i32 - og as i32).abs();
                let diff_b = (b as i32 - ob as i32).abs();

                assert!(
                    diff_r <= max_diff,
                    "Matrix {} Original RGB {:?}, Round-tripped RGB {:?}, diff {}",
                    yuv_accuracy,
                    [or, og, ob],
                    [r, g, b],
                    diff_r
                );
                assert!(
                    diff_g <= max_diff,
                    "Matrix {} Original RGB {:?}, Round-tripped RGB {:?}, diff {}",
                    yuv_accuracy,
                    [or, og, ob],
                    [r, g, b],
                    diff_g,
                );
                assert!(
                    diff_b <= max_diff,
                    "Matrix {} Original RGB {:?}, Round-tripped RGB {:?}, diff {}",
                    yuv_accuracy,
                    [or, og, ob],
                    [r, g, b],
                    diff_b,
                );
            }
        }
        matrix(YuvConversionMode::Balanced, 20);
        #[cfg(feature = "fast_mode")]
        matrix(YuvConversionMode::Fast, 30);
    }

    #[test]
    fn test_yuv422_round_trip_full_range() {
        fn matrix(yuv_accuracy: YuvConversionMode, max_diff: i32) {
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

            let mut source_rgb = vec![0u8; image_width * image_height * CHANNELS];

            let or = rand::rng().random_range(0..256) as u8;
            let og = rand::rng().random_range(0..256) as u8;
            let ob = rand::rng().random_range(0..256) as u8;

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

            let mut planar_image = YuvPlanarImageMut::<u8>::alloc(
                image_width as u32,
                image_height as u32,
                YuvChromaSubsampling::Yuv422,
            );

            rgb_to_yuv422(
                &mut planar_image,
                &source_rgb,
                image_width as u32 * 3,
                YuvRange::Full,
                YuvStandardMatrix::Bt709,
                yuv_accuracy,
            )
            .unwrap();

            let mut dest_rgb = vec![0u8; image_width * image_height * CHANNELS];

            let fixed_planar = planar_image.to_fixed();

            yuv422_to_rgb(
                &fixed_planar,
                &mut dest_rgb,
                image_width as u32 * 3,
                YuvRange::Full,
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
                    diff_r <= max_diff,
                    "Matrix {}, Actual diff {}, Original RGB {:?}, Round-tripped RGB {:?}",
                    yuv_accuracy,
                    diff_r,
                    [or, og, ob],
                    [r, g, b]
                );
                assert!(
                    diff_g <= max_diff,
                    "Matrix {}, Actual diff {}, Original RGB {:?}, Round-tripped RGB {:?}",
                    yuv_accuracy,
                    diff_g,
                    [or, og, ob],
                    [r, g, b]
                );
                assert!(
                    diff_b <= max_diff,
                    "Matrix {}, Actual diff {}, Original RGB {:?}, Round-tripped RGB {:?}",
                    yuv_accuracy,
                    diff_b,
                    [or, og, ob],
                    [r, g, b]
                );
            }
        }
        matrix(YuvConversionMode::Balanced, 3);
        #[cfg(feature = "fast_mode")]
        matrix(YuvConversionMode::Fast, 7);
        #[cfg(feature = "professional_mode")]
        matrix(YuvConversionMode::Professional, 3);
    }

    #[test]
    fn test_yuv422_round_trip_limited_range() {
        fn matrix(yuv_accuracy: YuvConversionMode, max_diff: i32) {
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

            let mut source_rgb = vec![0u8; image_width * image_height * CHANNELS];

            let or = rand::rng().random_range(0..256) as u8;
            let og = rand::rng().random_range(0..256) as u8;
            let ob = rand::rng().random_range(0..256) as u8;

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

            let mut planar_image = YuvPlanarImageMut::<u8>::alloc(
                image_width as u32,
                image_height as u32,
                YuvChromaSubsampling::Yuv422,
            );

            rgb_to_yuv422(
                &mut planar_image,
                &source_rgb,
                image_width as u32 * 3,
                YuvRange::Limited,
                YuvStandardMatrix::Bt709,
                yuv_accuracy,
            )
            .unwrap();

            let mut dest_rgb = vec![0u8; image_width * image_height * CHANNELS];

            let fixed_planar = planar_image.to_fixed();

            yuv422_to_rgb(
                &fixed_planar,
                &mut dest_rgb,
                image_width as u32 * 3,
                YuvRange::Limited,
                YuvStandardMatrix::Bt709,
            )
            .unwrap();

            for point in pixel_points.iter() {
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
                    diff_r <= max_diff,
                    "Matrix {}, Actual diff {}, Original RGB {:?}, Round-tripped RGB {:?}",
                    yuv_accuracy,
                    diff_r,
                    [or, og, ob],
                    [r, g, b]
                );
                assert!(
                    diff_g <= max_diff,
                    "Matrix {}, Actual diff {}, Original RGB {:?}, Round-tripped RGB {:?}",
                    yuv_accuracy,
                    diff_g,
                    [or, og, ob],
                    [r, g, b]
                );
                assert!(
                    diff_b <= max_diff,
                    "Matrix {}, Actual diff {}, Original RGB {:?}, Round-tripped RGB {:?}",
                    yuv_accuracy,
                    diff_b,
                    [or, og, ob],
                    [r, g, b]
                );
            }
        }
        #[cfg(feature = "fast_mode")]
        matrix(YuvConversionMode::Fast, 15);
        matrix(YuvConversionMode::Balanced, 10);
        #[cfg(feature = "professional_mode")]
        matrix(YuvConversionMode::Professional, 10);
    }

    #[test]
    fn test_yuv420_round_trip_full_range() {
        fn matrix(
            image_width: usize,
            image_height: usize,
            yuv_accuracy: YuvConversionMode,
            max_diff: i32,
        ) {
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

            let mut source_rgb = vec![0u8; image_width * image_height * CHANNELS];

            let or = rand::rng().random_range(0..256) as u8;
            let og = rand::rng().random_range(0..256) as u8;
            let ob = rand::rng().random_range(0..256) as u8;

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

            let mut planar_image = YuvPlanarImageMut::<u8>::alloc(
                image_width as u32,
                image_height as u32,
                YuvChromaSubsampling::Yuv420,
            );

            rgb_to_yuv420(
                &mut planar_image,
                &source_rgb,
                image_width as u32 * 3,
                YuvRange::Full,
                YuvStandardMatrix::Bt709,
                yuv_accuracy,
            )
            .unwrap();

            let mut dest_rgb = vec![0u8; image_width * image_height * CHANNELS];

            let fixed_planar = planar_image.to_fixed();

            yuv420_to_rgb(
                &fixed_planar,
                &mut dest_rgb,
                image_width as u32 * 3,
                YuvRange::Full,
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
                    diff_r <= max_diff,
                    "Matrix {}, Actual diff {}, Original RGB {:?}, Round-tripped RGB {:?}",
                    yuv_accuracy,
                    diff_r,
                    [or, og, ob],
                    [r, g, b]
                );
                assert!(
                    diff_g <= max_diff,
                    "Matrix {}, Actual diff {}, Original RGB {:?}, Round-tripped RGB {:?}",
                    yuv_accuracy,
                    diff_g,
                    [or, og, ob],
                    [r, g, b]
                );
                assert!(
                    diff_b <= max_diff,
                    "Matrix {}, Actual diff {}, Original RGB {:?}, Round-tripped RGB {:?}",
                    yuv_accuracy,
                    diff_b,
                    [or, og, ob],
                    [r, g, b]
                );
            }
        }

        let random_width = rand::rng().random_range(1..256);
        let random_height = rand::rng().random_range(1..256);

        matrix(random_width, random_height, YuvConversionMode::Balanced, 80);
        #[cfg(feature = "fast_mode")]
        matrix(random_width, random_height, YuvConversionMode::Fast, 80);
        #[cfg(feature = "professional_mode")]
        matrix(
            random_width,
            random_height,
            YuvConversionMode::Professional,
            72,
        );
    }

    #[test]
    fn test_yuv420_round_trip_limited_range() {
        fn matrix(yuv_accuracy: YuvConversionMode, max_diff: i32) {
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

            let mut source_rgb = vec![0u8; image_width * image_height * CHANNELS];

            let or = rand::rng().random_range(0..256) as u8;
            let og = rand::rng().random_range(0..256) as u8;
            let ob = rand::rng().random_range(0..256) as u8;

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

            let mut planar_image = YuvPlanarImageMut::<u8>::alloc(
                image_width as u32,
                image_height as u32,
                YuvChromaSubsampling::Yuv420,
            );

            rgb_to_yuv420(
                &mut planar_image,
                &source_rgb,
                image_width as u32 * 3,
                YuvRange::Limited,
                YuvStandardMatrix::Bt709,
                yuv_accuracy,
            )
            .unwrap();

            let mut dest_rgb = vec![0u8; image_width * image_height * CHANNELS];

            let fixed_planar = planar_image.to_fixed();

            yuv420_to_rgb(
                &fixed_planar,
                &mut dest_rgb,
                image_width as u32 * 3,
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
                    diff_r <= max_diff,
                    "Matrix {}, Actual diff {}, Original RGB {:?}, Round-tripped RGB {:?}",
                    yuv_accuracy,
                    diff_r,
                    [or, og, ob],
                    [r, g, b]
                );
                assert!(
                    diff_g <= max_diff,
                    "Matrix {}, Actual diff {}, Original RGB {:?}, Round-tripped RGB {:?}",
                    yuv_accuracy,
                    diff_g,
                    [or, og, ob],
                    [r, g, b]
                );
                assert!(
                    diff_b <= max_diff,
                    "Matrix {}, Actual diff {}, Original RGB {:?}, Round-tripped RGB {:?}",
                    yuv_accuracy,
                    diff_b,
                    [or, og, ob],
                    [r, g, b]
                );
            }
        }
        matrix(YuvConversionMode::Balanced, 82);
        #[cfg(feature = "fast_mode")]
        matrix(YuvConversionMode::Fast, 78);
        #[cfg(feature = "professional_mode")]
        matrix(YuvConversionMode::Professional, 74);
    }
}
