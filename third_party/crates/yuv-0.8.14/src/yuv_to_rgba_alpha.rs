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
use crate::images::{projected_rgba_plane_mut, YuvPlanarProjectionAlpha};
use crate::internals::{ProcessedOffset, WideRowAlphaInversionHandler};
use crate::numerics::{div_by_255, qrshr};
use crate::yuv_error::check_rgba_destination;
use crate::yuv_support::*;
use crate::{YuvError, YuvPlanarImageWithAlpha, YuvRange, YuvStandardMatrix};
#[cfg(feature = "rayon")]
use rayon::iter::{IndexedParallelIterator, ParallelIterator};
#[cfg(feature = "rayon")]
use rayon::prelude::{ParallelSlice, ParallelSliceMut};

type RgbHandler = unsafe fn(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
    y_plane: &[u8],
    u_plane: &[u8],
    v_plane: &[u8],
    a_plane: &[u8],
    rgba: &mut [u8],
    start_cx: usize,
    start_ux: usize,
    width: usize,
    use_premultiply: bool,
) -> ProcessedOffset;

struct RgbDecoder<const DESTINATION_CHANNELS: u8, const SAMPLING: u8, const PRECISION: i32> {
    handler: Option<RgbHandler>,
}

impl<const DESTINATION_CHANNELS: u8, const SAMPLING: u8, const PRECISION: i32> Default
    for RgbDecoder<DESTINATION_CHANNELS, SAMPLING, PRECISION>
{
    fn default() -> Self {
        #[cfg(all(target_arch = "aarch64", target_feature = "neon"))]
        {
            #[cfg(feature = "rdm")]
            {
                let is_rdm_available = std::arch::is_aarch64_feature_detected!("rdm");
                if is_rdm_available && PRECISION == 13 {
                    assert_eq!(PRECISION, 13);
                    use crate::neon::neon_yuv_to_rgba_alpha_rdm;
                    return Self {
                        handler: Some(neon_yuv_to_rgba_alpha_rdm::<DESTINATION_CHANNELS, SAMPLING>),
                    };
                }
            }
            use crate::neon::neon_yuv_to_rgba_alpha;
            Self {
                handler: Some(neon_yuv_to_rgba_alpha::<DESTINATION_CHANNELS, SAMPLING>),
            }
        }
        #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
        {
            if PRECISION != 13 {
                return Self { handler: None };
            }
            assert_eq!(PRECISION, 13);
            #[cfg(feature = "nightly_avx512")]
            {
                let use_avx512 = std::arch::is_x86_feature_detected!("avx512bw");
                let use_vbmi = std::arch::is_x86_feature_detected!("avx512vbmi");
                if use_avx512 {
                    use crate::avx512bw::avx512_yuv_to_rgba_alpha;
                    return Self {
                        handler: Some(if use_vbmi {
                            avx512_yuv_to_rgba_alpha::<DESTINATION_CHANNELS, SAMPLING, true>
                        } else {
                            avx512_yuv_to_rgba_alpha::<DESTINATION_CHANNELS, SAMPLING, false>
                        }),
                    };
                }
            }
            #[cfg(feature = "avx")]
            {
                let use_avx2 = std::arch::is_x86_feature_detected!("avx2");
                if use_avx2 {
                    use crate::avx2::avx2_yuv_to_rgba_alpha;
                    return Self {
                        handler: Some(avx2_yuv_to_rgba_alpha::<DESTINATION_CHANNELS, SAMPLING>),
                    };
                }
            }
            #[cfg(feature = "sse")]
            {
                let use_sse = std::arch::is_x86_feature_detected!("sse4.1");
                if use_sse {
                    use crate::sse::sse_yuv_to_rgba_alpha_row;
                    return Self {
                        handler: Some(sse_yuv_to_rgba_alpha_row::<DESTINATION_CHANNELS, SAMPLING>),
                    };
                }
            }
        }
        #[cfg(not(all(target_arch = "aarch64", target_feature = "neon")))]
        RgbDecoder { handler: None }
    }
}

