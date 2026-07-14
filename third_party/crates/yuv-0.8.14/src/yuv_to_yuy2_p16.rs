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
use crate::yuv_support::{YuvChromaSubsampling, Yuy2Description};
use crate::yuv_to_yuy2::yuv_to_yuy2_impl;
use crate::{YuvError, YuvPackedImageMut, YuvPlanarImage};

/// Convert YUV 444 planar format to YUYV ( YUV Packed ) format.
///
/// This function takes YUV 444 planar format data with 8-16 bit precision,
/// and converts it to YUYV format with 8-16 bit per channel precision.
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
/// Panic will be received if buffer doesn't expand with (width + 1) size for odd width.
///
pub fn yuv444_to_yuyv422_p16(
    packed_image: &mut YuvPackedImageMut<u16>,
    planar_image: &YuvPlanarImage<u16>,
) -> Result<(), YuvError> {
    yuv_to_yuy2_impl::<
        u16,
        { YuvChromaSubsampling::Yuv444 as u8 },
        { Yuy2Description::YUYV as usize },
    >(planar_image, packed_image)
}

/// Convert YUV 422 planar format to YUYV ( YUV Packed ) format.
///
/// This function takes YUV 422 planar format data with 8-16 bit precision,
/// and converts it to YUYV format with 8-16 bit per channel precision.
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
/// Panic will be received if buffer doesn't expand with (width + 1) size for odd width.
///
pub fn yuv422_to_yuyv422_p16(
    packed_image: &mut YuvPackedImageMut<u16>,
    planar_image: &YuvPlanarImage<u16>,
) -> Result<(), YuvError> {
    yuv_to_yuy2_impl::<
        u16,
        { YuvChromaSubsampling::Yuv422 as u8 },
        { Yuy2Description::YUYV as usize },
    >(planar_image, packed_image)
}

/// Convert YUV 420 planar format to YUYV ( YUV Packed ) format.
///
/// This function takes YUV 420 planar format data with 8-16 bit precision,
/// and converts it to YUYV format with 8-16 bit per channel precision.
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
/// Panic will be received if buffer doesn't expand with (width + 1) size for odd width.
///
pub fn yuv420_to_yuyv422_p16(
    packed_image: &mut YuvPackedImageMut<u16>,
    planar_image: &YuvPlanarImage<u16>,
) -> Result<(), YuvError> {
    yuv_to_yuy2_impl::<
        u16,
        { YuvChromaSubsampling::Yuv420 as u8 },
        { Yuy2Description::YUYV as usize },
    >(planar_image, packed_image)
}

/// Convert YUV 444 planar format to YVYU ( YUV Packed ) format.
///
/// This function takes YUV 444 planar format data with 8-16 bit precision,
/// and converts it to YVYU format with 8-16 bit per channel precision.
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
/// Panic will be received if buffer doesn't expand with (width + 1) size for odd width.
///
pub fn yuv444_to_yvyu422_p16(
    packed_image: &mut YuvPackedImageMut<u16>,
    planar_image: &YuvPlanarImage<u16>,
) -> Result<(), YuvError> {
    yuv_to_yuy2_impl::<
        u16,
        { YuvChromaSubsampling::Yuv444 as u8 },
        { Yuy2Description::YVYU as usize },
    >(planar_image, packed_image)
}

/// Convert YUV 422 planar format to YVYU ( YUV Packed ) format.
///
/// This function takes YUV 422 planar format data with 8-16 bit precision,
/// and converts it to YVYU format with 8-16 bit per channel precision.
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
/// Panic will be received if buffer doesn't expand with (width + 1) size for odd width.
///
pub fn yuv422_to_yvyu422_p16(
    packed_image: &mut YuvPackedImageMut<u16>,
    planar_image: &YuvPlanarImage<u16>,
) -> Result<(), YuvError> {
    yuv_to_yuy2_impl::<
        u16,
        { YuvChromaSubsampling::Yuv422 as u8 },
        { Yuy2Description::YVYU as usize },
    >(planar_image, packed_image)
}

/// Convert YUV 420 planar format to YVYU ( YUV Packed ) format.
///
/// This function takes YUV 420 planar format data with 8-16 bit precision,
/// and converts it to YVYU format with 8-16 bit per channel precision.
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
/// Panic will be received if buffer doesn't expand with (width + 1) size for odd width.
///
pub fn yuv420_to_yvyu422_p16(
    packed_image: &mut YuvPackedImageMut<u16>,
    planar_image: &YuvPlanarImage<u16>,
) -> Result<(), YuvError> {
    yuv_to_yuy2_impl::<
        u16,
        { YuvChromaSubsampling::Yuv420 as u8 },
        { Yuy2Description::YVYU as usize },
    >(planar_image, packed_image)
}

