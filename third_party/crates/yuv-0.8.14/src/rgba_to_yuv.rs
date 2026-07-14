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
use crate::avx512bw::{avx512_rgba_to_yuv, avx512_rgba_to_yuv420};
#[allow(unused_imports)]
use crate::internals::*;
#[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
use crate::neon::{neon_rgba_to_yuv, neon_rgba_to_yuv420};
use crate::yuv_error::check_rgba_destination;
#[allow(unused_imports)]
use crate::yuv_support::*;
use crate::{YuvError, YuvPlanarImageMut};
#[cfg(feature = "rayon")]
use rayon::iter::{IndexedParallelIterator, ParallelIterator};
#[cfg(feature = "rayon")]
use rayon::prelude::{ParallelSlice, ParallelSliceMut};

type RgbEncoder420Handler = Option<
    unsafe fn(
        transform: &CbCrForwardTransform<i32>,
        range: &YuvChromaRange,
        y_plane0: &mut [u8],
        y_plane1: &mut [u8],
        u_plane: &mut [u8],
        v_plane: &mut [u8],
        rgba0: &[u8],
        rgba1: &[u8],
        start_cx: usize,
        start_ux: usize,
        width: usize,
    ) -> ProcessedOffset,
>;

type RgbEncoderHandler = Option<
    unsafe fn(
        transform: &CbCrForwardTransform<i32>,
        range: &YuvChromaRange,
        y_plane: &mut [u8],
        u_plane: &mut [u8],
        v_plane: &mut [u8],
        rgba: &[u8],
        start_cx: usize,
        start_ux: usize,
        width: usize,
    ) -> ProcessedOffset,
>;

