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
#[cfg(all(
    any(target_arch = "x86", target_arch = "x86_64"),
    feature = "nightly_avx512"
))]
use crate::avx512bw::avx512_rgba_to_nv420;
use crate::images::YuvBiPlanarImageMut;
use crate::internals::{
    ProcessedOffset, WideRowForwardBiPlanar420Handler, WideRowForwardBiPlanarHandler,
};
#[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
use crate::neon::{neon_rgbx_to_nv_row, neon_rgbx_to_nv_row420};
use crate::yuv_error::check_rgba_destination;
use crate::yuv_support::*;
use crate::YuvError;
#[cfg(feature = "rayon")]
use rayon::iter::{IndexedParallelIterator, ParallelIterator};
#[cfg(feature = "rayon")]
use rayon::prelude::{ParallelSlice, ParallelSliceMut};

type SemiPlanarRowHandler = Option<
    unsafe fn(
        y_plane0: &mut [u8],
        y_plane1: &mut [u8],
        uv_plane: &mut [u8],
        rgba0: &[u8],
        rgba1: &[u8],
        width: u32,
        range: &YuvChromaRange,
        transform: &CbCrForwardTransform<i32>,
        start_cx: usize,
        start_ux: usize,
    ) -> ProcessedOffset,
>;

type SemiPlanarRow420Handler = Option<
    unsafe fn(
        y_plane: &mut [u8],
        uv_plane: &mut [u8],
        rgba0: &[u8],
        width: u32,
        range: &YuvChromaRange,
        transform: &CbCrForwardTransform<i32>,
        start_cx: usize,
        start_ux: usize,
    ) -> ProcessedOffset,
>;

struct SemiPlanar420Encoder<
    const ORIGIN_CHANNELS: u8,
    const UV_ORDER: u8,
    const SAMPLING: u8,
    const PRECISION: i32,
> {
    handler: SemiPlanarRowHandler,
}

#[cfg(feature = "professional_mode")]
struct SemiPlanar420EncoderProfessional<
    const ORIGIN_CHANNELS: u8,
    const UV_ORDER: u8,
    const SAMPLING: u8,
    const PRECISION: i32,
> {
    handler: SemiPlanarRowHandler,
}

#[cfg(feature = "fast_mode")]
struct SemiPlanar420EncoderFast<
    const ORIGIN_CHANNELS: u8,
    const UV_ORDER: u8,
    const SAMPLING: u8,
    const PRECISION: i32,
> {
    handler: SemiPlanarRowHandler,
}

impl<const ORIGIN_CHANNELS: u8, const UV_ORDER: u8, const SAMPLING: u8, const PRECISION: i32>
    Default for SemiPlanar420Encoder<ORIGIN_CHANNELS, UV_ORDER, SAMPLING, PRECISION>
{
    fn default() -> Self {
        let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();
        if chroma_subsampling != YuvChromaSubsampling::Yuv420 {
            return SemiPlanar420Encoder { handler: None };
        }

        if PRECISION != 13 {
            return SemiPlanar420Encoder { handler: None };
        }
        assert_eq!(PRECISION, 13);
        assert_eq!(chroma_subsampling, YuvChromaSubsampling::Yuv420);
        #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
        {
            #[cfg(feature = "rdm")]
            {
                let is_rdm_available = std::arch::is_aarch64_feature_detected!("rdm");
                use crate::neon::neon_rgbx_to_nv_row_rdm420;
                if is_rdm_available {
                    return SemiPlanar420Encoder {
                        handler: Some(neon_rgbx_to_nv_row_rdm420::<ORIGIN_CHANNELS, UV_ORDER>),
                    };
                }
            }

            SemiPlanar420Encoder {
                handler: Some(neon_rgbx_to_nv_row420::<ORIGIN_CHANNELS, UV_ORDER>),
            }
        }
        #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
        {
            #[cfg(feature = "nightly_avx512")]
            {
                let use_avx512 = std::arch::is_x86_feature_detected!("avx512bw");
                if use_avx512 {
                    let use_vbmi = std::arch::is_x86_feature_detected!("avx512vbmi");
                    return if use_vbmi {
                        SemiPlanar420Encoder {
                            handler: Some(
                                avx512_rgba_to_nv420::<ORIGIN_CHANNELS, UV_ORDER, PRECISION, true>,
                            ),
                        }
                    } else {
                        SemiPlanar420Encoder {
                            handler: Some(
                                avx512_rgba_to_nv420::<ORIGIN_CHANNELS, UV_ORDER, PRECISION, false>,
                            ),
                        }
                    };
                }
            }

            #[cfg(feature = "avx")]
            {
                let use_avx2 = std::arch::is_x86_feature_detected!("avx2");
                if use_avx2 {
                    use crate::avx2::avx2_rgba_to_nv420;
                    return SemiPlanar420Encoder {
                        handler: Some(avx2_rgba_to_nv420::<ORIGIN_CHANNELS, UV_ORDER, PRECISION>),
                    };
                }
            }
            #[cfg(feature = "sse")]
            {
                let use_sse = std::arch::is_x86_feature_detected!("sse4.1");
                use crate::sse::sse_rgba_to_nv_row420;
                if use_sse {
                    return SemiPlanar420Encoder {
                        handler: Some(
                            sse_rgba_to_nv_row420::<ORIGIN_CHANNELS, UV_ORDER, PRECISION>,
                        ),
                    };
                }
            }
        }
        #[cfg(not(all(target_arch = "aarch64", target_feature = "neon")))]
        SemiPlanar420Encoder { handler: None }
    }
}

#[cfg(feature = "fast_mode")]
impl<const ORIGIN_CHANNELS: u8, const UV_ORDER: u8, const SAMPLING: u8, const PRECISION: i32>
    Default for SemiPlanar420EncoderFast<ORIGIN_CHANNELS, UV_ORDER, SAMPLING, PRECISION>
{
    fn default() -> Self {
        let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();
        if chroma_subsampling != YuvChromaSubsampling::Yuv420 {
            return SemiPlanar420EncoderFast { handler: None };
        }
        if PRECISION == 7 {
            assert_eq!(PRECISION, 7);
            #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
            {
                #[cfg(feature = "nightly_i8mm")]
                {
                    let cn: YuvSourceChannels = ORIGIN_CHANNELS.into();
                    use crate::neon::neon_rgba_to_nv_dot_rgba420;
                    if std::arch::is_aarch64_feature_detected!("i8mm")
                        && (cn == YuvSourceChannels::Rgba || cn == YuvSourceChannels::Bgra)
                    {
                        assert!(cn == YuvSourceChannels::Rgba || cn == YuvSourceChannels::Bgra);
                        return SemiPlanar420EncoderFast {
                            handler: Some(neon_rgba_to_nv_dot_rgba420::<ORIGIN_CHANNELS, UV_ORDER>),
                        };
                    }
                }
                use crate::neon::neon_rgbx_to_nv_fast420;
                return SemiPlanar420EncoderFast {
                    handler: Some(neon_rgbx_to_nv_fast420::<ORIGIN_CHANNELS, UV_ORDER>),
                };
            }

            #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
            {
                #[cfg(feature = "avx")]
                if std::arch::is_x86_feature_detected!("avx2") {
                    use crate::avx2::avx2_rgba_to_nv_fast_rgba420;
                    return SemiPlanar420EncoderFast {
                        handler: Some(avx2_rgba_to_nv_fast_rgba420::<ORIGIN_CHANNELS, UV_ORDER>),
                    };
                }

                #[cfg(feature = "sse")]
                {
                    if std::arch::is_x86_feature_detected!("sse4.1") {
                        use crate::sse::sse_rgba_to_nv_fast_rgba420;
                        return SemiPlanar420EncoderFast {
                            handler: Some(sse_rgba_to_nv_fast_rgba420::<ORIGIN_CHANNELS, UV_ORDER>),
                        };
                    }
                }
            }
        }

        SemiPlanar420EncoderFast { handler: None }
    }
}

