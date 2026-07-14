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
use crate::neon::yuv_to_yuy2_neon_impl;

use crate::yuv_support::{YuvChromaSubsampling, Yuy2Description};
use crate::{YuvError, YuvPackedImageMut, YuvPlanarImage};
#[cfg(feature = "rayon")]
use rayon::iter::{IndexedParallelIterator, ParallelIterator};
#[cfg(feature = "rayon")]
use rayon::prelude::{ParallelSlice, ParallelSliceMut};
use std::fmt::Debug;

#[allow(dead_code)]
#[derive(Debug, Copy, Clone, Ord, PartialOrd, Eq, PartialEq)]
pub struct YuvToYuy2Navigation {
    pub cx: usize,
    pub uv_x: usize,
    pub x: usize,
}

impl YuvToYuy2Navigation {
    #[allow(dead_code)]
    pub const fn new(cx: usize, uv_x: usize, x: usize) -> YuvToYuy2Navigation {
        YuvToYuy2Navigation { cx, uv_x, x }
    }
}

pub(crate) trait AveragesIntensity<V> {
    fn averages(self, other: V) -> V;
}

impl AveragesIntensity<u8> for u8 {
    #[inline(always)]
    fn averages(self, other: u8) -> u8 {
        ((self as u16 + other as u16 + 1) >> 1) as u8
    }
}

impl AveragesIntensity<u16> for u16 {
    #[inline(always)]
    fn averages(self, other: u16) -> u16 {
        ((self as u32 + other as u32 + 1) >> 1) as u16
    }
}

pub(crate) trait ProcessWideRow<V> {
    fn process_wide_row<const SAMPLING: u8, const YUY2_TARGET: usize>(
        yuy2: &mut [V],
        y_src: &[V],
        u_src: &[V],
        v_src: &[V],
        width: usize,
    ) -> usize;
}

impl ProcessWideRow<u8> for u8 {
    fn process_wide_row<const SAMPLING: u8, const YUY2_TARGET: usize>(
        _yuy2: &mut [u8],
        _y_src: &[u8],
        _u_src: &[u8],
        _v_src: &[u8],
        _width: usize,
    ) -> usize {
        let mut _processed = 0usize;

        #[cfg(all(any(target_arch = "x86", target_arch = "x86_64"), feature = "sse"))]
        let _use_sse = is_x86_feature_detected!("sse4.1");
        #[cfg(all(any(target_arch = "x86", target_arch = "x86_64"), feature = "avx"))]
        let _use_avx2 = is_x86_feature_detected!("avx2");

        #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
        {
            let mut _nav = YuvToYuy2Navigation::new(0, 0, 0);
            #[cfg(feature = "avx")]
            if _use_avx2 {
                use crate::avx2::yuv_to_yuy2_avx2_row;
                _nav = yuv_to_yuy2_avx2_row::<SAMPLING, YUY2_TARGET>(
                    _y_src,
                    _u_src,
                    _v_src,
                    _yuy2,
                    _width as u32,
                    _nav,
                );
            }
            #[cfg(feature = "sse")]
            if _use_sse {
                use crate::sse::yuv_to_yuy2_sse;
                _nav = yuv_to_yuy2_sse::<SAMPLING, YUY2_TARGET>(
                    _y_src,
                    _u_src,
                    _v_src,
                    _yuy2,
                    _width as u32,
                    _nav,
                );
            }
            _processed = _nav.cx;
        }

        #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
        {
            let processed = yuv_to_yuy2_neon_impl::<SAMPLING, YUY2_TARGET>(
                _y_src,
                _u_src,
                _v_src,
                _yuy2,
                _width as u32,
                YuvToYuy2Navigation::new(0, 0, 0),
            );
            _processed = processed.cx;
        }
        _processed
    }
}