macro_rules! define_handler_impl {
    ($struct_name:ident) => {
        impl<const ORIGIN_CHANNELS: u8, const SAMPLING: u8, const PRECISION: i32>
            WideRowForwardHandler<u8, i32> for $struct_name<ORIGIN_CHANNELS, SAMPLING, PRECISION>
        {
            fn handle_row(
                &self,
                y_plane: &mut [u8],
                u_plane: &mut [u8],
                v_plane: &mut [u8],
                rgba: &[u8],
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

struct RgbEncoder<const ORIGIN_CHANNELS: u8, const SAMPLING: u8, const PRECISION: i32> {
    handler: RgbEncoderHandler,
}

#[cfg(feature = "fast_mode")]
struct RgbEncoderFast<const ORIGIN_CHANNELS: u8, const SAMPLING: u8, const PRECISION: i32> {
    handler: RgbEncoderHandler,
}

#[cfg(feature = "professional_mode")]
struct RgbEncoderProfessional<const ORIGIN_CHANNELS: u8, const SAMPLING: u8, const PRECISION: i32> {
    handler: RgbEncoderHandler,
}

impl<const ORIGIN_CHANNELS: u8, const SAMPLING: u8, const PRECISION: i32> Default
    for RgbEncoder<ORIGIN_CHANNELS, SAMPLING, PRECISION>
{
    fn default() -> Self {
        if PRECISION != 13 {
            return RgbEncoder { handler: None };
        }
        assert_eq!(PRECISION, 13);
        #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
        {
            #[cfg(feature = "rdm")]
            {
                use crate::neon::neon_rgba_to_yuv_rdm;
                let is_rdm_available = std::arch::is_aarch64_feature_detected!("rdm");
                if is_rdm_available {
                    return RgbEncoder {
                        handler: Some(neon_rgba_to_yuv_rdm::<ORIGIN_CHANNELS, SAMPLING>),
                    };
                }
            }
            RgbEncoder {
                handler: Some(neon_rgba_to_yuv::<ORIGIN_CHANNELS, SAMPLING>),
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
                        RgbEncoder {
                            handler: Some(avx512_rgba_to_yuv::<ORIGIN_CHANNELS, SAMPLING, true>),
                        }
                    } else {
                        RgbEncoder {
                            handler: Some(avx512_rgba_to_yuv::<ORIGIN_CHANNELS, SAMPLING, false>),
                        }
                    };
                }
            }
            #[cfg(feature = "avx")]
            {
                let use_avx = std::arch::is_x86_feature_detected!("avx2");
                if use_avx {
                    use crate::avx2::avx2_rgba_to_yuv;
                    return RgbEncoder {
                        handler: Some(avx2_rgba_to_yuv::<ORIGIN_CHANNELS, SAMPLING, PRECISION>),
                    };
                }
            }
            #[cfg(feature = "sse")]
            {
                use crate::sse::sse_rgba_to_yuv_row;
                let use_sse = std::arch::is_x86_feature_detected!("sse4.1");
                if use_sse {
                    return RgbEncoder {
                        handler: Some(sse_rgba_to_yuv_row::<ORIGIN_CHANNELS, SAMPLING, PRECISION>),
                    };
                }
            }
        }
        #[cfg(not(all(target_arch = "aarch64", target_feature = "neon")))]
        RgbEncoder { handler: None }
    }
}

#[cfg(feature = "fast_mode")]
impl<const ORIGIN_CHANNELS: u8, const SAMPLING: u8, const PRECISION: i32> Default
    for RgbEncoderFast<ORIGIN_CHANNELS, SAMPLING, PRECISION>
{
    fn default() -> Self {
        #[cfg(feature = "fast_mode")]
        if PRECISION == 7 {
            assert_eq!(PRECISION, 7);
            #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
            {
                #[cfg(feature = "nightly_i8mm")]
                if std::arch::is_aarch64_feature_detected!("i8mm") {
                    let chans: YuvSourceChannels = ORIGIN_CHANNELS.into();
                    use crate::neon::neon_rgba_to_yuv_dot_rgba;
                    if chans == YuvSourceChannels::Rgba || chans == YuvSourceChannels::Bgra {
                        assert!(
                            chans == YuvSourceChannels::Rgba || chans == YuvSourceChannels::Bgra
                        );
                        return RgbEncoderFast {
                            handler: Some(neon_rgba_to_yuv_dot_rgba::<ORIGIN_CHANNELS, SAMPLING>),
                        };
                    }
                }

                use crate::neon::neon_rgbx_to_yuv_fast;
                return RgbEncoderFast {
                    handler: Some(neon_rgbx_to_yuv_fast::<ORIGIN_CHANNELS, SAMPLING>),
                };
            }
            #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
            {
                #[cfg(feature = "nightly_avx512")]
                if std::arch::is_x86_feature_detected!("avx512bw") {
                    use crate::avx512bw::{
                        avx512_rgba_to_yuv_dot_rgba, avx512_rgba_to_yuv_dot_rgba_bmi,
                    };
                    let chans: YuvSourceChannels = ORIGIN_CHANNELS.into();
                    if chans == YuvSourceChannels::Rgba || chans == YuvSourceChannels::Bgra {
                        assert!(
                            chans == YuvSourceChannels::Rgba || chans == YuvSourceChannels::Bgra
                        );
                        return RgbEncoderFast {
                            handler: Some(avx512_rgba_to_yuv_dot_rgba::<ORIGIN_CHANNELS, SAMPLING>),
                        };
                    }
                    let has_vbmi = std::arch::is_x86_feature_detected!("avx512vbmi");
                    if (chans == YuvSourceChannels::Bgr || chans == YuvSourceChannels::Rgb)
                        && has_vbmi
                    {
                        assert!(chans == YuvSourceChannels::Bgr || chans == YuvSourceChannels::Rgb);
                        return RgbEncoderFast {
                            handler: Some(
                                avx512_rgba_to_yuv_dot_rgba_bmi::<ORIGIN_CHANNELS, SAMPLING>,
                            ),
                        };
                    }
                }

                #[cfg(feature = "avx")]
                if std::arch::is_x86_feature_detected!("avx2") {
                    use crate::avx2::avx2_rgba_to_yuv_dot_rgba;
                    return RgbEncoderFast {
                        handler: Some(avx2_rgba_to_yuv_dot_rgba::<ORIGIN_CHANNELS, SAMPLING>),
                    };
                }

                #[cfg(feature = "sse")]
                {
                    if std::arch::is_x86_feature_detected!("sse4.1") {
                        use crate::sse::sse_rgba_to_yuv_dot_rgba;
                        return RgbEncoderFast {
                            handler: Some(sse_rgba_to_yuv_dot_rgba::<ORIGIN_CHANNELS, SAMPLING>),
                        };
                    }
                }
            }
        }
        RgbEncoderFast { handler: None }
    }
}

#[cfg(feature = "professional_mode")]
impl<const ORIGIN_CHANNELS: u8, const SAMPLING: u8, const PRECISION: i32> Default
    for RgbEncoderProfessional<ORIGIN_CHANNELS, SAMPLING, PRECISION>
{
    fn default() -> Self {
        if PRECISION == 15 {
            assert_eq!(PRECISION, 15);
            #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
            {
                use crate::neon::neon_rgba_to_yuv_prof;
                return RgbEncoderProfessional {
                    handler: Some(neon_rgba_to_yuv_prof::<ORIGIN_CHANNELS, SAMPLING>),
                };
            }
            #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
            {
                #[cfg(feature = "avx")]
                {
                    let use_avx = std::arch::is_x86_feature_detected!("avx2");
                    if use_avx {
                        use crate::avx2::avx2_rgba_to_yuv_prof;
                        return RgbEncoderProfessional {
                            handler: Some(
                                avx2_rgba_to_yuv_prof::<ORIGIN_CHANNELS, SAMPLING, PRECISION>,
                            ),
                        };
                    }
                }
                #[cfg(feature = "sse")]
                if std::arch::is_x86_feature_detected!("sse4.1") {
                    use crate::sse::sse_rgba_to_yuv_prof;
                    return RgbEncoderProfessional {
                        handler: Some(sse_rgba_to_yuv_prof::<ORIGIN_CHANNELS, SAMPLING, PRECISION>),
                    };
                }
            }
        }
        RgbEncoderProfessional { handler: None }
    }
}

define_handler_impl!(RgbEncoder);
#[cfg(feature = "fast_mode")]
define_handler_impl!(RgbEncoderFast);
#[cfg(feature = "professional_mode")]
define_handler_impl!(RgbEncoderProfessional);

struct RgbEncoder420<const ORIGIN_CHANNELS: u8, const SAMPLING: u8, const PRECISION: i32> {
    handler: RgbEncoder420Handler,
}

impl<const ORIGIN_CHANNELS: u8, const SAMPLING: u8, const PRECISION: i32> Default
    for RgbEncoder420<ORIGIN_CHANNELS, SAMPLING, PRECISION>
{
    fn default() -> Self {
        let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();
        if chroma_subsampling != YuvChromaSubsampling::Yuv420 {
            return RgbEncoder420 { handler: None };
        }
        assert_eq!(chroma_subsampling, YuvChromaSubsampling::Yuv420);

        #[cfg(feature = "fast_mode")]
        if PRECISION == 7 {
            assert_eq!(PRECISION, 7);
            #[cfg(all(target_arch = "aarch64", target_feature = "neon",))]
            {
                #[cfg(feature = "nightly_i8mm")]
                {
                    if std::arch::is_aarch64_feature_detected!("i8mm") {
                        let chans: YuvSourceChannels = ORIGIN_CHANNELS.into();
                        use crate::neon::neon_rgba_to_yuv_dot_rgba420;
                        if chans == YuvSourceChannels::Rgba || chans == YuvSourceChannels::Bgra {
                            assert!(
                                chans == YuvSourceChannels::Rgba
                                    || chans == YuvSourceChannels::Bgra
                            );
                            return RgbEncoder420 {
                                handler: Some(neon_rgba_to_yuv_dot_rgba420::<ORIGIN_CHANNELS>),
                            };
                        }
                    }
                }
                use crate::neon::neon_rgbx_to_yuv_fast420;
                return RgbEncoder420 {
                    handler: Some(neon_rgbx_to_yuv_fast420::<ORIGIN_CHANNELS>),
                };
            }
            #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
            {
                #[cfg(feature = "nightly_avx512")]
                if std::arch::is_x86_feature_detected!("avx512bw") {
                    use crate::avx512bw::{
                        avx512_rgba_to_yuv_dot_rgba420, avx512_rgba_to_yuv_dot_rgba420_vbmi,
                    };
                    let chans: YuvSourceChannels = ORIGIN_CHANNELS.into();
                    if chans == YuvSourceChannels::Rgba || chans == YuvSourceChannels::Bgra {
                        assert!(
                            chans == YuvSourceChannels::Rgba || chans == YuvSourceChannels::Bgra
                        );
                        return RgbEncoder420 {
                            handler: Some(avx512_rgba_to_yuv_dot_rgba420::<ORIGIN_CHANNELS>),
                        };
                    }

                    let has_vbmi = std::arch::is_x86_feature_detected!("avx512vbmi");
                    if (chans == YuvSourceChannels::Rgb || chans == YuvSourceChannels::Bgr)
                        && has_vbmi
                    {
                        assert!(chans == YuvSourceChannels::Rgb || chans == YuvSourceChannels::Bgr);
                        return RgbEncoder420 {
                            handler: Some(avx512_rgba_to_yuv_dot_rgba420_vbmi::<ORIGIN_CHANNELS>),
                        };
                    }
                }

                #[cfg(feature = "avx")]
                if std::arch::is_x86_feature_detected!("avx2") {
                    use crate::avx2::avx2_rgba_to_yuv_dot_rgba420;
                    return RgbEncoder420 {
                        handler: Some(avx2_rgba_to_yuv_dot_rgba420::<ORIGIN_CHANNELS>),
                    };
                }

                #[cfg(feature = "sse")]
                if std::arch::is_x86_feature_detected!("sse4.1") {
                    use crate::sse::sse_rgba_to_yuv_dot_rgba420;
                    return RgbEncoder420 {
                        handler: Some(sse_rgba_to_yuv_dot_rgba420::<ORIGIN_CHANNELS>),
                    };
                }
            }
        }

        if PRECISION != 13 {
            return RgbEncoder420 { handler: None };
        }
        assert_eq!(PRECISION, 13);
        #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
        {
            #[cfg(feature = "rdm")]
            {
                use crate::neon::neon_rgba_to_yuv_rdm420;
                let is_rdm_available = std::arch::is_aarch64_feature_detected!("rdm");
                if is_rdm_available {
                    return RgbEncoder420 {
                        handler: Some(neon_rgba_to_yuv_rdm420::<ORIGIN_CHANNELS>),
                    };
                }
            }
            RgbEncoder420 {
                handler: Some(neon_rgba_to_yuv420::<ORIGIN_CHANNELS>),
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
                        RgbEncoder420 {
                            handler: Some(avx512_rgba_to_yuv420::<ORIGIN_CHANNELS, true>),
                        }
                    } else {
                        RgbEncoder420 {
                            handler: Some(avx512_rgba_to_yuv420::<ORIGIN_CHANNELS, false>),
                        }
                    };
                }
            }
            #[cfg(feature = "avx")]
            {
                let use_avx = std::arch::is_x86_feature_detected!("avx2");
                if use_avx {
                    use crate::avx2::avx2_rgba_to_yuv420;
                    return RgbEncoder420 {
                        handler: Some(avx2_rgba_to_yuv420::<ORIGIN_CHANNELS, PRECISION>),
                    };
                }
            }

            #[cfg(feature = "sse")]
            {
                use crate::sse::sse_rgba_to_yuv_row420;
                let use_sse = std::arch::is_x86_feature_detected!("sse4.1");
                if use_sse {
                    return RgbEncoder420 {
                        handler: Some(sse_rgba_to_yuv_row420::<ORIGIN_CHANNELS, PRECISION>),
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
        impl<const ORIGIN_CHANNELS: u8, const SAMPLING: u8, const PRECISION: i32>
            WideRowForward420Handler<u8, i32>
            for $struct_name<ORIGIN_CHANNELS, SAMPLING, PRECISION>
        {
            fn handle_row(
                &self,
                y_plane0: &mut [u8],
                y_plane1: &mut [u8],
                u_plane: &mut [u8],
                v_plane: &mut [u8],
                rgba0: &[u8],
                rgba1: &[u8],
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

#[cfg(feature = "professional_mode")]
struct RgbEncoder420Professional<
    const ORIGIN_CHANNELS: u8,
    const SAMPLING: u8,
    const PRECISION: i32,
> {
    handler: RgbEncoder420Handler,
}

#[cfg(feature = "professional_mode")]
impl_wide_row_forward_handler!(RgbEncoder420Professional);

#[cfg(feature = "professional_mode")]
impl<const ORIGIN_CHANNELS: u8, const SAMPLING: u8, const PRECISION: i32> Default
    for RgbEncoder420Professional<ORIGIN_CHANNELS, SAMPLING, PRECISION>
{
    fn default() -> Self {
        let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();
        if chroma_subsampling != YuvChromaSubsampling::Yuv420 {
            return RgbEncoder420Professional { handler: None };
        }
        assert_eq!(chroma_subsampling, YuvChromaSubsampling::Yuv420);

        if PRECISION == 15 {
            assert_eq!(PRECISION, 15);
            #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
            {
                use crate::neon::neon_rgba_to_yuv_prof420;
                return RgbEncoder420Professional {
                    handler: Some(neon_rgba_to_yuv_prof420::<ORIGIN_CHANNELS>),
                };
            }
            #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
            {
                #[cfg(feature = "avx")]
                {
                    let use_avx = std::arch::is_x86_feature_detected!("avx2");
                    if use_avx {
                        use crate::avx2::avx2_rgba_to_yuv420_prof;
                        return RgbEncoder420Professional {
                            handler: Some(avx2_rgba_to_yuv420_prof::<ORIGIN_CHANNELS, PRECISION>),
                        };
                    }
                }
                #[cfg(feature = "sse")]
                if std::arch::is_x86_feature_detected!("sse4.1") {
                    use crate::sse::sse_rgba_to_yuv420_prof;
                    return RgbEncoder420Professional {
                        handler: Some(sse_rgba_to_yuv420_prof::<ORIGIN_CHANNELS, PRECISION>),
                    };
                }
            }
        }

        RgbEncoder420Professional { handler: None }
    }
}

#[cfg(feature = "fast_mode")]
struct RgbEncoderFast420<const ORIGIN_CHANNELS: u8, const SAMPLING: u8, const PRECISION: i32> {
    handler: RgbEncoder420Handler,
}

#[cfg(feature = "fast_mode")]
impl<const ORIGIN_CHANNELS: u8, const SAMPLING: u8, const PRECISION: i32> Default
    for RgbEncoderFast420<ORIGIN_CHANNELS, SAMPLING, PRECISION>
{
    fn default() -> Self {
        let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();
        if chroma_subsampling != YuvChromaSubsampling::Yuv420 {
            return RgbEncoderFast420 { handler: None };
        }
        assert_eq!(chroma_subsampling, YuvChromaSubsampling::Yuv420);

        if PRECISION == 7 {
            assert_eq!(PRECISION, 7);
            #[cfg(all(target_arch = "aarch64", target_feature = "neon",))]
            {
                #[cfg(feature = "nightly_i8mm")]
                {
                    if std::arch::is_aarch64_feature_detected!("i8mm") {
                        let chans: YuvSourceChannels = ORIGIN_CHANNELS.into();
                        use crate::neon::neon_rgba_to_yuv_dot_rgba420;
                        if chans == YuvSourceChannels::Rgba || chans == YuvSourceChannels::Bgra {
                            assert!(
                                chans == YuvSourceChannels::Rgba
                                    || chans == YuvSourceChannels::Bgra
                            );
                            return RgbEncoderFast420 {
                                handler: Some(neon_rgba_to_yuv_dot_rgba420::<ORIGIN_CHANNELS>),
                            };
                        }
                    }
                }
                use crate::neon::neon_rgbx_to_yuv_fast420;
                return RgbEncoderFast420 {
                    handler: Some(neon_rgbx_to_yuv_fast420::<ORIGIN_CHANNELS>),
                };
            }
            #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
            {
                #[cfg(feature = "nightly_avx512")]
                if std::arch::is_x86_feature_detected!("avx512bw") {
                    use crate::avx512bw::{
                        avx512_rgba_to_yuv_dot_rgba420, avx512_rgba_to_yuv_dot_rgba420_vbmi,
                    };
                    let chans: YuvSourceChannels = ORIGIN_CHANNELS.into();
                    if chans == YuvSourceChannels::Rgba || chans == YuvSourceChannels::Bgra {
                        assert!(
                            chans == YuvSourceChannels::Rgba || chans == YuvSourceChannels::Bgra
                        );
                        return RgbEncoderFast420 {
                            handler: Some(avx512_rgba_to_yuv_dot_rgba420::<ORIGIN_CHANNELS>),
                        };
                    }

                    let has_vbmi = std::arch::is_x86_feature_detected!("avx512vbmi");
                    if (chans == YuvSourceChannels::Rgb || chans == YuvSourceChannels::Bgr)
                        && has_vbmi
                    {
                        assert!(chans == YuvSourceChannels::Rgb || chans == YuvSourceChannels::Bgr);
                        return RgbEncoderFast420 {
                            handler: Some(avx512_rgba_to_yuv_dot_rgba420_vbmi::<ORIGIN_CHANNELS>),
                        };
                    }
                }

                #[cfg(feature = "avx")]
                if std::arch::is_x86_feature_detected!("avx2") {
                    use crate::avx2::avx2_rgba_to_yuv_dot_rgba420;
                    return RgbEncoderFast420 {
                        handler: Some(avx2_rgba_to_yuv_dot_rgba420::<ORIGIN_CHANNELS>),
                    };
                }

                #[cfg(feature = "sse")]
                if std::arch::is_x86_feature_detected!("sse4.1") {
                    use crate::sse::sse_rgba_to_yuv_dot_rgba420;
                    return RgbEncoderFast420 {
                        handler: Some(sse_rgba_to_yuv_dot_rgba420::<ORIGIN_CHANNELS>),
                    };
                }
            }
        }
        RgbEncoderFast420 { handler: None }
    }
}

#[cfg(feature = "fast_mode")]
impl_wide_row_forward_handler!(RgbEncoderFast420);

fn rgbx_to_yuv8_impl<const ORIGIN_CHANNELS: u8, const SAMPLING: u8, const PRECISION: i32>(
    image: &mut YuvPlanarImageMut<u8>,
    rgba: &[u8],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    row_handler: impl WideRowForwardHandler<u8, i32> + Send + Sync,
    row_handler420: impl WideRowForward420Handler<u8, i32> + Send + Sync,
) -> Result<(), YuvError> {
    let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();
    let src_chans: YuvSourceChannels = ORIGIN_CHANNELS.into();
    let channels = src_chans.get_channels_count();

    check_rgba_destination(rgba, rgba_stride, image.width, image.height, channels)?;
    image.check_constraints(chroma_subsampling)?;

    let chroma_range = get_yuv_range(8, range);
    let kr_kb = matrix.get_kr_kb();

    let transform = search_forward_transform(PRECISION, 8, range, matrix, chroma_range, kr_kb);

    let rounding_const_bias: i32 = (1 << (PRECISION - 1)) - 1;
    let bias_y = chroma_range.bias_y as i32 * (1 << PRECISION) + rounding_const_bias;
    let bias_uv = chroma_range.bias_uv as i32 * (1 << PRECISION) + rounding_const_bias;

    let process_halved_chroma_row = |y_plane: &mut [u8],
                                     u_plane: &mut [u8],
                                     v_plane: &mut [u8],
                                     rgba: &[u8]| {
        let processed_offset = row_handler.handle_row(
            y_plane,
            u_plane,
            v_plane,
            rgba,
            image.width,
            chroma_range,
            &transform,
        );
        let cx = processed_offset.cx;
        if cx != image.width as usize {
            for (((y_dst, u_dst), v_dst), rgba) in y_plane
                .chunks_exact_mut(2)
                .zip(u_plane.iter_mut())
                .zip(v_plane.iter_mut())
                .zip(rgba.chunks_exact(channels * 2))
                .skip(cx / 2)
            {
                let src0 = &rgba[0..channels];

                let r0 = src0[src_chans.get_r_channel_offset()] as i32;
                let g0 = src0[src_chans.get_g_channel_offset()] as i32;
                let b0 = src0[src_chans.get_b_channel_offset()] as i32;
                let y_0 = (r0 * transform.yr + g0 * transform.yg + b0 * transform.yb + bias_y)
                    >> PRECISION;
                y_dst[0] = y_0 as u8;

                let src1 = &rgba[channels..channels * 2];

                let r1 = src1[src_chans.get_r_channel_offset()] as i32;
                let g1 = src1[src_chans.get_g_channel_offset()] as i32;
                let b1 = src1[src_chans.get_b_channel_offset()] as i32;
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
                *u_dst = cb as u8;
                *v_dst = cr as u8;
            }

            if image.width & 1 != 0 {
                let rgb_last = rgba.chunks_exact(channels * 2).remainder();
                let r0 = rgb_last[src_chans.get_r_channel_offset()] as i32;
                let g0 = rgb_last[src_chans.get_g_channel_offset()] as i32;
                let b0 = rgb_last[src_chans.get_b_channel_offset()] as i32;

                let y_last = y_plane.last_mut().unwrap();
                let u_last = u_plane.last_mut().unwrap();
                let v_last = v_plane.last_mut().unwrap();

                let y_0 = (r0 * transform.yr + g0 * transform.yg + b0 * transform.yb + bias_y)
                    >> PRECISION;
                *y_last = y_0 as u8;

                let cb =
                    (r0 * transform.cb_r + g0 * transform.cb_g + b0 * transform.cb_b + bias_uv)
                        >> PRECISION;
                let cr =
                    (r0 * transform.cr_r + g0 * transform.cr_g + b0 * transform.cr_b + bias_uv)
                        >> PRECISION;
                *u_last = cb as u8;
                *v_last = cr as u8;
            }
        }
    };

    let process_doubled_row = |y_plane0: &mut [u8],
                               y_plane1: &mut [u8],
                               u_plane: &mut [u8],
                               v_plane: &mut [u8],
                               rgba0: &[u8],
                               rgba1: &[u8]| {
        let processed_offset = row_handler420.handle_row(
            y_plane0,
            y_plane1,
            u_plane,
            v_plane,
            rgba0,
            rgba1,
            image.width,
            chroma_range,
            &transform,
        );
        let cx = processed_offset.cx;

        if cx != image.width as usize {
            for (((((y_dst0, y_dst1), u_dst), v_dst), rgba0), rgba1) in y_plane0
                .chunks_exact_mut(2)
                .zip(y_plane1.chunks_exact_mut(2))
                .zip(u_plane.iter_mut())
                .zip(v_plane.iter_mut())
                .zip(rgba0.chunks_exact(channels * 2))
                .zip(rgba1.chunks_exact(channels * 2))
                .skip(cx / 2)
            {
                let src00 = &rgba0[0..channels];

                let r00 = src00[src_chans.get_r_channel_offset()] as i32;
                let g00 = src00[src_chans.get_g_channel_offset()] as i32;
                let b00 = src00[src_chans.get_b_channel_offset()] as i32;
                let y_00 = (r00 * transform.yr + g00 * transform.yg + b00 * transform.yb + bias_y)
                    >> PRECISION;
                y_dst0[0] = y_00 as u8;

                let src1 = &rgba0[channels..channels * 2];

                let r01 = src1[src_chans.get_r_channel_offset()] as i32;
                let g01 = src1[src_chans.get_g_channel_offset()] as i32;
                let b01 = src1[src_chans.get_b_channel_offset()] as i32;
                let y_01 = (r01 * transform.yr + g01 * transform.yg + b01 * transform.yb + bias_y)
                    >> PRECISION;
                y_dst0[1] = y_01 as u8;

                let src10 = &rgba1[0..channels];

                let r10 = src10[src_chans.get_r_channel_offset()] as i32;
                let g10 = src10[src_chans.get_g_channel_offset()] as i32;
                let b10 = src10[src_chans.get_b_channel_offset()] as i32;
                let y_10 = (r10 * transform.yr + g10 * transform.yg + b10 * transform.yb + bias_y)
                    >> PRECISION;
                y_dst1[0] = y_10 as u8;

                let src11 = &rgba1[channels..channels * 2];

                let r11 = src11[src_chans.get_r_channel_offset()] as i32;
                let g11 = src11[src_chans.get_g_channel_offset()] as i32;
                let b11 = src11[src_chans.get_b_channel_offset()] as i32;
                let y_11 = (r11 * transform.yr + g11 * transform.yg + b11 * transform.yb + bias_y)
                    >> PRECISION;
                y_dst1[1] = y_11 as u8;

                let ruv = (r00 + r01 + r10 + r11 + 2) >> 2;
                let guv = (g00 + g01 + g10 + g11 + 2) >> 2;
                let buv = (b00 + b01 + b10 + b11 + 2) >> 2;

                let cb =
                    (ruv * transform.cb_r + guv * transform.cb_g + buv * transform.cb_b + bias_uv)
                        >> PRECISION;
                let cr =
                    (ruv * transform.cr_r + guv * transform.cr_g + buv * transform.cr_b + bias_uv)
                        >> PRECISION;
                *u_dst = cb as u8;
                *v_dst = cr as u8;
            }

            if image.width & 1 != 0 {
                let rgb_last0 = rgba0.chunks_exact(channels * 2).remainder();
                let rgb_last1 = rgba1.chunks_exact(channels * 2).remainder();
                let r0 = rgb_last0[src_chans.get_r_channel_offset()] as i32;
                let g0 = rgb_last0[src_chans.get_g_channel_offset()] as i32;
                let b0 = rgb_last0[src_chans.get_b_channel_offset()] as i32;

                let r1 = rgb_last1[src_chans.get_r_channel_offset()] as i32;
                let g1 = rgb_last1[src_chans.get_g_channel_offset()] as i32;
                let b1 = rgb_last1[src_chans.get_b_channel_offset()] as i32;

                let y0_last = y_plane0.last_mut().unwrap();
                let y1_last = y_plane1.last_mut().unwrap();
                let u_last = u_plane.last_mut().unwrap();
                let v_last = v_plane.last_mut().unwrap();

                let y_0 = (r0 * transform.yr + g0 * transform.yg + b0 * transform.yb + bias_y)
                    >> PRECISION;
                *y0_last = y_0 as u8;

                let y_1 = (r1 * transform.yr + g1 * transform.yg + b1 * transform.yb + bias_y)
                    >> PRECISION;
                *y1_last = y_1 as u8;

                let r0 = (r0 + r1) >> 1;
                let g0 = (g0 + g1) >> 1;
                let b0 = (b0 + b1) >> 1;

                let cb =
                    (r0 * transform.cb_r + g0 * transform.cb_g + b0 * transform.cb_b + bias_uv)
                        >> PRECISION;
                let cr =
                    (r0 * transform.cr_r + g0 * transform.cr_g + b0 * transform.cr_b + bias_uv)
                        >> PRECISION;
                *u_last = cb as u8;
                *v_last = cr as u8;
            }
        }
    };

    let y_plane = image.y_plane.borrow_mut();
    let u_plane = image.u_plane.borrow_mut();
    let v_plane = image.v_plane.borrow_mut();
    let y_stride = image.y_stride as usize;
    let u_stride = image.u_stride as usize;
    let v_stride = image.v_stride as usize;

    if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
        let iter;
        #[cfg(feature = "rayon")]
        {
            iter = y_plane
                .par_chunks_exact_mut(y_stride)
                .zip(u_plane.par_chunks_exact_mut(u_stride))
                .zip(v_plane.par_chunks_exact_mut(v_stride))
                .zip(rgba.par_chunks_exact(rgba_stride as usize));
        }
        #[cfg(not(feature = "rayon"))]
        {
            iter = y_plane
                .chunks_exact_mut(y_stride)
                .zip(u_plane.chunks_exact_mut(u_stride))
                .zip(v_plane.chunks_exact_mut(v_stride))
                .zip(rgba.chunks_exact(rgba_stride as usize));
        }
        iter.for_each(|(((y_dst, u_plane), v_plane), rgba)| {
            let y_dst = &mut y_dst[..image.width as usize];
            let processed_offset = row_handler.handle_row(
                y_dst,
                u_plane,
                v_plane,
                rgba,
                image.width,
                chroma_range,
                &transform,
            );
            let cx = processed_offset.cx;
            if cx != image.width as usize {
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
                    *y_dst = y_0 as u8;

                    let cb =
                        (r0 * transform.cb_r + g0 * transform.cb_g + b0 * transform.cb_b + bias_uv)
                            >> PRECISION;
                    let cr =
                        (r0 * transform.cr_r + g0 * transform.cr_g + b0 * transform.cr_b + bias_uv)
                            >> PRECISION;
                    *u_dst = cb as u8;
                    *v_dst = cr as u8;
                }
            }
        });
    } else if chroma_subsampling == YuvChromaSubsampling::Yuv422 {
        let iter;
        #[cfg(feature = "rayon")]
        {
            iter = y_plane
                .par_chunks_exact_mut(y_stride)
                .zip(u_plane.par_chunks_exact_mut(u_stride))
                .zip(v_plane.par_chunks_exact_mut(v_stride))
                .zip(rgba.par_chunks_exact(rgba_stride as usize));
        }
        #[cfg(not(feature = "rayon"))]
        {
            iter = y_plane
                .chunks_exact_mut(y_stride)
                .zip(u_plane.chunks_exact_mut(u_stride))
                .zip(v_plane.chunks_exact_mut(v_stride))
                .zip(rgba.chunks_exact(rgba_stride as usize));
        }

        iter.for_each(|(((y_plane, u_plane), v_plane), rgba)| {
            process_halved_chroma_row(
                &mut y_plane[..image.width as usize],
                &mut u_plane[..(image.width as usize).div_ceil(2)],
                &mut v_plane[..(image.width as usize).div_ceil(2)],
                &rgba[..image.width as usize * channels],
            );
        });
    } else if chroma_subsampling == YuvChromaSubsampling::Yuv420 {
        let iter;
        #[cfg(feature = "rayon")]
        {
            iter = y_plane
                .par_chunks_exact_mut(y_stride * 2)
                .zip(u_plane.par_chunks_exact_mut(u_stride))
                .zip(v_plane.par_chunks_exact_mut(v_stride))
                .zip(rgba.par_chunks_exact(rgba_stride as usize * 2));
        }
        #[cfg(not(feature = "rayon"))]
        {
            iter = y_plane
                .chunks_exact_mut(y_stride * 2)
                .zip(u_plane.chunks_exact_mut(u_stride))
                .zip(v_plane.chunks_exact_mut(v_stride))
                .zip(rgba.chunks_exact(rgba_stride as usize * 2));
        }
        iter.for_each(|(((y_plane, u_plane), v_plane), rgba)| {
            let (rgba0, rgba1) = rgba.split_at(rgba_stride as usize);
            let (y_plane0, y_plane1) = y_plane.split_at_mut(y_stride);
            process_doubled_row(
                &mut y_plane0[..image.width as usize],
                &mut y_plane1[..image.width as usize],
                &mut u_plane[..(image.width as usize).div_ceil(2)],
                &mut v_plane[..(image.width as usize).div_ceil(2)],
                &rgba0[..image.width as usize * channels],
                &rgba1[..image.width as usize * channels],
            );
        });

        if image.height & 1 != 0 {
            let remainder_y_plane = y_plane.chunks_exact_mut(y_stride * 2).into_remainder();
            let remainder_rgba = rgba.chunks_exact(rgba_stride as usize * 2).remainder();
            let u_plane = u_plane.chunks_exact_mut(u_stride).last().unwrap();
            let v_plane = v_plane.chunks_exact_mut(v_stride).last().unwrap();
            process_halved_chroma_row(
                &mut remainder_y_plane[..image.width as usize],
                &mut u_plane[..(image.width as usize).div_ceil(2)],
                &mut v_plane[..(image.width as usize).div_ceil(2)],
                &remainder_rgba[..image.width as usize * channels],
            );
        }
    } else {
        unreachable!();
    }

    Ok(())
}

fn rgbx_to_yuv8<const ORIGIN_CHANNELS: u8, const SAMPLING: u8>(
    image: &mut YuvPlanarImageMut<u8>,
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
            YuvConversionMode::Fast => rgbx_to_yuv8_impl::<ORIGIN_CHANNELS, SAMPLING, 7>(
                image,
                rgba,
                rgba_stride,
                range,
                matrix,
                RgbEncoderFast::<ORIGIN_CHANNELS, SAMPLING, 7>::default(),
                RgbEncoderFast420::<ORIGIN_CHANNELS, SAMPLING, 7>::default(),
            ),
            YuvConversionMode::Balanced => rgbx_to_yuv8_impl::<ORIGIN_CHANNELS, SAMPLING, 13>(
                image,
                rgba,
                rgba_stride,
                range,
                matrix,
                RgbEncoder::<ORIGIN_CHANNELS, SAMPLING, 13>::default(),
                RgbEncoder420::<ORIGIN_CHANNELS, SAMPLING, 13>::default(),
            ),
            #[cfg(feature = "professional_mode")]
            YuvConversionMode::Professional => rgbx_to_yuv8_impl::<ORIGIN_CHANNELS, SAMPLING, 15>(
                image,
                rgba,
                rgba_stride,
                range,
                matrix,
                RgbEncoderProfessional::<ORIGIN_CHANNELS, SAMPLING, 15>::default(),
                RgbEncoder420Professional::<ORIGIN_CHANNELS, SAMPLING, 15>::default(),
            ),
        }
    }
    #[cfg(not(any(
        all(any(target_arch = "x86", target_arch = "x86_64"),),
        all(target_arch = "aarch64", target_feature = "neon",),
    )))]
    {
        rgbx_to_yuv8_impl::<ORIGIN_CHANNELS, SAMPLING, 13>(
            image,
            rgba,
            rgba_stride,
            range,
            matrix,
            RgbEncoder::<ORIGIN_CHANNELS, SAMPLING, 13>::default(),
            RgbEncoder420::<ORIGIN_CHANNELS, SAMPLING, 13>::default(),
        )
    }
}

