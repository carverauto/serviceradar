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
use crate::internals::*;
use crate::numerics::qrshr;
use crate::yuv_error::check_rgba_destination;
use crate::yuv_support::*;
use crate::{YuvBiPlanarImage, YuvError};
#[cfg(feature = "rayon")]
use rayon::iter::{IndexedParallelIterator, ParallelIterator};
#[cfg(feature = "rayon")]
use rayon::prelude::{ParallelSlice, ParallelSliceMut};

type TRowHandler = Option<
    unsafe fn(
        range: &YuvChromaRange,
        transform: &CbCrInverseTransform<i32>,
        y_plane: &[u8],
        uv_plane: &[u8],
        rgba: &mut [u8],
        start_cx: usize,
        start_ux: usize,
        width: usize,
    ) -> ProcessedOffset,
>;

type TRowHandler420 = Option<
    unsafe fn(
        range: &YuvChromaRange,
        transform: &CbCrInverseTransform<i32>,
        y_plane0: &[u8],
        y_plane1: &[u8],
        uv_plane: &[u8],
        rgba0: &mut [u8],
        rgba1: &mut [u8],
        start_cx: usize,
        start_ux: usize,
        width: usize,
    ) -> ProcessedOffset,
>;

struct NVRowHandler<
    const UV_ORDER: u8,
    const DESTINATION_CHANNELS: u8,
    const YUV_CHROMA_SAMPLING: u8,
    const PRECISION: i32,
> {
    handler: TRowHandler,
}

#[cfg(feature = "fast_mode")]
struct NVRowHandlerFast<
    const UV_ORDER: u8,
    const DESTINATION_CHANNELS: u8,
    const YUV_CHROMA_SAMPLING: u8,
    const PRECISION: i32,
> {
    handler: TRowHandler,
}

#[cfg(feature = "professional_mode")]
struct NVRowHandlerProfessional<
    const UV_ORDER: u8,
    const DESTINATION_CHANNELS: u8,
    const YUV_CHROMA_SAMPLING: u8,
    const PRECISION: i32,
> {
    handler: TRowHandler,
}

impl<
        const UV_ORDER: u8,
        const DESTINATION_CHANNELS: u8,
        const YUV_CHROMA_SAMPLING: u8,
        const PRECISION: i32,
    > Default for NVRowHandler<UV_ORDER, DESTINATION_CHANNELS, YUV_CHROMA_SAMPLING, PRECISION>
{
    fn default() -> Self {
        if PRECISION != 13 {
            return NVRowHandler { handler: None };
        }
        assert_eq!(PRECISION, 13);
        #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
        {
            #[cfg(feature = "rdm")]
            {
                use crate::neon::neon_yuv_nv_to_rgba_row_rdm;
                let is_rdm_available = std::arch::is_aarch64_feature_detected!("rdm");
                if is_rdm_available {
                    return NVRowHandler {
                        handler: Some(
                            neon_yuv_nv_to_rgba_row_rdm::<
                                UV_ORDER,
                                DESTINATION_CHANNELS,
                                YUV_CHROMA_SAMPLING,
                            >,
                        ),
                    };
                }
            }
            use crate::neon::neon_yuv_nv_to_rgba_row;

            NVRowHandler {
                handler: Some(
                    neon_yuv_nv_to_rgba_row::<UV_ORDER, DESTINATION_CHANNELS, YUV_CHROMA_SAMPLING>,
                ),
            }
        }
        #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
        {
            #[cfg(feature = "nightly_avx512")]
            {
                let use_avx512 = std::arch::is_x86_feature_detected!("avx512bw");
                let use_vbmi = std::arch::is_x86_feature_detected!("avx512vbmi");
                use crate::avx512bw::{avx512_yuv_nv_to_rgba, avx512_yuv_nv_to_rgba422};
                let subsampling: YuvChromaSubsampling = YUV_CHROMA_SAMPLING.into();
                if use_avx512 {
                    return if subsampling == YuvChromaSubsampling::Yuv422
                        || subsampling == YuvChromaSubsampling::Yuv420
                    {
                        assert!(
                            subsampling == YuvChromaSubsampling::Yuv422
                                || subsampling == YuvChromaSubsampling::Yuv420
                        );
                        NVRowHandler {
                            handler: Some(if use_vbmi {
                                avx512_yuv_nv_to_rgba422::<UV_ORDER, DESTINATION_CHANNELS, true>
                            } else {
                                avx512_yuv_nv_to_rgba422::<UV_ORDER, DESTINATION_CHANNELS, false>
                            }),
                        }
                    } else {
                        NVRowHandler {
                            handler: Some(if use_vbmi {
                                avx512_yuv_nv_to_rgba::<
                                    UV_ORDER,
                                    DESTINATION_CHANNELS,
                                    YUV_CHROMA_SAMPLING,
                                    true,
                                >
                            } else {
                                avx512_yuv_nv_to_rgba::<
                                    UV_ORDER,
                                    DESTINATION_CHANNELS,
                                    YUV_CHROMA_SAMPLING,
                                    false,
                                >
                            }),
                        }
                    };
                }
            }

            #[cfg(feature = "avx")]
            {
                let use_avx2 = std::arch::is_x86_feature_detected!("avx2");
                let subsampling: YuvChromaSubsampling = YUV_CHROMA_SAMPLING.into();
                if use_avx2 {
                    use crate::avx2::{avx2_yuv_nv_to_rgba_row, avx2_yuv_nv_to_rgba_row422};
                    return NVRowHandler {
                        handler: Some(
                            if subsampling == YuvChromaSubsampling::Yuv420
                                || subsampling == YuvChromaSubsampling::Yuv422
                            {
                                avx2_yuv_nv_to_rgba_row422::<UV_ORDER, DESTINATION_CHANNELS>
                            } else {
                                avx2_yuv_nv_to_rgba_row::<
                                    UV_ORDER,
                                    DESTINATION_CHANNELS,
                                    YUV_CHROMA_SAMPLING,
                                >
                            },
                        ),
                    };
                }
            }

            #[cfg(feature = "sse")]
            {
                let subsampling: YuvChromaSubsampling = YUV_CHROMA_SAMPLING.into();
                let use_sse = std::arch::is_x86_feature_detected!("sse4.1");
                if use_sse {
                    use crate::sse::{sse_yuv_nv_to_rgba, sse_yuv_nv_to_rgba422};
                    return NVRowHandler {
                        handler: Some(
                            if subsampling == YuvChromaSubsampling::Yuv420
                                || subsampling == YuvChromaSubsampling::Yuv422
                            {
                                sse_yuv_nv_to_rgba422::<UV_ORDER, DESTINATION_CHANNELS>
                            } else {
                                sse_yuv_nv_to_rgba::<
                                    UV_ORDER,
                                    DESTINATION_CHANNELS,
                                    YUV_CHROMA_SAMPLING,
                                >
                            },
                        ),
                    };
                }
            }
        }
        #[cfg(all(target_arch = "wasm32", target_feature = "simd128"))]
        {
            use crate::wasm32::wasm_yuv_nv_to_rgba_row;
            return NVRowHandler {
                handler: Some(
                    wasm_yuv_nv_to_rgba_row::<UV_ORDER, DESTINATION_CHANNELS, YUV_CHROMA_SAMPLING>,
                ),
            };
        }
        #[cfg(not(any(
            all(target_arch = "aarch64", target_feature = "neon"),
            all(target_arch = "wasm32", target_feature = "simd128")
        )))]
        NVRowHandler { handler: None }
    }
}

#[cfg(feature = "fast_mode")]
impl<
        const UV_ORDER: u8,
        const DESTINATION_CHANNELS: u8,
        const YUV_CHROMA_SAMPLING: u8,
        const PRECISION: i32,
    > Default for NVRowHandlerFast<UV_ORDER, DESTINATION_CHANNELS, YUV_CHROMA_SAMPLING, PRECISION>
{
    fn default() -> Self {
        if PRECISION == 6 {
            assert_eq!(PRECISION, 6);
            #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
            {
                use crate::neon::neon_yuv_nv_to_rgba_fast_row;
                return NVRowHandlerFast {
                    handler: Some(
                        neon_yuv_nv_to_rgba_fast_row::<
                            UV_ORDER,
                            DESTINATION_CHANNELS,
                            YUV_CHROMA_SAMPLING,
                        >,
                    ),
                };
            }

            #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
            {
                #[cfg(feature = "avx")]
                {
                    let use_avx = std::arch::is_x86_feature_detected!("avx2");
                    if use_avx {
                        use crate::avx2::avx_yuv_nv_to_rgba_fast;
                        return NVRowHandlerFast {
                            handler: Some(
                                avx_yuv_nv_to_rgba_fast::<
                                    UV_ORDER,
                                    DESTINATION_CHANNELS,
                                    YUV_CHROMA_SAMPLING,
                                >,
                            ),
                        };
                    }
                }

                #[cfg(feature = "sse")]
                {
                    let use_sse = std::arch::is_x86_feature_detected!("sse4.1");
                    if use_sse {
                        use crate::sse::sse_yuv_nv_to_rgba_fast;
                        return NVRowHandlerFast {
                            handler: Some(
                                sse_yuv_nv_to_rgba_fast::<
                                    UV_ORDER,
                                    DESTINATION_CHANNELS,
                                    YUV_CHROMA_SAMPLING,
                                >,
                            ),
                        };
                    }
                }
            }
        }

        NVRowHandlerFast { handler: None }
    }
}

