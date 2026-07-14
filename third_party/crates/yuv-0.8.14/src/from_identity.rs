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
#![forbid(unsafe_code)]
use crate::images::projected_rgba_plane_mut;
use crate::numerics::qrshr;
use crate::yuv_error::check_rgba_destination;
use crate::yuv_support::{get_yuv_range, YuvSourceChannels};
use crate::{YuvChromaSubsampling, YuvError, YuvPlanarImage, YuvRange};
use num_traits::AsPrimitive;
#[cfg(feature = "rayon")]
use rayon::iter::{IndexedParallelIterator, ParallelIterator};
#[cfg(feature = "rayon")]
use rayon::prelude::{ParallelSlice, ParallelSliceMut};
use std::fmt::Debug;
use std::marker::PhantomData;
use std::mem::size_of;
use std::ops::Sub;

type TypicalHandlerLimited = fn(
    g_plane: &[u8],
    b_plane: &[u8],
    r_plane: &[u8],
    rgba: &mut [u8],
    start_cx: usize,
    width: usize,
    y_bias: i32,
    y_coeff: i32,
) -> usize;

type TypicalHandler = fn(
    g_plane: &[u8],
    b_plane: &[u8],
    r_plane: &[u8],
    rgba: &mut [u8],
    start_cx: usize,
    width: usize,
) -> usize;

struct WideRowGbrProcessor<T, const DEST: u8, const BIT_DEPTH: usize> {
    _phantom: PhantomData<T>,
    handler: Option<TypicalHandler>,
}

impl<T, const DEST: u8, const BIT_DEPTH: usize> Default
    for WideRowGbrProcessor<T, DEST, BIT_DEPTH>
{
    fn default() -> Self {
        #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
        {
            use crate::neon::yuv_to_rgba_row_full;
            WideRowGbrProcessor {
                _phantom: Default::default(),
                handler: Some(yuv_to_rgba_row_full::<DEST>),
            }
        }

        #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
        {
            #[cfg(feature = "avx")]
            {
                if std::arch::is_x86_feature_detected!("avx2") {
                    use crate::avx2::avx_yuv_to_rgba_row_full;
                    return WideRowGbrProcessor {
                        _phantom: Default::default(),
                        handler: Some(avx_yuv_to_rgba_row_full::<DEST>),
                    };
                }
            }
            #[cfg(feature = "sse")]
            {
                if std::arch::is_x86_feature_detected!("sse4.1") {
                    use crate::sse::sse_yuv_to_rgba_row_full;
                    return WideRowGbrProcessor {
                        _phantom: Default::default(),
                        handler: Some(sse_yuv_to_rgba_row_full::<DEST>),
                    };
                }
            }
        }

        #[cfg(not(all(target_arch = "aarch64", target_feature = "neon")))]
        WideRowGbrProcessor {
            _phantom: PhantomData,
            handler: None,
        }
    }
}

struct WideRowGbrLimitedProcessor<T, const DEST: u8, const BIT_DEPTH: usize, const PRECISION: i32> {
    _phantom: PhantomData<T>,
    handler: Option<TypicalHandlerLimited>,
}

impl<T, const DEST: u8, const BIT_DEPTH: usize, const PRECISION: i32> Default
    for WideRowGbrLimitedProcessor<T, DEST, BIT_DEPTH, PRECISION>
{
    fn default() -> Self {
        if PRECISION != 13 {
            return WideRowGbrLimitedProcessor {
                _phantom: Default::default(),
                handler: None,
            };
        }
        assert_eq!(PRECISION, 13);
        #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
        {
            #[cfg(feature = "rdm")]
            if std::arch::is_aarch64_feature_detected!("rdm") {
                use crate::neon::yuv_to_rgba_row_limited_rdm;
                return WideRowGbrLimitedProcessor {
                    _phantom: Default::default(),
                    handler: Some(yuv_to_rgba_row_limited_rdm::<DEST>),
                };
            }
            use crate::neon::yuv_to_rgba_row_limited;
            WideRowGbrLimitedProcessor {
                _phantom: Default::default(),
                handler: Some(yuv_to_rgba_row_limited::<DEST, PRECISION>),
            }
        }
        #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
        {
            #[cfg(all(any(target_arch = "x86", target_arch = "x86_64"), feature = "avx"))]
            {
                if std::arch::is_x86_feature_detected!("avx2") {
                    use crate::avx2::avx_yuv_to_rgba_row_limited;
                    return WideRowGbrLimitedProcessor {
                        _phantom: Default::default(),
                        handler: Some(avx_yuv_to_rgba_row_limited::<DEST>),
                    };
                }
            }
            #[cfg(all(any(target_arch = "x86", target_arch = "x86_64"), feature = "sse"))]
            {
                if std::arch::is_x86_feature_detected!("sse4.1") {
                    use crate::sse::sse_yuv_to_rgba_row_limited;
                    return WideRowGbrLimitedProcessor {
                        _phantom: Default::default(),
                        handler: Some(sse_yuv_to_rgba_row_limited::<DEST>),
                    };
                }
            }
        }
        #[cfg(not(all(target_arch = "aarch64", target_feature = "neon")))]
        WideRowGbrLimitedProcessor {
            _phantom: Default::default(),
            handler: None,
        }
    }
}