#[cfg(feature = "professional_mode")]
impl<const ORIGIN_CHANNELS: u8, const UV_ORDER: u8, const SAMPLING: u8, const PRECISION: i32>
    Default for SemiPlanar420EncoderProfessional<ORIGIN_CHANNELS, UV_ORDER, SAMPLING, PRECISION>
{
    fn default() -> Self {
        let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();
        if chroma_subsampling != YuvChromaSubsampling::Yuv420 {
            return SemiPlanar420EncoderProfessional { handler: None };
        }
        if PRECISION == 15 {
            assert_eq!(PRECISION, 15);
            #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
            {
                use crate::neon::neon_rgba_to_nv_prof420;
                return SemiPlanar420EncoderProfessional {
                    handler: Some(neon_rgba_to_nv_prof420::<ORIGIN_CHANNELS, SAMPLING>),
                };
            }
            #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
            {
                #[cfg(feature = "nightly_avx512")]
                {
                    let use_avx512 = std::arch::is_x86_feature_detected!("avx512bw");
                    if use_avx512 {
                        let use_vbmi = std::arch::is_x86_feature_detected!("avx512vbmi");
                        use crate::avx512bw::avx512_rgba_to_nv420_prof;
                        return if use_vbmi {
                            SemiPlanar420EncoderProfessional {
                                handler: Some(
                                    avx512_rgba_to_nv420_prof::<ORIGIN_CHANNELS, UV_ORDER, true>,
                                ),
                            }
                        } else {
                            SemiPlanar420EncoderProfessional {
                                handler: Some(
                                    avx512_rgba_to_nv420_prof::<ORIGIN_CHANNELS, UV_ORDER, false>,
                                ),
                            }
                        };
                    }
                }

                #[cfg(feature = "avx")]
                if std::arch::is_x86_feature_detected!("avx2") {
                    use crate::avx2::avx2_rgba_to_nv420_prof;
                    return SemiPlanar420EncoderProfessional {
                        handler: Some(
                            avx2_rgba_to_nv420_prof::<ORIGIN_CHANNELS, UV_ORDER, PRECISION>,
                        ),
                    };
                }
                #[cfg(feature = "sse")]
                if std::arch::is_x86_feature_detected!("sse4.1") {
                    use crate::sse::sse_rgba_to_nv420_prof;
                    return SemiPlanar420EncoderProfessional {
                        handler: Some(
                            sse_rgba_to_nv420_prof::<ORIGIN_CHANNELS, UV_ORDER, PRECISION>,
                        ),
                    };
                }
            }
        }

        SemiPlanar420EncoderProfessional { handler: None }
    }
}

macro_rules! define_biplanar420_handler {
    ($struct_name:ident) => {
        impl<
                const ORIGIN_CHANNELS: u8,
                const UV_ORDER: u8,
                const SAMPLING: u8,
                const PRECISION: i32,
            > WideRowForwardBiPlanar420Handler<u8, i32>
            for $struct_name<ORIGIN_CHANNELS, UV_ORDER, SAMPLING, PRECISION>
        {
            fn handle_rows(
                &self,
                rgba0: &[u8],
                rgba1: &[u8],
                y_plane0: &mut [u8],
                y_plane1: &mut [u8],
                uv_plane: &mut [u8],
                width: u32,
                chroma: YuvChromaRange,
                transform: &CbCrForwardTransform<i32>,
            ) -> ProcessedOffset {
                if let Some(handler) = self.handler {
                    unsafe {
                        return handler(
                            y_plane0, y_plane1, uv_plane, rgba0, rgba1, width, &chroma, transform,
                            0, 0,
                        );
                    }
                }
                ProcessedOffset { cx: 0, ux: 0 }
            }
        }
    };
}

define_biplanar420_handler!(SemiPlanar420Encoder);
#[cfg(feature = "fast_mode")]
define_biplanar420_handler!(SemiPlanar420EncoderFast);
#[cfg(feature = "professional_mode")]
define_biplanar420_handler!(SemiPlanar420EncoderProfessional);

struct SemiPlanarEncoder<
    const ORIGIN_CHANNELS: u8,
    const UV_ORDER: u8,
    const SAMPLING: u8,
    const PRECISION: i32,
> {
    handler: SemiPlanarRow420Handler,
}

#[cfg(feature = "professional_mode")]
struct SemiPlanarEncoderProfessional<
    const ORIGIN_CHANNELS: u8,
    const UV_ORDER: u8,
    const SAMPLING: u8,
    const PRECISION: i32,
> {
    handler: SemiPlanarRow420Handler,
}

#[cfg(feature = "fast_mode")]
struct SemiPlanarEncoderFast<
    const ORIGIN_CHANNELS: u8,
    const UV_ORDER: u8,
    const SAMPLING: u8,
    const PRECISION: i32,
> {
    handler: SemiPlanarRow420Handler,
}

impl<const ORIGIN_CHANNELS: u8, const UV_ORDER: u8, const SAMPLING: u8, const PRECISION: i32>
    Default for SemiPlanarEncoder<ORIGIN_CHANNELS, UV_ORDER, SAMPLING, PRECISION>
{
    fn default() -> Self {
        if PRECISION != 13 {
            return SemiPlanarEncoder { handler: None };
        }
        assert_eq!(PRECISION, 13);

        #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
        {
            #[cfg(feature = "rdm")]
            {
                let is_rdm_available = std::arch::is_aarch64_feature_detected!("rdm");
                use crate::neon::neon_rgbx_to_nv_row_rdm;
                if is_rdm_available {
                    return SemiPlanarEncoder {
                        handler: Some(
                            neon_rgbx_to_nv_row_rdm::<ORIGIN_CHANNELS, UV_ORDER, SAMPLING, PRECISION>,
                        ),
                    };
                }
            }

            SemiPlanarEncoder {
                handler: Some(
                    neon_rgbx_to_nv_row::<ORIGIN_CHANNELS, UV_ORDER, SAMPLING, PRECISION>,
                ),
            }
        }
        #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
        {
            #[cfg(feature = "avx")]
            {
                let use_avx2 = std::arch::is_x86_feature_detected!("avx2");
                if use_avx2 {
                    use crate::avx2::avx2_rgba_to_nv;
                    return SemiPlanarEncoder {
                        handler: Some(
                            avx2_rgba_to_nv::<ORIGIN_CHANNELS, UV_ORDER, SAMPLING, PRECISION>,
                        ),
                    };
                }
            }
            #[cfg(feature = "sse")]
            {
                let use_sse = std::arch::is_x86_feature_detected!("sse4.1");
                use crate::sse::sse_rgba_to_nv_row;
                if use_sse {
                    return SemiPlanarEncoder {
                        handler: Some(
                            sse_rgba_to_nv_row::<ORIGIN_CHANNELS, UV_ORDER, SAMPLING, PRECISION>,
                        ),
                    };
                }
            }
        }
        #[cfg(not(all(target_arch = "aarch64", target_feature = "neon")))]
        SemiPlanarEncoder { handler: None }
    }
}

