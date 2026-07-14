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
#[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
use crate::neon::neon_y_to_rgb_alpha_row;
use crate::numerics::qrshr;
use crate::yuv_error::check_rgba_destination;
use crate::yuv_support::*;
use crate::{YuvError, YuvGrayAlphaImage};
use num_traits::AsPrimitive;
#[cfg(feature = "rayon")]
use rayon::iter::{IndexedParallelIterator, ParallelIterator};
#[cfg(feature = "rayon")]
use rayon::prelude::{ParallelSlice, ParallelSliceMut};
use std::fmt::Debug;
use std::marker::PhantomData;

struct WideRowProcessor<T> {
    _phantom: PhantomData<T>,
    #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
    _use_rdm: bool,
    #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
    _use_sse: bool,
    #[cfg(all(any(target_arch = "x86", target_arch = "x86_64"), feature = "avx"))]
    _use_avx: bool,
}

impl<V> Default for WideRowProcessor<V> {
    fn default() -> Self {
        WideRowProcessor {
            _phantom: PhantomData,
            #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
            _use_rdm: std::arch::is_aarch64_feature_detected!("rdm"),
            #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
            _use_sse: std::arch::is_x86_feature_detected!("sse4.1"),
            #[cfg(all(any(target_arch = "x86", target_arch = "x86_64"), feature = "avx"))]
            _use_avx: std::arch::is_x86_feature_detected!("avx2"),
        }
    }
}

trait ProcessRowHandler<V> {
    fn handle_row<const PRECISION: i32, const DESTINATION_CHANNELS: u8>(
        &self,
        range: &YuvChromaRange,
        transform: &CbCrInverseTransform<i32>,
        y_plane: &[V],
        a_plane: &[V],
        rgba: &mut [V],
        start_cx: usize,
        width: usize,
    ) -> usize;
}

impl ProcessRowHandler<u16> for WideRowProcessor<u16> {
    fn handle_row<const PRECISION: i32, const DESTINATION_CHANNELS: u8>(
        &self,
        _range: &YuvChromaRange,
        _transform: &CbCrInverseTransform<i32>,
        _y_plane: &[u16],
        _a_plane: &[u16],
        _rgba: &mut [u16],
        _start_cx: usize,
        _width: usize,
    ) -> usize {
        0
    }
}

impl ProcessRowHandler<u8> for WideRowProcessor<u8> {
    fn handle_row<const PRECISION: i32, const DESTINATION_CHANNELS: u8>(
        &self,
        _range: &YuvChromaRange,
        _transform: &CbCrInverseTransform<i32>,
        _y_plane: &[u8],
        _a_plane: &[u8],
        _rgba: &mut [u8],
        _start_cx: usize,
        _width: usize,
    ) -> usize {
        let mut _cx = _start_cx;
        #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
        unsafe {
            let neon_wide_row_handler = if self._use_rdm {
                #[cfg(feature = "rdm")]
                {
                    use crate::neon::neon_y_to_rgb_row_alpha_rdm;
                    neon_y_to_rgb_row_alpha_rdm::<DESTINATION_CHANNELS>
                }
                #[cfg(not(feature = "rdm"))]
                {
                    neon_y_to_rgb_alpha_row::<DESTINATION_CHANNELS>
                }
            } else {
                neon_y_to_rgb_alpha_row::<DESTINATION_CHANNELS>
            };

            let offset =
                neon_wide_row_handler(_range, _transform, _y_plane, _a_plane, _rgba, _cx, _width);
            _cx = offset;
        }
        #[cfg(all(any(target_arch = "x86", target_arch = "x86_64"), feature = "avx"))]
        if self._use_avx {
            use crate::avx2::avx2_y_to_rgba_alpha_row;
            let offset = avx2_y_to_rgba_alpha_row::<DESTINATION_CHANNELS>(
                _range, _transform, _y_plane, _a_plane, _rgba, _cx, _width,
            );
            _cx = offset;
        }
        #[cfg(all(any(target_arch = "x86", target_arch = "x86_64"), feature = "sse"))]
        if self._use_sse {
            use crate::sse::sse_y_to_rgba_alpha_row;
            let offset = sse_y_to_rgba_alpha_row::<DESTINATION_CHANNELS>(
                _range, _transform, _y_plane, _a_plane, _rgba, _cx, _width,
            );
            _cx = offset;
        }
        _cx
    }
}

// Chroma subsampling always assumed as 400
#[inline]
fn y_with_alpha_to_rgbx<
    V: Copy + AsPrimitive<i16> + 'static + Send + Sync + Debug + Default + Clone,
    const DESTINATION_CHANNELS: u8,
    const BIT_DEPTH: usize,