trait FullRangeWideRow<V> {
    fn handle_row(
        &self,
        g_plane: &[V],
        b_plane: &[V],
        r_plane: &[V],
        rgba: &mut [V],
        start_cx: usize,
        width: usize,
    ) -> usize;
}

trait LimitedRangeWideRow<V> {
    fn handle_row(
        &self,
        g_plane: &[V],
        b_plane: &[V],
        r_plane: &[V],
        rgba: &mut [V],
        start_cx: usize,
        width: usize,
        y_bias: i32,
        y_coeff: i32,
    ) -> usize;
}

impl<const DEST: u8, const BIT_DEPTH: usize> FullRangeWideRow<u8>
    for WideRowGbrProcessor<u8, DEST, BIT_DEPTH>
{
    fn handle_row(
        &self,
        _g_plane: &[u8],
        _b_plane: &[u8],
        _r_plane: &[u8],
        _rgba: &mut [u8],
        _start_cx: usize,
        _width: usize,
    ) -> usize {
        if let Some(handler) = self.handler {
            return handler(_g_plane, _b_plane, _r_plane, _rgba, 0, _width);
        }
        0
    }
}

impl<const DEST: u8, const BIT_DEPTH: usize> FullRangeWideRow<u16>
    for WideRowGbrProcessor<u16, DEST, BIT_DEPTH>
{
    fn handle_row(
        &self,
        _g_plane: &[u16],
        _b_plane: &[u16],
        _r_plane: &[u16],
        _rgba: &mut [u16],
        _start_cx: usize,
        _width: usize,
    ) -> usize {
        0
    }
}

impl<const DEST: u8, const BIT_DEPTH: usize, const PRECISION: i32> LimitedRangeWideRow<u8>
    for WideRowGbrLimitedProcessor<u8, DEST, BIT_DEPTH, PRECISION>
{
    fn handle_row(
        &self,
        _g_plane: &[u8],
        _b_plane: &[u8],
        _r_plane: &[u8],
        _rgba: &mut [u8],
        _start_cx: usize,
        _width: usize,
        _y_bias: i32,
        _y_coeff: i32,
    ) -> usize {
        if let Some(handler) = self.handler {
            return handler(
                _g_plane, _b_plane, _r_plane, _rgba, 0, _width, _y_bias, _y_coeff,
            );
        }
        0
    }
}

impl<const DEST: u8, const BIT_DEPTH: usize, const PRECISION: i32> LimitedRangeWideRow<u16>
    for WideRowGbrLimitedProcessor<u16, DEST, BIT_DEPTH, PRECISION>
{
    fn handle_row(
        &self,
        _g_plane: &[u16],
        _b_plane: &[u16],
        _r_plane: &[u16],
        _rgba: &mut [u16],
        _start_cx: usize,
        _width: usize,
        _y_bias: i32,
        _y_coeff: i32,
    ) -> usize {
        0
    }
}

#[inline]
fn gbr_to_rgbx_impl<
    V: Copy + AsPrimitive<J> + AsPrimitive<u32> + 'static + Sized + Debug + Send + Sync,
    J: Copy + Sub<Output = J> + AsPrimitive<i32> + Sync + Send + Ord,
    const CHANNELS: u8,
    const BIT_DEPTH: usize,