#[cfg(feature = "fast_mode")]
impl<const ORIGIN_CHANNELS: u8, const UV_ORDER: u8, const SAMPLING: u8, const PRECISION: i32>
    Default for SemiPlanarEncoderFast<ORIGIN_CHANNELS, UV_ORDER, SAMPLING, PRECISION>
{
    fn default() -> Self {
        if PRECISION == 7 {
            assert_eq!(PRECISION, 7);
            #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
            {
                #[cfg(all(feature = "nightly_i8mm", feature = "fast_mode"))]
                {
                    let cn: YuvSourceChannels = ORIGIN_CHANNELS.into();
                    if std::arch::is_aarch64_feature_detected!("i8mm")
                        && (cn == YuvSourceChannels::Bgra || cn == YuvSourceChannels::Rgba)
                    {
                        use crate::neon::neon_rgba_to_nv_dot_rgba;
                        return SemiPlanarEncoderFast {
                            handler: Some(
                                neon_rgba_to_nv_dot_rgba::<ORIGIN_CHANNELS, UV_ORDER, SAMPLING>,
                            ),
                        };
                    }
                }

                use crate::neon::neon_rgbx_to_nv_fast;
                return SemiPlanarEncoderFast {
                    handler: Some(neon_rgbx_to_nv_fast::<ORIGIN_CHANNELS, UV_ORDER, SAMPLING>),
                };
            }

            #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
            {
                #[cfg(feature = "avx")]
                if std::arch::is_x86_feature_detected!("avx2") {
                    use crate::avx2::avx2_rgba_to_nv_fast_rgba;
                    return SemiPlanarEncoderFast {
                        handler: Some(
                            avx2_rgba_to_nv_fast_rgba::<ORIGIN_CHANNELS, UV_ORDER, SAMPLING>,
                        ),
                    };
                }

                #[cfg(feature = "sse")]
                {
                    if std::arch::is_x86_feature_detected!("sse4.1") {
                        use crate::sse::sse_rgba_to_nv_fast_rgba;
                        return SemiPlanarEncoderFast {
                            handler: Some(
                                sse_rgba_to_nv_fast_rgba::<ORIGIN_CHANNELS, UV_ORDER, SAMPLING>,
                            ),
                        };
                    }
                }
            }
        }

        SemiPlanarEncoderFast { handler: None }
    }
}

#[cfg(feature = "professional_mode")]
impl<const ORIGIN_CHANNELS: u8, const UV_ORDER: u8, const SAMPLING: u8, const PRECISION: i32>
    Default for SemiPlanarEncoderProfessional<ORIGIN_CHANNELS, UV_ORDER, SAMPLING, PRECISION>
{
    fn default() -> Self {
        if PRECISION == 15 {
            assert_eq!(PRECISION, 15);
            #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
            {
                use crate::neon::neon_rgba_to_nv_prof;
                return SemiPlanarEncoderProfessional {
                    handler: Some(neon_rgba_to_nv_prof::<ORIGIN_CHANNELS, UV_ORDER, SAMPLING>),
                };
            }
            #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
            {
                #[cfg(feature = "avx")]
                if std::arch::is_x86_feature_detected!("avx2") {
                    use crate::avx2::avx2_rgba_to_nv_prof;
                    return SemiPlanarEncoderProfessional {
                        handler: Some(
                            avx2_rgba_to_nv_prof::<ORIGIN_CHANNELS, UV_ORDER, SAMPLING, PRECISION>,
                        ),
                    };
                }
                #[cfg(feature = "sse")]
                if std::arch::is_x86_feature_detected!("sse4.1") {
                    use crate::sse::sse_rgba_to_nv_prof;
                    return SemiPlanarEncoderProfessional {
                        handler: Some(
                            sse_rgba_to_nv_prof::<ORIGIN_CHANNELS, UV_ORDER, SAMPLING, PRECISION>,
                        ),
                    };
                }
            }
        }

        SemiPlanarEncoderProfessional { handler: None }
    }
}

macro_rules! define_forward_biplanar_handler {
    ($struct_name:ident) => {
        impl<
                const ORIGIN_CHANNELS: u8,
                const UV_ORDER: u8,
                const SAMPLING: u8,
                const PRECISION: i32,
            > WideRowForwardBiPlanarHandler<u8, i32>
            for $struct_name<ORIGIN_CHANNELS, UV_ORDER, SAMPLING, PRECISION>
        {
            fn handle_row(
                &self,
                rgba: &[u8],
                y_plane: &mut [u8],
                uv_plane: &mut [u8],
                width: u32,
                chroma: YuvChromaRange,
                transform: &CbCrForwardTransform<i32>,
            ) -> ProcessedOffset {
                if let Some(handler) = self.handler {
                    unsafe {
                        return handler(y_plane, uv_plane, rgba, width, &chroma, transform, 0, 0);
                    }
                }
                ProcessedOffset { cx: 0, ux: 0 }
            }
        }
    };
}

define_forward_biplanar_handler!(SemiPlanarEncoder);
#[cfg(feature = "fast_mode")]
define_forward_biplanar_handler!(SemiPlanarEncoderFast);
#[cfg(feature = "professional_mode")]
define_forward_biplanar_handler!(SemiPlanarEncoderProfessional);

fn rgbx_to_nv_impl<
    const ORIGIN_CHANNELS: u8,
    const UV_ORDER: u8,
    const SAMPLING: u8,
    const PRECISION: i32,