impl ProcessWideRow<u16> for u16 {
    fn process_wide_row<const SAMPLING: u8, const YUY2_TARGET: usize>(
        _: &mut [u16],
        _: &[u16],
        _: &[u16],
        _: &[u16],
        _: usize,
    ) -> usize {
        0
    }
}

pub(crate) fn yuv_to_yuy2_impl<
    V: Copy + Debug + Send + Sync + AveragesIntensity<V> + Default + ProcessWideRow<V>,
    const SAMPLING: u8,
    const YUY2_TARGET: usize,
>(
    planar_image: &YuvPlanarImage<V>,
    image: &mut YuvPackedImageMut<V>,
) -> Result<(), YuvError> {
    let yuy2_target: Yuy2Description = YUY2_TARGET.into();
    let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();

    planar_image.check_constraints(chroma_subsampling)?;
    image.check_constraints()?;
    if planar_image.width != image.width || planar_image.height != image.height {
        return Err(YuvError::ImagesSizesNotMatch);
    }

    let yuy2_width = if planar_image.width % 2 == 0 {
        2 * planar_image.width as usize
    } else {
        2 * (planar_image.width as usize + 1)
    };

    let width = planar_image.width;

    if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
        let iter;
        #[cfg(feature = "rayon")]
        {
            iter = image
                .yuy
                .borrow_mut()
                .par_chunks_exact_mut(image.yuy_stride as usize)
                .zip(
                    planar_image
                        .y_plane
                        .par_chunks_exact(planar_image.y_stride as usize),
                )
                .zip(
                    planar_image
                        .u_plane
                        .par_chunks_exact(planar_image.u_stride as usize),
                )
                .zip(
                    planar_image
                        .v_plane
                        .par_chunks_exact(planar_image.v_stride as usize),
                );
        }
        #[cfg(not(feature = "rayon"))]
        {
            iter = image
                .yuy
                .borrow_mut()
                .chunks_exact_mut(image.yuy_stride as usize)
                .zip(
                    planar_image
                        .y_plane
                        .chunks_exact(planar_image.y_stride as usize),
                )
                .zip(
                    planar_image
                        .u_plane
                        .chunks_exact(planar_image.u_stride as usize),
                )
                .zip(
                    planar_image
                        .v_plane
                        .chunks_exact(planar_image.v_stride as usize),
                );
        }

        iter.for_each(|(((yuy2, y_src), u_src), v_src)| {
            let yuy2 = &mut yuy2[..yuy2_width];
            let y_src = &y_src[..image.width as usize];
            let u_src = &u_src[..image.width as usize];
            let v_src = &v_src[..image.width as usize];
            let processed = V::process_wide_row::<SAMPLING, YUY2_TARGET>(
                yuy2,
                y_src,
                u_src,
                v_src,
                width as usize,
            );

            for (((yuy2, y_src), u_src), v_src) in yuy2
                .chunks_exact_mut(4)
                .zip(y_src.chunks_exact(2))
                .zip(u_src.chunks_exact(2))
                .zip(v_src.chunks_exact(2))
                .skip(processed)
            {
                yuy2[yuy2_target.get_first_y_position()] = y_src[0];
                yuy2[yuy2_target.get_second_y_position()] = y_src[1];
                yuy2[yuy2_target.get_u_position()] = u_src[0].averages(u_src[1]);
                yuy2[yuy2_target.get_v_position()] = v_src[0].averages(v_src[1]);
            }

            if width & 1 != 0 {
                let yuy2 = yuy2.chunks_exact_mut(4).last().unwrap();
                let yuy2 = &mut yuy2[..4];
                let last_y = y_src.last().unwrap();
                let last_u = u_src.last().unwrap();
                let last_v = v_src.last().unwrap();
                yuy2[yuy2_target.get_first_y_position()] = *last_y;
                yuy2[yuy2_target.get_u_position()] = *last_u;
                yuy2[yuy2_target.get_second_y_position()] = V::default();
                yuy2[yuy2_target.get_v_position()] = *last_v;
            }
        });
    } else if chroma_subsampling == YuvChromaSubsampling::Yuv422 {
        let iter;
        #[cfg(feature = "rayon")]
        {
            iter = image
                .yuy
                .borrow_mut()
                .par_chunks_exact_mut(image.yuy_stride as usize)
                .zip(
                    planar_image
                        .y_plane
                        .par_chunks_exact(planar_image.y_stride as usize),
                )
                .zip(
                    planar_image
                        .u_plane
                        .par_chunks_exact(planar_image.u_stride as usize),
                )
                .zip(
                    planar_image
                        .v_plane
                        .par_chunks_exact(planar_image.v_stride as usize),
                );
        }
        #[cfg(not(feature = "rayon"))]
        {
            iter = image
                .yuy
                .borrow_mut()
                .chunks_exact_mut(image.yuy_stride as usize)
                .zip(
                    planar_image
                        .y_plane
                        .chunks_exact(planar_image.y_stride as usize),
                )
                .zip(
                    planar_image
                        .u_plane
                        .chunks_exact(planar_image.u_stride as usize),
                )
                .zip(
                    planar_image
                        .v_plane
                        .chunks_exact(planar_image.v_stride as usize),
                );
        }

        iter.for_each(|(((yuy2, y_src), u_src), v_src)| {
            let yuy2 = &mut yuy2[0..yuy2_width];
            let y_src = &y_src[0..image.width as usize];
            let u_src = &u_src[0..(image.width as usize).div_ceil(2)];
            let v_src = &v_src[0..(image.width as usize).div_ceil(2)];

            let processed = V::process_wide_row::<SAMPLING, YUY2_TARGET>(
                yuy2,
                y_src,
                u_src,
                v_src,
                width as usize,
            );

            for (((yuy2, y_src), u_src), v_src) in yuy2
                .chunks_exact_mut(4)
                .zip(y_src.chunks_exact(2))
                .zip(u_src.iter())
                .zip(v_src.iter())
                .skip(processed / 2)
            {
                yuy2[yuy2_target.get_first_y_position()] = y_src[0];
                yuy2[yuy2_target.get_second_y_position()] = y_src[1];
                yuy2[yuy2_target.get_u_position()] = *u_src;
                yuy2[yuy2_target.get_v_position()] = *v_src;
            }

            if width & 1 != 0 {
                let yuy2 = yuy2.chunks_exact_mut(4).last().unwrap();
                let yuy2 = &mut yuy2[..4];
                let last_y = y_src.last().unwrap();
                let last_u = u_src.last().unwrap();
                let last_v = v_src.last().unwrap();
                yuy2[yuy2_target.get_first_y_position()] = *last_y;
                yuy2[yuy2_target.get_u_position()] = *last_u;
                yuy2[yuy2_target.get_second_y_position()] = V::default();
                yuy2[yuy2_target.get_v_position()] = *last_v;
            }
        });
    } else if chroma_subsampling == YuvChromaSubsampling::Yuv420 {
        let iter;
        #[cfg(feature = "rayon")]
        {
            iter = image
                .yuy
                .borrow_mut()
                .par_chunks_exact_mut(image.yuy_stride as usize * 2)
                .zip(
                    planar_image
                        .y_plane
                        .par_chunks_exact(planar_image.y_stride as usize * 2),
                )
                .zip(
                    planar_image
                        .u_plane
                        .par_chunks_exact(planar_image.u_stride as usize),
                )
                .zip(
                    planar_image
                        .v_plane
                        .par_chunks_exact(planar_image.v_stride as usize),
                );
        }
        #[cfg(not(feature = "rayon"))]
        {
            iter = image
                .yuy
                .borrow_mut()
                .chunks_exact_mut(image.yuy_stride as usize * 2)
                .zip(
                    planar_image
                        .y_plane
                        .chunks_exact(planar_image.y_stride as usize * 2),
                )
                .zip(
                    planar_image
                        .u_plane
                        .chunks_exact(planar_image.u_stride as usize),
                )
                .zip(
                    planar_image
                        .v_plane
                        .chunks_exact(planar_image.v_stride as usize),
                );
        }

        iter.for_each(|(((yuy2, y_src), u_src), v_src)| {
            for (yuy2, y_src) in yuy2
                .chunks_exact_mut(image.yuy_stride as usize)
                .zip(y_src.chunks_exact(planar_image.y_stride as usize))
            {
                let yuy2 = &mut yuy2[..yuy2_width];
                let y_src = &y_src[..image.width as usize];
                let u_src = &u_src[..(image.width as usize).div_ceil(2)];
                let v_src = &v_src[..(image.width as usize).div_ceil(2)];

                let processed = V::process_wide_row::<SAMPLING, YUY2_TARGET>(
                    yuy2,
                    y_src,
                    u_src,
                    v_src,
                    width as usize,
                );

                for (((yuy2, y_src), u_src), v_src) in yuy2
                    .chunks_exact_mut(4)
                    .zip(y_src.chunks_exact(2))
                    .zip(u_src.iter())
                    .zip(v_src.iter())
                    .skip(processed / 2)
                {
                    yuy2[yuy2_target.get_first_y_position()] = y_src[0];
                    yuy2[yuy2_target.get_second_y_position()] = y_src[1];
                    yuy2[yuy2_target.get_u_position()] = *u_src;
                    yuy2[yuy2_target.get_v_position()] = *v_src;
                }

                if width & 1 != 0 {
                    let yuy2 = yuy2.chunks_exact_mut(4).last().unwrap();
                    let yuy2 = &mut yuy2[..4];
                    let last_y = y_src.last().unwrap();
                    let last_u = u_src.last().unwrap();
                    let last_v = v_src.last().unwrap();
                    yuy2[yuy2_target.get_first_y_position()] = *last_y;
                    yuy2[yuy2_target.get_u_position()] = *last_u;
                    yuy2[yuy2_target.get_second_y_position()] = V::default();
                    yuy2[yuy2_target.get_v_position()] = *last_v;
                }
            }
        });

        if planar_image.height & 1 != 0 {
            let rem_yuy = image
                .yuy
                .borrow_mut()
                .chunks_exact_mut(image.yuy_stride as usize * 2)
                .into_remainder();
            let rem_y = planar_image
                .y_plane
                .chunks_exact(planar_image.y_stride as usize * 2)
                .remainder();
            let last_u = planar_image
                .u_plane
                .chunks_exact(planar_image.u_stride as usize)
                .last()
                .unwrap();
            let last_v = planar_image
                .v_plane
                .chunks_exact(planar_image.v_stride as usize)
                .last()
                .unwrap();

            let processed = V::process_wide_row::<SAMPLING, YUY2_TARGET>(
                rem_yuy,
                rem_y,
                last_u,
                last_v,
                width as usize,
            );

            let rem_yuy = &mut rem_yuy[..yuy2_width];
            let rem_y = &rem_y[..image.width as usize];
            let last_u = &last_u[..(image.width as usize).div_ceil(2)];
            let last_v = &last_v[..(image.width as usize).div_ceil(2)];

            for (((yuy2, y_src), u_src), v_src) in rem_yuy
                .chunks_exact_mut(4)
                .zip(rem_y.chunks_exact(2))
                .zip(last_u.iter())
                .zip(last_v.iter())
                .skip(processed / 2)
            {
                yuy2[yuy2_target.get_first_y_position()] = y_src[0];
                yuy2[yuy2_target.get_second_y_position()] = y_src[1];
                yuy2[yuy2_target.get_u_position()] = *u_src;
                yuy2[yuy2_target.get_v_position()] = *v_src;
            }

            if width & 1 != 0 {
                let yuy2 = rem_yuy.chunks_exact_mut(4).last().unwrap();
                let yuy2 = &mut yuy2[..4];
                let last_y = rem_y.last().unwrap();
                let last_u = last_u.last().unwrap();
                let last_v = last_v.last().unwrap();
                yuy2[yuy2_target.get_first_y_position()] = *last_y;
                yuy2[yuy2_target.get_u_position()] = *last_u;
                yuy2[yuy2_target.get_second_y_position()] = V::default();
                yuy2[yuy2_target.get_v_position()] = *last_v;
            }
        }
    } else {
        unreachable!();
    }
    Ok(())
}