/// Convert RGB image data to YUV 422 planar format.
///
/// This function performs RGB to YUV conversion and stores the result in YUV422 planar format,
/// with separate planes for Y (luminance), U (chrominance), and V (chrominance) components.
///
/// # Arguments
///
/// * `planar_image` - Target planar image.
/// * `rgb` - The input RGB image data slice.
/// * `rgb_stride` - The stride (components per row) for the RGB image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
/// * `mode` - See [YuvConversionMode] for more info.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input RGB data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn rgb_to_yuv422(
    planar_image: &mut YuvPlanarImageMut<u8>,
    rgb: &[u8],
    rgb_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    rgbx_to_yuv8::<{ YuvSourceChannels::Rgb as u8 }, { YuvChromaSubsampling::Yuv422 as u8 }>(
        planar_image,
        rgb,
        rgb_stride,
        range,
        matrix,
        mode,
    )
}

/// Convert BGR image data to YUV 422 planar format.
///
/// This function performs BGR to YUV conversion and stores the result in YUV422 planar format,
/// with separate planes for Y (luminance), U (chrominance), and V (chrominance) components.
///
/// # Arguments
///
/// * `planar_image` - Target planar image.
/// * `bgr` - The input BGR image data slice.
/// * `bgr_stride` - The stride (components per row) for the BGR image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
/// * `mode` - See [YuvConversionMode] for more info.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGR data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn bgr_to_yuv422(
    planar_image: &mut YuvPlanarImageMut<u8>,
    bgr: &[u8],
    bgr_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    rgbx_to_yuv8::<{ YuvSourceChannels::Bgr as u8 }, { YuvChromaSubsampling::Yuv422 as u8 }>(
        planar_image,
        bgr,
        bgr_stride,
        range,
        matrix,
        mode,
    )
}