>(
    image: &mut YuvBiPlanarImageMut<u8>,
    rgba: &[u8],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    semi_planar_handler: impl WideRowForwardBiPlanarHandler<u8, i32> + Send + Sync,
    semi_planar_handler420: impl WideRowForwardBiPlanar420Handler<u8, i32> + Send + Sync,
) -> Result<(), YuvError> {
    let order: YuvNVOrder = UV_ORDER.into();
    let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();
    let src_chans: YuvSourceChannels = ORIGIN_CHANNELS.into();
    let channels = src_chans.get_channels_count();

    check_rgba_destination(rgba, rgba_stride, image.width, image.height, channels)?;
    image.check_constraints(chroma_subsampling)?;

    let chroma_range = get_yuv_range(8, range);
    let kr_kb = matrix.get_kr_kb();

    let transform = search_forward_transform(PRECISION, 8, range, matrix, chroma_range, kr_kb);

    let rnd_bias: i32 = (1 << (PRECISION - 1)) - 1;
    let bias_y = chroma_range.bias_y as i32 * (1 << PRECISION) + rnd_bias;
    let bias_uv = chroma_range.bias_uv as i32 * (1 << PRECISION) + rnd_bias;

    let width = image.width;

    let process_halved_row = |y_dst: &mut [u8], uv_dst: &mut [u8], rgba: &[u8]| {
        let offset = semi_planar_handler.handle_row(
            rgba,
            y_dst,
            uv_dst,
            image.width,
            chroma_range,
            &transform,
        );
        if offset.cx != image.width as usize {
            for ((y_dst, uv_dst), rgba) in y_dst
                .chunks_exact_mut(2)
                .zip(uv_dst.chunks_exact_mut(2))
                .zip(rgba.chunks_exact(channels * 2))
                .skip(offset.cx / 2)
            {
                let rgba0 = &rgba[0..channels];
                let r0 = rgba0[src_chans.get_r_channel_offset()] as i32;
                let g0 = rgba0[src_chans.get_g_channel_offset()] as i32;
                let b0 = rgba0[src_chans.get_b_channel_offset()] as i32;
                let y_0 = (r0 * transform.yr + g0 * transform.yg + b0 * transform.yb + bias_y)
                    >> PRECISION;
                y_dst[0] = y_0 as u8;

                let rgba1 = &rgba[channels..channels * 2];

                let r1 = rgba1[src_chans.get_r_channel_offset()] as i32;
                let g1 = rgba1[src_chans.get_g_channel_offset()] as i32;
                let b1 = rgba1[src_chans.get_b_channel_offset()] as i32;

                let y_1 = (r1 * transform.yr + g1 * transform.yg + b1 * transform.yb + bias_y)
                    >> PRECISION;
                y_dst[1] = y_1 as u8;

                let r = (r0 + r1 + 1) >> 1;
                let g = (g0 + g1 + 1) >> 1;
                let b = (b0 + b1 + 1) >> 1;

                let cb = (r * transform.cb_r + g * transform.cb_g + b * transform.cb_b + bias_uv)
                    >> PRECISION;
                let cr = (r * transform.cr_r + g * transform.cr_g + b * transform.cr_b + bias_uv)
                    >> PRECISION;
                uv_dst[order.get_u_position()] = cb as u8;
                uv_dst[order.get_v_position()] = cr as u8;
            }

            if width & 1 != 0 {
                let rgba = rgba.chunks_exact(channels * 2).remainder();
                let rgba = &rgba[..channels];
                let uv_dst = uv_dst.chunks_exact_mut(2).last().unwrap();
                let y_dst = y_dst.chunks_exact_mut(2).into_remainder();

                let r0 = rgba[src_chans.get_r_channel_offset()] as i32;
                let g0 = rgba[src_chans.get_g_channel_offset()] as i32;
                let b0 = rgba[src_chans.get_b_channel_offset()] as i32;
                let y_0 = (r0 * transform.yr + g0 * transform.yg + b0 * transform.yb + bias_y)
                    >> PRECISION;
                y_dst[0] = y_0 as u8;

                let cb =
                    (r0 * transform.cb_r + g0 * transform.cb_g + b0 * transform.cb_b + bias_uv)
                        >> PRECISION;
                let cr =
                    (r0 * transform.cr_r + g0 * transform.cr_g + b0 * transform.cr_b + bias_uv)
                        >> PRECISION;
                uv_dst[order.get_u_position()] = cb as u8;
                uv_dst[order.get_v_position()] = cr as u8;
            }
        }
    };

    let process_double_row = |y_dst0: &mut [u8],
                              y_dst1: &mut [u8],
                              uv_dst: &mut [u8],
                              rgba0: &[u8],
                              rgba1: &[u8]| {
        let offset = semi_planar_handler420.handle_rows(
            rgba0,
            rgba1,
            y_dst0,
            y_dst1,
            uv_dst,
            image.width,
            chroma_range,
            &transform,
        );
        if offset.cx != image.width as usize {
            for ((((y_dst0, y_dst1), uv_dst), rgba0), rgba1) in y_dst0
                .chunks_exact_mut(2)
                .zip(y_dst1.chunks_exact_mut(2))
                .zip(uv_dst.chunks_exact_mut(2))
                .zip(rgba0.chunks_exact(channels * 2))
                .zip(rgba1.chunks_exact(channels * 2))
                .skip(offset.cx / 2)
            {
                let rgba00 = &rgba0[..channels];
                let r00 = rgba00[src_chans.get_r_channel_offset()] as i32;
                let g00 = rgba00[src_chans.get_g_channel_offset()] as i32;
                let b00 = rgba00[src_chans.get_b_channel_offset()] as i32;
                let y_00 = (r00 * transform.yr + g00 * transform.yg + b00 * transform.yb + bias_y)
                    >> PRECISION;
                y_dst0[0] = y_00 as u8;

                let rgba01 = &rgba0[channels..channels * 2];

                let r01 = rgba01[src_chans.get_r_channel_offset()] as i32;
                let g01 = rgba01[src_chans.get_g_channel_offset()] as i32;
                let b01 = rgba01[src_chans.get_b_channel_offset()] as i32;

                let y_1 = (r01 * transform.yr + g01 * transform.yg + b01 * transform.yb + bias_y)
                    >> PRECISION;
                y_dst0[1] = y_1 as u8;

                let rgba10 = &rgba1[..channels];
                let r10 = rgba10[src_chans.get_r_channel_offset()] as i32;
                let g10 = rgba10[src_chans.get_g_channel_offset()] as i32;
                let b10 = rgba10[src_chans.get_b_channel_offset()] as i32;
                let y_10 = (r10 * transform.yr + g10 * transform.yg + b10 * transform.yb + bias_y)
                    >> PRECISION;
                y_dst1[0] = y_10 as u8;

                let rgba11 = &rgba1[channels..channels * 2];
                let r11 = rgba11[src_chans.get_r_channel_offset()] as i32;
                let g11 = rgba11[src_chans.get_g_channel_offset()] as i32;
                let b11 = rgba11[src_chans.get_b_channel_offset()] as i32;
                let y_11 = (r11 * transform.yr + g11 * transform.yg + b11 * transform.yb + bias_y)
                    >> PRECISION;
                y_dst1[1] = y_11 as u8;

                let r = (r00 + r01 + r10 + r11 + 2) >> 2;
                let g = (g00 + g01 + g10 + g11 + 2) >> 2;
                let b = (b00 + b01 + b10 + b11 + 2) >> 2;

                let cb = (r * transform.cb_r + g * transform.cb_g + b * transform.cb_b + bias_uv)
                    >> PRECISION;
                let cr = (r * transform.cr_r + g * transform.cr_g + b * transform.cr_b + bias_uv)
                    >> PRECISION;
                uv_dst[order.get_u_position()] = cb as u8;
                uv_dst[order.get_v_position()] = cr as u8;
            }

            if width & 1 != 0 {
                let rgba0 = rgba0.chunks_exact(channels * 2).remainder();
                let rgba0 = &rgba0[..channels];
                let rgba1 = rgba1.chunks_exact(channels * 2).remainder();
                let rgba1 = &rgba1[..channels];
                let uv_dst = uv_dst.chunks_exact_mut(2).last().unwrap();
                let y_dst0 = y_dst0.chunks_exact_mut(2).into_remainder();
                let y_dst1 = y_dst1.chunks_exact_mut(2).into_remainder();

                let r0 = rgba0[src_chans.get_r_channel_offset()] as i32;
                let g0 = rgba0[src_chans.get_g_channel_offset()] as i32;
                let b0 = rgba0[src_chans.get_b_channel_offset()] as i32;
                let y_0 = (r0 * transform.yr + g0 * transform.yg + b0 * transform.yb + bias_y)
                    >> PRECISION;
                y_dst0[0] = y_0 as u8;

                let r1 = rgba1[src_chans.get_r_channel_offset()] as i32;
                let g1 = rgba1[src_chans.get_g_channel_offset()] as i32;
                let b1 = rgba1[src_chans.get_b_channel_offset()] as i32;
                let y_1 = (r1 * transform.yr + g1 * transform.yg + b1 * transform.yb + bias_y)
                    >> PRECISION;
                y_dst1[0] = y_1 as u8;

                let r = (r0 + r1 + 1) >> 1;
                let g = (g0 + g1 + 1) >> 1;
                let b = (b0 + b1 + 1) >> 1;

                let cb = (r * transform.cb_r + g * transform.cb_g + b * transform.cb_b + bias_uv)
                    >> PRECISION;
                let cr = (r * transform.cr_r + g * transform.cr_g + b * transform.cr_b + bias_uv)
                    >> PRECISION;
                uv_dst[order.get_u_position()] = cb as u8;
                uv_dst[order.get_v_position()] = cr as u8;
            }
        }
    };

    let y_plane = image.y_plane.borrow_mut();
    let y_stride = image.y_stride;
    let uv_plane = image.uv_plane.borrow_mut();
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
            let y_dst = &mut y_dst[..image.width as usize];
            let offset = semi_planar_handler.handle_row(
                rgba,
                y_dst,
                uv_dst,
                image.width,
                chroma_range,
                &transform,
            );

            if offset.cx != image.width as usize {
                for ((y_dst, uv_dst), rgba) in y_dst
                    .iter_mut()
                    .zip(uv_dst.chunks_exact_mut(2))
                    .zip(rgba.chunks_exact(channels))
                    .skip(offset.cx)
                {
                    let r0 = rgba[src_chans.get_r_channel_offset()] as i32;
                    let g0 = rgba[src_chans.get_g_channel_offset()] as i32;
                    let b0 = rgba[src_chans.get_b_channel_offset()] as i32;
                    let y_0 = (r0 * transform.yr + g0 * transform.yg + b0 * transform.yb + bias_y)
                        >> PRECISION;
                    *y_dst = y_0 as u8;
                    let cb =
                        (r0 * transform.cb_r + g0 * transform.cb_g + b0 * transform.cb_b + bias_uv)
                            >> PRECISION;
                    let cr =
                        (r0 * transform.cr_r + g0 * transform.cr_g + b0 * transform.cr_b + bias_uv)
                            >> PRECISION;
                    uv_dst[order.get_u_position()] = cb as u8;
                    uv_dst[order.get_v_position()] = cr as u8;
                }
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
                &mut y_dst[..image.width as usize],
                &mut uv_dst[..(image.width as usize).div_ceil(2) * 2],
                &rgba[..image.width as usize * channels],
            );
        });
    } else if chroma_subsampling == YuvChromaSubsampling::Yuv420 {
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
            let (y_dst0, y_dst1) = y_dst.split_at_mut(image.y_stride as usize);
            let (rgba0, rgba1) = rgba.split_at(rgba_stride as usize);
            process_double_row(
                &mut y_dst0[..image.width as usize],
                &mut y_dst1[..image.width as usize],
                &mut uv_dst[..(image.width as usize).div_ceil(2) * 2],
                &rgba0[..image.width as usize * channels],
                &rgba1[..image.width as usize * channels],
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
                &mut y_dst[..image.width as usize],
                &mut uv_dst[..(image.width as usize).div_ceil(2) * 2],
                &rgba[..image.width as usize * channels],
            );
        }
    }

    Ok(())
}