/// Convert YUV 444 planar format to YUYV ( YUV Packed ) format.
///
/// This function takes YUV 444 planar format data with 8-bit precision,
/// and converts it to YUYV format with 8-bit per channel precision.
/// Do not forget about odd alignment, use (width + 1) for buffers.
///
/// # Arguments
///
/// * `packed_image` - Target packed frame image.
/// * `planar_image` - Source planar image.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input YUYV data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
/// Panic will be received if buffer doesn't expand with (width + 1) size for odd width
///
pub fn yuv444_to_yuyv422(
    packed_image: &mut YuvPackedImageMut<u8>,
    planar_image: &YuvPlanarImage<u8>,
) -> Result<(), YuvError> {
    yuv_to_yuy2_impl::<u8, { YuvChromaSubsampling::Yuv444 as u8 }, { Yuy2Description::YUYV as usize }>(
        planar_image,
        packed_image,
    )
}

/// Convert YUV 422 planar format to YUYV ( YUV Packed ) format.
///
/// This function takes YUV 422 planar format data with 8-bit precision,
/// and converts it to YUYV format with 8-bit per channel precision.
/// Do not forget about odd alignment, use (width + 1) for buffers.
///
/// # Arguments
///
/// * `packed_image` - Target packed frame image.
/// * `planar_image` - Source planar image.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input YUYV data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
/// Panic will be received if buffer doesn't expand with (width + 1) size for odd width
///
pub fn yuv422_to_yuyv422(
    packed_image: &mut YuvPackedImageMut<u8>,
    planar_image: &YuvPlanarImage<u8>,
) -> Result<(), YuvError> {
    yuv_to_yuy2_impl::<u8, { YuvChromaSubsampling::Yuv422 as u8 }, { Yuy2Description::YUYV as usize }>(
        planar_image,
        packed_image,
    )
}