/// Convert RGBA image data to YUV 422 planar format.
///
/// This function performs RGBA to YUV conversion and stores the result in YUV422 planar format,
/// with separate planes for Y (luminance), U (chrominance), and V (chrominance) components.
///
/// # Arguments
///
/// * `planar_image` - Target planar image.
/// * `rgba` - The input RGBA image data slice.
/// * `rgba_stride` - The stride (components per row) for the RGBA image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
/// * `mode` - See [YuvConversionMode] for more info.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input RGBA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn rgba_to_yuv422(
    planar_image: &mut YuvPlanarImageMut<u8>,
    rgba: &[u8],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    rgbx_to_yuv8::<{ YuvSourceChannels::Rgba as u8 }, { YuvChromaSubsampling::Yuv422 as u8 }>(
        planar_image,
        rgba,
        rgba_stride,
        range,
        matrix,
        mode,
    )
}

/// Convert BGRA image data to YUV 422 planar format.
///
/// This function performs BGRA to YUV conversion and stores the result in YUV422 planar format,
/// with separate planes for Y (luminance), U (chrominance), and V (chrominance) components.
///
/// # Arguments
///
/// * `planar_image` - Target planar image.
/// * `bgra` - The input BGRA image data slice.
/// * `bgra_stride` - The stride (components per row) for the BGRA image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
/// * `mode` - See [YuvConversionMode] for more info.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGRA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn bgra_to_yuv422(
    planar_image: &mut YuvPlanarImageMut<u8>,
    bgra: &[u8],
    bgra_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    rgbx_to_yuv8::<{ YuvSourceChannels::Bgra as u8 }, { YuvChromaSubsampling::Yuv422 as u8 }>(
        planar_image,
        bgra,
        bgra_stride,
        range,
        matrix,
        mode,
    )
}