impl<const DESTINATION_CHANNELS: u8, const SAMPLING: u8, const PRECISION: i32>
    WideRowAlphaInversionHandler<u8, u8, i32>
    for RgbDecoder<DESTINATION_CHANNELS, SAMPLING, PRECISION>
{
    fn handle_row(
        &self,
        y_plane: &[u8],
        u_plane: &[u8],
        v_plane: &[u8],
        a_plane: &[u8],
        rgba: &mut [u8],
        width: u32,
        chroma: YuvChromaRange,
        transform: &CbCrInverseTransform<i32>,
        use_premultiplied_alpha: bool,
    ) -> ProcessedOffset {
        if let Some(handler) = self.handler {
            unsafe {
                return handler(
                    &chroma,
                    transform,
                    y_plane,
                    u_plane,
                    v_plane,
                    a_plane,
                    rgba,
                    0,
                    0,
                    width as usize,
                    use_premultiplied_alpha,
                );
            }
        }
        ProcessedOffset { cx: 0, ux: 0 }
    }
}

fn yuv_with_alpha_to_rgbx<const DESTINATION_CHANNELS: u8, const SAMPLING: u8>(
    image: &YuvPlanarImageWithAlpha<u8>,
    rgba: &mut [u8],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    premultiply_alpha: bool,
) -> Result<(), YuvError> {
    let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();
    let dst_chans: YuvSourceChannels = DESTINATION_CHANNELS.into();
    assert!(
        dst_chans.has_alpha(),
        "yuv_with_alpha_to_rgbx cannot be called on configuration without alpha"
    );
    let channels = dst_chans.get_channels_count();

    check_rgba_destination(rgba, rgba_stride, image.width, image.height, channels)?;
    image.check_constraints(chroma_subsampling)?;

    let chroma_range = get_yuv_range(8, range);
    let kr_kb = matrix.get_kr_kb();
    const PRECISION: i32 = 13;
    let inverse_transform =
        search_inverse_transform(PRECISION, 8, range, matrix, chroma_range, kr_kb);

    let cr_coef = inverse_transform.cr_coef;
    let cb_coef = inverse_transform.cb_coef;
    let y_coef = inverse_transform.y_coef;
    let g_coef_1 = inverse_transform.g_coeff_1;
    let g_coef_2 = inverse_transform.g_coeff_2;

    let bias_y = chroma_range.bias_y as i32;
    let bias_uv = chroma_range.bias_uv as i32;

    const BIT_DEPTH: usize = 8;

    let handler = RgbDecoder::<DESTINATION_CHANNELS, SAMPLING, PRECISION>::default();

    let process_halved_chroma_row =
        |y_plane: &[u8], u_plane: &[u8], v_plane: &[u8], a_plane: &[u8], rgba: &mut [u8]| {
            let cx = handler
                .handle_row(
                    y_plane,
                    u_plane,
                    v_plane,
                    a_plane,
                    rgba,
                    image.width,
                    chroma_range,
                    &inverse_transform,
                    premultiply_alpha,
                )
                .cx;
            if cx != image.width as usize {
                for ((((rgba, y_src), &u_src), &v_src), a_src) in rgba
                    .chunks_exact_mut(channels * 2)
                    .zip(y_plane.chunks_exact(2))
                    .zip(u_plane.iter())
                    .zip(v_plane.iter())
                    .zip(a_plane.chunks_exact(2))
                    .skip(cx / 2)
                {
                    let y_value0 = (y_src[0] as i32 - bias_y) * y_coef;
                    let cb_value = u_src as i32 - bias_uv;
                    let cr_value = v_src as i32 - bias_uv;

                    let mut r0 = qrshr::<PRECISION, BIT_DEPTH>(y_value0 + cr_coef * cr_value);
                    let mut b0 = qrshr::<PRECISION, BIT_DEPTH>(y_value0 + cb_coef * cb_value);
                    let mut g0 = qrshr::<PRECISION, BIT_DEPTH>(
                        y_value0 - g_coef_1 * cr_value - g_coef_2 * cb_value,
                    );

                    if premultiply_alpha {
                        let a0 = a_src[0];
                        r0 = div_by_255(r0 as u16 * a0 as u16) as i32;
                        g0 = div_by_255(g0 as u16 * a0 as u16) as i32;
                        b0 = div_by_255(b0 as u16 * a0 as u16) as i32;
                    }

                    let rgba0 = &mut rgba[..channels];

                    rgba0[dst_chans.get_r_channel_offset()] = r0 as u8;
                    rgba0[dst_chans.get_g_channel_offset()] = g0 as u8;
                    rgba0[dst_chans.get_b_channel_offset()] = b0 as u8;
                    rgba0[dst_chans.get_a_channel_offset()] = a_src[0];

                    let y_value1 = (y_src[1] as i32 - bias_y) * y_coef;

                    let mut r1 = qrshr::<PRECISION, BIT_DEPTH>(y_value1 + cr_coef * cr_value);
                    let mut b1 = qrshr::<PRECISION, BIT_DEPTH>(y_value1 + cb_coef * cb_value);
                    let mut g1 = qrshr::<PRECISION, BIT_DEPTH>(
                        y_value1 - g_coef_1 * cr_value - g_coef_2 * cb_value,
                    );

                    if premultiply_alpha {
                        let a1 = a_src[1];
                        r1 = div_by_255(r1 as u16 * a1 as u16) as i32;
                        g1 = div_by_255(g1 as u16 * a1 as u16) as i32;
                        b1 = div_by_255(b1 as u16 * a1 as u16) as i32;
                    }

                    let rgba1 = &mut rgba[channels..channels * 2];

                    rgba1[dst_chans.get_r_channel_offset()] = r1 as u8;
                    rgba1[dst_chans.get_g_channel_offset()] = g1 as u8;
                    rgba1[dst_chans.get_b_channel_offset()] = b1 as u8;
                    rgba1[dst_chans.get_a_channel_offset()] = a_src[1];
                }

                if image.width & 1 != 0 {
                    let y_value0 = (*y_plane.last().unwrap() as i32 - bias_y) * y_coef;
                    let cb_value = *u_plane.last().unwrap() as i32 - bias_uv;
                    let cr_value = *v_plane.last().unwrap() as i32 - bias_uv;
                    let a_value = *a_plane.last().unwrap();
                    let rgba = rgba.chunks_exact_mut(channels).last().unwrap();
                    let rgba0 = &mut rgba[..channels];

                    let mut r0 = qrshr::<PRECISION, BIT_DEPTH>(y_value0 + cr_coef * cr_value);
                    let mut b0 = qrshr::<PRECISION, BIT_DEPTH>(y_value0 + cb_coef * cb_value);
                    let mut g0 = qrshr::<PRECISION, BIT_DEPTH>(
                        y_value0 - g_coef_1 * cr_value - g_coef_2 * cb_value,
                    );

                    if premultiply_alpha {
                        let a0 = a_value;
                        r0 = div_by_255(r0 as u16 * a0 as u16) as i32;
                        g0 = div_by_255(g0 as u16 * a0 as u16) as i32;
                        b0 = div_by_255(b0 as u16 * a0 as u16) as i32;
                    }

                    rgba0[dst_chans.get_r_channel_offset()] = r0 as u8;
                    rgba0[dst_chans.get_g_channel_offset()] = g0 as u8;
                    rgba0[dst_chans.get_b_channel_offset()] = b0 as u8;
                    rgba0[dst_chans.get_a_channel_offset()] = a_value;
                }
            }
        };

    let YuvPlanarProjectionAlpha {
        y: y_plane,
        u: u_plane,
        v: v_plane,
        a: a_plane,
    } = image.projected_planes(chroma_subsampling);
    let rgba = projected_rgba_plane_mut(rgba, image.width, image.height, rgba_stride, dst_chans);

    if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
        let iter;
        #[cfg(feature = "rayon")]
        {
            iter = rgba
                .par_chunks_mut(rgba_stride as usize)
                .zip(y_plane.par_chunks(image.y_stride as usize))
                .zip(a_plane.par_chunks(image.a_stride as usize))
                .zip(u_plane.par_chunks(image.u_stride as usize))
                .zip(v_plane.par_chunks(image.v_stride as usize));
        }
        #[cfg(not(feature = "rayon"))]
        {
            iter = rgba
                .chunks_mut(rgba_stride as usize)
                .zip(y_plane.chunks(image.y_stride as usize))
                .zip(a_plane.chunks(image.a_stride as usize))
                .zip(u_plane.chunks(image.u_stride as usize))
                .zip(v_plane.chunks(image.v_stride as usize));
        }
        iter.for_each(|((((rgba, y_plane), a_plane), u_plane), v_plane)| {
            let y_plane = &y_plane[..image.width as usize];
            let u_plane = &u_plane[..image.width as usize];
            let v_plane = &v_plane[..image.width as usize];
            let a_plane = &a_plane[..image.width as usize];
            let cx = handler
                .handle_row(
                    y_plane,
                    u_plane,
                    v_plane,
                    a_plane,
                    rgba,
                    image.width,
                    chroma_range,
                    &inverse_transform,
                    premultiply_alpha,
                )
                .cx;
            if cx != image.width as usize {
                for ((((rgba, &y_src), &u_src), &v_src), &a_src) in rgba
                    .chunks_exact_mut(channels)
                    .zip(y_plane.iter())
                    .zip(u_plane.iter())
                    .zip(v_plane.iter())
                    .zip(a_plane.iter())
                    .skip(cx)
                {
                    let y_value = (y_src as i32 - bias_y) * y_coef;
                    let cb_value = u_src as i32 - bias_uv;
                    let cr_value = v_src as i32 - bias_uv;

                    let mut r = qrshr::<PRECISION, BIT_DEPTH>(y_value + cr_coef * cr_value);
                    let mut b = qrshr::<PRECISION, BIT_DEPTH>(y_value + cb_coef * cb_value);
                    let mut g = qrshr::<PRECISION, BIT_DEPTH>(
                        y_value - g_coef_1 * cr_value - g_coef_2 * cb_value,
                    );

                    if premultiply_alpha {
                        let a0 = a_src;
                        r = div_by_255(r as u16 * a0 as u16) as i32;
                        b = div_by_255(b as u16 * a0 as u16) as i32;
                        g = div_by_255(g as u16 * a0 as u16) as i32;
                    }

                    rgba[dst_chans.get_r_channel_offset()] = r as u8;
                    rgba[dst_chans.get_g_channel_offset()] = g as u8;
                    rgba[dst_chans.get_b_channel_offset()] = b as u8;
                    rgba[dst_chans.get_a_channel_offset()] = a_src;
                }
            }
        });
    } else if chroma_subsampling == YuvChromaSubsampling::Yuv422 {
        let iter;
        #[cfg(feature = "rayon")]
        {
            iter = rgba
                .par_chunks_mut(rgba_stride as usize)
                .zip(y_plane.par_chunks(image.y_stride as usize))
                .zip(a_plane.par_chunks(image.a_stride as usize))
                .zip(u_plane.par_chunks(image.u_stride as usize))
                .zip(v_plane.par_chunks(image.v_stride as usize));
        }
        #[cfg(not(feature = "rayon"))]
        {
            iter = rgba
                .chunks_mut(rgba_stride as usize)
                .zip(y_plane.chunks(image.y_stride as usize))
                .zip(a_plane.chunks(image.a_stride as usize))
                .zip(u_plane.chunks(image.u_stride as usize))
                .zip(v_plane.chunks(image.v_stride as usize));
        }
        iter.for_each(|((((rgba, y_plane), a_plane), u_plane), v_plane)| {
            process_halved_chroma_row(
                &y_plane[..image.width as usize],
                &u_plane[..(image.width as usize).div_ceil(2)],
                &v_plane[..(image.width as usize).div_ceil(2)],
                &a_plane[..image.width as usize],
                &mut rgba[..image.width as usize * channels],
            );
        });
    } else if chroma_subsampling == YuvChromaSubsampling::Yuv420 {
        let iter;
        #[cfg(feature = "rayon")]
        {
            iter = rgba
                .par_chunks_mut(rgba_stride as usize * 2)
                .zip(y_plane.par_chunks(image.y_stride as usize * 2))
                .zip(a_plane.par_chunks(image.a_stride as usize * 2))
                .zip(u_plane.par_chunks(image.u_stride as usize))
                .zip(v_plane.par_chunks(image.v_stride as usize));
        }
        #[cfg(not(feature = "rayon"))]
        {
            iter = rgba
                .chunks_mut(rgba_stride as usize * 2)
                .zip(y_plane.chunks(image.y_stride as usize * 2))
                .zip(a_plane.chunks(image.a_stride as usize * 2))
                .zip(u_plane.chunks(image.u_stride as usize))
                .zip(v_plane.chunks(image.v_stride as usize));
        }
        iter.take(image.height as usize / 2).for_each(
            |((((rgba, y_plane), a_plane), u_plane), v_plane)| {
                for ((rgba, y_plane), a_plane) in rgba
                    .chunks_mut(rgba_stride as usize)
                    .zip(y_plane.chunks(image.y_stride as usize))
                    .zip(a_plane.chunks(image.a_stride as usize))
                {
                    process_halved_chroma_row(
                        &y_plane[..image.width as usize],
                        &u_plane[..(image.width as usize).div_ceil(2)],
                        &v_plane[..(image.width as usize).div_ceil(2)],
                        &a_plane[..image.width as usize],
                        &mut rgba[..image.width as usize * channels],
                    );
                }
            },
        );

        if image.height & 1 != 0 {
            let rgba = rgba.chunks_mut(rgba_stride as usize).last().unwrap();
            let u_plane = u_plane.chunks(image.u_stride as usize).last().unwrap();
            let v_plane = v_plane.chunks(image.v_stride as usize).last().unwrap();
            let a_plane = a_plane.chunks(image.a_stride as usize).last().unwrap();
            let y_plane = y_plane.chunks(image.y_stride as usize).last().unwrap();
            process_halved_chroma_row(
                &y_plane[..image.width as usize],
                &u_plane[..(image.width as usize).div_ceil(2)],
                &v_plane[..(image.width as usize).div_ceil(2)],
                &a_plane[..image.width as usize],
                &mut rgba[..image.width as usize * channels],
            );
        }
    } else {
        unreachable!();
    }

    Ok(())
}

