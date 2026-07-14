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
use crate::neon::yuy2_to_rgb_neon;
use crate::numerics::qrshr;
use crate::yuv_error::check_rgba_destination;
use crate::yuv_support::{
    get_inverse_transform, get_yuv_range, YuvSourceChannels, Yuy2Description,
};
#[allow(unused_imports)]
use crate::yuv_to_yuy2::YuvToYuy2Navigation;
use crate::{YuvError, YuvPackedImage, YuvRange, YuvStandardMatrix};
#[cfg(feature = "rayon")]
use rayon::iter::{IndexedParallelIterator, ParallelIterator};
#[cfg(feature = "rayon")]
use rayon::prelude::{ParallelSlice, ParallelSliceMut};

fn yuy2_to_rgb_impl<const DESTINATION_CHANNELS: u8, const YUY2_SOURCE: usize>(
    packed_image: &YuvPackedImage<u8>,
    rgb_store: &mut [u8],
    rgb_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    let yuy2_source: Yuy2Description = YUY2_SOURCE.into();

    let dst_chans: YuvSourceChannels = DESTINATION_CHANNELS.into();
    let channels = dst_chans.get_channels_count();

    packed_image.check_constraints()?;
    check_rgba_destination(
        rgb_store,
        rgb_stride,
        packed_image.width,
        packed_image.height,
        channels,
    )?;

    let range = get_yuv_range(8, range);
    let kr_kb = matrix.get_kr_kb();
    let transform = get_inverse_transform(255, range.range_y, range.range_uv, kr_kb.kr, kr_kb.kb);
    const PRECISION: i32 = 6;
    let inverse_transform = transform.to_integers(PRECISION as u32);
    let i16_transform = inverse_transform.cast::<i16>();
    let cr_coef = i16_transform.cr_coef;
    let cb_coef = i16_transform.cb_coef;
    let y_coef = i16_transform.y_coef;
    let g_coef_1 = i16_transform.g_coeff_1;
    let g_coef_2 = i16_transform.g_coeff_2;
    let bias_y = range.bias_y as i16;
    let bias_uv = range.bias_uv as i16;

    #[cfg(all(any(target_arch = "x86", target_arch = "x86_64"), feature = "sse"))]
    let _use_sse = std::arch::is_x86_feature_detected!("sse4.1");
    #[cfg(all(any(target_arch = "x86", target_arch = "x86_64"), feature = "avx"))]
    let _use_avx = std::arch::is_x86_feature_detected!("avx2");

    let rgb_iter;
    let yuy2_iter;
    #[cfg(feature = "rayon")]
    {
        rgb_iter = rgb_store.par_chunks_exact_mut(rgb_stride as usize);
        yuy2_iter = packed_image
            .yuy
            .par_chunks_exact(packed_image.yuy_stride as usize);
    }
    #[cfg(not(feature = "rayon"))]
    {
        rgb_iter = rgb_store.chunks_exact_mut(rgb_stride as usize);
        yuy2_iter = packed_image
            .yuy
            .chunks_exact(packed_image.yuy_stride as usize);
    }

    let yuy2_width = if packed_image.width % 2 == 0 {
        2 * packed_image.width as usize
    } else {
        2 * (packed_image.width as usize + 1)
    };

    rgb_iter.zip(yuy2_iter).for_each(|(rgb_store, yuy2_store)| {
        let yuy2_store = &yuy2_store[0..yuy2_width];
        let rgb_store = &mut rgb_store[0..(packed_image.width as usize * channels)];

        let mut _cx = 0usize;
        let mut _yuy2_x = 0usize;

        #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
        {
            #[cfg(feature = "avx")]
            if _use_avx {
                use crate::avx2::yuy2_to_rgb_avx;
                let processed = yuy2_to_rgb_avx::<DESTINATION_CHANNELS, YUY2_SOURCE>(
                    &range,
                    &inverse_transform,
                    yuy2_store,
                    rgb_store,
                    packed_image.width,
                    YuvToYuy2Navigation::new(_cx, 0, _yuy2_x),
                );
                _cx = processed.cx;
                _yuy2_x = processed.x;
            }
            #[cfg(feature = "sse")]
            if _use_sse {
                use crate::sse::yuy2_to_rgb_sse;
                let processed = yuy2_to_rgb_sse::<DESTINATION_CHANNELS, YUY2_SOURCE>(
                    &range,
                    &inverse_transform,
                    yuy2_store,
                    rgb_store,
                    packed_image.width,
                    YuvToYuy2Navigation::new(_cx, 0, _yuy2_x),
                );
                _cx = processed.cx;
                _yuy2_x = processed.x;
            }
        }

        #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
        {
            let processed = yuy2_to_rgb_neon::<DESTINATION_CHANNELS, YUY2_SOURCE, PRECISION>(
                &range,
                &inverse_transform,
                yuy2_store,
                rgb_store,
                packed_image.width,
                YuvToYuy2Navigation::new(_cx, 0, _yuy2_x),
            );
            _cx = processed.cx;
            _yuy2_x = processed.x;
        }

        for (rgb, yuy2) in rgb_store
            .chunks_exact_mut(2 * channels)
            .zip(yuy2_store.chunks_exact(4))
            .skip(_cx / 2)
        {
            let first_y = yuy2[yuy2_source.get_first_y_position()];
            let second_y = yuy2[yuy2_source.get_second_y_position()];
            let u_value = yuy2[yuy2_source.get_u_position()];
            let v_value = yuy2[yuy2_source.get_v_position()];

            let cb = u_value as i16 - bias_uv;
            let cr = v_value as i16 - bias_uv;
            let f_y = (first_y as i16 - bias_y) as i32 * y_coef as i32;
            let s_y = (second_y as i16 - bias_y) as i32 * y_coef as i32;

            let r0 = qrshr::<PRECISION, 8>(f_y + cr_coef as i32 * cr as i32);
            let b0 = qrshr::<PRECISION, 8>(f_y + cb_coef as i32 * cb as i32);
            let g0 = qrshr::<PRECISION, 8>(
                f_y - g_coef_1 as i32 * cr as i32 - g_coef_2 as i32 * cb as i32,
            );

            rgb[dst_chans.get_r_channel_offset()] = r0 as u8;
            rgb[dst_chans.get_g_channel_offset()] = g0 as u8;
            rgb[dst_chans.get_b_channel_offset()] = b0 as u8;

            if dst_chans.has_alpha() {
                rgb[dst_chans.get_a_channel_offset()] = 255;
            }

            let r1 = qrshr::<PRECISION, 8>(s_y + cr_coef as i32 * cr as i32);
            let b1 = qrshr::<PRECISION, 8>(s_y + cb_coef as i32 * cb as i32);
            let g1 = qrshr::<PRECISION, 8>(
                s_y - g_coef_1 as i32 * cr as i32 - g_coef_2 as i32 * cb as i32,
            );

            let rgb = &mut rgb[channels..channels * 2];

            rgb[dst_chans.get_r_channel_offset()] = r1 as u8;
            rgb[dst_chans.get_g_channel_offset()] = g1 as u8;
            rgb[dst_chans.get_b_channel_offset()] = b1 as u8;

            if dst_chans.has_alpha() {
                rgb[dst_chans.get_a_channel_offset()] = 255;
            }
        }

        if packed_image.width & 1 == 1 {
            let last_rgb = rgb_store.chunks_exact_mut(2 * channels).into_remainder();
            let rgb = &mut last_rgb[0..channels];
            let yuy2 = yuy2_store.chunks_exact(4).last().unwrap();

            let first_y = yuy2[yuy2_source.get_first_y_position()];
            let u_value = yuy2[yuy2_source.get_u_position()];
            let v_value = yuy2[yuy2_source.get_v_position()];

            let cb = u_value as i16 - bias_uv;
            let cr = v_value as i16 - bias_uv;
            let f_y = (first_y as i16 - bias_y) as i32 * y_coef as i32;

            let r0 = qrshr::<PRECISION, 8>(f_y + cr_coef as i32 * cr as i32);
            let b0 = qrshr::<PRECISION, 8>(f_y + cb_coef as i32 * cb as i32);
            let g0 = qrshr::<PRECISION, 8>(
                f_y - g_coef_1 as i32 * cr as i32 - g_coef_2 as i32 * cb as i32,
            );
            rgb[dst_chans.get_r_channel_offset()] = r0 as u8;
            rgb[dst_chans.get_g_channel_offset()] = g0 as u8;
            rgb[dst_chans.get_b_channel_offset()] = b0 as u8;

            if dst_chans.has_alpha() {
                rgb[dst_chans.get_a_channel_offset()] = 255;
            }
        }
    });
    Ok(())
}