fn rgbx_to_nv<const ORIGIN_CHANNELS: u8, const UV_ORDER: u8, const SAMPLING: u8>(
    image: &mut YuvBiPlanarImageMut<u8>,
    rgba: &[u8],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    _mode: YuvConversionMode,
) -> Result<(), YuvError> {
    #[cfg(any(
        any(target_arch = "x86", target_arch = "x86_64"),
        all(target_arch = "aarch64", target_feature = "neon")
    ))]
    {
        match _mode {
            #[cfg(feature = "fast_mode")]
            YuvConversionMode::Fast => rgbx_to_nv_impl::<ORIGIN_CHANNELS, UV_ORDER, SAMPLING, 7>(
                image,
                rgba,
                rgba_stride,
                range,
                matrix,
                SemiPlanarEncoderFast::<ORIGIN_CHANNELS, UV_ORDER, SAMPLING, 7>::default(),
                SemiPlanar420EncoderFast::<ORIGIN_CHANNELS, UV_ORDER, SAMPLING, 7>::default(),
            ),
            YuvConversionMode::Balanced => {
                rgbx_to_nv_impl::<ORIGIN_CHANNELS, UV_ORDER, SAMPLING, 13>(
                    image,
                    rgba,
                    rgba_stride,
                    range,
                    matrix,
                    SemiPlanarEncoder::<ORIGIN_CHANNELS, UV_ORDER, SAMPLING, 13>::default(),
                    SemiPlanar420Encoder::<ORIGIN_CHANNELS, UV_ORDER, SAMPLING, 13>::default(),
                )
            }
            #[cfg(feature = "professional_mode")]
            YuvConversionMode::Professional => {
                rgbx_to_nv_impl::<ORIGIN_CHANNELS, UV_ORDER, SAMPLING, 15>(
                    image,
                    rgba,
                    rgba_stride,
                    range,
                    matrix,
                    SemiPlanarEncoderProfessional::<ORIGIN_CHANNELS, UV_ORDER, SAMPLING, 15>::default(),
                    SemiPlanar420EncoderProfessional::<ORIGIN_CHANNELS, UV_ORDER, SAMPLING, 15>::default(),
                )
            }
        }
    }
    #[cfg(not(any(
        all(any(target_arch = "x86", target_arch = "x86_64"),),
        all(target_arch = "aarch64", target_feature = "neon",),
    )))]
    {
        rgbx_to_nv_impl::<ORIGIN_CHANNELS, UV_ORDER, SAMPLING, 13>(
            image,
            rgba,
            rgba_stride,
            range,
            matrix,
            SemiPlanarEncoder::<ORIGIN_CHANNELS, UV_ORDER, SAMPLING, 13>::default(),
            SemiPlanar420Encoder::<ORIGIN_CHANNELS, UV_ORDER, SAMPLING, 13>::default(),
        )
    }
}