#[cfg(feature = "professional_mode")]
impl<
        const UV_ORDER: u8,
        const DESTINATION_CHANNELS: u8,
        const YUV_CHROMA_SAMPLING: u8,
        const PRECISION: i32,
    > Default
    for NVRowHandlerProfessional<UV_ORDER, DESTINATION_CHANNELS, YUV_CHROMA_SAMPLING, PRECISION>
{
    fn default() -> Self {
        if PRECISION == 14 {
            assert_eq!(PRECISION, 14);
            #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
            {
                use crate::neon::neon_yuv_nv_to_rgba_row_prof;
                return NVRowHandlerProfessional {
                    handler: Some(
                        neon_yuv_nv_to_rgba_row_prof::<
                            UV_ORDER,
                            DESTINATION_CHANNELS,
                            YUV_CHROMA_SAMPLING,
                        >,
                    ),
                };
            }
            #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
            {
                #[cfg(feature = "avx")]
                {
                    let use_avx = std::arch::is_x86_feature_detected!("avx2");
                    if use_avx {
                        use crate::avx2::avx2_yuv_nv_to_rgba_row_prof;
                        return NVRowHandlerProfessional {
                            handler: Some(
                                avx2_yuv_nv_to_rgba_row_prof::<
                                    UV_ORDER,
                                    DESTINATION_CHANNELS,
                                    YUV_CHROMA_SAMPLING,
                                >,
                            ),
                        };
                    }
                }
                #[cfg(feature = "sse")]
                {
                    let use_sse = std::arch::is_x86_feature_detected!("sse4.1");
                    if use_sse {
                        use crate::sse::sse_yuv_nv_to_rgba_row_prof;
                        return NVRowHandlerProfessional {
                            handler: Some(
                                sse_yuv_nv_to_rgba_row_prof::<
                                    UV_ORDER,
                                    DESTINATION_CHANNELS,
                                    YUV_CHROMA_SAMPLING,
                                >,
                            ),
                        };
                    }
                }
            }
        }

        NVRowHandlerProfessional { handler: None }
    }
}

macro_rules! impl_row_biplanar_inversion_handler {
    ($struct_name:ident) => {
        impl<
                const UV_ORDER: u8,
                const DESTINATION_CHANNELS: u8,
                const YUV_CHROMA_SAMPLING: u8,
                const PRECISION: i32,
            > RowBiPlanarInversionHandler<u8, i32>
            for $struct_name<UV_ORDER, DESTINATION_CHANNELS, YUV_CHROMA_SAMPLING, PRECISION>
        {
            fn handle_row(
                &self,
                y_plane: &[u8],
                uv_plane: &[u8],
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
                            uv_plane,
                            rgba,
                            0,
                            0,
                            width as usize,
                        );
                    }
                }
                ProcessedOffset { ux: 0, cx: 0 }
            }
        }
    };
}

impl_row_biplanar_inversion_handler!(NVRowHandler);
#[cfg(feature = "fast_mode")]
impl_row_biplanar_inversion_handler!(NVRowHandlerFast);
#[cfg(feature = "professional_mode")]
impl_row_biplanar_inversion_handler!(NVRowHandlerProfessional);

struct NVRow420Handler<
    const UV_ORDER: u8,
    const DESTINATION_CHANNELS: u8,
    const YUV_CHROMA_SAMPLING: u8,
    const PRECISION: i32,
> {
    handler: TRowHandler420,
}

#[cfg(feature = "fast_mode")]
struct NVRow420HandlerFast<
    const UV_ORDER: u8,
    const DESTINATION_CHANNELS: u8,
    const YUV_CHROMA_SAMPLING: u8,
    const PRECISION: i32,
> {
    handler: TRowHandler420,
}

#[cfg(feature = "professional_mode")]
struct NVRow420HandlerProfessional<
    const UV_ORDER: u8,
    const DESTINATION_CHANNELS: u8,
    const YUV_CHROMA_SAMPLING: u8,
    const PRECISION: i32,
> {
    handler: TRowHandler420,
}

macro_rules! impl_row_biplanar_inversion_420_handler {
    ($struct_name:ident, $handler_trait:ident) => {
        impl<
                const UV_ORDER: u8,
                const DESTINATION_CHANNELS: u8,
                const YUV_CHROMA_SAMPLING: u8,
                const PRECISION: i32,
            > $handler_trait<u8, i32>
            for $struct_name<UV_ORDER, DESTINATION_CHANNELS, YUV_CHROMA_SAMPLING, PRECISION>
        {
            fn handle_row(
                &self,
                y_plane0: &[u8],
                y_plane1: &[u8],
                uv_plane: &[u8],
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
                            y_plane0,
                            y_plane1,
                            uv_plane,
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

impl_row_biplanar_inversion_420_handler!(NVRow420Handler, RowBiPlanarInversion420Handler);
#[cfg(feature = "fast_mode")]
impl_row_biplanar_inversion_420_handler!(NVRow420HandlerFast, RowBiPlanarInversion420Handler);
#[cfg(feature = "professional_mode")]
impl_row_biplanar_inversion_420_handler!(
    NVRow420HandlerProfessional,
    RowBiPlanarInversion420Handler
);

impl<
        const UV_ORDER: u8,
        const DESTINATION_CHANNELS: u8,
        const YUV_CHROMA_SAMPLING: u8,
        const PRECISION: i32,
    > Default for NVRow420Handler<UV_ORDER, DESTINATION_CHANNELS, YUV_CHROMA_SAMPLING, PRECISION>
{
    fn default() -> Self {
        let sampling: YuvChromaSubsampling = YUV_CHROMA_SAMPLING.into();
        if sampling != YuvChromaSubsampling::Yuv420 {
            return NVRow420Handler { handler: None };
        }
        assert_eq!(sampling, YuvChromaSubsampling::Yuv420);
        if PRECISION != 13 {
            return NVRow420Handler { handler: None };
        }
        assert_eq!(PRECISION, 13);
        #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
        {
            #[cfg(feature = "rdm")]
            {
                use crate::neon::neon_yuv_nv_to_rgba_row_rdm420;
                let is_rdm_available = std::arch::is_aarch64_feature_detected!("rdm");
                if is_rdm_available {
                    return NVRow420Handler {
                        handler: Some(
                            neon_yuv_nv_to_rgba_row_rdm420::<UV_ORDER, DESTINATION_CHANNELS>,
                        ),
                    };
                }
            }

            use crate::neon::neon_yuv_nv_to_rgba_row420;
            NVRow420Handler {
                handler: Some(neon_yuv_nv_to_rgba_row420::<UV_ORDER, DESTINATION_CHANNELS>),
            }
        }
        #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
        {
            #[cfg(feature = "nightly_avx512")]
            {
                let use_avx512 = std::arch::is_x86_feature_detected!("avx512bw");
                let use_vbmi = std::arch::is_x86_feature_detected!("avx512vbmi");
                if use_avx512 {
                    use crate::avx512bw::avx512_yuv_nv_to_rgba420;
                    return NVRow420Handler {
                        handler: Some(if use_vbmi {
                            avx512_yuv_nv_to_rgba420::<UV_ORDER, DESTINATION_CHANNELS, true>
                        } else {
                            avx512_yuv_nv_to_rgba420::<UV_ORDER, DESTINATION_CHANNELS, false>
                        }),
                    };
                }
            }

            #[cfg(feature = "avx")]
            {
                let use_avx2 = std::arch::is_x86_feature_detected!("avx2");
                if use_avx2 {
                    use crate::avx2::avx2_yuv_nv_to_rgba_row420;
                    return NVRow420Handler {
                        handler: Some(avx2_yuv_nv_to_rgba_row420::<UV_ORDER, DESTINATION_CHANNELS>),
                    };
                }
            }

            #[cfg(feature = "sse")]
            {
                let use_sse = std::arch::is_x86_feature_detected!("sse4.1");
                if use_sse {
                    use crate::sse::sse_yuv_nv_to_rgba420;
                    return NVRow420Handler {
                        handler: Some(sse_yuv_nv_to_rgba420::<UV_ORDER, DESTINATION_CHANNELS>),
                    };
                }
            }
        }
        #[cfg(all(target_arch = "wasm32", target_feature = "simd128"))]
        {
            use crate::wasm32::wasm_yuv_nv_to_rgba_row420;
            return NVRow420Handler {
                handler: Some(
                    wasm_yuv_nv_to_rgba_row420::<UV_ORDER, DESTINATION_CHANNELS, YUV_CHROMA_SAMPLING>,
                ),
            };
        }
        #[cfg(not(any(
            all(target_arch = "aarch64", target_feature = "neon"),
            all(target_arch = "wasm32", target_feature = "simd128")
        )))]
        NVRow420Handler { handler: None }
    }
}