>(
    image: &YuvGrayAlphaImage<V>,
    rgba: &mut [V],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError>
where
    i32: AsPrimitive<V>,
    WideRowProcessor<V>: ProcessRowHandler<V>,
{
    let destination_channels: YuvSourceChannels = DESTINATION_CHANNELS.into();
    let channels = destination_channels.get_channels_count();
    assert!(
        destination_channels.has_alpha(),
        "YUV400 with alpha cannot be called on target image without alpha"
    );
    assert_eq!(
        channels, 4,
        "YUV400 with alpha cannot be called on target image without alpha"
    );
    assert!(
        (8..=16).contains(&BIT_DEPTH),
        "Invalid bit depth is provided"
    );

    check_rgba_destination(rgba, rgba_stride, image.width, image.height, channels)?;
    image.check_constraints()?;

    let chroma_range = get_yuv_range(BIT_DEPTH as u32, range);
    let kr_kb = matrix.get_kr_kb();
    const PRECISION: i32 = 13;
    let inverse_transform =
        search_inverse_transform(PRECISION, 8, range, matrix, chroma_range, kr_kb);
    let y_coef = inverse_transform.y_coef as i16;
    let bias_y = chroma_range.bias_y as i16;

    let iter;
    let y_iter;
    let a_iter;
    #[cfg(feature = "rayon")]
    {
        iter = rgba.par_chunks_exact_mut(rgba_stride as usize);
        y_iter = image.y_plane.par_chunks_exact(image.y_stride as usize);
        a_iter = image.a_plane.par_chunks_exact(image.a_stride as usize);
    }
    #[cfg(not(feature = "rayon"))]
    {
        iter = rgba.chunks_exact_mut(rgba_stride as usize);
        y_iter = image.y_plane.chunks_exact(image.y_stride as usize);
        a_iter = image.a_plane.chunks_exact(image.a_stride as usize);
    }

    if range == YuvRange::Limited {
        let handler = WideRowProcessor::<V>::default();
        iter.zip(y_iter)
            .zip(a_iter)
            .for_each(|((rgba, y_plane), a_plane)| {
                let y_plane = &y_plane[..image.width as usize];
                let mut _cx = 0usize;

                let offset = handler.handle_row::<PRECISION, DESTINATION_CHANNELS>(
                    &chroma_range,
                    &inverse_transform,
                    y_plane,
                    a_plane,
                    rgba,
                    _cx,
                    image.width as usize,
                );
                _cx = offset;

                for ((y_src, a_src), rgba) in y_plane
                    .iter()
                    .zip(a_plane)
                    .zip(rgba.chunks_exact_mut(channels))
                    .skip(_cx)
                {
                    let y_value = (y_src.as_() - bias_y) as i32 * y_coef as i32;

                    let r = qrshr::<PRECISION, BIT_DEPTH>(y_value);
                    rgba[destination_channels.get_r_channel_offset()] = r.as_();
                    rgba[destination_channels.get_g_channel_offset()] = r.as_();
                    rgba[destination_channels.get_b_channel_offset()] = r.as_();
                    rgba[destination_channels.get_a_channel_offset()] = *a_src;
                }
            });
    } else {
        iter.zip(y_iter)
            .zip(a_iter)
            .for_each(|((rgba, y_plane), a_plane)| {
                let y_plane = &y_plane[..image.width as usize];
                for ((y_src, a_src), rgba) in y_plane
                    .iter()
                    .zip(a_plane)
                    .zip(rgba.chunks_exact_mut(channels))
                {
                    let y_value = *y_src;
                    rgba[destination_channels.get_r_channel_offset()] = y_value;
                    rgba[destination_channels.get_g_channel_offset()] = y_value;
                    rgba[destination_channels.get_b_channel_offset()] = y_value;
                    rgba[destination_channels.get_a_channel_offset()] = *a_src;
                }
            });
    }

    Ok(())
}

/// Convert YUV 400 planar format with alpha plane to RGBA format.
///
/// This function takes YUV 400 planar format data with 8-bit precision,
/// and converts it to RGBA format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `gray_alpha_image` - Source gray image with alpha.
/// * `rgba` - A mutable slice to store the converted RGBA data.
/// * `rgba_stride` - Elements per row.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGRA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv400_alpha_to_rgba(
    gray_alpha_image: &YuvGrayAlphaImage<u8>,
    rgba: &mut [u8],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    y_with_alpha_to_rgbx::<u8, { YuvSourceChannels::Rgba as u8 }, 8>(
        gray_alpha_image,
        rgba,
        rgba_stride,
        range,
        matrix,
    )
}

/// Convert YUV 400 planar format with alpha plane to BGRA format.
///
/// This function takes YUV 400 planar format data with 8-bit precision,
/// and converts it to BGRA format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `gray_alpha_image` - Source gray image with alpha.
/// * `bgra` - A mutable slice to store the converted BGRA data.
/// * `bgra_stride` - Elements per row.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGRA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv400_alpha_to_bgra(
    gray_alpha_image: &YuvGrayAlphaImage<u8>,
    bgra: &mut [u8],
    bgra_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    y_with_alpha_to_rgbx::<u8, { YuvSourceChannels::Bgra as u8 }, 8>(
        gray_alpha_image,
        bgra,
        bgra_stride,
        range,
        matrix,
    )
}