/// Convert RGB image data to YUV NV16 bi-planar format.
///
/// This function performs RGB to YUV conversion and stores the result in YUV NV16 bi-planar format,
/// with plane for Y (luminance), and bi-plane UV (chrominance) components.
///
/// # Arguments
///
/// * `bi_planar_image` - Target Bi-Planar image
/// * `rgb` - The input RGB image data slice.
/// * `rgb_stride` - The stride (components per row) for the RGB image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input RGB data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn rgb_to_yuv_nv16(
    bi_planar_image: &mut YuvBiPlanarImageMut<u8>,
    rgb: &[u8],
    rgb_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    rgbx_to_nv::<
        { YuvSourceChannels::Rgb as u8 },
        { YuvNVOrder::UV as u8 },
        { YuvChromaSubsampling::Yuv422 as u8 },
    >(bi_planar_image, rgb, rgb_stride, range, matrix, mode)
}

/// Convert RGB image data to YUV NV61 bi-planar format.
///
/// This function performs RGB to YUV conversion and stores the result in YUV NV61 bi-planar format,
/// with plane for Y (luminance), and bi-plane VU (chrominance) components.
///
/// # Arguments
///
/// * `bi_planar_image` - Target Bi-Planar image
/// * `rgb` - The input RGB image data slice.
/// * `rgb_stride` - The stride (components per row) for the RGB image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input RGB data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn rgb_to_yuv_nv61(
    bi_planar_image: &mut YuvBiPlanarImageMut<u8>,
    rgb: &[u8],
    rgb_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    rgbx_to_nv::<
        { YuvSourceChannels::Rgb as u8 },
        { YuvNVOrder::VU as u8 },
        { YuvChromaSubsampling::Yuv422 as u8 },
    >(bi_planar_image, rgb, rgb_stride, range, matrix, mode)
}

/// Convert BGR image data to YUV NV16 bi-planar format.
///
/// This function performs BGR to YUV conversion and stores the result in YUV NV16 bi-planar format,
/// with plane for Y (luminance), and bi-plane UV (chrominance) components.
///
/// # Arguments
///
/// * `bi_planar_image` - Target Bi-Planar image
/// * `rgb` - The input BGR image data slice.
/// * `rgb_stride` - The stride (components per row) for the BGR image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGR data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn bgr_to_yuv_nv16(
    bi_planar_image: &mut YuvBiPlanarImageMut<u8>,
    bgr: &[u8],
    bgr_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    rgbx_to_nv::<
        { YuvSourceChannels::Bgr as u8 },
        { YuvNVOrder::UV as u8 },
        { YuvChromaSubsampling::Yuv422 as u8 },
    >(bi_planar_image, bgr, bgr_stride, range, matrix, mode)
}

/// Convert BGR image data to YUV NV61 bi-planar format.
///
/// This function performs BGR to YUV conversion and stores the result in YUV NV61 bi-planar format,
/// with plane for Y (luminance), and bi-plane VU (chrominance) components.
///
/// # Arguments
///
/// * `bi_planar_image` - Target Bi-Planar image
/// * `rgb` - The input BGR image data slice.
/// * `rgb_stride` - The stride (components per row) for the BGR image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGR data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn bgr_to_yuv_nv61(
    bi_planar_image: &mut YuvBiPlanarImageMut<u8>,
    bgr: &[u8],
    bgr_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    rgbx_to_nv::<
        { YuvSourceChannels::Bgr as u8 },
        { YuvNVOrder::VU as u8 },
        { YuvChromaSubsampling::Yuv422 as u8 },
    >(bi_planar_image, bgr, bgr_stride, range, matrix, mode)
}

/// Convert RGBA image data to YUV NV16 bi-planar format.
///
/// This function performs RGBA to YUV conversion and stores the result in YUV NV16 bi-planar format,
/// with plane for Y (luminance), and bi-plane UV (chrominance) components.
///
/// # Arguments
///
/// * `bi_planar_image` - Target Bi-Planar image
/// * `rgba` - The input RGBA image data slice.
/// * `rgba_stride` - The stride (components per row) for the RGBA image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input RGBA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn rgba_to_yuv_nv16(
    bi_planar_image: &mut YuvBiPlanarImageMut<u8>,
    rgba: &[u8],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    rgbx_to_nv::<
        { YuvSourceChannels::Rgba as u8 },
        { YuvNVOrder::UV as u8 },
        { YuvChromaSubsampling::Yuv422 as u8 },
    >(bi_planar_image, rgba, rgba_stride, range, matrix, mode)
}

/// Convert RGBA image data to YUV NV61 bi-planar format.
///
/// This function performs RGBA to YUV conversion and stores the result in YUV NV61 bi-planar format,
/// with plane for Y (luminance), and bi-plane VU (chrominance) components.
///
/// # Arguments
///
/// * `bi_planar_image` - Target Bi-Planar image
/// * `rgba` - The input RGBA image data slice.
/// * `rgba_stride` - The stride (components per row) for the RGBA image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input RGBA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn rgba_to_yuv_nv61(
    bi_planar_image: &mut YuvBiPlanarImageMut<u8>,
    rgba: &[u8],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    rgbx_to_nv::<
        { YuvSourceChannels::Rgba as u8 },
        { YuvNVOrder::VU as u8 },
        { YuvChromaSubsampling::Yuv422 as u8 },
    >(bi_planar_image, rgba, rgba_stride, range, matrix, mode)
}

/// Convert BGRA image data to YUV NV16 bi-planar format.
///
/// This function performs BGRA to YUV conversion and stores the result in YUV NV16 bi-planar format,
/// with plane for Y (luminance), and bi-plane UV (chrominance) components.
///
/// # Arguments
///
/// * `bi_planar_image` - Target Bi-Planar image
/// * `bgra` - The input BGRA image data slice.
/// * `bgra_stride` - The stride (components per row) for the BGRA image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGRA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn bgra_to_yuv_nv16(
    bi_planar_image: &mut YuvBiPlanarImageMut<u8>,
    bgra: &[u8],
    bgra_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    rgbx_to_nv::<
        { YuvSourceChannels::Bgra as u8 },
        { YuvNVOrder::UV as u8 },
        { YuvChromaSubsampling::Yuv422 as u8 },
    >(bi_planar_image, bgra, bgra_stride, range, matrix, mode)
}

/// Convert BGRA image data to YUV NV61 bi-planar format.
///
/// This function performs BGRA to YUV conversion and stores the result in YUV NV61 bi-planar format,
/// with plane for Y (luminance), and bi-plane VU (chrominance) components.
///
/// # Arguments
///
/// * `bi_planar_image` - Target Bi-Planar image
/// * `bgra` - The input BGRA image data slice.
/// * `bgra_stride` - The stride (components per row) for the BGRA image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGRA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn bgra_to_yuv_nv61(
    bi_planar_image: &mut YuvBiPlanarImageMut<u8>,
    bgra: &[u8],
    bgra_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    rgbx_to_nv::<
        { YuvSourceChannels::Bgra as u8 },
        { YuvNVOrder::VU as u8 },
        { YuvChromaSubsampling::Yuv422 as u8 },
    >(bi_planar_image, bgra, bgra_stride, range, matrix, mode)
}