#[cfg(feature = "fast_mode")]
impl<
        const UV_ORDER: u8,
        const DESTINATION_CHANNELS: u8,
        const YUV_CHROMA_SAMPLING: u8,
        const PRECISION: i32,
    > Default
    for NVRow420HandlerFast<UV_ORDER, DESTINATION_CHANNELS, YUV_CHROMA_SAMPLING, PRECISION>
{
    fn default() -> Self {
        let sampling: YuvChromaSubsampling = YUV_CHROMA_SAMPLING.into();
        if sampling != YuvChromaSubsampling::Yuv420 {
            return NVRow420HandlerFast { handler: None };
        }
        assert_eq!(sampling, YuvChromaSubsampling::Yuv420);
        if PRECISION == 6 {
            assert_eq!(PRECISION, 6);
            #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
            {
                use crate::neon::neon_yuv_nv_to_rgba_fast_row420;
                return NVRow420HandlerFast {
                    handler: Some(
                        neon_yuv_nv_to_rgba_fast_row420::<UV_ORDER, DESTINATION_CHANNELS>,
                    ),
                };
            }
            #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
            {
                #[cfg(feature = "nightly_avx512")]
                {
                    let use_avx512 = std::arch::is_x86_feature_detected!("avx512bw");
                    let use_vbmi = std::arch::is_x86_feature_detected!("avx512vbmi");
                    if use_avx512 {
                        use crate::avx512bw::avx512_yuv_nv_to_rgba_fast420;
                        return NVRow420HandlerFast {
                            handler: Some(if use_vbmi {
                                avx512_yuv_nv_to_rgba_fast420::<UV_ORDER, DESTINATION_CHANNELS, true>
                            } else {
                                avx512_yuv_nv_to_rgba_fast420::<UV_ORDER, DESTINATION_CHANNELS, false>
                            }),
                        };
                    }
                }

                #[cfg(feature = "avx")]
                {
                    let use_avx = std::arch::is_x86_feature_detected!("avx2");
                    if use_avx {
                        use crate::avx2::avx_yuv_nv_to_rgba_fast420;
                        return NVRow420HandlerFast {
                            handler: Some(
                                avx_yuv_nv_to_rgba_fast420::<UV_ORDER, DESTINATION_CHANNELS>,
                            ),
                        };
                    }
                }

                #[cfg(feature = "sse")]
                {
                    let use_sse = std::arch::is_x86_feature_detected!("sse4.1");
                    if use_sse {
                        use crate::sse::sse_yuv_nv_to_rgba_fast420;
                        return NVRow420HandlerFast {
                            handler: Some(
                                sse_yuv_nv_to_rgba_fast420::<UV_ORDER, DESTINATION_CHANNELS>,
                            ),
                        };
                    }
                }
            }
        }

        NVRow420HandlerFast { handler: None }
    }
}

#[cfg(feature = "professional_mode")]
impl<
        const UV_ORDER: u8,
        const DESTINATION_CHANNELS: u8,
        const YUV_CHROMA_SAMPLING: u8,
        const PRECISION: i32,
    > Default
    for NVRow420HandlerProfessional<UV_ORDER, DESTINATION_CHANNELS, YUV_CHROMA_SAMPLING, PRECISION>
{
    fn default() -> Self {
        let sampling: YuvChromaSubsampling = YUV_CHROMA_SAMPLING.into();
        if sampling != YuvChromaSubsampling::Yuv420 {
            return NVRow420HandlerProfessional { handler: None };
        }
        assert_eq!(sampling, YuvChromaSubsampling::Yuv420);
        if PRECISION == 14 {
            assert_eq!(PRECISION, 14);
            #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
            {
                use crate::neon::neon_yuv_nv_to_rgba_row420_prof;
                return NVRow420HandlerProfessional {
                    handler: Some(
                        neon_yuv_nv_to_rgba_row420_prof::<UV_ORDER, DESTINATION_CHANNELS>,
                    ),
                };
            }
            #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
            {
                #[cfg(feature = "avx")]
                {
                    let use_avx = std::arch::is_x86_feature_detected!("avx2");
                    if use_avx {
                        use crate::avx2::avx2_yuv_nv_to_rgba_row420_prof;
                        return NVRow420HandlerProfessional {
                            handler: Some(
                                avx2_yuv_nv_to_rgba_row420_prof::<UV_ORDER, DESTINATION_CHANNELS>,
                            ),
                        };
                    }
                }
                #[cfg(feature = "sse")]
                {
                    let use_sse = std::arch::is_x86_feature_detected!("sse4.1");
                    if use_sse {
                        use crate::sse::sse_yuv_nv_to_rgba_row420_prof;
                        return NVRow420HandlerProfessional {
                            handler: Some(
                                sse_yuv_nv_to_rgba_row420_prof::<UV_ORDER, DESTINATION_CHANNELS>,
                            ),
                        };
                    }
                }
            }
        }

        NVRow420HandlerProfessional { handler: None }
    }
}

fn yuv_nv12_to_rgbx_impl<
    const UV_ORDER: u8,
    const DESTINATION_CHANNELS: u8,
    const YUV_CHROMA_SAMPLING: u8,
    const PRECISION: i32,
