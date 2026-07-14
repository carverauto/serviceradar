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
use crate::images::YuvPackedImage;
#[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
use crate::neon::yuy2_to_yuv_neon_impl;
use crate::yuv_support::{YuvChromaSubsampling, Yuy2Description};
#[allow(unused_imports)]
use crate::yuv_to_yuy2::YuvToYuy2Navigation;
use crate::{YuvError, YuvPlanarImageMut};
#[cfg(feature = "rayon")]
use rayon::iter::{IndexedParallelIterator, ParallelIterator};
#[cfg(feature = "rayon")]
use rayon::prelude::{ParallelSlice, ParallelSliceMut};

fn yuy2_to_yuv_impl<const SAMPLING: u8, const YUY2_TARGET: usize>(
    planar_image: &mut YuvPlanarImageMut<u8>,
    packed_image: &YuvPackedImage<u8>,
) -> Result<(), YuvError> {
    let yuy2_target: Yuy2Description = YUY2_TARGET.into();
    let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();

    planar_image.check_constraints(chroma_subsampling)?;
    packed_image.check_constraints()?;
    if planar_image.width != packed_image.width || planar_image.height != packed_image.height {
        return Err(YuvError::ImagesSizesNotMatch);
    }

    #[cfg(all(any(target_arch = "x86", target_arch = "x86_64"), feature = "sse"))]
    let _use_sse = std::arch::is_x86_feature_detected!("sse4.1");
    #[cfg(all(any(target_arch = "x86", target_arch = "x86_64"), feature = "avx"))]
    let _use_avx2 = std::arch::is_x86_feature_detected!("avx2");

    let width = planar_image.width;

    let process_wide_row =
        |_y_plane: &mut [u8], _u_plane: &mut [u8], _v_plane: &mut [u8], _yuy2_store: &[u8]| {
            let mut _yuy2_nav = YuvToYuy2Navigation::new(0, 0, 0);
            #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
            {
                _yuy2_nav = yuy2_to_yuv_neon_impl::<SAMPLING, YUY2_TARGET>(
                    _y_plane,
                    _u_plane,
                    _v_plane,
                    _yuy2_store,
                    width,
                    _yuy2_nav,
                );
            }

            #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
            {
                #[cfg(feature = "avx")]
                if _use_avx2 {
                    use crate::avx2::yuy2_to_yuv_avx;
                    _yuy2_nav = yuy2_to_yuv_avx::<SAMPLING, YUY2_TARGET>(
                        _y_plane,
                        _u_plane,
                        _v_plane,
                        _yuy2_store,
                        width,
                        _yuy2_nav,
                    );
                }
                #[cfg(feature = "sse")]
                if _use_sse {
                    use crate::sse::yuy2_to_yuv_sse;
                    _yuy2_nav = yuy2_to_yuv_sse::<SAMPLING, YUY2_TARGET>(
                        _y_plane,
                        _u_plane,
                        _v_plane,
                        _yuy2_store,
                        width,
                        _yuy2_nav,
                    );
                }
            }
            _yuy2_nav
        };

    let y_plane = planar_image.y_plane.borrow_mut();
    let u_plane = planar_image.u_plane.borrow_mut();
    let v_plane = planar_image.v_plane.borrow_mut();
    let y_stride = planar_image.y_stride;
    let u_stride = planar_image.u_stride;
    let v_stride = planar_image.v_stride;

    let yuy2_width = if packed_image.width % 2 == 0 {
        2 * packed_image.width as usize
    } else {
        2 * (packed_image.width as usize + 1)
    };

    if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
        let iter;
        #[cfg(feature = "rayon")]
        {
            iter = y_plane
                .par_chunks_exact_mut(y_stride as usize)
                .zip(u_plane.par_chunks_exact_mut(u_stride as usize))
                .zip(v_plane.par_chunks_exact_mut(v_stride as usize))
                .zip(
                    packed_image
                        .yuy
                        .par_chunks_exact(packed_image.yuy_stride as usize),
                );
        }
        #[cfg(not(feature = "rayon"))]
        {
            iter = y_plane
                .chunks_exact_mut(y_stride as usize)
                .zip(u_plane.chunks_exact_mut(u_stride as usize))
                .zip(v_plane.chunks_exact_mut(v_stride as usize))
                .zip(
                    packed_image
                        .yuy
                        .chunks_exact(packed_image.yuy_stride as usize),
                );
        }
        iter.for_each(|(((y_dst, u_dst), v_dst), yuy2_src)| {
            let yuy2_src = &yuy2_src[..yuy2_width];
            let y_dst = &mut y_dst[..planar_image.width as usize];
            let u_dst = &mut u_dst[..planar_image.width as usize];
            let u_dst = &mut u_dst[..planar_image.width as usize];

            let p_offset = process_wide_row(y_dst, u_dst, v_dst, yuy2_src);

            for (((y_dst, u_dst), v_dst), yuy2) in y_dst
                .chunks_exact_mut(2)
                .zip(u_dst.chunks_exact_mut(2))
                .zip(v_dst.chunks_exact_mut(2))
                .zip(yuy2_src.chunks_exact(4))
                .skip(p_offset.cx / 2)
            {
                let first_y_position = yuy2[yuy2_target.get_first_y_position()];
                let second_y_position = yuy2[yuy2_target.get_second_y_position()];
                let u_value = yuy2[yuy2_target.get_u_position()];
                let v_value = yuy2[yuy2_target.get_v_position()];
                y_dst[0] = first_y_position;
                y_dst[1] = second_y_position;
                u_dst[0] = u_value;
                u_dst[1] = u_value;
                v_dst[0] = v_value;
                v_dst[1] = v_value;
            }

            if width & 1 != 0 {
                let y_dst = y_dst.last_mut().unwrap();
                let u_dst = u_dst.last_mut().unwrap();
                let v_dst = v_dst.last_mut().unwrap();
                let yuy2 = yuy2_src.chunks_exact(4).last().unwrap();
                let yuy2 = &yuy2[..4];
                *y_dst = yuy2[yuy2_target.get_first_y_position()];
                *u_dst = yuy2[yuy2_target.get_u_position()];
                *v_dst = yuy2[yuy2_target.get_v_position()];
            }
        });
    } else if chroma_subsampling == YuvChromaSubsampling::Yuv422 {
        let iter;
        #[cfg(feature = "rayon")]
        {
            iter = y_plane
                .par_chunks_exact_mut(y_stride as usize)
                .zip(u_plane.par_chunks_exact_mut(u_stride as usize))
                .zip(v_plane.par_chunks_exact_mut(v_stride as usize))
                .zip(
                    packed_image
                        .yuy
                        .par_chunks_exact(packed_image.yuy_stride as usize),
                );
        }
        #[cfg(not(feature = "rayon"))]
        {
            iter = y_plane
                .chunks_exact_mut(y_stride as usize)
                .zip(u_plane.chunks_exact_mut(u_stride as usize))
                .zip(v_plane.chunks_exact_mut(v_stride as usize))
                .zip(
                    packed_image
                        .yuy
                        .chunks_exact(packed_image.yuy_stride as usize),
                );
        }
        iter.for_each(|(((y_dst, u_dst), v_dst), yuy2_src)| {
            let yuy2_src = &yuy2_src[..yuy2_width];
            let y_dst = &mut y_dst[..planar_image.width as usize];
            let u_dst = &mut u_dst[..(planar_image.width as usize).div_ceil(2)];
            let u_dst = &mut u_dst[..(planar_image.width as usize).div_ceil(2)];

            let p_offset = process_wide_row(y_dst, u_dst, v_dst, yuy2_src);

            for (((y_dst, u_dst), v_dst), yuy2) in y_dst
                .chunks_exact_mut(2)
                .zip(u_dst.iter_mut())
                .zip(v_dst.iter_mut())
                .zip(yuy2_src.chunks_exact(4))
                .skip(p_offset.cx / 2)
            {
                let first_y_position = yuy2[yuy2_target.get_first_y_position()];
                let second_y_position = yuy2[yuy2_target.get_second_y_position()];
                let u_value = yuy2[yuy2_target.get_u_position()];
                let v_value = yuy2[yuy2_target.get_v_position()];
                y_dst[0] = first_y_position;
                y_dst[1] = second_y_position;
                *u_dst = u_value;
                *v_dst = v_value;
            }

            if width & 1 != 0 {
                let y_dst = y_dst.last_mut().unwrap();
                let u_dst = u_dst.last_mut().unwrap();
                let v_dst = v_dst.last_mut().unwrap();
                let yuy2 = yuy2_src.chunks_exact(4).last().unwrap();
                let yuy2 = &yuy2[..4];
                *y_dst = yuy2[yuy2_target.get_first_y_position()];
                *u_dst = yuy2[yuy2_target.get_u_position()];
                *v_dst = yuy2[yuy2_target.get_v_position()];
            }
        });
    } else if chroma_subsampling == YuvChromaSubsampling::Yuv420 {
        let iter;
        #[cfg(feature = "rayon")]
        {
            iter = y_plane
                .par_chunks_exact_mut(y_stride as usize * 2)
                .zip(u_plane.par_chunks_exact_mut(u_stride as usize))
                .zip(v_plane.par_chunks_exact_mut(v_stride as usize))
                .zip(
                    packed_image
                        .yuy
                        .par_chunks_exact(packed_image.yuy_stride as usize * 2),
                );
        }
        #[cfg(not(feature = "rayon"))]
        {
            iter = y_plane
                .chunks_exact_mut(y_stride as usize * 2)
                .zip(u_plane.chunks_exact_mut(u_stride as usize))
                .zip(v_plane.chunks_exact_mut(v_stride as usize))
                .zip(
                    packed_image
                        .yuy
                        .chunks_exact(packed_image.yuy_stride as usize * 2),
                );
        }
        iter.for_each(|(((y_dst, u_dst), v_dst), yuy2_src)| {
            for (y, (y_dst, yuy2)) in y_dst
                .chunks_exact_mut(y_stride as usize)
                .zip(yuy2_src.chunks_exact(packed_image.yuy_stride as usize))
                .enumerate()
            {
                let yuy2 = &yuy2[..yuy2_width];
                let y_dst = &mut y_dst[..planar_image.width as usize];
                let u_dst = &mut u_dst[..(planar_image.width as usize).div_ceil(2)];
                let u_dst = &mut u_dst[..(planar_image.width as usize).div_ceil(2)];

                let p_offset = process_wide_row(y_dst, u_dst, v_dst, yuy2);

                let process_chroma = y & 1 == 0;

                if process_chroma {
                    for (((y_dst, u_dst), v_dst), yuy2) in y_dst
                        .chunks_exact_mut(2)
                        .zip(u_dst.iter_mut())
                        .zip(v_dst.iter_mut())
                        .zip(yuy2.chunks_exact(4))
                        .skip(p_offset.cx / 2)
                    {
                        let first_y_position = yuy2[yuy2_target.get_first_y_position()];
                        let second_y_position = yuy2[yuy2_target.get_second_y_position()];
                        y_dst[0] = first_y_position;
                        y_dst[1] = second_y_position;
                        let u_value = yuy2[yuy2_target.get_u_position()];
                        let v_value = yuy2[yuy2_target.get_v_position()];
                        *u_dst = u_value;
                        *v_dst = v_value;
                    }
                } else {
                    for (y_dst, yuy2) in y_dst
                        .chunks_exact_mut(2)
                        .zip(yuy2.chunks_exact(4))
                        .skip(p_offset.cx / 2)
                    {
                        let first_y_position = yuy2[yuy2_target.get_first_y_position()];
                        let second_y_position = yuy2[yuy2_target.get_second_y_position()];
                        y_dst[0] = first_y_position;
                        y_dst[1] = second_y_position;
                    }
                }

                if width & 1 != 0 {
                    let y_dst = y_dst.last_mut().unwrap();
                    let yuy2 = yuy2.chunks_exact(4).last().unwrap();
                    let yuy2 = &yuy2[..4];
                    *y_dst = yuy2[yuy2_target.get_first_y_position()];
                    if process_chroma {
                        let u_dst = u_dst.last_mut().unwrap();
                        let v_dst = v_dst.last_mut().unwrap();
                        *u_dst = yuy2[yuy2_target.get_u_position()];
                        *v_dst = yuy2[yuy2_target.get_v_position()];
                    }
                }
            }
        });
    }

    Ok(())
}