/// Convert YUV 420 planar format to YUYV ( YUV Packed ) format.
///
/// This function takes YUV 420 planar format data with 8-bit precision,
/// and converts it to YUYV format with 8-bit per channel precision.
/// Do not forget about odd alignment, use (width + 1) for buffers.
///
/// # Arguments
///
/// * `packed_image` - Target packed frame image.
/// * `planar_image` - Source planar image.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input YUYV data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
/// Panic will be received if buffer doesn't expand with (width + 1) size for odd width
///
pub fn yuv420_to_yuyv422(
    packed_image: &mut YuvPackedImageMut<u8>,
    planar_image: &YuvPlanarImage<u8>,
) -> Result<(), YuvError> {
    yuv_to_yuy2_impl::<u8, { YuvChromaSubsampling::Yuv420 as u8 }, { Yuy2Description::YUYV as usize }>(
        planar_image,
        packed_image,
    )
}

/// Convert YUV 444 planar format to YVYU ( YUV Packed ) format.
///
/// This function takes YUV 444 planar format data with 8-bit precision,
/// and converts it to YVYU format with 8-bit per channel precision.
/// Do not forget about odd alignment, use (width + 1) for buffers.
///
/// # Arguments
///
/// * `packed_image` - Target packed frame image.
/// * `planar_image` - Source planar image.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input YVYU data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
/// Panic will be received if buffer doesn't expand with (width + 1) size for odd width
///
pub fn yuv444_to_yvyu422(
    packed_image: &mut YuvPackedImageMut<u8>,
    planar_image: &YuvPlanarImage<u8>,
) -> Result<(), YuvError> {
    yuv_to_yuy2_impl::<u8, { YuvChromaSubsampling::Yuv444 as u8 }, { Yuy2Description::YVYU as usize }>(
        planar_image,
        packed_image,
    )
}