/// Convert YUYV (YUV Packed) format to RGB image.
///
/// This function takes YUYV (4:2:2 Packed) format data with 8-bit precision,
/// and converts it to RGB with 8-bit per channel precision.
///
/// # Arguments
///
/// * `packed_image` - Source packed image.
/// * `rgb` - A mutable slice to store the converted RGB data.
/// * `rgb_stride` - The stride (components per row) for the RGB image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input YUYV data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuyv422_to_rgb(
    packed_image: &YuvPackedImage<u8>,
    rgb: &mut [u8],
    rgb_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuy2_to_rgb_impl::<{ YuvSourceChannels::Rgb as u8 }, { Yuy2Description::YUYV as usize }>(
        packed_image,
        rgb,
        rgb_stride,
        range,
        matrix,
    )
}

/// Convert YUYV (YUV Packed) format to RGBA image.
///
/// This function takes YUYV (4:2:2 Packed) format data with 8-bit precision,
/// and converts it to RGBA with 8-bit per channel precision.
///
/// # Arguments
///
/// * `packed_image` - Source packed image.
/// * `rgba` - A mutable slice to store the converted RGBA data.
/// * `rgba_stride` - The stride (components per row) for the RGBA image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input YUYV data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuyv422_to_rgba(
    packed_image: &YuvPackedImage<u8>,
    rgba: &mut [u8],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuy2_to_rgb_impl::<{ YuvSourceChannels::Rgba as u8 }, { Yuy2Description::YUYV as usize }>(
        packed_image,
        rgba,
        rgba_stride,
        range,
        matrix,
    )
}