/// Convert RGB image data to YUV 420 planar format.
///
/// This function performs RGB to YUV conversion and stores the result in YUV420 planar format,
/// with separate planes for Y (luminance), U (chrominance), and V (chrominance) components.
///
/// # Arguments
///
/// * `planar_image` - Target planar image.
/// * `rgb` - The input RGB image data slice.
/// * `rgb_stride` - The stride (components per row) for the RGB image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
/// * `mode` - See [YuvConversionMode] for more info.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input RGB data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn rgb_to_yuv420(
    planar_image: &mut YuvPlanarImageMut<u8>,
    rgb: &[u8],
    rgb_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    rgbx_to_yuv8::<{ YuvSourceChannels::Rgb as u8 }, { YuvChromaSubsampling::Yuv420 as u8 }>(
        planar_image,
        rgb,
        rgb_stride,
        range,
        matrix,
        mode,
    )
}

/// Convert BGR image data to YUV 420 planar format.
///
/// This function performs BGR to YUV conversion and stores the result in YUV420 planar format,
/// with separate planes for Y (luminance), U (chrominance), and V (chrominance) components.
///
/// # Arguments
///
/// * `planar_image` - Target planar image.
/// * `bgr` - The input BGR image data slice.
/// * `bgr_stride` - The stride (components per row) for the BGR image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
/// * `mode` - See [YuvConversionMode] for more info.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input RGB data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn bgr_to_yuv420(
    planar_image: &mut YuvPlanarImageMut<u8>,
    bgr: &[u8],
    bgr_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    rgbx_to_yuv8::<{ YuvSourceChannels::Bgr as u8 }, { YuvChromaSubsampling::Yuv420 as u8 }>(
        planar_image,
        bgr,
        bgr_stride,
        range,
        matrix,
        mode,
    )
}