/// Convert YUYV (YUV Packed) format to YUV 444 planar format.
///
/// This function takes YUYV (4:2:2) format data with 8-bit precision,
/// and converts it to YUV 444 planar format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `planar_image` - Target planar image.
/// * `packed_image` - Source packed image.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input YUYV data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuyv422_to_yuv444(
    planar_image: &mut YuvPlanarImageMut<u8>,
    packed_image: &YuvPackedImage<u8>,
) -> Result<(), YuvError> {
    yuy2_to_yuv_impl::<{ YuvChromaSubsampling::Yuv444 as u8 }, { Yuy2Description::YUYV as usize }>(
        planar_image,
        packed_image,
    )
}

/// Convert YUYV (YUV Packed) format to YUV 420 planar format.
///
/// This function takes YUYV (4:2:2) format data with 8-bit precision,
/// and converts it to YUV 444 planar format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `planar_image` - Target planar image.
/// * `packed_image` - Source packed image.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input YUYV data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuyv422_to_yuv420(
    planar_image: &mut YuvPlanarImageMut<u8>,
    packed_image: &YuvPackedImage<u8>,
) -> Result<(), YuvError> {
    yuy2_to_yuv_impl::<{ YuvChromaSubsampling::Yuv420 as u8 }, { Yuy2Description::YUYV as usize }>(
        planar_image,
        packed_image,
    )
}