>(
    image: &YuvBiPlanarImage<u8>,
    bgra: &mut [u8],
    bgra_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    row_handler: impl RowBiPlanarInversionHandler<u8, i32> + Sync + Send,
    row_handler420: impl RowBiPlanarInversion420Handler<u8, i32> + Sync + Send,
) -> Result<(), YuvError> {
    let order: YuvNVOrder = UV_ORDER.into();
    let dst_chans: YuvSourceChannels = DESTINATION_CHANNELS.into();
    let chroma_subsampling: YuvChromaSubsampling = YUV_CHROMA_SAMPLING.into();

    image.check_constraints(chroma_subsampling)?;
    check_rgba_destination(
        bgra,
        bgra_stride,
        image.width,
        image.height,
        dst_chans.get_channels_count(),
    )?;

    let chroma_range = get_yuv_range(8, range);
    let channels = dst_chans.get_channels_count();
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

    let width = image.width;

    let process_double_chroma_row =
        |y_src0: &[u8], y_src1: &[u8], uv_src: &[u8], rgba0: &mut [u8], rgba1: &mut [u8]| {
            let processed = row_handler420.handle_row(
                y_src0,
                y_src1,
                uv_src,
                rgba0,
                rgba1,
                width,
                chroma_range,
                &inverse_transform,
            );
            if processed.cx != image.width as usize {
                for ((((rgba0, rgba1), y_src0), y_src1), uv_src) in rgba0
                    .chunks_exact_mut(channels * 2)
                    .zip(rgba1.chunks_exact_mut(channels * 2))
                    .zip(y_src0.chunks_exact(2))
                    .zip(y_src1.chunks_exact(2))
                    .zip(uv_src.chunks_exact(2))
                    .skip(processed.cx / 2)
                {
                    let y_vl00 = y_src0[0] as i32;
                    let cb_value = (uv_src[order.get_u_position()] as i32) - bias_uv;
                    let cr_value = (uv_src[order.get_v_position()] as i32) - bias_uv;

                    let y_value00: i32 = (y_vl00 - bias_y) * y_coef;

                    let g_built_coeff = -g_coef_1 * cr_value - g_coef_2 * cb_value;

                    let r00 = qrshr::<PRECISION, 8>(y_value00 + cr_coef * cr_value);
                    let b00 = qrshr::<PRECISION, 8>(y_value00 + cb_coef * cb_value);
                    let g00 = qrshr::<PRECISION, 8>(y_value00 + g_built_coeff);

                    let rgba00 = &mut rgba0[0..channels];

                    rgba00[dst_chans.get_b_channel_offset()] = b00 as u8;
                    rgba00[dst_chans.get_g_channel_offset()] = g00 as u8;
                    rgba00[dst_chans.get_r_channel_offset()] = r00 as u8;

                    if dst_chans.has_alpha() {
                        rgba00[dst_chans.get_a_channel_offset()] = 255;
                    }

                    let y_vl01 = y_src0[1] as i32;

                    let y_value01: i32 = (y_vl01 - bias_y) * y_coef;

                    let r01 = qrshr::<PRECISION, 8>(y_value01 + cr_coef * cr_value);
                    let b01 = qrshr::<PRECISION, 8>(y_value01 + cb_coef * cb_value);
                    let g01 = qrshr::<PRECISION, 8>(y_value01 + g_built_coeff);

                    let rgba01 = &mut rgba0[channels..channels * 2];

                    rgba01[dst_chans.get_b_channel_offset()] = b01 as u8;
                    rgba01[dst_chans.get_g_channel_offset()] = g01 as u8;
                    rgba01[dst_chans.get_r_channel_offset()] = r01 as u8;

                    if dst_chans.has_alpha() {
                        rgba01[dst_chans.get_a_channel_offset()] = 255;
                    }

                    let y_vl10 = y_src1[0] as i32;

                    let y_value00: i32 = (y_vl10 - bias_y) * y_coef;

                    let r10 = qrshr::<PRECISION, 8>(y_value00 + cr_coef * cr_value);
                    let b10 = qrshr::<PRECISION, 8>(y_value00 + cb_coef * cb_value);
                    let g10 = qrshr::<PRECISION, 8>(y_value00 + g_built_coeff);

                    let rgba10 = &mut rgba1[..channels];

                    rgba10[dst_chans.get_b_channel_offset()] = b10 as u8;
                    rgba10[dst_chans.get_g_channel_offset()] = g10 as u8;
                    rgba10[dst_chans.get_r_channel_offset()] = r10 as u8;

                    if dst_chans.has_alpha() {
                        rgba10[dst_chans.get_a_channel_offset()] = 255;
                    }

                    let y_vl11 = y_src1[1] as i32;

                    let y_value11: i32 = (y_vl11 - bias_y) * y_coef;

                    let r11 = qrshr::<PRECISION, 8>(y_value11 + cr_coef * cr_value);
                    let b11 = qrshr::<PRECISION, 8>(y_value11 + cb_coef * cb_value);
                    let g11 = qrshr::<PRECISION, 8>(y_value11 + g_built_coeff);

                    let rgba11 = &mut rgba1[channels..channels * 2];

                    rgba11[dst_chans.get_b_channel_offset()] = b11 as u8;
                    rgba11[dst_chans.get_g_channel_offset()] = g11 as u8;
                    rgba11[dst_chans.get_r_channel_offset()] = r11 as u8;

                    if dst_chans.has_alpha() {
                        rgba11[dst_chans.get_a_channel_offset()] = 255;
                    }
                }

                if width & 1 != 0 {
                    let rgba0 = rgba0.chunks_exact_mut(channels * 2).into_remainder();
                    let rgba1 = rgba1.chunks_exact_mut(channels * 2).into_remainder();
                    let rgba0 = &mut rgba0[0..channels];
                    let rgba1 = &mut rgba1[0..channels];
                    let uv_src = uv_src.chunks_exact(2).last().unwrap();
                    let y_src0 = y_src0.chunks_exact(2).remainder();
                    let y_src1 = y_src1.chunks_exact(2).remainder();

                    let y_vl0 = y_src0[0] as i32;
                    let y_value0: i32 = (y_vl0 - bias_y) * y_coef;
                    let cb_value = (uv_src[order.get_u_position()] as i32) - bias_uv;
                    let cr_value = (uv_src[order.get_v_position()] as i32) - bias_uv;

                    let g_built_coeff = -g_coef_1 * cr_value - g_coef_2 * cb_value;

                    let r0 = qrshr::<PRECISION, 8>(y_value0 + cr_coef * cr_value);
                    let b0 = qrshr::<PRECISION, 8>(y_value0 + cb_coef * cb_value);
                    let g0 = qrshr::<PRECISION, 8>(y_value0 + g_built_coeff);

                    rgba0[dst_chans.get_b_channel_offset()] = b0 as u8;
                    rgba0[dst_chans.get_g_channel_offset()] = g0 as u8;
                    rgba0[dst_chans.get_r_channel_offset()] = r0 as u8;

                    if dst_chans.has_alpha() {
                        rgba0[dst_chans.get_a_channel_offset()] = 255;
                    }

                    let y_vl1 = y_src1[0] as i32;
                    let y_value1: i32 = (y_vl1 - bias_y) * y_coef;

                    let r1 = qrshr::<PRECISION, 8>(y_value1 + cr_coef * cr_value);
                    let b1 = qrshr::<PRECISION, 8>(y_value1 + cb_coef * cb_value);
                    let g1 = qrshr::<PRECISION, 8>(y_value1 + g_built_coeff);

                    rgba1[dst_chans.get_b_channel_offset()] = b1 as u8;
                    rgba1[dst_chans.get_g_channel_offset()] = g1 as u8;
                    rgba1[dst_chans.get_r_channel_offset()] = r1 as u8;

                    if dst_chans.has_alpha() {
                        rgba1[dst_chans.get_a_channel_offset()] = 255;
                    }
                }
            }
        };

    let process_halved_chroma_row = |y_src: &[u8], uv_src: &[u8], rgba: &mut [u8]| {
        let processed =
            row_handler.handle_row(y_src, uv_src, rgba, width, chroma_range, &inverse_transform);

        if processed.cx != image.width as usize {
            for ((rgba, y_src), uv_src) in rgba
                .chunks_exact_mut(channels * 2)
                .zip(y_src.chunks_exact(2))
                .zip(uv_src.chunks_exact(2))
                .skip(processed.cx / 2)
            {
                let y_vl0 = y_src[0] as i32;
                let cb_value = (uv_src[order.get_u_position()] as i32) - bias_uv;
                let cr_value = (uv_src[order.get_v_position()] as i32) - bias_uv;

                let y_value0: i32 = (y_vl0 - bias_y) * y_coef;

                let r0 = qrshr::<PRECISION, 8>(y_value0 + cr_coef * cr_value);
                let b0 = qrshr::<PRECISION, 8>(y_value0 + cb_coef * cb_value);
                let g0 =
                    qrshr::<PRECISION, 8>(y_value0 - g_coef_1 * cr_value - g_coef_2 * cb_value);

                rgba[dst_chans.get_b_channel_offset()] = b0 as u8;
                rgba[dst_chans.get_g_channel_offset()] = g0 as u8;
                rgba[dst_chans.get_r_channel_offset()] = r0 as u8;

                if dst_chans.has_alpha() {
                    rgba[dst_chans.get_a_channel_offset()] = 255;
                }

                let y_vl1 = y_src[1] as i32;

                let y_value1: i32 = (y_vl1 - bias_y) * y_coef;

                let r1 = qrshr::<PRECISION, 8>(y_value1 + cr_coef * cr_value);
                let b1 = qrshr::<PRECISION, 8>(y_value1 + cb_coef * cb_value);
                let g1 =
                    qrshr::<PRECISION, 8>(y_value1 - g_coef_1 * cr_value - g_coef_2 * cb_value);

                let rgba0 = &mut rgba[channels..channels * 2];

                rgba0[dst_chans.get_b_channel_offset()] = b1 as u8;
                rgba0[dst_chans.get_g_channel_offset()] = g1 as u8;
                rgba0[dst_chans.get_r_channel_offset()] = r1 as u8;

                if dst_chans.has_alpha() {
                    rgba0[dst_chans.get_a_channel_offset()] = 255;
                }
            }

            if width & 1 != 0 {
                let rgba = rgba.chunks_exact_mut(channels * 2).into_remainder();
                let rgba = &mut rgba[0..channels];
                let uv_src = uv_src.chunks_exact(2).last().unwrap();
                let y_src = y_src.chunks_exact(2).remainder();

                let y_vl0 = y_src[0] as i32;
                let y_value0: i32 = (y_vl0 - bias_y) * y_coef;
                let cb_value = (uv_src[order.get_u_position()] as i32) - bias_uv;
                let cr_value = (uv_src[order.get_v_position()] as i32) - bias_uv;

                let r0 = qrshr::<PRECISION, 8>(y_value0 + cr_coef * cr_value);
                let b0 = qrshr::<PRECISION, 8>(y_value0 + cb_coef * cb_value);
                let g0 =
                    qrshr::<PRECISION, 8>(y_value0 - g_coef_1 * cr_value - g_coef_2 * cb_value);

                rgba[dst_chans.get_b_channel_offset()] = b0 as u8;
                rgba[dst_chans.get_g_channel_offset()] = g0 as u8;
                rgba[dst_chans.get_r_channel_offset()] = r0 as u8;

                if dst_chans.has_alpha() {
                    rgba[dst_chans.get_a_channel_offset()] = 255;
                }
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
            let processed = row_handler.handle_row(
                y_src,
                uv_src,
                rgba,
                width,
                chroma_range,
                &inverse_transform,
            );

            for ((rgba, &y_src), uv_src) in rgba
                .chunks_exact_mut(channels)
                .zip(y_src.iter())
                .zip(uv_src.chunks_exact(2))
                .skip(processed.cx)
            {
                let y_vl = y_src as i32;
                let mut cb_value = uv_src[order.get_u_position()] as i32;
                let mut cr_value = uv_src[order.get_v_position()] as i32;

                let y_value: i32 = (y_vl - bias_y) * y_coef;

                cb_value -= bias_uv;
                cr_value -= bias_uv;

                let r = qrshr::<PRECISION, 8>(y_value + cr_coef * cr_value);
                let b = qrshr::<PRECISION, 8>(y_value + cb_coef * cb_value);
                let g = qrshr::<PRECISION, 8>(y_value - g_coef_1 * cr_value - g_coef_2 * cb_value);

                rgba[dst_chans.get_b_channel_offset()] = b as u8;
                rgba[dst_chans.get_g_channel_offset()] = g as u8;
                rgba[dst_chans.get_r_channel_offset()] = r as u8;

                if dst_chans.has_alpha() {
                    rgba[dst_chans.get_a_channel_offset()] = 255;
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
                &y_src[0..image.width as usize],
                &uv_src[0..(image.width as usize).div_ceil(2) * 2],
                &mut rgba[0..image.width as usize * channels],
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
            let (y_src0, y_src1) = y_src.split_at(y_stride as usize);
            let (rgba0, rgba1) = rgba.split_at_mut(bgra_stride as usize);
            process_double_chroma_row(
                &y_src0[..image.width as usize],
                &y_src1[..image.width as usize],
                &uv_src[..(image.width as usize).div_ceil(2) * 2],
                &mut rgba0[..image.width as usize * channels],
                &mut rgba1[..image.width as usize * channels],
            );
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

fn yuv_nv12_to_rgbx<
    const UV_ORDER: u8,
    const DESTINATION_CHANNELS: u8,
    const YUV_CHROMA_SAMPLING: u8,
>(
    image: &YuvBiPlanarImage<u8>,
    bgra: &mut [u8],
    bgra_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    _mode: YuvConversionMode,
) -> Result<(), YuvError> {
    match _mode {
        #[cfg(feature = "fast_mode")]
        YuvConversionMode::Fast => {
            yuv_nv12_to_rgbx_impl::<UV_ORDER, DESTINATION_CHANNELS, YUV_CHROMA_SAMPLING, 6>(
                image,
                bgra,
                bgra_stride,
                range,
                matrix,
                NVRowHandlerFast::<UV_ORDER, DESTINATION_CHANNELS, YUV_CHROMA_SAMPLING, 6>::default(
                ),
                NVRow420HandlerFast::<UV_ORDER, DESTINATION_CHANNELS, YUV_CHROMA_SAMPLING, 6>::default(
                ),
            )
        }
        YuvConversionMode::Balanced => {
            yuv_nv12_to_rgbx_impl::<UV_ORDER, DESTINATION_CHANNELS, YUV_CHROMA_SAMPLING, 13>(
                image,
                bgra,
                bgra_stride,
                range,
                matrix,
                NVRowHandler::<UV_ORDER, DESTINATION_CHANNELS, YUV_CHROMA_SAMPLING, 13>::default(),
                NVRow420Handler::<UV_ORDER, DESTINATION_CHANNELS, YUV_CHROMA_SAMPLING, 13>::default(
                ),
            )
        }
        #[cfg(feature = "professional_mode")]
        YuvConversionMode::Professional => {
            yuv_nv12_to_rgbx_impl::<UV_ORDER, DESTINATION_CHANNELS, YUV_CHROMA_SAMPLING, 14>(
                image,
                bgra,
                bgra_stride,
                range,
                matrix,
                NVRowHandlerProfessional::<UV_ORDER, DESTINATION_CHANNELS, YUV_CHROMA_SAMPLING, 14>::default(),
                NVRow420HandlerProfessional::<
                    UV_ORDER,
                    DESTINATION_CHANNELS,
                    YUV_CHROMA_SAMPLING,
                    14,
                >::default(),
            )
        }
    }
}

/// Convert YUV NV12 format to BGRA format.
///
/// This function takes YUV NV12 data with 8-bit precision,
/// and converts it to BGRA format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `bi_planar_image` - Source Bi-Planar image.
/// * `bgra` - A mutable slice to store the converted BGRA data.
/// * `bgra_stride` - The stride (components per row) for the BGRA image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGRA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv_nv12_to_bgra(
    bi_planar_image: &YuvBiPlanarImage<u8>,
    bgra: &mut [u8],
    bgra_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    yuv_nv12_to_rgbx::<
        { YuvNVOrder::UV as u8 },
        { YuvSourceChannels::Bgra as u8 },
        { YuvChromaSubsampling::Yuv420 as u8 },
    >(bi_planar_image, bgra, bgra_stride, range, matrix, mode)
}

/// Convert YUV NV16 format to BGRA format.
///
/// This function takes YUV NV16 data with 8-bit precision,
/// and converts it to BGRA format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `bi_planar_image` - Source Bi-Planar image.
/// * `bgra` - A mutable slice to store the converted BGRA data.
/// * `bgra_stride` - The stride (components per row) for the BGRA image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGRA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv_nv16_to_bgra(
    bi_planar_image: &YuvBiPlanarImage<u8>,
    bgra: &mut [u8],
    bgra_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    yuv_nv12_to_rgbx::<
        { YuvNVOrder::UV as u8 },
        { YuvSourceChannels::Bgra as u8 },
        { YuvChromaSubsampling::Yuv422 as u8 },
    >(bi_planar_image, bgra, bgra_stride, range, matrix, mode)
}

/// Convert YUV NV61 format to BGRA format.
///
/// This function takes YUV NV61 data with 8-bit precision,
/// and converts it to BGRA format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `bi_planar_image` - Source Bi-Planar image.
/// * `bgra` - A mutable slice to store the converted BGRA data.
/// * `bgra_stride` - The stride (components per row) for the BGRA image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGRA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv_nv61_to_bgra(
    bi_planar_image: &YuvBiPlanarImage<u8>,
    bgra: &mut [u8],
    bgra_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    yuv_nv12_to_rgbx::<
        { YuvNVOrder::VU as u8 },
        { YuvSourceChannels::Bgra as u8 },
        { YuvChromaSubsampling::Yuv422 as u8 },
    >(bi_planar_image, bgra, bgra_stride, range, matrix, mode)
}

/// Convert YUV NV21 format to BGRA format.
///
/// This function takes YUV NV12 data with 8-bit precision,
/// and converts it to BGRA format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `bi_planar_image` - Source Bi-Planar image.
/// * `bgra` - A mutable slice to store the converted BGRA data.
/// * `bgra_stride` - The stride (components per row) for the BGRA image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGRA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv_nv21_to_bgra(
    bi_planar_image: &YuvBiPlanarImage<u8>,
    bgra: &mut [u8],
    bgra_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    yuv_nv12_to_rgbx::<
        { YuvNVOrder::VU as u8 },
        { YuvSourceChannels::Bgra as u8 },
        { YuvChromaSubsampling::Yuv420 as u8 },
    >(bi_planar_image, bgra, bgra_stride, range, matrix, mode)
}

/// Convert YUV NV16 format to RGBA format.
///
/// This function takes YUV NV16 data with 8-bit precision,
/// and converts it to RGBA format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `bi_planar_image` - Source Bi-Planar image.
/// * `rgba` - A mutable slice to store the converted RGBA data.
/// * `rgba_stride` - The stride (components per row) for the RGBA image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGRA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv_nv16_to_rgba(
    bi_planar_image: &YuvBiPlanarImage<u8>,
    rgba: &mut [u8],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    yuv_nv12_to_rgbx::<
        { YuvNVOrder::UV as u8 },
        { YuvSourceChannels::Rgba as u8 },
        { YuvChromaSubsampling::Yuv422 as u8 },
    >(bi_planar_image, rgba, rgba_stride, range, matrix, mode)
}

/// Convert YUV NV61 format to RGBA format.
///
/// This function takes YUV NV61 data with 8-bit precision,
/// and converts it to RGBA format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `bi_planar_image` - Source Bi-Planar image.
/// * `rgba` - A mutable slice to store the converted RGBA data.
/// * `rgba_stride` - The stride (components per row) for the RGBA image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input RGBA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv_nv61_to_rgba(
    bi_planar_image: &YuvBiPlanarImage<u8>,
    rgba: &mut [u8],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    yuv_nv12_to_rgbx::<
        { YuvNVOrder::VU as u8 },
        { YuvSourceChannels::Rgba as u8 },
        { YuvChromaSubsampling::Yuv422 as u8 },
    >(bi_planar_image, rgba, rgba_stride, range, matrix, mode)
}