/// Convert RGBA image data to YUV 420 planar format.
///
/// This function performs RGBA to YUV conversion and stores the result in YUV420 planar format,
/// with separate planes for Y (luminance), U (chrominance), and V (chrominance) components.
///
/// # Arguments
///
/// * `planar_image` - Target planar image.
/// * `rgba` - The input RGBA image data slice.
/// * `rgba_stride` - The stride (components per row) for the RGBA image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
/// * `mode` - See [YuvConversionMode] for more info.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input RGBA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn rgba_to_yuv420(
    planar_image: &mut YuvPlanarImageMut<u8>,
    rgba: &[u8],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    rgbx_to_yuv8::<{ YuvSourceChannels::Rgba as u8 }, { YuvChromaSubsampling::Yuv420 as u8 }>(
        planar_image,
        rgba,
        rgba_stride,
        range,
        matrix,
        mode,
    )
}

/// Convert BGRA image data to YUV 420 planar format.
///
/// This function performs BGRA to YUV conversion and stores the result in YUV420 planar format,
/// with separate planes for Y (luminance), U (chrominance), and V (chrominance) components.
///
/// # Arguments
///
/// * `planar_image` - Target planar image.
/// * `bgra` - The input BGRA image data slice.
/// * `bgra_stride` - The stride (components per row) for the BGRA image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
/// * `mode` - See [YuvConversionMode] for more info.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGRA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn bgra_to_yuv420(
    planar_image: &mut YuvPlanarImageMut<u8>,
    bgra: &[u8],
    bgra_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    rgbx_to_yuv8::<{ YuvSourceChannels::Bgra as u8 }, { YuvChromaSubsampling::Yuv420 as u8 }>(
        planar_image,
        bgra,
        bgra_stride,
        range,
        matrix,
        mode,
    )
}