/// Convert RGB image data to YUV NV12 bi-planar format.
///
/// This function performs RGB to YUV conversion and stores the result in YUV NV12 bi-planar format,
/// with plane for Y (luminance), and bi-plane UV (chrominance) components.
///
/// # Arguments
///
/// * `bi_planar_image` - Target Bi-Planar image
/// * `rgb` - The input RGB image data slice.
/// * `rgb_stride` - The stride (components per row) for the RGB image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input RGB data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn rgb_to_yuv_nv12(
    bi_planar_image: &mut YuvBiPlanarImageMut<u8>,
    rgb: &[u8],
    rgb_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    rgbx_to_nv::<
        { YuvSourceChannels::Rgb as u8 },
        { YuvNVOrder::UV as u8 },
        { YuvChromaSubsampling::Yuv420 as u8 },
    >(bi_planar_image, rgb, rgb_stride, range, matrix, mode)
}

/// Convert RGB image data to YUV NV21 bi-planar format.
///
/// This function performs RGB to YUV conversion and stores the result in YUV NV21 bi-planar format,
/// with plane for Y (luminance), and bi-plane VU (chrominance) components.
///
/// # Arguments
///
/// * `bi_planar_image` - Target Bi-Planar image
/// * `rgb` - The input RGB image data slice.
/// * `rgb_stride` - The stride (components per row) for the RGB image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input RGB data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn rgb_to_yuv_nv21(
    bi_planar_image: &mut YuvBiPlanarImageMut<u8>,
    rgb: &[u8],
    rgb_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    rgbx_to_nv::<
        { YuvSourceChannels::Rgb as u8 },
        { YuvNVOrder::VU as u8 },
        { YuvChromaSubsampling::Yuv420 as u8 },
    >(bi_planar_image, rgb, rgb_stride, range, matrix, mode)
}

/// Convert BGR image data to YUV NV12 bi-planar format.
///
/// This function performs BGR to YUV conversion and stores the result in YUV NV12 bi-planar format,
/// with plane for Y (luminance), and bi-plane UV (chrominance) components.
///
/// # Arguments
///
/// * `bi_planar_image` - Target Bi-Planar image
/// * `bgr` - The input BGR image data slice.
/// * `bgr_stride` - The stride (components per row) for the BGR image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGR data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn bgr_to_yuv_nv12(
    bi_planar_image: &mut YuvBiPlanarImageMut<u8>,
    bgr: &[u8],
    bgr_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    rgbx_to_nv::<
        { YuvSourceChannels::Bgr as u8 },
        { YuvNVOrder::UV as u8 },
        { YuvChromaSubsampling::Yuv420 as u8 },
    >(bi_planar_image, bgr, bgr_stride, range, matrix, mode)
}

/// Convert BGR image data to YUV NV21 bi-planar format.
///
/// This function performs BGR to YUV conversion and stores the result in YUV NV21 bi-planar format,
/// with plane for Y (luminance), and bi-plane VU (chrominance) components.
///
/// # Arguments
///
/// * `bi_planar_image` - Target Bi-Planar image
/// * `bgr` - The input BGR image data slice.
/// * `bgr_stride` - The stride (components per row) for the BGR image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGR data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn bgr_to_yuv_nv21(
    bi_planar_image: &mut YuvBiPlanarImageMut<u8>,
    bgr: &[u8],
    bgr_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    rgbx_to_nv::<
        { YuvSourceChannels::Bgr as u8 },
        { YuvNVOrder::VU as u8 },
        { YuvChromaSubsampling::Yuv420 as u8 },
    >(bi_planar_image, bgr, bgr_stride, range, matrix, mode)
}

/// Convert RGBA image data to YUV NV12 bi-planar format.
///
/// This function performs RGBA to YUV conversion and stores the result in YUV NV12 bi-planar format,
/// with plane for Y (luminance), and bi-plane UV (chrominance) components.
///
/// # Arguments
///
/// * `bi_planar_image` - Target Bi-Planar image
/// * `rgba` - The input RGBA image data slice.
/// * `rgba_stride` - The stride (components per row) for the RGBA image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input RGBA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn rgba_to_yuv_nv12(
    bi_planar_image: &mut YuvBiPlanarImageMut<u8>,
    rgba: &[u8],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    rgbx_to_nv::<
        { YuvSourceChannels::Rgba as u8 },
        { YuvNVOrder::UV as u8 },
        { YuvChromaSubsampling::Yuv420 as u8 },
    >(bi_planar_image, rgba, rgba_stride, range, matrix, mode)
}

/// Convert RGBA image data to YUV NV21 bi-planar format.
///
/// This function performs RGBA to YUV conversion and stores the result in YUV NV21 bi-planar format,
/// with plane for Y (luminance), and bi-plane VU (chrominance) components.
///
/// # Arguments
///
/// * `bi_planar_image` - Target Bi-Planar image
/// * `rgba` - The input RGBA image data slice.
/// * `rgba_stride` - The stride (components per row) for the RGBA image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input RGBA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn rgba_to_yuv_nv21(
    bi_planar_image: &mut YuvBiPlanarImageMut<u8>,
    rgba: &[u8],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    rgbx_to_nv::<
        { YuvSourceChannels::Rgba as u8 },
        { YuvNVOrder::VU as u8 },
        { YuvChromaSubsampling::Yuv420 as u8 },
    >(bi_planar_image, rgba, rgba_stride, range, matrix, mode)
}

/// Convert BGRA image data to YUV NV12 bi-planar format.
///
/// This function performs BGRA to YUV conversion and stores the result in YUV NV12 bi-planar format,
/// with plane for Y (luminance), and bi-plane UV (chrominance) components.
///
/// # Arguments
///
/// * `bi_planar_image` - Target Bi-Planar image
/// * `bgra` - The input BGRA image data slice.
/// * `bgra_stride` - The stride (components per row) for the BGRA image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGRA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn bgra_to_yuv_nv12(
    bi_planar_image: &mut YuvBiPlanarImageMut<u8>,
    bgra: &[u8],
    bgra_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    rgbx_to_nv::<
        { YuvSourceChannels::Bgra as u8 },
        { YuvNVOrder::UV as u8 },
        { YuvChromaSubsampling::Yuv420 as u8 },
    >(bi_planar_image, bgra, bgra_stride, range, matrix, mode)
}

/// Convert BGRA image data to YUV NV21 bi-planar format.
///
/// This function performs BGRA to YUV conversion and stores the result in YUV NV21 bi-planar format,
/// with plane for Y (luminance), and bi-plane VU (chrominance) components.
///
/// # Arguments
///
/// * `bi_planar_image` - Target Bi-Planar image
/// * `bgra` - The input BGRA image data slice.
/// * `bgra_stride` - The stride (components per row) for the BGRA image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGRA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn bgra_to_yuv_nv21(
    bi_planar_image: &mut YuvBiPlanarImageMut<u8>,
    bgra: &[u8],
    bgra_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    rgbx_to_nv::<
        { YuvSourceChannels::Bgra as u8 },
        { YuvNVOrder::VU as u8 },
        { YuvChromaSubsampling::Yuv420 as u8 },
    >(bi_planar_image, bgra, bgra_stride, range, matrix, mode)
}