/// Convert YUV NV12 format to RGBA format.
///
/// This function takes YUV NV12 data with 8-bit precision,
/// and converts it to RGBA format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `bi_planar_image` - Source Bi-Planar image.
/// * `rgba` - A mutable slice to store the converted RGBA data.
/// * `rgba_stride` - The stride (components per row) for the RGBA image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input RGBA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv_nv12_to_rgba(
    bi_planar_image: &YuvBiPlanarImage<u8>,
    rgba: &mut [u8],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    yuv_nv12_to_rgbx::<
        { YuvNVOrder::UV as u8 },
        { YuvSourceChannels::Rgba as u8 },
        { YuvChromaSubsampling::Yuv420 as u8 },
    >(bi_planar_image, rgba, rgba_stride, range, matrix, mode)
}

/// Convert YUV NV21 format to RGBA format.
///
/// This function takes YUV NV21 data with 8-bit precision,
/// and converts it to RGBA format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `bi_planar_image` - Source Bi-Planar image.
/// * `rgba` - A mutable slice to store the converted RGBA data.
/// * `rgba_stride` - The stride (components per row) for the RGBA image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input RGBA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv_nv21_to_rgba(
    bi_planar_image: &YuvBiPlanarImage<u8>,
    rgba: &mut [u8],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    yuv_nv12_to_rgbx::<
        { YuvNVOrder::VU as u8 },
        { YuvSourceChannels::Rgba as u8 },
        { YuvChromaSubsampling::Yuv420 as u8 },
    >(bi_planar_image, rgba, rgba_stride, range, matrix, mode)
}