>(
    image: &YuvPlanarImage<V>,
    rgba: &mut [V],
    rgba_stride: u32,
    yuv_range: YuvRange,
) -> Result<(), YuvError>
where
    i32: AsPrimitive<V>,
    u32: AsPrimitive<J> + AsPrimitive<V>,
    WideRowGbrProcessor<V, CHANNELS, BIT_DEPTH>: FullRangeWideRow<V>,
    WideRowGbrLimitedProcessor<V, CHANNELS, BIT_DEPTH, 13>: LimitedRangeWideRow<V>,
{
    let cn: YuvSourceChannels = CHANNELS.into();
    let channels = cn.get_channels_count();
    assert!(
        channels == 3 || channels == 4,
        "GBR -> RGB is implemented only on 3 and 4 channels"
    );
    assert!(
        (8..=16).contains(&BIT_DEPTH),
        "Invalid bit depth is provided"
    );
    assert!(
        if BIT_DEPTH > 8 {
            size_of::<V>() == 2
        } else {
            size_of::<V>() == 1
        },
        "Unsupported bit depth and data type combination"
    );
    let y_stride = image.y_stride as usize;
    let u_stride = image.u_stride as usize;
    let v_stride = image.v_stride as usize;
    let height = image.height;

    image.check_constraints(YuvChromaSubsampling::Yuv444)?;
    check_rgba_destination(rgba, rgba_stride, image.width, height, channels)?;

    let max_value = (1i32 << BIT_DEPTH) - 1;
    let max_value_u32: u32 = ((1u32 << BIT_DEPTH) - 1).as_();

    let y_iter;
    let rgb_iter;
    let u_iter;
    let v_iter;

    let (y_plane, u_plane, v_plane) = image.projected_planes(YuvChromaSubsampling::Yuv444);
    let rgba = projected_rgba_plane_mut(rgba, image.width, image.height, rgba_stride, cn);

    #[cfg(feature = "rayon")]
    {
        y_iter = y_plane.par_chunks(y_stride);
        rgb_iter = rgba.par_chunks_mut(rgba_stride as usize);
        u_iter = u_plane.par_chunks(u_stride);
        v_iter = v_plane.par_chunks(v_stride);
    }
    #[cfg(not(feature = "rayon"))]
    {
        y_iter = y_plane.chunks(y_stride);
        rgb_iter = rgba.chunks_mut(rgba_stride as usize);
        u_iter = u_plane.chunks(u_stride);
        v_iter = v_plane.chunks(v_stride);
    }

    match yuv_range {
        YuvRange::Limited => {
            const PRECISION: i32 = 13;
            // All channels on identity should use Y range
            let range = get_yuv_range(BIT_DEPTH as u32, yuv_range);
            let range_rgba = (1 << BIT_DEPTH) - 1;
            let y_coef = ((range_rgba as f32 / range.range_y as f32) * (1 << PRECISION) as f32)
                .round() as i32;
            let y_bias: J = range.bias_y.as_();
            let jy_bias = range.bias_y as i32;

            let iter = y_iter.zip(u_iter).zip(v_iter).zip(rgb_iter);

            let wide_handler = WideRowGbrLimitedProcessor::<V, CHANNELS, BIT_DEPTH, 13>::default();

            iter.for_each(|(((y_src, u_src), v_src), rgb)| {
                let y_src = &y_src[0..image.width as usize];

                let cx = wide_handler.handle_row(
                    y_src,
                    u_src,
                    v_src,
                    rgb,
                    0,
                    image.width as usize,
                    jy_bias,
                    y_coef,
                );

                let rgb_chunks = rgb.chunks_exact_mut(channels);

                for (((&y_src, &u_src), &v_src), rgb_dst) in
                    y_src.iter().zip(u_src).zip(v_src).zip(rgb_chunks).skip(cx)
                {
                    let v_32: J = v_src.as_();
                    let y_32: J = y_src.as_();
                    let u_32: J = u_src.as_();
                    rgb_dst[cn.get_r_channel_offset()] =
                        qrshr::<PRECISION, BIT_DEPTH>((v_32 - y_bias).as_() * y_coef).as_();
                    rgb_dst[cn.get_g_channel_offset()] =
                        qrshr::<PRECISION, BIT_DEPTH>((y_32 - y_bias).as_() * y_coef).as_();
                    rgb_dst[cn.get_b_channel_offset()] =
                        qrshr::<PRECISION, BIT_DEPTH>((u_32 - y_bias).as_() * y_coef).as_();
                    if channels == 4 {
                        rgb_dst[cn.get_a_channel_offset()] = max_value.as_();
                    }
                }
            });
        }
        YuvRange::Full => {
            let wide_handler = WideRowGbrProcessor::<V, CHANNELS, BIT_DEPTH>::default();
            let iter = y_iter.zip(u_iter).zip(v_iter).zip(rgb_iter);
            iter.for_each(|(((y_src, u_src), v_src), rgb)| {
                let y_src = &y_src[..image.width as usize];

                let cx = wide_handler.handle_row(y_src, u_src, v_src, rgb, 0, image.width as usize);

                let rgb_chunks = rgb.chunks_exact_mut(channels);

                if size_of::<V>() == 1 {
                    for (((&y_src, &u_src), &v_src), rgb_dst) in
                        y_src.iter().zip(u_src).zip(v_src).zip(rgb_chunks).skip(cx)
                    {
                        rgb_dst[cn.get_r_channel_offset()] = v_src;
                        rgb_dst[cn.get_g_channel_offset()] = y_src;
                        rgb_dst[cn.get_b_channel_offset()] = u_src;
                        if channels == 4 {
                            rgb_dst[cn.get_a_channel_offset()] = max_value.as_();
                        }
                    }
                } else {
                    for (((&y_src, &u_src), &v_src), rgb_dst) in
                        y_src.iter().zip(u_src).zip(v_src).zip(rgb_chunks).skip(cx)
                    {
                        let v_32: u32 = v_src.as_();
                        let y_32: u32 = y_src.as_();
                        let u_32: u32 = u_src.as_();
                        rgb_dst[cn.get_r_channel_offset()] = v_32.min(max_value_u32).as_();
                        rgb_dst[cn.get_g_channel_offset()] = y_32.min(max_value_u32).as_();
                        rgb_dst[cn.get_b_channel_offset()] = u_32.min(max_value_u32).as_();
                        if channels == 4 {
                            rgb_dst[cn.get_a_channel_offset()] = max_value.as_();
                        }
                    }
                }
            });
        }
    }

    Ok(())
}