/// Convert RGB image data to YUV NV24 bi-planar format.
///
/// This function performs RGB to YUV conversion and stores the result in YUV NV24 bi-planar format,
/// with plane for Y (luminance), and bi-plane UV (chrominance) components.
///
/// # Arguments
///
/// * `bi_planar_image` - Target Bi-Planar image
/// * `rgb` - The input RGB image data slice.
/// * `rgb_stride` - The stride (components per row) for the RGB image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input RGB data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn rgb_to_yuv_nv24(
    bi_planar_image: &mut YuvBiPlanarImageMut<u8>,
    rgb: &[u8],
    rgb_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    rgbx_to_nv::<
        { YuvSourceChannels::Rgb as u8 },
        { YuvNVOrder::UV as u8 },
        { YuvChromaSubsampling::Yuv444 as u8 },
    >(bi_planar_image, rgb, rgb_stride, range, matrix, mode)
}

/// Convert RGB image data to YUV NV42 bi-planar format.
///
/// This function performs RGB to YUV conversion and stores the result in YUV NV42 bi-planar format,
/// with plane for Y (luminance), and bi-plane VU (chrominance) components.
///
/// # Arguments
///
/// * `bi_planar_image` - Target Bi-Planar image
/// * `rgb` - The input RGB image data slice.
/// * `rgb_stride` - The stride (components per row) for the RGB image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input RGB data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn rgb_to_yuv_nv42(
    bi_planar_image: &mut YuvBiPlanarImageMut<u8>,
    rgb: &[u8],
    rgb_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    rgbx_to_nv::<
        { YuvSourceChannels::Rgb as u8 },
        { YuvNVOrder::VU as u8 },
        { YuvChromaSubsampling::Yuv444 as u8 },
    >(bi_planar_image, rgb, rgb_stride, range, matrix, mode)
}

/// Convert BGR image data to YUV NV24 bi-planar format.
///
/// This function performs BGR to YUV conversion and stores the result in YUV NV24 bi-planar format,
/// with plane for Y (luminance), and bi-plane UV (chrominance) components.
///
/// # Arguments
///
/// * `bi_planar_image` - Target Bi-Planar image
/// * `bgr` - The input BGR image data slice.
/// * `bgr_stride` - The stride (components per row) for the BGR image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGR data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn bgr_to_yuv_nv24(
    bi_planar_image: &mut YuvBiPlanarImageMut<u8>,
    bgr: &[u8],
    bgr_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    rgbx_to_nv::<
        { YuvSourceChannels::Bgr as u8 },
        { YuvNVOrder::UV as u8 },
        { YuvChromaSubsampling::Yuv444 as u8 },
    >(bi_planar_image, bgr, bgr_stride, range, matrix, mode)
}

/// Convert BGR image data to YUV NV42 bi-planar format.
///
/// This function performs BGR to YUV conversion and stores the result in YUV NV42 bi-planar format,
/// with plane for Y (luminance), and bi-plane VU (chrominance) components.
///
/// # Arguments
///
/// * `bi_planar_image` - Target Bi-Planar image
/// * `bgr` - The input BGR image data slice.
/// * `bgr_stride` - The stride (components per row) for the BGR image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGR data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn bgr_to_yuv_nv42(
    bi_planar_image: &mut YuvBiPlanarImageMut<u8>,
    bgr: &[u8],
    bgr_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    rgbx_to_nv::<
        { YuvSourceChannels::Bgr as u8 },
        { YuvNVOrder::VU as u8 },
        { YuvChromaSubsampling::Yuv444 as u8 },
    >(bi_planar_image, bgr, bgr_stride, range, matrix, mode)
}

/// Convert RGBA image data to YUV NV24 bi-planar format.
///
/// This function performs RGBA to YUV conversion and stores the result in YUV NV24 bi-planar format,
/// with plane for Y (luminance), and bi-plane UV (chrominance) components.
///
/// # Arguments
///
/// * `bi_planar_image` - Target Bi-Planar image
/// * `rgba` - The input RGBA image data slice.
/// * `rgba_stride` - The stride (components per row) for the RGBA image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input RGBA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn rgba_to_yuv_nv24(
    bi_planar_image: &mut YuvBiPlanarImageMut<u8>,
    rgba: &[u8],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    rgbx_to_nv::<
        { YuvSourceChannels::Rgba as u8 },
        { YuvNVOrder::UV as u8 },
        { YuvChromaSubsampling::Yuv444 as u8 },
    >(bi_planar_image, rgba, rgba_stride, range, matrix, mode)
}

/// Convert RGBA image data to YUV NV42 bi-planar format.
///
/// This function performs RGBA to YUV conversion and stores the result in YUV NV42 bi-planar format,
/// with plane for Y (luminance), and bi-plane VU (chrominance) components.
///
/// # Arguments
///
/// * `bi_planar_image` - Target Bi-Planar image
/// * `rgba` - The input RGBA image data slice.
/// * `rgba_stride` - The stride (components per row) for the RGBA image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input RGBA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn rgba_to_yuv_nv42(
    bi_planar_image: &mut YuvBiPlanarImageMut<u8>,
    rgba: &[u8],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    rgbx_to_nv::<
        { YuvSourceChannels::Rgba as u8 },
        { YuvNVOrder::VU as u8 },
        { YuvChromaSubsampling::Yuv444 as u8 },
    >(bi_planar_image, rgba, rgba_stride, range, matrix, mode)
}

/// Convert BGRA image data to YUV NV24 bi-planar format.
///
/// This function performs BGRA to YUV conversion and stores the result in YUV NV24 bi-planar format,
/// with plane for Y (luminance), and bi-plane UV (chrominance) components.
///
/// # Arguments
///
/// * `bi_planar_image` - Target Bi-Planar image
/// * `bgra` - The input BGRA image data slice.
/// * `bgra_stride` - The stride (components per row) for the BGRA image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGRA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn bgra_to_yuv_nv24(
    bi_planar_image: &mut YuvBiPlanarImageMut<u8>,
    bgra: &[u8],
    bgra_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    rgbx_to_nv::<
        { YuvSourceChannels::Bgra as u8 },
        { YuvNVOrder::UV as u8 },
        { YuvChromaSubsampling::Yuv444 as u8 },
    >(bi_planar_image, bgra, bgra_stride, range, matrix, mode)
}

/// Convert BGRA image data to YUV NV42 bi-planar format.
///
/// This function performs BGRA to YUV conversion and stores the result in YUV NV42 bi-planar format,
/// with plane for Y (luminance), and bi-plane VU (chrominance) components.
///
/// # Arguments
///
/// * `bi_planar_image` - Target Bi-Planar image
/// * `bgra` - The input BGRA image data slice.
/// * `bgra_stride` - The stride (components per row) for the BGRA image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGRA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn bgra_to_yuv_nv42(
    bi_planar_image: &mut YuvBiPlanarImageMut<u8>,
    bgra: &[u8],
    bgra_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    rgbx_to_nv::<
        { YuvSourceChannels::Bgra as u8 },
        { YuvNVOrder::VU as u8 },
        { YuvChromaSubsampling::Yuv444 as u8 },
    >(bi_planar_image, bgra, bgra_stride, range, matrix, mode)
}