/// Convert YUV NV12 format to RGB format.
///
/// This function takes YUV NV12 data with 8-bit precision,
/// and converts it to RGB format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `bi_planar_image` - Source Bi-Planar image.
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
pub fn yuv_nv12_to_rgb(
    bi_planar_image: &YuvBiPlanarImage<u8>,
    rgb: &mut [u8],
    rgb_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    yuv_nv12_to_rgbx::<
        { YuvNVOrder::UV as u8 },
        { YuvSourceChannels::Rgb as u8 },
        { YuvChromaSubsampling::Yuv420 as u8 },
    >(bi_planar_image, rgb, rgb_stride, range, matrix, mode)
}

/// Convert YUV NV12 format to BGR format.
///
/// This function takes YUV NV12 data with 8-bit precision,
/// and converts it to BGR format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `bi_planar_image` - Source Bi-Planar image.
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
pub fn yuv_nv12_to_bgr(
    bi_planar_image: &YuvBiPlanarImage<u8>,
    bgr: &mut [u8],
    bgr_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    yuv_nv12_to_rgbx::<
        { YuvNVOrder::UV as u8 },
        { YuvSourceChannels::Bgr as u8 },
        { YuvChromaSubsampling::Yuv420 as u8 },
    >(bi_planar_image, bgr, bgr_stride, range, matrix, mode)
}

/// Convert YUV NV16 format to RGB format.
///
/// This function takes YUV NV16 data with 8-bit precision,
/// and converts it to RGB format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `bi_planar_image` - Source Bi-Planar image.
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
pub fn yuv_nv16_to_rgb(
    bi_planar_image: &YuvBiPlanarImage<u8>,
    rgb: &mut [u8],
    rgb_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    yuv_nv12_to_rgbx::<
        { YuvNVOrder::UV as u8 },
        { YuvSourceChannels::Rgb as u8 },
        { YuvChromaSubsampling::Yuv422 as u8 },
    >(bi_planar_image, rgb, rgb_stride, range, matrix, mode)
}

/// Convert YUV NV16 format to BGR format.
///
/// This function takes YUV NV16 data with 8-bit precision,
/// and converts it to BGR format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `bi_planar_image` - Source Bi-Planar image.
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
pub fn yuv_nv16_to_bgr(
    bi_planar_image: &YuvBiPlanarImage<u8>,
    bgr: &mut [u8],
    bgr_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    yuv_nv12_to_rgbx::<
        { YuvNVOrder::UV as u8 },
        { YuvSourceChannels::Bgr as u8 },
        { YuvChromaSubsampling::Yuv422 as u8 },
    >(bi_planar_image, bgr, bgr_stride, range, matrix, mode)
}

/// Convert YUV NV61 format to RGB format.
///
/// This function takes YUV NV61 data with 8-bit precision,
/// and converts it to RGB format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `bi_planar_image` - Source Bi-Planar image.
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
pub fn yuv_nv61_to_rgb(
    bi_planar_image: &YuvBiPlanarImage<u8>,
    rgb: &mut [u8],
    rgb_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    yuv_nv12_to_rgbx::<
        { YuvNVOrder::VU as u8 },
        { YuvSourceChannels::Rgb as u8 },
        { YuvChromaSubsampling::Yuv422 as u8 },
    >(bi_planar_image, rgb, rgb_stride, range, matrix, mode)
}

/// Convert YUV NV61 format to BGR format.
///
/// This function takes YUV NV61 data with 8-bit precision,
/// and converts it to BGR format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `bi_planar_image` - Source Bi-Planar image.
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
pub fn yuv_nv61_to_bgr(
    bi_planar_image: &YuvBiPlanarImage<u8>,
    bgr: &mut [u8],
    bgr_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    yuv_nv12_to_rgbx::<
        { YuvNVOrder::VU as u8 },
        { YuvSourceChannels::Bgr as u8 },
        { YuvChromaSubsampling::Yuv422 as u8 },
    >(bi_planar_image, bgr, bgr_stride, range, matrix, mode)
}

/// Convert YUV NV21 format to RGB format.
///
/// This function takes YUV NV21 data with 8-bit precision,
/// and converts it to RGB format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `bi_planar_image` - Source Bi-Planar image.
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
pub fn yuv_nv21_to_rgb(
    bi_planar_image: &YuvBiPlanarImage<u8>,
    rgb: &mut [u8],
    rgb_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    yuv_nv12_to_rgbx::<
        { YuvNVOrder::VU as u8 },
        { YuvSourceChannels::Rgb as u8 },
        { YuvChromaSubsampling::Yuv420 as u8 },
    >(bi_planar_image, rgb, rgb_stride, range, matrix, mode)
}

/// Convert YUV NV21 format to BGR format.
///
/// This function takes YUV NV21 data with 8-bit precision,
/// and converts it to BGR format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `bi_planar_image` - Source Bi-Planar image.
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
pub fn yuv_nv21_to_bgr(
    bi_planar_image: &YuvBiPlanarImage<u8>,
    bgr: &mut [u8],
    bgr_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    yuv_nv12_to_rgbx::<
        { YuvNVOrder::VU as u8 },
        { YuvSourceChannels::Bgr as u8 },
        { YuvChromaSubsampling::Yuv420 as u8 },
    >(bi_planar_image, bgr, bgr_stride, range, matrix, mode)
}

/// Convert YUV NV24 format to RGBA format.
///
/// This function takes YUV NV24 data with 8-bit precision,
/// and converts it to RGBA format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `bi_planar_image` - Source Bi-Planar image.
/// * `rgba` - A mutable slice to store the converted RGBA data.
/// * `rgba_stride` - The stride (components per row) for the RGBA image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGRA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv_nv42_to_rgba(
    bi_planar_image: &YuvBiPlanarImage<u8>,
    rgba: &mut [u8],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    yuv_nv12_to_rgbx::<
        { YuvNVOrder::VU as u8 },
        { YuvSourceChannels::Rgba as u8 },
        { YuvChromaSubsampling::Yuv444 as u8 },
    >(bi_planar_image, rgba, rgba_stride, range, matrix, mode)
}