/// Convert YUV Identity Matrix ( aka 'GBR ) to RGB
///
/// This function takes GBR planar format data with 8-bit precision,
/// and converts it to RGB format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `image` - Source GBR image.
/// * `rgb` - A slice to store the RGB data.
/// * `rgb_stride` - The stride (components per row) for the RGB.
/// * `range` - Yuv values range.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input RGB data are not valid based
/// on the specified width, height, and strides is provided.
///
pub fn gbr_to_rgb(
    image: &YuvPlanarImage<u8>,
    rgb: &mut [u8],
    rgb_stride: u32,
    range: YuvRange,
) -> Result<(), YuvError> {
    gbr_to_rgbx_impl::<u8, i16, { YuvSourceChannels::Rgb as u8 }, 8>(image, rgb, rgb_stride, range)
}

/// Convert YUV Identity Matrix ( aka 'GBR ) to BGR
///
/// This function takes GBR planar format data with 8-bit precision,
/// and converts it to BGR format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `image` - Source GBR image.
/// * `bgr` - A slice to store the BGR data.
/// * `bgr_stride` - The stride (components per row) for the BGR.
/// * `range` - Yuv values range.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGR data are not valid based
/// on the specified width, height, and strides is provided.
///
pub fn gbr_to_bgr(
    image: &YuvPlanarImage<u8>,
    bgr: &mut [u8],
    bgr_stride: u32,
    range: YuvRange,
) -> Result<(), YuvError> {
    gbr_to_rgbx_impl::<u8, i16, { YuvSourceChannels::Bgr as u8 }, 8>(image, bgr, bgr_stride, range)
}

