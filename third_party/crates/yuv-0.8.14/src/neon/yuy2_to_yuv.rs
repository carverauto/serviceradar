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
use crate::neon::utils::xvst1q_u8_x2;
use crate::yuv_support::{YuvChromaSubsampling, Yuy2Description};
use crate::yuv_to_yuy2::YuvToYuy2Navigation;
use std::arch::aarch64::*;

pub(crate) fn yuy2_to_yuv_neon_impl<const SAMPLING: u8, const YUY2_TARGET: usize>(
    y_plane: &mut [u8],
    u_plane: &mut [u8],
    v_plane: &mut [u8],
    yuy2_store: &[u8],
    width: u32,
    nav: YuvToYuy2Navigation,
) -> YuvToYuy2Navigation {
    let yuy2_source: Yuy2Description = YUY2_TARGET.into();
    let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();

    let mut cx = nav.cx;
    let mut uv_x = nav.uv_x;
    let mut _yuy2_x = nav.x;

    unsafe {
        while cx + 32 < width as usize {
            let dst_offset = cx * 2;
            let u_pos = uv_x;
            let v_pos = uv_x;
            let y_pos = cx;

            let pixel_set = vld4q_u8(yuy2_store.get_unchecked(dst_offset..).as_ptr());
            let mut y_first = match yuy2_source {
                Yuy2Description::YUYV | Yuy2Description::YVYU => pixel_set.0,
                Yuy2Description::UYVY | Yuy2Description::VYUY => pixel_set.1,
            };
            let mut y_second = match yuy2_source {
                Yuy2Description::YUYV | Yuy2Description::YVYU => pixel_set.2,
                Yuy2Description::UYVY | Yuy2Description::VYUY => pixel_set.3,
            };

            let y_first_reconstructed = vzip1q_u8(y_first, y_second);
            let y_second_reconstructed = vzip2q_u8(y_first, y_second);
            y_first = y_first_reconstructed;
            y_second = y_second_reconstructed;

            let u_value = match yuy2_source {
                Yuy2Description::YUYV => pixel_set.1,
                Yuy2Description::UYVY => pixel_set.0,
                Yuy2Description::YVYU => pixel_set.3,
                Yuy2Description::VYUY => pixel_set.2,
            };
            let v_value = match yuy2_source {
                Yuy2Description::YUYV => pixel_set.3,
                Yuy2Description::UYVY => pixel_set.2,
                Yuy2Description::YVYU => pixel_set.1,
                Yuy2Description::VYUY => pixel_set.0,
            };

            xvst1q_u8_x2(
                y_plane.get_unchecked_mut(y_pos..).as_mut_ptr(),
                uint8x16x2_t(y_first, y_second),
            );

            if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
                let low_u_value = vzip1q_u8(u_value, u_value);
                let high_u_value = vzip2q_u8(u_value, u_value);
                let low_v_value = vzip1q_u8(v_value, v_value);
                let high_v_value = vzip2q_u8(v_value, v_value);
                xvst1q_u8_x2(
                    u_plane.get_unchecked_mut(u_pos..).as_mut_ptr(),
                    uint8x16x2_t(low_u_value, high_u_value),
                );
                xvst1q_u8_x2(
                    v_plane.get_unchecked_mut(v_pos..).as_mut_ptr(),
                    uint8x16x2_t(low_v_value, high_v_value),
                );
            } else {
                vst1q_u8(u_plane.get_unchecked_mut(u_pos..).as_mut_ptr(), u_value);
                vst1q_u8(v_plane.get_unchecked_mut(v_pos..).as_mut_ptr(), v_value);
            }

            uv_x += match chroma_subsampling {
                YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => 16,
                YuvChromaSubsampling::Yuv444 => 32,
            };
            cx += 32;
        }

        while cx + 16 < width as usize {
            let dst_offset = cx * 2;
            let u_pos = uv_x;
            let v_pos = uv_x;
            let y_pos = cx;

            let pixel_set = vld4_u8(yuy2_store.get_unchecked(dst_offset..).as_ptr());
            let mut y_first = match yuy2_source {
                Yuy2Description::YUYV | Yuy2Description::YVYU => pixel_set.0,
                Yuy2Description::UYVY | Yuy2Description::VYUY => pixel_set.1,
            };
            let mut y_second = match yuy2_source {
                Yuy2Description::YUYV | Yuy2Description::YVYU => pixel_set.2,
                Yuy2Description::UYVY | Yuy2Description::VYUY => pixel_set.3,
            };

            let y_first_reconstructed = vzip1_u8(y_first, y_second);
            let y_second_reconstructed = vzip2_u8(y_first, y_second);
            y_first = y_first_reconstructed;
            y_second = y_second_reconstructed;

            let u_value = match yuy2_source {
                Yuy2Description::YUYV => pixel_set.1,
                Yuy2Description::UYVY => pixel_set.0,
                Yuy2Description::YVYU => pixel_set.3,
                Yuy2Description::VYUY => pixel_set.2,
            };
            let v_value = match yuy2_source {
                Yuy2Description::YUYV => pixel_set.3,
                Yuy2Description::UYVY => pixel_set.2,
                Yuy2Description::YVYU => pixel_set.1,
                Yuy2Description::VYUY => pixel_set.0,
            };

            vst1q_u8(
                y_plane.as_mut_ptr().add(y_pos),
                vcombine_u8(y_first, y_second),
            );

            if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
                let low_u_value = vzip1_u8(u_value, u_value);
                let high_u_value = vzip2_u8(u_value, u_value);
                let low_v_value = vzip1_u8(v_value, v_value);
                let high_v_value = vzip2_u8(v_value, v_value);
                vst1q_u8(
                    u_plane.get_unchecked_mut(u_pos..).as_mut_ptr(),
                    vcombine_u8(low_u_value, high_u_value),
                );
                vst1q_u8(
                    v_plane.get_unchecked_mut(v_pos..).as_mut_ptr(),
                    vcombine_u8(low_v_value, high_v_value),
                );
            } else {
                vst1_u8(u_plane.get_unchecked_mut(u_pos..).as_mut_ptr(), u_value);
                vst1_u8(v_plane.get_unchecked_mut(v_pos..).as_mut_ptr(), v_value);
            }

            uv_x += match chroma_subsampling {
                YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => 8,
                YuvChromaSubsampling::Yuv444 => 16,
            };
            cx += 16;
        }

        _yuy2_x = cx;
    }

    YuvToYuy2Navigation {
        cx,
        uv_x,
        x: _yuy2_x,
    }
}