/// Convert YVYU (YUV Packed) format to YUV 422 planar format.
///
/// This function takes YUYV (4:2:2) format data with 8-bit precision,
/// and converts it to YUV 444 planar format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `planar_image` - Target planar image.
/// * `packed_image` - Source packed image.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input YUYV data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuyv422_to_yuv422(
    planar_image: &mut YuvPlanarImageMut<u8>,
    packed_image: &YuvPackedImage<u8>,
) -> Result<(), YuvError> {
    yuy2_to_yuv_impl::<{ YuvChromaSubsampling::Yuv422 as u8 }, { Yuy2Description::YUYV as usize }>(
        planar_image,
        packed_image,
    )
}

/// Convert YVYU (YUV Packed) format to YUV 444 planar format.
///
/// This function takes YVYU (4:2:2) format data with 8-bit precision,
/// and converts it to YUV 444 planar format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `planar_image` - Target planar image.
/// * `packed_image` - Source packed image.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input YVYU data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yvyu422_to_yuv444(
    planar_image: &mut YuvPlanarImageMut<u8>,
    packed_image: &YuvPackedImage<u8>,
) -> Result<(), YuvError> {
    yuy2_to_yuv_impl::<{ YuvChromaSubsampling::Yuv444 as u8 }, { Yuy2Description::YVYU as usize }>(
        planar_image,
        packed_image,
    )
}