/// Convert YUV NV24 format to RGB format.
///
/// This function takes YUV NV24 data with 8-bit precision,
/// and converts it to RGB format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `bi_planar_image` - Source Bi-Planar image.
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
pub fn yuv_nv24_to_rgb(
    bi_planar_image: &YuvBiPlanarImage<u8>,
    rgb: &mut [u8],
    rgb_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    yuv_nv12_to_rgbx::<
        { YuvNVOrder::UV as u8 },
        { YuvSourceChannels::Rgb as u8 },
        { YuvChromaSubsampling::Yuv444 as u8 },
    >(bi_planar_image, rgb, rgb_stride, range, matrix, mode)
}

/// Convert YUV NV24 format to BGR format.
///
/// This function takes YUV NV24 data with 8-bit precision,
/// and converts it to BGR format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `bi_planar_image` - Source Bi-Planar image.
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
pub fn yuv_nv24_to_bgr(
    bi_planar_image: &YuvBiPlanarImage<u8>,
    bgr: &mut [u8],
    bgr_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    yuv_nv12_to_rgbx::<
        { YuvNVOrder::UV as u8 },
        { YuvSourceChannels::Bgr as u8 },
        { YuvChromaSubsampling::Yuv444 as u8 },
    >(bi_planar_image, bgr, bgr_stride, range, matrix, mode)
}

/// Convert YUV NV24 format to RGBA format.
///
/// This function takes YUV NV24 data with 8-bit precision,
/// and converts it to RGBA format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `bi_planar_image` - Source Bi-Planar image.
/// * `rgba` - A mutable slice to store the converted RGBA data.
/// * `rgba_stride` - The stride (components per row) for the RGBA image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input RGBA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv_nv24_to_rgba(
    bi_planar_image: &YuvBiPlanarImage<u8>,
    rgb: &mut [u8],
    rgb_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    yuv_nv12_to_rgbx::<
        { YuvNVOrder::UV as u8 },
        { YuvSourceChannels::Rgba as u8 },
        { YuvChromaSubsampling::Yuv444 as u8 },
    >(bi_planar_image, rgb, rgb_stride, range, matrix, mode)
}

/// Convert YUV NV24 format to BGRA format.
///
/// This function takes YUV NV24 data with 8-bit precision,
/// and converts it to RGBA format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `bi_planar_image` - Source Bi-Planar image.
/// * `bgra` - A mutable slice to store the converted BGRA data.
/// * `bgra_stride` - The stride (components per row) for the BGRA image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGRA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv_nv24_to_bgra(
    bi_planar_image: &YuvBiPlanarImage<u8>,
    rgb: &mut [u8],
    rgb_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    yuv_nv12_to_rgbx::<
        { YuvNVOrder::UV as u8 },
        { YuvSourceChannels::Bgra as u8 },
        { YuvChromaSubsampling::Yuv444 as u8 },
    >(bi_planar_image, rgb, rgb_stride, range, matrix, mode)
}

/// Convert YUV NV42 format to RGB format.
///
/// This function takes YUV NV42 data with 8-bit precision,
/// and converts it to RGB format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `bi_planar_image` - Source Bi-Planar image.
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
pub fn yuv_nv42_to_rgb(
    bi_planar_image: &YuvBiPlanarImage<u8>,
    rgb: &mut [u8],
    rgb_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    yuv_nv12_to_rgbx::<
        { YuvNVOrder::VU as u8 },
        { YuvSourceChannels::Rgb as u8 },
        { YuvChromaSubsampling::Yuv444 as u8 },
    >(bi_planar_image, rgb, rgb_stride, range, matrix, mode)
}

/// Convert YUV NV42 format to BGR format.
///
/// This function takes YUV NV42 data with 8-bit precision,
/// and converts it to BGR format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `bi_planar_image` - Source Bi-Planar image.
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
pub fn yuv_nv42_to_bgr(
    bi_planar_image: &YuvBiPlanarImage<u8>,
    bgr: &mut [u8],
    bgr_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    yuv_nv12_to_rgbx::<
        { YuvNVOrder::VU as u8 },
        { YuvSourceChannels::Bgr as u8 },
        { YuvChromaSubsampling::Yuv444 as u8 },
    >(bi_planar_image, bgr, bgr_stride, range, matrix, mode)
}