/// Convert YUYV (YUV Packed) format to BGR image.
///
/// This function takes YUYV (4:2:2 Packed) format data with 8-bit precision,
/// and converts it to BGR with 8-bit per channel precision.
///
/// # Arguments
///
/// * `packed_image` - Source packed image.
/// * `bgr` - A mutable slice to store the converted BGR data.
/// * `bgr_stride` - The stride (components per row) for the BGR image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input YUYV data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuyv422_to_bgr(
    packed_image: &YuvPackedImage<u8>,
    bgr: &mut [u8],
    bgr_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuy2_to_rgb_impl::<{ YuvSourceChannels::Bgr as u8 }, { Yuy2Description::YUYV as usize }>(
        packed_image,
        bgr,
        bgr_stride,
        range,
        matrix,
    )
}

/// Convert YUYV (YUV Packed) format to BGR image.
///
/// This function takes YUYV (4:2:2 Packed) format data with 8-bit precision,
/// and converts it to BGRA with 8-bit per channel precision.
///
/// # Arguments
///
/// * `packed_image` - Source packed image.
/// * `bgra` - A mutable slice to store the converted BGRA data.
/// * `bgra_stride` - The stride (components per row) for the BGRA image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input YUYV data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuyv422_to_bgra(
    packed_image: &YuvPackedImage<u8>,
    bgra: &mut [u8],
    bgra_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuy2_to_rgb_impl::<{ YuvSourceChannels::Bgra as u8 }, { Yuy2Description::YUYV as usize }>(
        packed_image,
        bgra,
        bgra_stride,
        range,
        matrix,
    )
}

/// Convert UYVY (YUV Packed) format to RGB image.
///
/// This function takes UYVY (4:2:2 Packed) format data with 8-bit precision,
/// and converts it to RGB with 8-bit per channel precision.
///
/// # Arguments
///
/// * `packed_image` - Source packed image.
/// * `rgb` - A mutable slice to store the converted RGB data.
/// * `rgb_stride` - The stride (components per row) for the RGB image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input UYVY data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn uyvy422_to_rgb(
    packed_image: &YuvPackedImage<u8>,
    rgb: &mut [u8],
    rgb_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuy2_to_rgb_impl::<{ YuvSourceChannels::Rgb as u8 }, { Yuy2Description::UYVY as usize }>(
        packed_image,
        rgb,
        rgb_stride,
        range,
        matrix,
    )
}