/// Convert YVYU (YUV Packed) format to YUV 420 planar format.
///
/// This function takes YVYU (4:2:2) format data with 8-bit precision,
/// and converts it to YUV 444 planar format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `planar_image` - Target planar image.
/// * `packed_image` - Source packed image.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input YVYU data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yvyu422_to_yuv420(
    planar_image: &mut YuvPlanarImageMut<u8>,
    packed_image: &YuvPackedImage<u8>,
) -> Result<(), YuvError> {
    yuy2_to_yuv_impl::<{ YuvChromaSubsampling::Yuv420 as u8 }, { Yuy2Description::YVYU as usize }>(
        planar_image,
        packed_image,
    )
}

/// Convert YVYU (YUV Packed) format to YUV 422 planar format.
///
/// This function takes YVYU (4:2:2) format data with 8-bit precision,
/// and converts it to YUV 444 planar format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `planar_image` - Target planar image.
/// * `packed_image` - Source packed image.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input YVYU data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yvyu422_to_yuv422(
    planar_image: &mut YuvPlanarImageMut<u8>,
    packed_image: &YuvPackedImage<u8>,
) -> Result<(), YuvError> {
    yuy2_to_yuv_impl::<{ YuvChromaSubsampling::Yuv422 as u8 }, { Yuy2Description::YVYU as usize }>(
        planar_image,
        packed_image,
    )
}