/// Convert YUV 420 planar format to RGBA format and appends provided alpha channel.
///
/// This function takes YUV 420 planar format data with 8-bit precision,
/// and converts it to RGBA format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `planar_with_alpha` - Source planar image.
/// * `rgba` - A mutable slice to store the converted RGBA data.
/// * `rgba_stride` - Elements per row.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
/// * `premultiply_alpha` - Flag to premultiply alpha or not
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGRA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv420_alpha_to_rgba(
    planar_with_alpha: &YuvPlanarImageWithAlpha<u8>,
    rgba: &mut [u8],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    premultiply_alpha: bool,
) -> Result<(), YuvError> {
    yuv_with_alpha_to_rgbx::<
        { YuvSourceChannels::Rgba as u8 },
        { YuvChromaSubsampling::Yuv420 as u8 },
    >(
        planar_with_alpha,
        rgba,
        rgba_stride,
        range,
        matrix,
        premultiply_alpha,
    )
}

/// Convert YUV 420 planar format to BGRA format and appends provided alpha channel.
///
/// This function takes YUV 420 planar format data with 8-bit precision,
/// and converts it to BGRA format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `planar_with_alpha` - Source planar image.
/// * `bgra` - A mutable slice to store the converted BGRA data.
/// * `bgra_stride` - Elements per row.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
/// * `premultiply_alpha` - Flag to premultiply alpha or not
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGRA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv420_alpha_to_bgra(
    planar_with_alpha: &YuvPlanarImageWithAlpha<u8>,
    bgra: &mut [u8],
    bgra_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    premultiply_alpha: bool,
) -> Result<(), YuvError> {
    yuv_with_alpha_to_rgbx::<
        { YuvSourceChannels::Bgra as u8 },
        { YuvChromaSubsampling::Yuv420 as u8 },
    >(
        planar_with_alpha,
        bgra,
        bgra_stride,
        range,
        matrix,
        premultiply_alpha,
    )
}