/// Convert YUV NV42 format to BGRA format.
///
/// This function takes YUV NV42 data with 8-bit precision,
/// and converts it to RGB format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `bi_planar_image` - Source Bi-Planar image.
/// * `bgra` - A mutable slice to store the converted BGRA data.
/// * `bgra_stride` - The stride (components per row) for the BGRA image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGRA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv_nv42_to_bgra(
    bi_planar_image: &YuvBiPlanarImage<u8>,
    rgb: &mut [u8],
    rgb_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    yuv_nv12_to_rgbx::<
        { YuvNVOrder::VU as u8 },
        { YuvSourceChannels::Bgra as u8 },
        { YuvChromaSubsampling::Yuv444 as u8 },
    >(bi_planar_image, rgb, rgb_stride, range, matrix, mode)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{rgb_to_yuv_nv12, rgb_to_yuv_nv16, rgb_to_yuv_nv24, YuvBiPlanarImageMut};
    use rand::RngExt;

    #[test]
    fn test_yuv444_nv_round_trip_full_range() {
        fn matrix(mode: YuvConversionMode, max_diff: i32) {
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

            let mut image_rgb = vec![0u8; image_width * image_height * 3];

            let or = rand::rng().random_range(0..256) as u8;
            let og = rand::rng().random_range(0..256) as u8;
            let ob = rand::rng().random_range(0..256) as u8;

            for point in &pixel_points {
                image_rgb[point[0] * CHANNELS + point[1] * image_width * CHANNELS] = or;
                image_rgb[point[0] * CHANNELS + point[1] * image_width * CHANNELS + 1] = og;
                image_rgb[point[0] * CHANNELS + point[1] * image_width * CHANNELS + 2] = ob;
            }

            let mut planar_image = YuvBiPlanarImageMut::<u8>::alloc(
                image_width as u32,
                image_height as u32,
                YuvChromaSubsampling::Yuv444,
            );

            rgb_to_yuv_nv24(
                &mut planar_image,
                &image_rgb,
                image_width as u32 * CHANNELS as u32,
                YuvRange::Full,
                YuvStandardMatrix::Bt709,
                mode,
            )
            .unwrap();

            image_rgb.fill(0);

            let fixed_planar = planar_image.to_fixed();

            yuv_nv24_to_rgb(
                &fixed_planar,
                &mut image_rgb,
                image_width as u32 * CHANNELS as u32,
                YuvRange::Full,
                YuvStandardMatrix::Bt709,
                mode,
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
                    diff_r <= max_diff,
                    "Matrix {}, Original RGB {:?}, Round-tripped RGB {:?}, diff {}",
                    mode,
                    [or, og, ob],
                    [r, g, b],
                    diff_r,
                );
                assert!(
                    diff_g <= max_diff,
                    "Matrix {}, Original RGB {:?}, Round-tripped RGB {:?}, diff {}",
                    mode,
                    [or, og, ob],
                    [r, g, b],
                    diff_g
                );
                assert!(
                    diff_b <= max_diff,
                    "Matrix {}, Original RGB {:?}, Round-tripped RGB {:?}, diff {}",
                    mode,
                    [or, og, ob],
                    [r, g, b],
                    diff_b
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
    fn test_yuv444_nv_round_trip_limited_range() {
        fn matrix(mode: YuvConversionMode, max_diff: i32) {
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

            const CHANNELS: usize = 3;

            let mut image_rgb = vec![0u8; image_width * image_height * CHANNELS];

            let or = rand::rng().random_range(0..256) as u8;
            let og = rand::rng().random_range(0..256) as u8;
            let ob = rand::rng().random_range(0..256) as u8;

            for point in &pixel_points {
                image_rgb[point[0] * CHANNELS + point[1] * image_width * CHANNELS] = or;
                image_rgb[point[0] * CHANNELS + point[1] * image_width * CHANNELS + 1] = og;
                image_rgb[point[0] * CHANNELS + point[1] * image_width * CHANNELS + 2] = ob;
            }

            let mut planar_image = YuvBiPlanarImageMut::<u8>::alloc(
                image_width as u32,
                image_height as u32,
                YuvChromaSubsampling::Yuv444,
            );

            rgb_to_yuv_nv24(
                &mut planar_image,
                &image_rgb,
                image_width as u32 * CHANNELS as u32,
                YuvRange::Limited,
                YuvStandardMatrix::Bt709,
                mode,
            )
            .unwrap();

            image_rgb.fill(0);

            let fixed_planar = planar_image.to_fixed();

            yuv_nv24_to_rgb(
                &fixed_planar,
                &mut image_rgb,
                image_width as u32 * CHANNELS as u32,
                YuvRange::Limited,
                YuvStandardMatrix::Bt709,
                mode,
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
                    diff_r <= max_diff,
                    "Matrix {}, Original RGB {:?}, Round-tripped RGB {:?}, actual diff {}",
                    mode,
                    [or, og, ob],
                    [r, g, b],
                    diff_r,
                );
                assert!(
                    diff_g <= max_diff,
                    "Matrix {}, Original RGB {:?}, Round-tripped RGB {:?}, actual diff {}",
                    mode,
                    [or, og, ob],
                    [r, g, b],
                    diff_g,
                );
                assert!(
                    diff_b <= max_diff,
                    "Matrix {}, Original RGB {:?}, Round-tripped RGB {:?}, actual diff {}",
                    mode,
                    [or, og, ob],
                    [r, g, b],
                    diff_b,
                );
            }
        }
        matrix(YuvConversionMode::Balanced, 37);
        #[cfg(feature = "fast_mode")]
        matrix(YuvConversionMode::Fast, 50);
        #[cfg(feature = "professional_mode")]
        matrix(YuvConversionMode::Professional, 37);
    }

    #[test]
    fn test_yuv422_nv_round_trip_full_range() {
        fn matrix(mode: YuvConversionMode, max_diff: i32) {
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

            let mut planar_image = YuvBiPlanarImageMut::<u8>::alloc(
                image_width as u32,
                image_height as u32,
                YuvChromaSubsampling::Yuv422,
            );

            rgb_to_yuv_nv16(
                &mut planar_image,
                &source_rgb,
                image_width as u32 * CHANNELS as u32,
                YuvRange::Full,
                YuvStandardMatrix::Bt709,
                mode,
            )
            .unwrap();

            let mut dest_rgb = vec![0u8; image_width * image_height * CHANNELS];

            let fixed_planar = planar_image.to_fixed();

            yuv_nv16_to_rgb(
                &fixed_planar,
                &mut dest_rgb,
                image_width as u32 * CHANNELS as u32,
                YuvRange::Full,
                YuvStandardMatrix::Bt709,
                mode,
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
                    mode,
                    diff_r,
                    [or, og, ob],
                    [r, g, b]
                );
                assert!(
                    diff_g <= max_diff,
                    "Matrix {}, Actual diff {}, Original RGB {:?}, Round-tripped RGB {:?}",
                    mode,
                    diff_g,
                    [or, og, ob],
                    [r, g, b]
                );
                assert!(
                    diff_b <= max_diff,
                    "Matrix {}, Actual diff {}, Original RGB {:?}, Round-tripped RGB {:?}",
                    mode,
                    diff_b,
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
    fn test_yuv422_nv_round_trip_limited_range() {
        fn matrix(mode: YuvConversionMode, max_diff: i32) {
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

            let mut planar_image = YuvBiPlanarImageMut::<u8>::alloc(
                image_width as u32,
                image_height as u32,
                YuvChromaSubsampling::Yuv422,
            );

            rgb_to_yuv_nv16(
                &mut planar_image,
                &source_rgb,
                image_width as u32 * CHANNELS as u32,
                YuvRange::Limited,
                YuvStandardMatrix::Bt709,
                mode,
            )
            .unwrap();

            let mut dest_rgb = vec![0u8; image_width * image_height * CHANNELS];

            let fixed_planar = planar_image.to_fixed();

            yuv_nv16_to_rgb(
                &fixed_planar,
                &mut dest_rgb,
                image_width as u32 * CHANNELS as u32,
                YuvRange::Limited,
                YuvStandardMatrix::Bt709,
                mode,
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
                    mode,
                    diff_r,
                    [or, og, ob],
                    [r, g, b]
                );
                assert!(
                    diff_g <= max_diff,
                    "Matrix {}, Actual diff {}, Original RGB {:?}, Round-tripped RGB {:?}",
                    mode,
                    diff_g,
                    [or, og, ob],
                    [r, g, b]
                );
                assert!(
                    diff_b <= max_diff,
                    "Matrix {}, Actual diff {}, Original RGB {:?}, Round-tripped RGB {:?}",
                    mode,
                    diff_b,
                    [or, og, ob],
                    [r, g, b]
                );
            }
        }
        matrix(YuvConversionMode::Balanced, 20);
        #[cfg(feature = "fast_mode")]
        matrix(YuvConversionMode::Fast, 26);
        #[cfg(feature = "professional_mode")]
        matrix(YuvConversionMode::Professional, 12);
    }

    #[test]
    fn test_yuv420_nv_round_trip_full_range() {
        fn matrix(mode: YuvConversionMode, max_diff: i32) {
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

            let mut planar_image = YuvBiPlanarImageMut::<u8>::alloc(
                image_width as u32,
                image_height as u32,
                YuvChromaSubsampling::Yuv420,
            );

            rgb_to_yuv_nv12(
                &mut planar_image,
                &source_rgb,
                image_width as u32 * CHANNELS as u32,
                YuvRange::Full,
                YuvStandardMatrix::Bt709,
                mode,
            )
            .unwrap();

            let mut dest_rgb = vec![0u8; image_width * image_height * CHANNELS];

            let fixed_planar = planar_image.to_fixed();

            yuv_nv12_to_rgb(
                &fixed_planar,
                &mut dest_rgb,
                image_width as u32 * CHANNELS as u32,
                YuvRange::Full,
                YuvStandardMatrix::Bt709,
                mode,
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
                    "Matrix {}, Actual diff {}, Original RGB {:?}, Round-tripped RGB {:?}, Point (x: {}, y: {})",
                    mode,
                    diff_r,
                    [or, og, ob],
                    [r, g, b],
                    x,
                    y,
                );
                assert!(
                    diff_g <= max_diff,
                    "Matrix {}, Actual diff {}, Original RGB {:?}, Round-tripped RGB {:?}, Point (x: {}, y: {})",
                    mode,
                    diff_g,
                    [or, og, ob],
                    [r, g, b],
                    x,
                    y,
                );
                assert!(
                    diff_b <= max_diff,
                    "Matrix {}, Actual diff {}, Original RGB {:?}, Round-tripped RGB {:?}, Point (x: {}, y: {})",
                    mode,
                    diff_b,
                    [or, og, ob],
                    [r, g, b],
                    x,
                    y,
                );
            }
        }
        matrix(YuvConversionMode::Balanced, 82);
        #[cfg(feature = "fast_mode")]
        matrix(YuvConversionMode::Fast, 84);
        #[cfg(feature = "professional_mode")]
        matrix(YuvConversionMode::Professional, 74);
    }

    #[test]
    fn test_yuv420_nv_round_trip_limited_range() {
        fn matrix(mode: YuvConversionMode, max_diff: i32) {
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

            let mut planar_image = YuvBiPlanarImageMut::<u8>::alloc(
                image_width as u32,
                image_height as u32,
                YuvChromaSubsampling::Yuv420,
            );

            rgb_to_yuv_nv12(
                &mut planar_image,
                &source_rgb,
                image_width as u32 * CHANNELS as u32,
                YuvRange::Limited,
                YuvStandardMatrix::Bt709,
                mode,
            )
            .unwrap();

            let mut dest_rgb = vec![0u8; image_width * image_height * CHANNELS];

            let fixed_planar = planar_image.to_fixed();

            yuv_nv12_to_rgb(
                &fixed_planar,
                &mut dest_rgb,
                image_width as u32 * CHANNELS as u32,
                YuvRange::Limited,
                YuvStandardMatrix::Bt709,
                mode,
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
                    mode,
                    diff_r,
                    [or, og, ob],
                    [r, g, b]
                );
                assert!(
                    diff_g <= max_diff,
                    "Matrix {}, Actual diff {}, Original RGB {:?}, Round-tripped RGB {:?}",
                    mode,
                    diff_g,
                    [or, og, ob],
                    [r, g, b]
                );
                assert!(
                    diff_b <= max_diff,
                    "Matrix {}, Actual diff {}, Original RGB {:?}, Round-tripped RGB {:?}",
                    mode,
                    diff_b,
                    [or, og, ob],
                    [r, g, b]
                );
            }
        }
        matrix(YuvConversionMode::Balanced, 78);
        #[cfg(feature = "fast_mode")]
        matrix(YuvConversionMode::Fast, 82);
        #[cfg(feature = "professional_mode")]
        matrix(YuvConversionMode::Professional, 70);
    }
}