/// Convert VYUY (YUV Packed) format to YUV 444 planar format.
///
/// This function takes VYUY (4:2:2) format data with 8-bit precision,
/// and converts it to YUV 444 planar format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `planar_image` - Target planar image.
/// * `packed_image` - Source packed image.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input VYUY data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn vyuy422_to_yuv444(
    planar_image: &mut YuvPlanarImageMut<u8>,
    packed_image: &YuvPackedImage<u8>,
) -> Result<(), YuvError> {
    yuy2_to_yuv_impl::<{ YuvChromaSubsampling::Yuv444 as u8 }, { Yuy2Description::VYUY as usize }>(
        planar_image,
        packed_image,
    )
}

/// Convert VYUY (YUV Packed) format to YUV 420 planar format.
///
/// This function takes VYUY (4:2:2) format data with 8-bit precision,
/// and converts it to YUV 444 planar format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `planar_image` - Target planar image.
/// * `packed_image` - Source packed image.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input VYUY data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn vyuy422_to_yuv420(
    planar_image: &mut YuvPlanarImageMut<u8>,
    packed_image: &YuvPackedImage<u8>,
) -> Result<(), YuvError> {
    yuy2_to_yuv_impl::<{ YuvChromaSubsampling::Yuv420 as u8 }, { Yuy2Description::VYUY as usize }>(
        planar_image,
        packed_image,
    )
}

/// Convert VYUY (YUV Packed) format to YUV 422 planar format.
///
/// This function takes VYUY (4:2:2) format data with 8-bit precision,
/// and converts it to YUV 444 planar format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `planar_image` - Target planar image.
/// * `packed_image` - Source packed image.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input VYUY data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn vyuy422_to_yuv422(
    planar_image: &mut YuvPlanarImageMut<u8>,
    packed_image: &YuvPackedImage<u8>,
) -> Result<(), YuvError> {
    yuy2_to_yuv_impl::<{ YuvChromaSubsampling::Yuv422 as u8 }, { Yuy2Description::VYUY as usize }>(
        planar_image,
        packed_image,
    )
}

/// Convert UYVY (YUV Packed) format to YUV 444 planar format.
///
/// This function takes UYVY (4:2:2) format data with 8-bit precision,
/// and converts it to YUV 444 planar format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `planar_image` - Target planar image.
/// * `packed_image` - Source packed image.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input UYVY data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn uyvy422_to_yuv444(
    planar_image: &mut YuvPlanarImageMut<u8>,
    packed_image: &YuvPackedImage<u8>,
) -> Result<(), YuvError> {
    yuy2_to_yuv_impl::<{ YuvChromaSubsampling::Yuv444 as u8 }, { Yuy2Description::UYVY as usize }>(
        planar_image,
        packed_image,
    )
}

