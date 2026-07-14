/*
 * Copyright (c) Radzivon Bartoshyk, 1/2025. All rights reserved.
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
use crate::yuv_error::check_rgba_destination;
use crate::YuvError;
use core::f16;

pub(crate) trait SurfaceToFloat16<V> {
    fn to_float16(&self, src: &[V], dst: &mut [f16], bit_depth: usize);
}

pub(crate) trait SurfaceFloat16ToUnsigned<V> {
    fn to_unsigned(&self, src: &[f16], dst: &mut [V], bit_depth: usize);
}

trait ConverterFactoryFloat16<V> {
    fn make_forward_converter(bit_depth: usize) -> Box<dyn SurfaceToFloat16<V>>;
    fn make_inverse_converter(bit_depth: usize) -> Box<dyn SurfaceFloat16ToUnsigned<V>>;
}

impl ConverterFactoryFloat16<u8> for u8 {
    #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
    fn make_forward_converter(bit_depth: usize) -> Box<dyn SurfaceToFloat16<u8>> {
        use crate::neon::{SurfaceU8ToFloat16Neon, SurfaceU8ToFloat16NeonFallback};
        if bit_depth <= 14 && std::arch::is_aarch64_feature_detected!("fp16") {
            return Box::new(SurfaceU8ToFloat16Neon::default());
        }
        Box::new(SurfaceU8ToFloat16NeonFallback::default())
    }

    #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
    fn make_forward_converter(_bit_depth: usize) -> Box<dyn SurfaceToFloat16<u8>> {
        #[cfg(feature = "avx")]
        {
            use crate::avx2::SurfaceU8ToFloat16Avx2;
            if _bit_depth <= 14
                && std::arch::is_x86_feature_detected!("avx2")
                && std::arch::is_x86_feature_detected!("f16c")
            {
                return Box::new(SurfaceU8ToFloat16Avx2::default());
            }
        }
        Box::new(CommonSurfaceToFloat16::<u8> {
            _phantom: Default::default(),
        })
    }

    #[cfg(not(any(
        all(target_arch = "aarch64", target_feature = "neon"),
        any(target_arch = "x86", target_arch = "x86_64")
    )))]
    fn make_forward_converter(_: usize) -> Box<dyn SurfaceToFloat16<u8>> {
        Box::new(CommonSurfaceToFloat16::<u8> {
            _phantom: Default::default(),
        })
    }

    #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
    fn make_inverse_converter(bit_depth: usize) -> Box<dyn SurfaceFloat16ToUnsigned<u8>> {
        use crate::neon::{SurfaceF16ToUnsigned8Neon, SurfaceF16ToUnsigned8NeonFallback};
        if bit_depth <= 14 && std::arch::is_aarch64_feature_detected!("fp16") {
            return Box::new(SurfaceF16ToUnsigned8Neon::default());
        }
        Box::new(SurfaceF16ToUnsigned8NeonFallback::default())
    }

    #[cfg(not(any(
        all(target_arch = "aarch64", target_feature = "neon"),
        any(target_arch = "x86", target_arch = "x86_64")
    )))]
    fn make_inverse_converter(_: usize) -> Box<dyn SurfaceFloat16ToUnsigned<u8>> {
        Box::new(CommonSurfaceFloat16ToUnsigned::<u8> {
            _phantom: Default::default(),
        })
    }

    #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
    fn make_inverse_converter(_: usize) -> Box<dyn SurfaceFloat16ToUnsigned<u8>> {
        Box::new(CommonSurfaceFloat16ToUnsigned::<u8> {
            _phantom: Default::default(),
        })
    }
}

impl ConverterFactoryFloat16<u16> for u16 {
    #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
    fn make_forward_converter(bit_depth: usize) -> Box<dyn SurfaceToFloat16<u16>> {
        use crate::neon::{SurfaceU16ToFloat16Neon, SurfaceU16ToFloat16NeonFallback};
        if bit_depth <= 14 && std::arch::is_aarch64_feature_detected!("fp16") {
            return Box::new(SurfaceU16ToFloat16Neon::default());
        }
        Box::new(SurfaceU16ToFloat16NeonFallback::default())
    }

    #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
    fn make_forward_converter(_bit_depth: usize) -> Box<dyn SurfaceToFloat16<u16>> {
        #[cfg(feature = "avx")]
        {
            use crate::avx2::SurfaceU16ToFloat16Avx2;
            if _bit_depth <= 14
                && std::arch::is_x86_feature_detected!("avx2")
                && std::arch::is_x86_feature_detected!("f16c")
            {
                return Box::new(SurfaceU16ToFloat16Avx2::default());
            }
        }
        Box::new(CommonSurfaceToFloat16::<u16> {
            _phantom: Default::default(),
        })
    }

    #[cfg(not(any(
        all(target_arch = "aarch64", target_feature = "neon"),
        any(target_arch = "x86", target_arch = "x86_64")
    )))]
    fn make_forward_converter(_: usize) -> Box<dyn SurfaceToFloat16<u16>> {
        Box::new(CommonSurfaceToFloat16::<u16> {
            _phantom: Default::default(),
        })
    }

    #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
    fn make_inverse_converter(bit_depth: usize) -> Box<dyn SurfaceFloat16ToUnsigned<u16>> {
        use crate::neon::{SurfaceF16ToUnsigned16Neon, SurfaceF16ToUnsigned16NeonFallback};
        if bit_depth <= 14 && std::arch::is_aarch64_feature_detected!("fp16") {
            return Box::new(SurfaceF16ToUnsigned16Neon::default());
        }
        Box::new(SurfaceF16ToUnsigned16NeonFallback::default())
    }

    #[cfg(not(any(
        all(target_arch = "aarch64", target_feature = "neon"),
        any(target_arch = "x86", target_arch = "x86_64")
    )))]
    fn make_inverse_converter(_: usize) -> Box<dyn SurfaceFloat16ToUnsigned<u16>> {
        Box::new(CommonSurfaceFloat16ToUnsigned::<u16> {
            _phantom: Default::default(),
        })
    }

    #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
    fn make_inverse_converter(_: usize) -> Box<dyn SurfaceFloat16ToUnsigned<u16>> {
        Box::new(CommonSurfaceFloat16ToUnsigned::<u16> {
            _phantom: Default::default(),
        })
    }
}

#[cfg(not(all(target_arch = "aarch64", target_feature = "neon")))]
struct CommonSurfaceToFloat16<V: num_traits::AsPrimitive<f32> + Copy> {
    _phantom: std::marker::PhantomData<V>,
}

#[cfg(not(all(target_arch = "aarch64", target_feature = "neon")))]
impl<V: num_traits::AsPrimitive<f32> + Copy> SurfaceToFloat16<V> for CommonSurfaceToFloat16<V> {
    fn to_float16(&self, src: &[V], dst: &mut [f16], bit_depth: usize) {
        let scale_f32 = 1. / ((1 << (bit_depth)) - 1) as f32;
        for (src, dst) in src.iter().zip(dst.iter_mut()) {
            let src_f32 = src.as_();
            *dst = (src_f32 * scale_f32) as f16;
        }
    }
}

#[cfg(not(all(target_arch = "aarch64", target_feature = "neon")))]
struct CommonSurfaceFloat16ToUnsigned<V: num_traits::AsPrimitive<f32> + Copy> {
    _phantom: std::marker::PhantomData<V>,
}

#[cfg(not(all(target_arch = "aarch64", target_feature = "neon")))]
impl<V: num_traits::AsPrimitive<f32> + Copy> SurfaceFloat16ToUnsigned<V>
    for CommonSurfaceFloat16ToUnsigned<V>
where
    f32: num_traits::AsPrimitive<V>,
{
    fn to_unsigned(&self, src: &[f16], dst: &mut [V], bit_depth: usize) {
        use num_traits::AsPrimitive;
        let scale_f32 = ((1 << (bit_depth)) - 1) as f32;
        for (src, dst) in src.iter().zip(dst.iter_mut()) {
            let src_f32 = (*src as f32 * scale_f32).round();
            *dst = src_f32.as_();
        }
    }
}

fn convert_surface_to_f16<V: Copy + ConverterFactoryFloat16<V>, const CN: usize>(
    src: &[V],
    src_stride: usize,
    dst: &mut [f16],
    dst_stride: usize,
    bit_depth: usize,
    width: usize,
    height: usize,
) -> Result<(), YuvError> {
    check_rgba_destination(src, src_stride as u32, width as u32, height as u32, CN)?;
    check_rgba_destination(dst, dst_stride as u32, width as u32, height as u32, CN)?;

    let converter = V::make_forward_converter(bit_depth);

    for (src, dst) in src
        .chunks_exact(src_stride)
        .zip(dst.chunks_exact_mut(dst_stride))
    {
        let src = &src[0..width * CN];
        let dst = &mut dst[0..width * CN];
        converter.to_float16(src, dst, bit_depth);
    }

    Ok(())
}

fn convert_f16_surface_to_unsigned<V: Copy + ConverterFactoryFloat16<V>, const CN: usize>(
    src: &[f16],
    src_stride: usize,
    dst: &mut [V],
    dst_stride: usize,
    bit_depth: usize,
    width: usize,
    height: usize,
) -> Result<(), YuvError> {
    check_rgba_destination(src, src_stride as u32, width as u32, height as u32, CN)?;
    check_rgba_destination(dst, dst_stride as u32, width as u32, height as u32, CN)?;

    let converter = V::make_inverse_converter(bit_depth);

    for (src, dst) in src
        .chunks_exact(src_stride)
        .zip(dst.chunks_exact_mut(dst_stride))
    {
        let src = &src[0..width * CN];
        let dst = &mut dst[0..width * CN];
        converter.to_unsigned(src, dst, bit_depth);
    }

    Ok(())
}

/// Converts planar 8-bit image to `f16`.
///
/// # Arguments
///
/// * `src`: Source image
/// * `src_stride`: Source image stride
/// * `dst`: Destination image
/// * `dst_stride`: Destination image stride
/// * `width`: Image width
/// * `height`: Image height
///
/// returns: Result<(), YuvError>
pub fn convert_plane_to_f16(
    src: &[u8],
    src_stride: usize,
    dst: &mut [f16],
    dst_stride: usize,
    width: usize,
    height: usize,
) -> Result<(), YuvError> {
    convert_surface_to_f16::<u8, 1>(src, src_stride, dst, dst_stride, 8, width, height)
}

/// Converts RGBA 8-bit image to `f16`.
///
/// Channel order does not matter.
///
/// # Arguments
///
/// * `src`: Source image
/// * `src_stride`: Source image stride
/// * `dst`: Destination image
/// * `dst_stride`: Destination image stride
/// * `width`: Image width
/// * `height`: Image height
///
/// returns: Result<(), YuvError>
pub fn convert_rgba_to_f16(
    src: &[u8],
    src_stride: usize,
    dst: &mut [f16],
    dst_stride: usize,
    width: usize,
    height: usize,
) -> Result<(), YuvError> {
    convert_surface_to_f16::<u8, 4>(src, src_stride, dst, dst_stride, 8, width, height)
}

/// Converts RGB 8-bit image to `f16`.
///
/// Channel order does not matter.
///
/// # Arguments
///
/// * `src`: Source image
/// * `src_stride`: Source image stride
/// * `dst`: Destination image
/// * `dst_stride`: Destination image stride
/// * `width`: Image width
/// * `height`: Image height
///
/// returns: Result<(), YuvError>
pub fn convert_rgb_to_f16(
    src: &[u8],
    src_stride: usize,
    dst: &mut [f16],
    dst_stride: usize,
    width: usize,
    height: usize,
) -> Result<(), YuvError> {
    convert_surface_to_f16::<u8, 3>(src, src_stride, dst, dst_stride, 8, width, height)
}

/// Converts planar 8+ bit-depth image to `f16`.
///
/// # Arguments
///
/// * `src`: Source image
/// * `src_stride`: Source image stride
/// * `dst`: Destination image
/// * `dst_stride`: Destination image stride
/// * `bit_depth`: Image bit depth
/// * `width`: Image width
/// * `height`: Image height
///
/// returns: Result<(), YuvError>
pub fn convert_plane16_to_f16(
    src: &[u16],
    src_stride: usize,
    dst: &mut [f16],
    dst_stride: usize,
    bit_depth: usize,
    width: usize,
    height: usize,
) -> Result<(), YuvError> {
    convert_surface_to_f16::<u16, 1>(src, src_stride, dst, dst_stride, bit_depth, width, height)
}

/// Converts RGBA 8+ bit-depth image to `f16`.
///
/// Channel order does not matter.
///
/// # Arguments
///
/// * `src`: Source image
/// * `src_stride`: Source image stride
/// * `dst`: Destination image
/// * `dst_stride`: Destination image stride
/// * `bit_depth`: Image bit depth
/// * `width`: Image width
/// * `height`: Image height
///
/// returns: Result<(), YuvError>
pub fn convert_rgba16_to_f16(
    src: &[u16],
    src_stride: usize,
    dst: &mut [f16],
    dst_stride: usize,
    bit_depth: usize,
    width: usize,
    height: usize,
) -> Result<(), YuvError> {
    convert_surface_to_f16::<u16, 4>(src, src_stride, dst, dst_stride, bit_depth, width, height)
}

/// Converts RGB 8+ bit-depth image to `f16`.
///
/// Channel order does not matter.
///
/// # Arguments
///
/// * `src`: Source image
/// * `src_stride`: Source image stride
/// * `dst`: Destination image
/// * `dst_stride`: Destination image stride
/// * `bit_depth`: Image bit depth.
/// * `width`: Image width
/// * `height`: Image height
///
/// returns: Result<(), YuvError>
pub fn convert_rgb16_to_f16(
    src: &[u16],
    src_stride: usize,
    dst: &mut [f16],
    dst_stride: usize,
    bit_depth: usize,
    width: usize,
    height: usize,
) -> Result<(), YuvError> {
    convert_surface_to_f16::<u16, 3>(src, src_stride, dst, dst_stride, bit_depth, width, height)
}

/// Converts planar `f16` image to 8 bit-depth image.
///
/// # Arguments
///
/// * `src`: Source image
/// * `src_stride`: Source image stride
/// * `dst`: Destination image
/// * `dst_stride`: Destination image stride
/// * `width`: Image width
/// * `height`: Image height
///
/// returns: Result<(), YuvError>
pub fn convert_plane_f16_to_planar(
    src: &[f16],
    src_stride: usize,
    dst: &mut [u8],
    dst_stride: usize,
    width: usize,
    height: usize,
) -> Result<(), YuvError> {
    convert_f16_surface_to_unsigned::<u8, 1>(src, src_stride, dst, dst_stride, 8, width, height)
}

/// Converts RGB `f16` image to 8 bit-depth image.
///
/// # Arguments
///
/// * `src`: Source image
/// * `src_stride`: Source image stride
/// * `dst`: Destination image
/// * `dst_stride`: Destination image stride
/// * `width`: Image width
/// * `height`: Image height
///
/// returns: Result<(), YuvError>
pub fn convert_rgb_f16_to_rgb(
    src: &[f16],
    src_stride: usize,
    dst: &mut [u8],
    dst_stride: usize,
    width: usize,
    height: usize,
) -> Result<(), YuvError> {
    convert_f16_surface_to_unsigned::<u8, 3>(src, src_stride, dst, dst_stride, 8, width, height)
}

/// Converts RGBA `f16` image to 8 bit-depth image.
///
/// # Arguments
///
/// * `src`: Source image
/// * `src_stride`: Source image stride
/// * `dst`: Destination image
/// * `dst_stride`: Destination image stride
/// * `width`: Image width
/// * `height`: Image height
///
/// returns: Result<(), YuvError>
pub fn convert_rgba_f16_to_rgba(
    src: &[f16],
    src_stride: usize,
    dst: &mut [u8],
    dst_stride: usize,
    width: usize,
    height: usize,
) -> Result<(), YuvError> {
    convert_f16_surface_to_unsigned::<u8, 4>(src, src_stride, dst, dst_stride, 8, width, height)
}

/// Converts planar `f16` image to 8+ bit-depth image.
///
/// # Arguments
///
/// * `src`: Source image
/// * `src_stride`: Source image stride
/// * `dst`: Destination image
/// * `dst_stride`: Destination image stride
/// * `bit_depth`: Image bit depth
/// * `width`: Image width
/// * `height`: Image height
///
/// returns: Result<(), YuvError>
pub fn convert_plane_f16_to_planar16(
    src: &[f16],
    src_stride: usize,
    dst: &mut [u16],
    dst_stride: usize,
    bit_depth: usize,
    width: usize,
    height: usize,
) -> Result<(), YuvError> {
    convert_f16_surface_to_unsigned::<u16, 1>(
        src, src_stride, dst, dst_stride, bit_depth, width, height,
    )
}

/// Converts RGB `f16` image to 8+ bit-depth image.
///
/// # Arguments
///
/// * `src`: Source image
/// * `src_stride`: Source image stride
/// * `dst`: Destination image
/// * `dst_stride`: Destination image stride
/// * `bit_depth`: Image bit depth
/// * `width`: Image width
/// * `height`: Image height
///
/// returns: Result<(), YuvError>
pub fn convert_rgb_f16_to_rgb16(
    src: &[f16],
    src_stride: usize,
    dst: &mut [u16],
    dst_stride: usize,
    bit_depth: usize,
    width: usize,
    height: usize,
) -> Result<(), YuvError> {
    convert_f16_surface_to_unsigned::<u16, 3>(
        src, src_stride, dst, dst_stride, bit_depth, width, height,
    )
}

/// Converts RGBA `f16` image to 8+ bit-depth image.
///
/// # Arguments
///
/// * `src`: Source image
/// * `src_stride`: Source image stride
/// * `dst`: Destination image
/// * `dst_stride`: Destination image stride
/// * `bit_depth`: Image bit depth
/// * `width`: Image width
/// * `height`: Image height
///
/// returns: Result<(), YuvError>
pub fn convert_rgba_f16_to_rgba16(
    src: &[f16],
    src_stride: usize,
    dst: &mut [u16],
    dst_stride: usize,
    bit_depth: usize,
    width: usize,
    height: usize,
) -> Result<(), YuvError> {
    convert_f16_surface_to_unsigned::<u16, 4>(
        src, src_stride, dst, dst_stride, bit_depth, width, height,
    )
}