/// Convert YUV 422 planar format to YVYU ( YUV Packed ) format.
///
/// This function takes YUV 422 planar format data with 8-bit precision,
/// and converts it to YVYU format with 8-bit per channel precision.
/// Do not forget about odd alignment, use (width + 1) for buffers.
///
/// # Arguments
///
/// * `packed_image` - Target packed frame image.
/// * `planar_image` - Source planar image.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input YVYU data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
/// Panic will be received if buffer doesn't expand with (width + 1) size for odd width
///
pub fn yuv422_to_yvyu422(
    packed_image: &mut YuvPackedImageMut<u8>,
    planar_image: &YuvPlanarImage<u8>,
) -> Result<(), YuvError> {
    yuv_to_yuy2_impl::<u8, { YuvChromaSubsampling::Yuv422 as u8 }, { Yuy2Description::YVYU as usize }>(
        planar_image,
        packed_image,
    )
}

/// Convert YUV 420 planar format to YVYU ( YUV Packed ) format.
///
/// This function takes YUV 420 planar format data with 8-bit precision,
/// and converts it to YVYU format with 8-bit per channel precision.
/// Do not forget about odd alignment, use (width + 1) for buffers.
///
/// # Arguments
///
/// * `packed_image` - Target packed frame image.
/// * `planar_image` - Source planar image.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input YVYU data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
/// Panic will be received if buffer doesn't expand with (width + 1) size for odd width
///
pub fn yuv420_to_yvyu422(
    packed_image: &mut YuvPackedImageMut<u8>,
    planar_image: &YuvPlanarImage<u8>,
) -> Result<(), YuvError> {
    yuv_to_yuy2_impl::<u8, { YuvChromaSubsampling::Yuv420 as u8 }, { Yuy2Description::YVYU as usize }>(
        planar_image,
        packed_image,
    )
}