/// Convert YUV Identity Matrix ( aka 'GBR ) to RGBA
///
/// This function takes GBR planar format data with 8-bit precision,
/// and converts it to RGBA format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `image` - Source GBR image.
/// * `rgba` - A slice to store the RGBA data.
/// * `rgba_stride` - The stride (components per row) for the RGBA.
/// * `range` - Yuv values range.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input RGBA data are not valid based
/// on the specified width, height, and strides is provided.
///
pub fn gbr_to_rgba(
    image: &YuvPlanarImage<u8>,
    rgb: &mut [u8],
    rgb_stride: u32,
    range: YuvRange,
) -> Result<(), YuvError> {
    gbr_to_rgbx_impl::<u8, i16, { YuvSourceChannels::Rgba as u8 }, 8>(image, rgb, rgb_stride, range)
}

/// Convert YUV Identity Matrix ( aka 'GBR ) to BGRA
///
/// This function takes GBR planar format data with 8-bit precision,
/// and converts it to BGRA format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `image` - Source GBR image.
/// * `rgba` - A slice to store the BGRA data.
/// * `rgba_stride` - The stride (components per row) for the BGRA.
/// * `range` - Yuv values range.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGRA data are not valid based
/// on the specified width, height, and strides is provided.
///
pub fn gbr_to_bgra(
    image: &YuvPlanarImage<u8>,
    rgb: &mut [u8],
    rgb_stride: u32,
    range: YuvRange,
) -> Result<(), YuvError> {
    gbr_to_rgbx_impl::<u8, i16, { YuvSourceChannels::Bgra as u8 }, 8>(image, rgb, rgb_stride, range)
}

/// Convert GBR 12 bit-depth to RGB
///
/// This function takes GBR planar format data with 12 bit precision,
/// and converts it to RGB format with 12 bit per channel precision.
///
/// # Arguments
///
/// * `image` - Source GBR image.
/// * `rgb` - A slice to store the RGB data.
/// * `rgb_stride` - The stride (components per row) for the RGB.
/// * `range` - Yuv values range.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input RGB data are not valid based
/// on the specified width, height, and strides is provided.
///
pub fn gb12_to_rgb12(
    image: &YuvPlanarImage<u16>,
    rgb: &mut [u16],
    rgb_stride: u32,
    range: YuvRange,
) -> Result<(), YuvError> {
    gbr_to_rgbx_impl::<u16, i16, { YuvSourceChannels::Rgb as u8 }, 12>(
        image, rgb, rgb_stride, range,
    )
}

/// Convert YUV Identity Matrix ( aka 'GBR ) to RGB
///
/// This function takes GBR planar format data with 8+ bit precision,
/// and converts it to RGB format with 8+ bit per channel precision.
///
/// # Arguments
///
/// * `image` - Source GBR image.
/// * `rgb` - A slice to store the RGB data.
/// * `rgb_stride` - The stride (components per row) for the RGB.
/// * `bit_depth` - YUV and RGB bit depth, only 10 and 12 is supported.
/// * `range` - Yuv values range.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input RGB data are not valid based
/// on the specified width, height, and strides is provided.
///
pub fn gb10_to_rgb10(
    image: &YuvPlanarImage<u16>,
    rgb: &mut [u16],
    rgb_stride: u32,
    range: YuvRange,
) -> Result<(), YuvError> {
    gbr_to_rgbx_impl::<u16, i16, { YuvSourceChannels::Rgb as u8 }, 10>(
        image, rgb, rgb_stride, range,
    )
}

/// Convert GBR10 to RGBA10
///
/// This function takes GBR planar format data with 10 bit precision,
/// and converts it to RGBA format with 10 bit per channel precision.
///
/// # Arguments
///
/// * `image` - Source GBR image.
/// * `rgba` - A slice to store the RGBA data.
/// * `rgba_stride` - The stride (components per row) for the RGBA.
/// * `range` - Yuv values range.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input RGBA data are not valid based
/// on the specified width, height, and strides is provided.
///
pub fn gb10_to_rgba10(
    image: &YuvPlanarImage<u16>,
    rgba: &mut [u16],
    rgba_stride: u32,
    range: YuvRange,
) -> Result<(), YuvError> {
    gbr_to_rgbx_impl::<u16, i16, { YuvSourceChannels::Rgba as u8 }, 10>(
        image,
        rgba,
        rgba_stride,
        range,
    )
}

