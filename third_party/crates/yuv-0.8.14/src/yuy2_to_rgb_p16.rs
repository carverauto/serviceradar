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
use crate::numerics::qrshr_n;
use crate::yuv_error::check_rgba_destination;
use crate::yuv_support::{
    get_inverse_transform, get_yuv_range, YuvSourceChannels, Yuy2Description,
};
use crate::{YuvError, YuvPackedImage, YuvRange, YuvStandardMatrix};
#[cfg(feature = "rayon")]
use rayon::iter::{IndexedParallelIterator, ParallelIterator};
#[cfg(feature = "rayon")]
use rayon::prelude::{ParallelSlice, ParallelSliceMut};

fn yuy2_to_rgb_impl_p16<const DESTINATION_CHANNELS: u8, const YUY2_SOURCE: usize>(
    packed_image: &YuvPackedImage<u16>,
    rgb_store: &mut [u16],
    rgb_stride: u32,
    bit_depth: u32,
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

    const PRECISION: i32 = 13;
    let range = get_yuv_range(bit_depth, range);
    let max_colors = (1 << bit_depth) - 1;
    let kr_kb = matrix.get_kr_kb();
    let transform = get_inverse_transform(
        max_colors as u32,
        range.range_y,
        range.range_uv,
        kr_kb.kr,
        kr_kb.kb,
    );
    let inverse_transform = transform.to_integers(PRECISION as u32);
    let cr_coef = inverse_transform.cr_coef;
    let cb_coef = inverse_transform.cb_coef;
    let y_coef = inverse_transform.y_coef;
    let g_coef_1 = inverse_transform.g_coeff_1;
    let g_coef_2 = inverse_transform.g_coeff_2;
    let bias_y = range.bias_y as i32;
    let bias_uv = range.bias_uv as i32;

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

        for (rgb, yuy2) in rgb_store
            .chunks_exact_mut(2 * channels)
            .zip(yuy2_store.chunks_exact(4))
        {
            let first_y = yuy2[yuy2_source.get_first_y_position()];
            let second_y = yuy2[yuy2_source.get_second_y_position()];
            let u_value = yuy2[yuy2_source.get_u_position()];
            let v_value = yuy2[yuy2_source.get_v_position()];

            let cb = u_value as i32 - bias_uv;
            let cr = v_value as i32 - bias_uv;
            let f_y = (first_y as i32 - bias_y) * y_coef;
            let s_y = (second_y as i32 - bias_y) * y_coef;

            let r0 = qrshr_n::<PRECISION>(f_y + cr_coef * cr, max_colors);
            let b0 = qrshr_n::<PRECISION>(f_y + cb_coef * cb, max_colors);
            let g0 = qrshr_n::<PRECISION>(f_y - g_coef_1 * cr - g_coef_2 * cb, max_colors);

            rgb[dst_chans.get_r_channel_offset()] = r0 as u16;
            rgb[dst_chans.get_g_channel_offset()] = g0 as u16;
            rgb[dst_chans.get_b_channel_offset()] = b0 as u16;

            if dst_chans.has_alpha() {
                rgb[dst_chans.get_a_channel_offset()] = max_colors as u16;
            }

            let r1 = qrshr_n::<PRECISION>(s_y + cr_coef * cr, max_colors);
            let b1 = qrshr_n::<PRECISION>(s_y + cb_coef * cb, max_colors);
            let g1 = qrshr_n::<PRECISION>(s_y - g_coef_1 * cr - g_coef_2 * cb, max_colors);

            let rgb = &mut rgb[channels..channels * 2];

            rgb[dst_chans.get_r_channel_offset()] = r1 as u16;
            rgb[dst_chans.get_g_channel_offset()] = g1 as u16;
            rgb[dst_chans.get_b_channel_offset()] = b1 as u16;

            if dst_chans.has_alpha() {
                rgb[dst_chans.get_a_channel_offset()] = max_colors as u16;
            }
        }

        if packed_image.width & 1 == 1 {
            let last_rgb = rgb_store.chunks_exact_mut(2 * channels).into_remainder();
            let rgb = &mut last_rgb[0..channels];
            let yuy2 = yuy2_store.chunks_exact(4).last().unwrap();

            let first_y = yuy2[yuy2_source.get_first_y_position()];
            let u_value = yuy2[yuy2_source.get_u_position()];
            let v_value = yuy2[yuy2_source.get_v_position()];

            let cb = u_value as i32 - bias_uv;
            let cr = v_value as i32 - bias_uv;
            let f_y = (first_y as i32 - bias_y) * y_coef;

            let r0 = qrshr_n::<PRECISION>(f_y + cr_coef * cr, max_colors);
            let b0 = qrshr_n::<PRECISION>(f_y + cb_coef * cb, max_colors);
            let g0 = qrshr_n::<PRECISION>(f_y - g_coef_1 * cr - g_coef_2 * cb, max_colors);
            rgb[dst_chans.get_r_channel_offset()] = r0 as u16;
            rgb[dst_chans.get_g_channel_offset()] = g0 as u16;
            rgb[dst_chans.get_b_channel_offset()] = b0 as u16;

            if dst_chans.has_alpha() {
                rgb[dst_chans.get_a_channel_offset()] = max_colors as u16;
            }
        }
    });
    Ok(())
}