/// Convert UYVY (YUV Packed) format to RGBA image.
///
/// This function takes UYVY (4:2:2 Packed) format data with 8-bit precision,
/// and converts it to RGBA with 8-bit per channel precision.
///
/// # Arguments
///
/// * `packed_image` - Source packed image.
/// * `rgba` - A mutable slice to store the converted RGBA data.
/// * `rgba_stride` - The stride (components per row) for the RGBA image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input UYVY data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn uyvy422_to_rgba(
    packed_image: &YuvPackedImage<u8>,
    rgba: &mut [u8],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuy2_to_rgb_impl::<{ YuvSourceChannels::Rgba as u8 }, { Yuy2Description::UYVY as usize }>(
        packed_image,
        rgba,
        rgba_stride,
        range,
        matrix,
    )
}

/// Convert UYVY (YUV Packed) format to BGR image.
///
/// This function takes UYVY (4:2:2 Packed) format data with 8-bit precision,
/// and converts it to BGR with 8-bit per channel precision.
///
/// # Arguments
///
/// * `packed_image` - Source packed image.
/// * `bgr` - A mutable slice to store the converted BGR data.
/// * `bgr_stride` - The stride (components per row) for the BGR image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input UYVY data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn uyvy422_to_bgr(
    packed_image: &YuvPackedImage<u8>,
    bgr: &mut [u8],
    bgr_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuy2_to_rgb_impl::<{ YuvSourceChannels::Bgr as u8 }, { Yuy2Description::UYVY as usize }>(
        packed_image,
        bgr,
        bgr_stride,
        range,
        matrix,
    )
}

/// Convert UYVY (YUV Packed) format to BGRA image.
///
/// This function takes UYVY (4:2:2 Packed) format data with 8-bit precision,
/// and converts it to BGRA with 8-bit per channel precision.
///
/// # Arguments
///
/// * `packed_image` - Source packed image.
/// * `bgra` - A mutable slice to store the converted BGRA data.
/// * `bgra_stride` - The stride (components per row) for the BGRA image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input UYVY data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn uyvy422_to_bgra(
    packed_image: &YuvPackedImage<u8>,
    bgra: &mut [u8],
    bgra_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuy2_to_rgb_impl::<{ YuvSourceChannels::Bgra as u8 }, { Yuy2Description::UYVY as usize }>(
        packed_image,
        bgra,
        bgra_stride,
        range,
        matrix,
    )
}

/// Convert YVYU ( YUV Packed ) format to RGB image.
///
/// This function takes YVYU (4:2:2 Packed) format data with 8-bit precision,
/// and converts it to RGB with 8-bit per channel precision.
///
/// # Arguments
///
/// * `packed_image` - Source packed image.
/// * `rgb` - A mutable slice to store the converted RGB data.
/// * `rgb_stride` - The stride (components per row) for the RGB image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input YVYU data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yvyu422_to_rgb(
    packed_image: &YuvPackedImage<u8>,
    rgb: &mut [u8],
    rgb_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuy2_to_rgb_impl::<{ YuvSourceChannels::Rgb as u8 }, { Yuy2Description::YVYU as usize }>(
        packed_image,
        rgb,
        rgb_stride,
        range,
        matrix,
    )
}

/// Convert YVYU (YUV Packed) format to RGBA image.
///
/// This function takes YVYU (4:2:2 Packed) format data with 8-bit precision,
/// and converts it to RGBA with 8-bit per channel precision.
///
/// # Arguments
///
/// * `packed_image` - Source packed image.
/// * `rgba` - A mutable slice to store the converted RGBA data.
/// * `rgba_stride` - The stride (components per row) for the RGBA image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input YVYU data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yvyu422_to_rgba(
    packed_image: &YuvPackedImage<u8>,
    rgba: &mut [u8],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuy2_to_rgb_impl::<{ YuvSourceChannels::Rgba as u8 }, { Yuy2Description::YVYU as usize }>(
        packed_image,
        rgba,
        rgba_stride,
        range,
        matrix,
    )
}

/// Convert YVYU (YUV Packed) format to BGR image.
///
/// This function takes YVYU (4:2:2 Packed) format data with 8-bit precision,
/// and converts it to BGR with 8-bit per channel precision.
///
/// # Arguments
///
/// * `packed_image` - Source packed image.
/// * `bgr` - A mutable slice to store the converted BGR data.
/// * `bgr_stride` - The stride (components per row) for the BGR image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input YVYU data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yvyu422_to_bgr(
    packed_image: &YuvPackedImage<u8>,
    bgr: &mut [u8],
    bgr_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuy2_to_rgb_impl::<{ YuvSourceChannels::Bgr as u8 }, { Yuy2Description::YVYU as usize }>(
        packed_image,
        bgr,
        bgr_stride,
        range,
        matrix,
    )
}