/// Convert GBR12 to RGBA12
///
/// This function takes GBR planar format data with 12 bit precision,
/// and converts it to RGBA format with 12 bit per channel precision.
///
/// # Arguments
///
/// * `image` - Source GBR image.
/// * `rgba` - A slice to store the RGBA data.
/// * `rgba_stride` - The stride (components per row) for the RGBA.
/// * `range` - Yuv values range.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input RGBA data are not valid based
/// on the specified width, height, and strides is provided.
///
pub fn gb12_to_rgba12(
    image: &YuvPlanarImage<u16>,
    rgba: &mut [u16],
    rgba_stride: u32,
    range: YuvRange,
) -> Result<(), YuvError> {
    gbr_to_rgbx_impl::<u16, i16, { YuvSourceChannels::Rgba as u8 }, 12>(
        image,
        rgba,
        rgba_stride,
        range,
    )
}

/// Convert GBR 14 bit-depth to RGB14
///
/// This function takes GBR planar format data with 14 bit precision,
/// and converts it to RGB format with 14 bit per channel precision.
///
/// # Arguments
///
/// * `image` - Source GBR image.
/// * `rgb` - A slice to store the RGB data.
/// * `rgb_stride` - The stride (components per row) for the RGB.
/// * `range` - Yuv values range.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input RGB data are not valid based
/// on the specified width, height, and strides is provided.
///
pub fn gb14_to_rgb14(
    image: &YuvPlanarImage<u16>,
    rgb: &mut [u16],
    rgb_stride: u32,
    range: YuvRange,
) -> Result<(), YuvError> {
    gbr_to_rgbx_impl::<u16, i16, { YuvSourceChannels::Rgb as u8 }, 14>(
        image, rgb, rgb_stride, range,
    )
}

/// Convert GBR14 to RGBA14
///
/// This function takes GBR planar format data with 14 bit precision,
/// and converts it to RGBA format with 14 bit per channel precision.
///
/// # Arguments
///
/// * `image` - Source GBR image.
/// * `rgba` - A slice to store the RGBA data.
/// * `rgba_stride` - The stride (components per row) for the RGBA.
/// * `range` - Yuv values range.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input RGBA data are not valid based
/// on the specified width, height, and strides is provided.
///
pub fn gb14_to_rgba14(
    image: &YuvPlanarImage<u16>,
    rgba: &mut [u16],
    rgba_stride: u32,
    range: YuvRange,
) -> Result<(), YuvError> {
    gbr_to_rgbx_impl::<u16, i16, { YuvSourceChannels::Rgba as u8 }, 14>(
        image,
        rgba,
        rgba_stride,
        range,
    )
}

/// Convert GBR16 bit-depth to RGB16
///
/// This function takes GBR planar format data with 16 bit precision,
/// and converts it to RGB format with 16 bit per channel precision.
///
/// # Arguments
///
/// * `image` - Source GBR image.
/// * `rgb` - A slice to store the RGB data.
/// * `rgb_stride` - The stride (components per row) for the RGB.
/// * `range` - Yuv values range.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input RGB data are not valid based
/// on the specified width, height, and strides is provided.
///
pub fn gb16_to_rgb16(
    image: &YuvPlanarImage<u16>,
    rgb: &mut [u16],
    rgb_stride: u32,
    range: YuvRange,
) -> Result<(), YuvError> {
    gbr_to_rgbx_impl::<u16, i32, { YuvSourceChannels::Rgb as u8 }, 16>(
        image, rgb, rgb_stride, range,
    )
}

/// Convert GBR16 to RGBA16
///
/// This function takes GBR planar format data with 16 bit precision,
/// and converts it to RGBA format with 16 bit per channel precision.
///
/// # Arguments
///
/// * `image` - Source GBR image.
/// * `rgba` - A slice to store the RGBA data.
/// * `rgba_stride` - The stride (components per row) for the RGBA.
/// * `range` - Yuv values range.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input RGBA data are not valid based
/// on the specified width, height, and strides is provided.
///
pub fn gb16_to_rgba16(
    image: &YuvPlanarImage<u16>,
    rgba: &mut [u16],
    rgba_stride: u32,
    range: YuvRange,
) -> Result<(), YuvError> {
    gbr_to_rgbx_impl::<u16, i32, { YuvSourceChannels::Rgba as u8 }, 16>(
        image,
        rgba,
        rgba_stride,
        range,
    )
}