/// Convert RGB image data to YUV 444 planar format.
///
/// This function performs RGB to YUV conversion and stores the result in YUV444 planar format,
/// with separate planes for Y (luminance), U (chrominance), and V (chrominance) components.
///
/// # Arguments
///
/// * `planar_image` - Target planar image.
/// * `rgb` - The input RGB image data slice.
/// * `rgb_stride` - The stride (components per row) for the RGB image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
/// * `mode` - See [YuvConversionMode] for more info.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input RGB data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn rgb_to_yuv444(
    planar_image: &mut YuvPlanarImageMut<u8>,
    rgb: &[u8],
    rgb_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    rgbx_to_yuv8::<{ YuvSourceChannels::Rgb as u8 }, { YuvChromaSubsampling::Yuv444 as u8 }>(
        planar_image,
        rgb,
        rgb_stride,
        range,
        matrix,
        mode,
    )
}

/// Convert BGR image data to YUV 444 planar format.
///
/// This function performs BGR to YUV conversion and stores the result in YUV444 planar format,
/// with separate planes for Y (luminance), U (chrominance), and V (chrominance) components.
///
/// # Arguments
///
/// * `planar_image` - Target planar image.
/// * `bgr` - The input BGR image data slice.
/// * `bgr_stride` - The stride (components per row) for the BGR image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
/// * `mode` - See [YuvConversionMode] for more info.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGR data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn bgr_to_yuv444(
    planar_image: &mut YuvPlanarImageMut<u8>,
    bgr: &[u8],
    bgr_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    rgbx_to_yuv8::<{ YuvSourceChannels::Bgr as u8 }, { YuvChromaSubsampling::Yuv444 as u8 }>(
        planar_image,
        bgr,
        bgr_stride,
        range,
        matrix,
        mode,
    )
}