/// Convert YUV 444 planar format to VYUY ( YUV Packed ) format.
///
/// This function takes YUV 444 planar format data with 8-bit precision,
/// and converts it to VYUY format with 8-bit per channel precision.
/// Do not forget about odd alignment, use (width + 1) for buffers.
///
/// # Arguments
///
/// * `packed_image` - Target packed frame image.
/// * `planar_image` - Source planar image.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input VYUY data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
/// Panic will be received if buffer doesn't expand with (width + 1) size for odd width
///
pub fn yuv444_to_vyuy422(
    packed_image: &mut YuvPackedImageMut<u8>,
    planar_image: &YuvPlanarImage<u8>,
) -> Result<(), YuvError> {
    yuv_to_yuy2_impl::<u8, { YuvChromaSubsampling::Yuv444 as u8 }, { Yuy2Description::VYUY as usize }>(
        planar_image,
        packed_image,
    )
}

/// Convert YUV 422 planar format to VYUY ( YUV Packed ) format.
///
/// This function takes YUV 422 planar format data with 8-bit precision,
/// and converts it to VYUY format with 8-bit per channel precision.
/// Do not forget about odd alignment, use (width + 1) for buffers.
///
/// # Arguments
///
/// * `packed_image` - Target packed frame image.
/// * `planar_image` - Source planar image.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input VYUY data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
/// Panic will be received if buffer doesn't expand with (width + 1) size for odd width
///
pub fn yuv422_to_vyuy422(
    packed_image: &mut YuvPackedImageMut<u8>,
    planar_image: &YuvPlanarImage<u8>,
) -> Result<(), YuvError> {
    yuv_to_yuy2_impl::<u8, { YuvChromaSubsampling::Yuv422 as u8 }, { Yuy2Description::VYUY as usize }>(
        planar_image,
        packed_image,
    )
}