/// Convert UYVY (YUV Packed) format to YUV 420 planar format.
///
/// This function takes UYVY (4:2:2) format data with 8-bit precision,
/// and converts it to YUV 444 planar format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `planar_image` - Target planar image.
/// * `packed_image` - Source packed image.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input UYVY data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn uyvy422_to_yuv420(
    planar_image: &mut YuvPlanarImageMut<u8>,
    packed_image: &YuvPackedImage<u8>,
) -> Result<(), YuvError> {
    yuy2_to_yuv_impl::<{ YuvChromaSubsampling::Yuv420 as u8 }, { Yuy2Description::UYVY as usize }>(
        planar_image,
        packed_image,
    )
}

/// Convert UYVY (YUV Packed) format to YUV 422 planar format.
///
/// This function takes UYVY (4:2:2) format data with 8-bit precision,
/// and converts it to YUV 444 planar format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `planar_image` - Target planar image.
/// * `yuy2_store` - A slice to store the converted UYVY data.
/// * `yuy2_stride` - The stride (components per row) for the UYVY plane.
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input UYVY data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn uyvy422_to_yuv422(
    planar_image: &mut YuvPlanarImageMut<u8>,
    packed_image: &YuvPackedImage<u8>,
) -> Result<(), YuvError> {
    yuy2_to_yuv_impl::<{ YuvChromaSubsampling::Yuv422 as u8 }, { Yuy2Description::UYVY as usize }>(
        planar_image,
        packed_image,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_yuyv420() {
        const W: u32 = 96;
        const H: u32 = 4;

        fn yuyv() -> Vec<u8> {
            let min = 16;
            let max = min + 2 * W as u8;
            (0..H).flat_map(|_| min..max).collect()
        }
        let mut dst = YuvPlanarImageMut::alloc(W, H, YuvChromaSubsampling::Yuv420);
        let src = YuvPackedImage {
            yuy: &yuyv(),
            yuy_stride: W * 2,
            width: W,
            height: H,
        };
        yuyv422_to_yuv420(&mut dst, &src).unwrap();
        dst.y_plane.borrow().iter().for_each(|&x| {
            assert_ne!(x, 0);
        });
        dst.u_plane.borrow().iter().for_each(|&x| {
            assert_ne!(x, 0);
        });
        dst.v_plane.borrow().iter().for_each(|&x| {
            assert_ne!(x, 0);
        })
    }

    #[test]
    fn test_yuyv422() {
        const W: u32 = 96;
        const H: u32 = 4;

        fn yuyv() -> Vec<u8> {
            let min = 16;
            let max = min + 2 * W as u8;
            (0..H).flat_map(|_| min..max).collect()
        }
        let mut dst = YuvPlanarImageMut::alloc(W, H, YuvChromaSubsampling::Yuv422);
        let src = YuvPackedImage {
            yuy: &yuyv(),
            yuy_stride: W * 2,
            width: W,
            height: H,
        };
        yuyv422_to_yuv422(&mut dst, &src).unwrap();
        dst.y_plane.borrow().iter().for_each(|&x| {
            assert_ne!(x, 0);
        });
        dst.u_plane.borrow().iter().for_each(|&x| {
            assert_ne!(x, 0);
        });
        dst.v_plane.borrow().iter().for_each(|&x| {
            assert_ne!(x, 0);
        })
    }

    #[test]
    fn test_yuyv444() {
        const W: u32 = 96;
        const H: u32 = 4;

        fn yuyv() -> Vec<u8> {
            let min = 16;
            let max = min + 2 * W as u8;
            (0..H).flat_map(|_| min..max).collect()
        }
        let mut dst = YuvPlanarImageMut::alloc(W, H, YuvChromaSubsampling::Yuv444);
        let src = YuvPackedImage {
            yuy: &yuyv(),
            yuy_stride: W * 2,
            width: W,
            height: H,
        };
        yuyv422_to_yuv444(&mut dst, &src).unwrap();
        dst.y_plane.borrow().iter().for_each(|&x| {
            assert_ne!(x, 0);
        });
        dst.u_plane.borrow().iter().for_each(|&x| {
            assert_ne!(x, 0);
        });
        dst.v_plane.borrow().iter().for_each(|&x| {
            assert_ne!(x, 0);
        })
    }
}