/// Convert RGBA image data to YUV 444 planar format.
///
/// This function performs RGBA to YUV conversion and stores the result in YUV444 planar format,
/// with separate planes for Y (luminance), U (chrominance), and V (chrominance) components.
///
/// # Arguments
///
/// * `planar_image` - Target planar image.
/// * `rgba` - The input RGBA image data slice.
/// * `rgba_stride` - The stride (components per row) for the RGBA image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
/// * `mode` - See [YuvConversionMode] for more info.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input RGBA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn rgba_to_yuv444(
    planar_image: &mut YuvPlanarImageMut<u8>,
    rgba: &[u8],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    rgbx_to_yuv8::<{ YuvSourceChannels::Rgba as u8 }, { YuvChromaSubsampling::Yuv444 as u8 }>(
        planar_image,
        rgba,
        rgba_stride,
        range,
        matrix,
        mode,
    )
}

/// Convert BGRA image data to YUV 444 planar format.
///
/// This function performs BGRA to YUV conversion and stores the result in YUV444 planar format,
/// with separate planes for Y (luminance), U (chrominance), and V (chrominance) components.
///
/// # Arguments
///
/// * `planar_image` - Target planar image.
/// * `bgra` - The input BGRA image data slice.
/// * `bgra_stride` - The stride (components per row) for the BGRA image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
/// * `mode` - See [YuvConversionMode] for more info.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGRA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn bgra_to_yuv444(
    planar_image: &mut YuvPlanarImageMut<u8>,
    bgra: &[u8],
    bgra_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    mode: YuvConversionMode,
) -> Result<(), YuvError> {
    rgbx_to_yuv8::<{ YuvSourceChannels::Bgra as u8 }, { YuvChromaSubsampling::Yuv444 as u8 }>(
        planar_image,
        bgra,
        bgra_stride,
        range,
        matrix,
        mode,
    )
}