/// Convert YUV 420 planar format to VYUY ( YUV Packed ) format.
///
/// This function takes YUV 420 planar format data with 8-bit precision,
/// and converts it to VYUY format with 8-bit per channel precision.
/// Do not forget about odd alignment, use (width + 1) for buffers.
///
/// # Arguments
///
/// * `packed_image` - Target packed frame image.
/// * `planar_image` - Source planar image.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input VYUY data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
/// Panic will be received if buffer doesn't expand with (width + 1) size for odd width
///
pub fn yuv420_to_vyuy422(
    packed_image: &mut YuvPackedImageMut<u8>,
    planar_image: &YuvPlanarImage<u8>,
) -> Result<(), YuvError> {
    yuv_to_yuy2_impl::<u8, { YuvChromaSubsampling::Yuv420 as u8 }, { Yuy2Description::VYUY as usize }>(
        planar_image,
        packed_image,
    )
}

/// Convert YUV 444 planar format to UYVY ( YUV Packed ) format.
///
/// This function takes YUV 444 planar format data with 8-bit precision,
/// and converts it to UYVY format with 8-bit per channel precision.
/// Do not forget about odd alignment, use (width + 1) for buffers.
///
/// # Arguments
///
/// * `packed_image` - Target packed frame image.
/// * `planar_image` - Source planar image.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input UYVY data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
/// Panic will be received if buffer doesn't expand with (width + 1) size for odd width
///
pub fn yuv444_to_uyvy422(
    packed_image: &mut YuvPackedImageMut<u8>,
    planar_image: &YuvPlanarImage<u8>,
) -> Result<(), YuvError> {
    yuv_to_yuy2_impl::<u8, { YuvChromaSubsampling::Yuv444 as u8 }, { Yuy2Description::UYVY as usize }>(
        planar_image,
        packed_image,
    )
}

/// Convert YUV 422 planar format to UYVY ( YUV Packed ) format.
///
/// This function takes YUV 422 planar format data with 8-bit precision,
/// and converts it to UYVY format with 8-bit per channel precision.
/// Do not forget about odd alignment, use (width + 1) for buffers.
///
/// # Arguments
///
/// * `packed_image` - Target packed frame image.
/// * `planar_image` - Source planar image.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input UYVY data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
/// Panic will be received if buffer doesn't expand with (width + 1) size for odd width
///
pub fn yuv422_to_uyvy422(
    packed_image: &mut YuvPackedImageMut<u8>,
    planar_image: &YuvPlanarImage<u8>,
) -> Result<(), YuvError> {
    yuv_to_yuy2_impl::<u8, { YuvChromaSubsampling::Yuv422 as u8 }, { Yuy2Description::UYVY as usize }>(
        planar_image,
        packed_image,
    )
}

/// Convert YUV 420 planar format to UYVY ( YUV Packed ) format.
///
/// This function takes YUV 420 planar format data with 8-bit precision,
/// and converts it to UYVY format with 8-bit per channel precision.
/// Do not forget about odd alignment, use (width + 1) for buffers.
///
/// # Arguments
///
/// * `packed_image` - Target packed frame image.
/// * `planar_image` - Source planar image.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input UYVY data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
/// Panic will be received if buffer doesn't expand with (width + 1) size for odd width
///
pub fn yuv420_to_uyvy422(
    packed_image: &mut YuvPackedImageMut<u8>,
    planar_image: &YuvPlanarImage<u8>,
) -> Result<(), YuvError> {
    yuv_to_yuy2_impl::<u8, { YuvChromaSubsampling::Yuv420 as u8 }, { Yuy2Description::UYVY as usize }>(
        planar_image,
        packed_image,
    )
}