/// Convert YUYV (YUV Packed) 8+ bit depth format to RGB image.
///
/// This function takes YUYV (4:2:2 Packed) format data with 8-16 bit precision,
/// and converts it to RGB with 8-16 bit per channel precision.
///
/// # Arguments
///
/// * `packed_image` - Source packed image.
/// * `rgb` - A mutable slice to store the converted RGB data.
/// * `rgb_stride` - The stride (components per row) for the RGB image data.
/// * `bit_depth` - YUV and RGB bit depth.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input YUYV data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuyv422_to_rgb_p16(
    packed_image: &YuvPackedImage<u16>,
    rgb: &mut [u16],
    rgb_stride: u32,
    bit_depth: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuy2_to_rgb_impl_p16::<{ YuvSourceChannels::Rgb as u8 }, { Yuy2Description::YUYV as usize }>(
        packed_image,
        rgb,
        rgb_stride,
        bit_depth,
        range,
        matrix,
    )
}

/// Convert YUYV (YUV Packed) 8+ bit depth format to RGBA image.
///
/// This function takes YUYV (4:2:2 Packed) format data with 8-16 bit precision,
/// and converts it to RGBA with 8-16 bit per channel precision.
///
/// # Arguments
///
/// * `packed_image` - Source packed image.
/// * `rgba` - A mutable slice to store the converted RGBA data.
/// * `rgba_stride` - The stride (components per row) for the RGBA image data.
/// * `bit_depth` - YUV and RGB bit depth.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input YUYV data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuyv422_to_rgba_p16(
    packed_image: &YuvPackedImage<u16>,
    rgba: &mut [u16],
    rgba_stride: u32,
    bit_depth: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuy2_to_rgb_impl_p16::<{ YuvSourceChannels::Rgba as u8 }, { Yuy2Description::YUYV as usize }>(
        packed_image,
        rgba,
        rgba_stride,
        bit_depth,
        range,
        matrix,
    )
}

/// Convert UYVY (YUV Packed) 8+ bit depth format to RGB image.
///
/// This function takes UYVY (4:2:2 Packed) format data with 8-16 bit precision,
/// and converts it to RGB with 8-16 bit per channel precision.
///
/// # Arguments
///
/// * `packed_image` - Source packed image.
/// * `rgb` - A mutable slice to store the converted RGB data.
/// * `rgb_stride` - The stride (components per row) for the RGB image data.
/// * `bit_depth` - YUV and RGB bit depth.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input UYVY data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn uyvy422_to_rgb_p16(
    packed_image: &YuvPackedImage<u16>,
    rgb: &mut [u16],
    rgb_stride: u32,
    bit_depth: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuy2_to_rgb_impl_p16::<{ YuvSourceChannels::Rgb as u8 }, { Yuy2Description::UYVY as usize }>(
        packed_image,
        rgb,
        rgb_stride,
        bit_depth,
        range,
        matrix,
    )
}

/// Convert UYVY (YUV Packed) 8+ bit depth format to RGBA image.
///
/// This function takes UYVY (4:2:2 Packed) format data with 8-16 bit precision,
/// and converts it to RGBA with 8-16 bit per channel precision.
///
/// # Arguments
///
/// * `packed_image` - Source packed image.
/// * `rgba` - A mutable slice to store the converted RGBA data.
/// * `rgba_stride` - The stride (components per row) for the RGBA image data.
/// * `bit_depth` - YUV and RGB bit depth.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input UYVY data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn uyvy422_to_rgba_p16(
    packed_image: &YuvPackedImage<u16>,
    rgba: &mut [u16],
    rgba_stride: u32,
    bit_depth: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuy2_to_rgb_impl_p16::<{ YuvSourceChannels::Rgba as u8 }, { Yuy2Description::UYVY as usize }>(
        packed_image,
        rgba,
        rgba_stride,
        bit_depth,
        range,
        matrix,
    )
}