/// Convert YUV 422 planar format to RGBA format and appends provided alpha channel.
///
/// This function takes YUV 422 planar format data with 8-bit precision,
/// and converts it to RGBA format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `planar_with_alpha` - Source planar image.
/// * `rgba` - A mutable slice to store the converted RGBA data.
/// * `rgba_stride` - Elements per row.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
/// * `premultiply_alpha` - Flag to premultiply alpha or not
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGRA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv422_alpha_to_rgba(
    planar_with_alpha: &YuvPlanarImageWithAlpha<u8>,
    rgba: &mut [u8],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    premultiply_alpha: bool,
) -> Result<(), YuvError> {
    yuv_with_alpha_to_rgbx::<
        { YuvSourceChannels::Rgba as u8 },
        { YuvChromaSubsampling::Yuv422 as u8 },
    >(
        planar_with_alpha,
        rgba,
        rgba_stride,
        range,
        matrix,
        premultiply_alpha,
    )
}

/// Convert YUV 422 planar format to BGRA format and appends provided alpha channel.
///
/// This function takes YUV 422 planar format data with 8-bit precision,
/// and converts it to BGRA format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `planar_with_alpha` - Source planar image.
/// * `bgra` - A mutable slice to store the converted BGRA data.
/// * `bgra_stride` - Elements per row.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
/// * `premultiply_alpha` - Flag to premultiply alpha or not
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGRA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv422_alpha_to_bgra(
    planar_with_alpha: &YuvPlanarImageWithAlpha<u8>,
    bgra: &mut [u8],
    bgra_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    premultiply_alpha: bool,
) -> Result<(), YuvError> {
    yuv_with_alpha_to_rgbx::<
        { YuvSourceChannels::Bgra as u8 },
        { YuvChromaSubsampling::Yuv422 as u8 },
    >(
        planar_with_alpha,
        bgra,
        bgra_stride,
        range,
        matrix,
        premultiply_alpha,
    )
}