/// Convert YVYU (YUV Packed) format to BGRA image.
///
/// This function takes YVYU (4:2:2 Packed) format data with 8-bit precision,
/// and converts it to BGRA with 8-bit per channel precision.
///
/// # Arguments
///
/// * `packed_image` - Source packed image.
/// * `bgra` - A mutable slice to store the converted BGRA data.
/// * `bgra_stride` - The stride (components per row) for the BGRA image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input YVYU data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yvyu422_to_bgra(
    packed_image: &YuvPackedImage<u8>,
    bgra: &mut [u8],
    bgra_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuy2_to_rgb_impl::<{ YuvSourceChannels::Bgra as u8 }, { Yuy2Description::YVYU as usize }>(
        packed_image,
        bgra,
        bgra_stride,
        range,
        matrix,
    )
}

/// Convert VYUY (YUV Packed) format to RGB image.
///
/// This function takes VYUY (4:2:2 Packed) format data with 8-bit precision,
/// and converts it to RGB with 8-bit per channel precision.
///
/// # Arguments
///
/// * `packed_image` - Source packed image.
/// * `rgb` - A mutable slice to store the converted RGB data.
/// * `rgb_stride` - The stride (components per row) for the RGB image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input VYUY data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn vyuy422_to_rgb(
    packed_image: &YuvPackedImage<u8>,
    rgb: &mut [u8],
    rgb_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuy2_to_rgb_impl::<{ YuvSourceChannels::Rgb as u8 }, { Yuy2Description::VYUY as usize }>(
        packed_image,
        rgb,
        rgb_stride,
        range,
        matrix,
    )
}

/// Convert VYUY (YUV Packed) format to RGBA image.
///
/// This function takes VYUY (4:2:2 Packed) format data with 8-bit precision,
/// and converts it to RGBA with 8-bit per channel precision.
///
/// # Arguments
///
/// * `packed_image` - Source packed image.
/// * `rgba` - A mutable slice to store the converted RGBA data.
/// * `rgba_stride` - The stride (components per row) for the RGBA image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input VYUY data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn vyuy422_to_rgba(
    packed_image: &YuvPackedImage<u8>,
    rgba: &mut [u8],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuy2_to_rgb_impl::<{ YuvSourceChannels::Rgba as u8 }, { Yuy2Description::VYUY as usize }>(
        packed_image,
        rgba,
        rgba_stride,
        range,
        matrix,
    )
}

/// Convert VYUY (YUV Packed) format to BGR image.
///
/// This function takes VYUY (4:2:2 Packed) format data with 8-bit precision,
/// and converts it to BGR with 8-bit per channel precision.
///
/// # Arguments
///
/// * `packed_image` - Source packed image.
/// * `bgr` - A mutable slice to store the converted BGR data.
/// * `bgr_stride` - The stride (components per row) for the BGR image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input VYUY data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn vyuy422_to_bgr(
    packed_image: &YuvPackedImage<u8>,
    bgr: &mut [u8],
    bgr_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuy2_to_rgb_impl::<{ YuvSourceChannels::Bgr as u8 }, { Yuy2Description::VYUY as usize }>(
        packed_image,
        bgr,
        bgr_stride,
        range,
        matrix,
    )
}

/// Convert VYUY (YUV Packed) format to BGRA image.
///
/// This function takes VYUY (4:2:2 Packed) format data with 8-bit precision,
/// and converts it to BGRA with 8-bit per channel precision.
///
/// # Arguments
///
/// * `packed_image` - Source packed image.
/// * `bgra` - A mutable slice to store the converted BGRA data.
/// * `bgra_stride` - The stride (components per row) for the BGRA image data.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input VYUY data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn vyuy422_to_bgra(
    packed_image: &YuvPackedImage<u8>,
    bgra: &mut [u8],
    bgra_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuy2_to_rgb_impl::<{ YuvSourceChannels::Bgra as u8 }, { Yuy2Description::VYUY as usize }>(
        packed_image,
        bgra,
        bgra_stride,
        range,
        matrix,
    )
}