/// Convert YVYU ( YUV Packed ) 8+ bit depth format to RGB image.
///
/// This function takes YVYU (4:2:2 Packed) format data with 8-16 bit precision,
/// and converts it to RGB with 8-16 bit per channel precision.
///
/// # Arguments
///
/// * `packed_image` - Source packed image.
/// * `rgb` - A mutable slice to store the converted RGB data.
/// * `rgb_stride` - The stride (components per row) for the RGB image data.
/// * `bit_depth` - YUV and RGB bit depth.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input YVYU data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yvyu422_to_rgb_p16(
    packed_image: &YuvPackedImage<u16>,
    rgb: &mut [u16],
    rgb_stride: u32,
    bit_depth: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuy2_to_rgb_impl_p16::<{ YuvSourceChannels::Rgb as u8 }, { Yuy2Description::YVYU as usize }>(
        packed_image,
        rgb,
        rgb_stride,
        bit_depth,
        range,
        matrix,
    )
}

/// Convert YVYU (YUV Packed) 8+ bit depth format to RGBA image.
///
/// This function takes YVYU (4:2:2) format data with 8-16 bit precision,
/// and converts it to RGBA with 8-16 bit per channel precision.
///
/// # Arguments
///
/// * `packed_image` - Source packed image.
/// * `rgba` - A mutable slice to store the converted RGBA data.
/// * `rgba_stride` - The stride (components per row) for the RGBA image data.
/// * `bit_depth` - YUV and RGB bit depth.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input YVYU data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yvyu422_to_rgba_p16(
    packed_image: &YuvPackedImage<u16>,
    rgba: &mut [u16],
    rgba_stride: u32,
    bit_depth: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuy2_to_rgb_impl_p16::<{ YuvSourceChannels::Rgba as u8 }, { Yuy2Description::YVYU as usize }>(
        packed_image,
        rgba,
        rgba_stride,
        bit_depth,
        range,
        matrix,
    )
}

/// Convert VYUY (YUV Packed) 8+ bit depth format to RGB image.
///
/// This function takes VYUY (4:2:2 Packed) format data with 8-16 bit precision,
/// and converts it to RGB with 8-16 bit per channel precision.
///
/// # Arguments
///
/// * `packed_image` - Source packed image.
/// * `rgb` - A mutable slice to store the converted RGB data.
/// * `rgb_stride` - The stride (components per row) for the RGB image data.
/// * `bit_depth` - YUV and RGB bit depth.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input VYUY data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn vyuy422_to_rgb_p16(
    packed_image: &YuvPackedImage<u16>,
    rgb: &mut [u16],
    rgb_stride: u32,
    bit_depth: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuy2_to_rgb_impl_p16::<{ YuvSourceChannels::Rgb as u8 }, { Yuy2Description::VYUY as usize }>(
        packed_image,
        rgb,
        rgb_stride,
        bit_depth,
        range,
        matrix,
    )
}

/// Convert VYUY (YUV Packed) 8+ bit depth format to RGBA image.
///
/// This function takes VYUY (4:2:2 Packed) format data with 8-16 bit precision,
/// and converts it to RGBA with 8-16 bit per channel precision.
///
/// # Arguments
///
/// * `packed_image` - Source packed image.
/// * `rgba` - A mutable slice to store the converted RGBA data.
/// * `rgba_stride` - The stride (components per row) for the RGBA image data.
/// * `bit_depth` - YUV and RGB bit depth.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input VYUY data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn vyuy422_to_rgba_p16(
    packed_image: &YuvPackedImage<u16>,
    rgba: &mut [u16],
    rgba_stride: u32,
    bit_depth: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
) -> Result<(), YuvError> {
    yuy2_to_rgb_impl_p16::<{ YuvSourceChannels::Rgba as u8 }, { Yuy2Description::VYUY as usize }>(
        packed_image,
        rgba,
        rgba_stride,
        bit_depth,
        range,
        matrix,
    )
}