/// Convert YUV 444 planar format to VYUY ( YUV Packed ) format.
///
/// This function takes YUV 444 planar format data with 8-16 bit precision,
/// and converts it to VYUY format with 8-16 bit per channel precision.
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
/// Panic will be received if buffer doesn't expand with (width + 1) size for odd width.
///
pub fn yuv444_to_vyuy422_p16(
    packed_image: &mut YuvPackedImageMut<u16>,
    planar_image: &YuvPlanarImage<u16>,
) -> Result<(), YuvError> {
    yuv_to_yuy2_impl::<
        u16,
        { YuvChromaSubsampling::Yuv444 as u8 },
        { Yuy2Description::VYUY as usize },
    >(planar_image, packed_image)
}

/// Convert YUV 422 planar format to VYUY ( YUV Packed ) format.
///
/// This function takes YUV 422 planar format data with 8-16 bit precision,
/// and converts it to VYUY format with 8-16 bit per channel precision.
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
/// Panic will be received if buffer doesn't expand with (width + 1) size for odd width.
///
pub fn yuv422_to_vyuy422_p16(
    packed_image: &mut YuvPackedImageMut<u16>,
    planar_image: &YuvPlanarImage<u16>,
) -> Result<(), YuvError> {
    yuv_to_yuy2_impl::<
        u16,
        { YuvChromaSubsampling::Yuv422 as u8 },
        { Yuy2Description::VYUY as usize },
    >(planar_image, packed_image)
}

/// Convert YUV 420 planar format to VYUY ( YUV Packed ) format.
///
/// This function takes YUV 420 planar format data with 8-16 bit precision,
/// and converts it to VYUY format with 8-16 bit per channel precision.
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
/// Panic will be received if buffer doesn't expand with (width + 1) size for odd width.
///
pub fn yuv420_to_vyuy422_p16(
    packed_image: &mut YuvPackedImageMut<u16>,
    planar_image: &YuvPlanarImage<u16>,
) -> Result<(), YuvError> {
    yuv_to_yuy2_impl::<
        u16,
        { YuvChromaSubsampling::Yuv420 as u8 },
        { Yuy2Description::VYUY as usize },
    >(planar_image, packed_image)
}

/// Convert YUV 444 planar format to UYVY ( YUV Packed ) format.
///
/// This function takes YUV 444 planar format data with 8-16 bit precision,
/// and converts it to UYVY format with 8-16 bit per channel precision.
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
/// Panic will be received if buffer doesn't expand with (width + 1) size for odd width.
///
pub fn yuv444_to_uyvy422_p16(
    packed_image: &mut YuvPackedImageMut<u16>,
    planar_image: &YuvPlanarImage<u16>,
) -> Result<(), YuvError> {
    yuv_to_yuy2_impl::<
        u16,
        { YuvChromaSubsampling::Yuv444 as u8 },
        { Yuy2Description::UYVY as usize },
    >(planar_image, packed_image)
}

/// Convert YUV 422 planar format to UYVY ( YUV Packed ) format.
///
/// This function takes YUV 422 planar format data with 8-16 bit precision,
/// and converts it to UYVY format with 8-16 bit per channel precision.
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
/// Panic will be received if buffer doesn't expand with (width + 1) size for odd width.
///
pub fn yuv422_to_uyvy422_p16(
    packed_image: &mut YuvPackedImageMut<u16>,
    planar_image: &YuvPlanarImage<u16>,
) -> Result<(), YuvError> {
    yuv_to_yuy2_impl::<
        u16,
        { YuvChromaSubsampling::Yuv422 as u8 },
        { Yuy2Description::UYVY as usize },
    >(planar_image, packed_image)
}

/// Convert YUV 420 planar format to UYVY ( YUV Packed ) format.
///
/// This function takes YUV 420 planar format data with 8-16 bit precision,
/// and converts it to UYVY format with 8-16 bit per channel precision.
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
/// Panic will be received if buffer doesn't expand with (width + 1) size for odd width.
///
pub fn yuv420_to_uyvy422_p16(
    packed_image: &mut YuvPackedImageMut<u16>,
    planar_image: &YuvPlanarImage<u16>,
) -> Result<(), YuvError> {
    yuv_to_yuy2_impl::<
        u16,
        { YuvChromaSubsampling::Yuv420 as u8 },
        { Yuy2Description::UYVY as usize },
    >(planar_image, packed_image)
}