/// Convert YUV 444 planar format to RGBA format and appends provided alpha channel.
///
/// This function takes YUV 444 planar format data with 8-bit precision,
/// and converts it to RGBA format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `planar_with_alpha` - Source planar image.
/// * `rgba` - A mutable slice to store the converted RGBA data.
/// * `rgba_stride` - Elements per row.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
/// * `premultiply_alpha` - Flag to premultiply alpha or not
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGRA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv444_alpha_to_rgba(
    planar_with_alpha: &YuvPlanarImageWithAlpha<u8>,
    rgba: &mut [u8],
    rgba_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    premultiply_alpha: bool,
) -> Result<(), YuvError> {
    yuv_with_alpha_to_rgbx::<
        { YuvSourceChannels::Rgba as u8 },
        { YuvChromaSubsampling::Yuv444 as u8 },
    >(
        planar_with_alpha,
        rgba,
        rgba_stride,
        range,
        matrix,
        premultiply_alpha,
    )
}

/// Convert YUV 444 planar format to BGRA format and appends provided alpha channel.
///
/// This function takes YUV 444 planar format data with 8-bit precision,
/// and converts it to BGRA format with 8-bit per channel precision.
///
/// # Arguments
///
/// * `planar_with_alpha` - Source planar image.
/// * `bgra` - A mutable slice to store the converted BGRA data.
/// * `bgra_stride` - Elements per row.
/// * `range` - The YUV range (limited or full).
/// * `matrix` - The YUV standard matrix (BT.601 or BT.709 or BT.2020 or other).
/// * `premultiply_alpha` - Flag to premultiply alpha or not
///
/// # Panics
///
/// This function panics if the lengths of the planes or the input BGRA data are not valid based
/// on the specified width, height, and strides, or if invalid YUV range or matrix is provided.
///
pub fn yuv444_alpha_to_bgra(
    planar_with_alpha: &YuvPlanarImageWithAlpha<u8>,
    bgra: &mut [u8],
    bgra_stride: u32,
    range: YuvRange,
    matrix: YuvStandardMatrix,
    premultiply_alpha: bool,
) -> Result<(), YuvError> {
    yuv_with_alpha_to_rgbx::<
        { YuvSourceChannels::Bgra as u8 },
        { YuvChromaSubsampling::Yuv444 as u8 },
    >(
        planar_with_alpha,
        bgra,
        bgra_stride,
        range,
        matrix,
        premultiply_alpha,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{rgba_to_yuv444, YuvPlanarImageMut};
    use rand::RngExt;

    #[test]
    fn test_yuv444_round_trip_full_range_with_alpha() {
        let image_width = 256usize;
        let image_height = 256usize;

        let random_point_x = rand::rng().random_range(0..image_width);
        let random_point_y = rand::rng().random_range(0..image_height);

        const CHANNELS: usize = 4;

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
        let mut image_rgb = vec![0u8; image_width * image_height * CHANNELS];

        let or = rand::rng().random_range(0..256) as u8;
        let og = rand::rng().random_range(0..256) as u8;
        let ob = rand::rng().random_range(0..256) as u8;
        let oa = rand::rng().random_range(0..256) as u8;

        for point in &pixel_points {
            image_rgb[point[0] * 4 + point[1] * image_width * 4] = or;
            image_rgb[point[0] * 4 + point[1] * image_width * 4 + 1] = og;
            image_rgb[point[0] * 4 + point[1] * image_width * 4 + 2] = ob;
            image_rgb[point[0] * 4 + point[1] * image_width * 4 + 3] = oa;
        }

        let mut planar_image = YuvPlanarImageMut::<u8>::alloc(
            image_width as u32,
            image_height as u32,
            YuvChromaSubsampling::Yuv444,
        );

        rgba_to_yuv444(
            &mut planar_image,
            &image_rgb,
            image_width as u32 * CHANNELS as u32,
            YuvRange::Full,
            YuvStandardMatrix::Bt709,
            YuvConversionMode::Balanced,
        )
        .unwrap();

        image_rgb.fill(0);

        let a_plane = vec![oa; image_width * image_height];

        let fixed_planar = YuvPlanarImageWithAlpha {
            y_plane: planar_image.y_plane.borrow(),
            y_stride: planar_image.y_stride,
            u_plane: planar_image.u_plane.borrow(),
            u_stride: planar_image.u_stride,
            v_plane: planar_image.v_plane.borrow(),
            v_stride: planar_image.v_stride,
            a_plane: &a_plane,
            a_stride: image_width as u32,
            width: image_width as u32,
            height: image_height as u32,
        };

        yuv444_alpha_to_rgba(
            &fixed_planar,
            &mut image_rgb,
            image_width as u32 * CHANNELS as u32,
            YuvRange::Full,
            YuvStandardMatrix::Bt709,
            false,
        )
        .unwrap();

        for point in &pixel_points {
            let x = point[0];
            let y = point[1];
            let r = image_rgb[x * CHANNELS + y * image_width * CHANNELS];
            let g = image_rgb[x * CHANNELS + y * image_width * CHANNELS + 1];
            let b = image_rgb[x * CHANNELS + y * image_width * CHANNELS + 2];
            let a = image_rgb[x * CHANNELS + y * image_width * CHANNELS + 3];

            let diff_r = (r as i32 - or as i32).abs();
            let diff_g = (g as i32 - og as i32).abs();
            let diff_b = (b as i32 - ob as i32).abs();

            assert!(
                diff_r <= 3,
                "Original RGBA {:?}, Round-tripped RGBA {:?}",
                [or, og, ob, oa],
                [r, g, b, a]
            );
            assert!(
                diff_g <= 3,
                "Original RGBA {:?}, Round-tripped RGBA {:?}",
                [or, og, ob, oa],
                [r, g, b, a]
            );
            assert!(
                diff_b <= 3,
                "Original RGBA {:?}, Round-tripped RGBA {:?}",
                [or, og, ob, oa],
                [r, g, b, a]
            );
            assert_eq!(
                a,
                oa,
                "Original RGBA {:?}, Round-tripped RGBA {:?}",
                [or, og, ob, oa],
                [r, g, b, a]
            );
        }
    }

    #[test]
    fn test_yuv444_round_trip_limited_range_with_alpha() {
        let image_width = 256usize;
        let image_height = 256usize;

        let random_point_x = rand::rng().random_range(0..image_width);
        let random_point_y = rand::rng().random_range(0..image_height);

        const CHANNELS: usize = 4;

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
        let mut image_rgb = vec![0u8; image_width * image_height * CHANNELS];

        let or = rand::rng().random_range(0..256) as u8;
        let og = rand::rng().random_range(0..256) as u8;
        let ob = rand::rng().random_range(0..256) as u8;
        let oa = rand::rng().random_range(0..256) as u8;

        for point in &pixel_points {
            image_rgb[point[0] * CHANNELS + point[1] * image_width * CHANNELS] = or;
            image_rgb[point[0] * CHANNELS + point[1] * image_width * CHANNELS + 1] = og;
            image_rgb[point[0] * CHANNELS + point[1] * image_width * CHANNELS + 2] = ob;
            image_rgb[point[0] * CHANNELS + point[1] * image_width * CHANNELS + 3] = oa;
        }

        let mut planar_image = YuvPlanarImageMut::<u8>::alloc(
            image_width as u32,
            image_height as u32,
            YuvChromaSubsampling::Yuv444,
        );

        rgba_to_yuv444(
            &mut planar_image,
            &image_rgb,
            image_width as u32 * CHANNELS as u32,
            YuvRange::Full,
            YuvStandardMatrix::Bt709,
            YuvConversionMode::Balanced,
        )
        .unwrap();

        image_rgb.fill(0);

        let a_plane = vec![oa; image_width * image_height];

        let fixed_planar = YuvPlanarImageWithAlpha {
            y_plane: planar_image.y_plane.borrow(),
            y_stride: planar_image.y_stride,
            u_plane: planar_image.u_plane.borrow(),
            u_stride: planar_image.u_stride,
            v_plane: planar_image.v_plane.borrow(),
            v_stride: planar_image.v_stride,
            a_plane: &a_plane,
            a_stride: image_width as u32,
            width: image_width as u32,
            height: image_height as u32,
        };

        yuv444_alpha_to_rgba(
            &fixed_planar,
            &mut image_rgb,
            image_width as u32 * 4,
            YuvRange::Full,
            YuvStandardMatrix::Bt709,
            false,
        )
        .unwrap();

        for point in &pixel_points {
            let x = point[0];
            let y = point[1];
            let r = image_rgb[x * CHANNELS + y * image_width * CHANNELS];
            let g = image_rgb[x * CHANNELS + y * image_width * CHANNELS + 1];
            let b = image_rgb[x * CHANNELS + y * image_width * CHANNELS + 2];
            let a = image_rgb[x * CHANNELS + y * image_width * CHANNELS + 3];

            let diff_r = (r as i32 - or as i32).abs();
            let diff_g = (g as i32 - og as i32).abs();
            let diff_b = (b as i32 - ob as i32).abs();

            assert!(
                diff_r <= 10,
                "Original RGBA {:?}, Round-tripped RGBA {:?}",
                [or, og, ob, oa],
                [r, g, b, a]
            );
            assert!(
                diff_g <= 10,
                "Original RGBA {:?}, Round-tripped RGBA {:?}",
                [or, og, ob, oa],
                [r, g, b, a]
            );
            assert!(
                diff_b <= 10,
                "Original RGBA {:?}, Round-tripped RGBA {:?}",
                [or, og, ob, oa],
                [r, g, b, a]
            );
            assert_eq!(
                a,
                oa,
                "Original RGBA {:?}, Round-tripped RGBA {:?}",
                [or, og, ob, oa],
                [r, g, b, a]
            );
        }
    }
}
