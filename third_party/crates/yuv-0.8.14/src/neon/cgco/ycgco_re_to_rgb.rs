/*
 * Copyright (c) Radzivon Bartoshyk, 4/2026. All rights reserved.
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
use crate::yuv_support::{YuvChromaRange, YuvSourceChannels};
use crate::YuvChromaSubsampling;

#[target_feature(enable = "neon")]
pub(crate) unsafe fn ycgco_ro_re_u16_to_rgba_neon<
    const SAMPLING: u8,
    const PRECISION: i32,
    const BIT_DEPTH: usize,
    const R_TYPE: usize,
    const DST_CHANS: u8,
>(
    y_plane: &[u16],
    u_plane: &[u16],
    v_plane: &[u16],
    rgba_data: &mut [u8],
    width: usize,
    chroma_range: YuvChromaRange,
    range_reduction_y: i32,
) {
    use std::arch::aarch64::*;
    let sampling: YuvChromaSubsampling = SAMPLING.into();

    let dst_chans: YuvSourceChannels = DST_CHANS.into();
    let channels = dst_chans.get_channels_count();

    let max_colors = ((1u32 << BIT_DEPTH) - 1u32) as i32;

    let v_bias_y = vdupq_n_u16(chroma_range.bias_y as u16);
    let v_bias_uv = vdupq_n_s16(chroma_range.bias_uv as i16);
    let v_rry = vdupq_n_s16(range_reduction_y as i16);

    let v_round = vdupq_n_s32((1 << PRECISION) - 1);

    let mut ux = 0usize;
    let mut x: usize = 0;

    macro_rules! decode8 {
        ($y_u16:expr, $cg_u16:expr, $co_u16:expr) => {{
            let y_val = vreinterpretq_s16_u16(vqsubq_u16($y_u16, v_bias_y));
            let cg_val = vsubq_s16($cg_u16, v_bias_uv);
            let co_val = vsubq_s16($co_u16, v_bias_uv);

            let cg_half = vshrq_n_s16::<1>(cg_val);
            let co_half = vshrq_n_s16::<1>(co_val);
            let t0 = vsubq_s16(y_val, cg_half);
            let bz0 = vsubq_s16(t0, co_half);

            let r_s16 = vaddq_s16(bz0, co_val);
            let g_s16 = vaddq_s16(t0, cg_val);
            let b_s16 = bz0;

            let r_lo = vmlal_s16(v_round, vget_low_s16(r_s16), vget_low_s16(v_rry));
            let g_lo = vmlal_s16(v_round, vget_low_s16(g_s16), vget_low_s16(v_rry));
            let b_lo = vmlal_s16(v_round, vget_low_s16(b_s16), vget_low_s16(v_rry));
            let r_hi = vmlal_high_s16(v_round, r_s16, v_rry);
            let g_hi = vmlal_high_s16(v_round, g_s16, v_rry);
            let b_hi = vmlal_high_s16(v_round, b_s16, v_rry);

            let r8 = vqmovn_u16(vcombine_u16(
                vqshrun_n_s32::<PRECISION>(r_lo),
                vqshrun_n_s32::<PRECISION>(r_hi),
            ));
            let g8 = vqmovn_u16(vcombine_u16(
                vqshrun_n_s32::<PRECISION>(g_lo),
                vqshrun_n_s32::<PRECISION>(g_hi),
            ));
            let b8 = vqmovn_u16(vcombine_u16(
                vqshrun_n_s32::<PRECISION>(b_lo),
                vqshrun_n_s32::<PRECISION>(b_hi),
            ));
            (r8, g8, b8)
        }};
    }

    while x + 16 <= width {
        let y_u16_0 = vld1q_u16(y_plane.get_unchecked(x));
        let y_u16_1 = vld1q_u16(y_plane.get_unchecked(x + 8));
        let (cg_u16_0, cg_u16_1) = match sampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                let q = vld1q_u16(u_plane.get_unchecked(ux));
                (
                    vreinterpretq_s16_u16(vzip1q_u16(q, q)),
                    vreinterpretq_s16_u16(vzip2q_u16(q, q)),
                )
            }
            YuvChromaSubsampling::Yuv444 => (
                vreinterpretq_s16_u16(vld1q_u16(u_plane.get_unchecked(ux))),
                vreinterpretq_s16_u16(vld1q_u16(u_plane.get_unchecked(ux + 8))),
            ),
        };
        let (co_u16_0, co_u16_1) = match sampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                let q = vld1q_u16(v_plane.get_unchecked(ux));
                (
                    vreinterpretq_s16_u16(vzip1q_u16(q, q)),
                    vreinterpretq_s16_u16(vzip2q_u16(q, q)),
                )
            }
            YuvChromaSubsampling::Yuv444 => (
                vreinterpretq_s16_u16(vld1q_u16(v_plane.get_unchecked(ux))),
                vreinterpretq_s16_u16(vld1q_u16(v_plane.get_unchecked(ux + 8))),
            ),
        };

        let (r8_0, g8_0, b8_0) = decode8!(y_u16_0, cg_u16_0, co_u16_0);
        let (r8_1, g8_1, b8_1) = decode8!(y_u16_1, cg_u16_1, co_u16_1);

        let r8 = vcombine_u8(r8_0, r8_1);
        let g8 = vcombine_u8(g8_0, g8_1);
        let b8 = vcombine_u8(b8_0, b8_1);

        let dst = rgba_data.get_unchecked_mut(x * channels);

        match dst_chans {
            YuvSourceChannels::Rgb => {
                let rgb = uint8x16x3_t(r8, g8, b8);
                vst3q_u8(dst, rgb);
            }
            YuvSourceChannels::Rgba => {
                let a8 = vdupq_n_u8(max_colors as u8);
                let rgba = uint8x16x4_t(r8, g8, b8, a8);
                vst4q_u8(dst, rgba);
            }
            YuvSourceChannels::Bgr => {
                let bgr = uint8x16x3_t(b8, g8, r8);
                vst3q_u8(dst, bgr);
            }
            YuvSourceChannels::Bgra => {
                let a8 = vdupq_n_u8(max_colors as u8);
                let bgra = uint8x16x4_t(b8, g8, r8, a8);
                vst4q_u8(dst, bgra);
            }
        }

        x += 16;
        ux += match sampling {
            YuvChromaSubsampling::Yuv422 | YuvChromaSubsampling::Yuv420 => 8,
            YuvChromaSubsampling::Yuv444 => 16,
        };
    }

    while x + 8 <= width {
        let y_u16 = vld1q_u16(y_plane.get_unchecked(x));
        let cg_u16 = match sampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                let q = vld1_u16(u_plane.get_unchecked(ux));
                let r = vcombine_u16(q, q);
                vreinterpretq_s16_u16(vzip1q_u16(r, r))
            }
            YuvChromaSubsampling::Yuv444 => {
                vreinterpretq_s16_u16(vld1q_u16(u_plane.get_unchecked(ux)))
            }
        };
        let co_u16 = match sampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                let q = vld1_u16(v_plane.get_unchecked(ux));
                let r = vcombine_u16(q, q);
                vreinterpretq_s16_u16(vzip1q_u16(r, r))
            }
            YuvChromaSubsampling::Yuv444 => {
                vreinterpretq_s16_u16(vld1q_u16(v_plane.get_unchecked(ux)))
            }
        };

        let (r8, g8, b8) = decode8!(y_u16, cg_u16, co_u16);

        let dst = rgba_data.get_unchecked_mut(x * channels);

        match dst_chans {
            YuvSourceChannels::Rgb => {
                let rgb = uint8x8x3_t(r8, g8, b8);
                vst3_u8(dst, rgb);
            }
            YuvSourceChannels::Rgba => {
                let a8 = vdup_n_u8(max_colors as u8);
                let rgba = uint8x8x4_t(r8, g8, b8, a8);
                vst4_u8(dst, rgba);
            }
            YuvSourceChannels::Bgr => {
                let bgr = uint8x8x3_t(b8, g8, r8);
                vst3_u8(dst, bgr);
            }
            YuvSourceChannels::Bgra => {
                let a8 = vdup_n_u8(max_colors as u8);
                let bgra = uint8x8x4_t(b8, g8, r8, a8);
                vst4_u8(dst, bgra);
            }
        }

        x += 8;
        ux += match sampling {
            YuvChromaSubsampling::Yuv422 | YuvChromaSubsampling::Yuv420 => 4,
            YuvChromaSubsampling::Yuv444 => 8,
        };
    }

    if x < width {
        let diff = width - x;
        assert!(diff <= 8);

        let mut y_buffer: [u16; 8] = [0; 8];
        let mut u_buffer: [u16; 8] = [0; 8];
        let mut v_buffer: [u16; 8] = [0; 8];

        std::ptr::copy_nonoverlapping(
            y_plane.get_unchecked(x..).as_ptr(),
            y_buffer.as_mut_ptr().cast(),
            diff,
        );

        if sampling == YuvChromaSubsampling::Yuv444 {
            std::ptr::copy_nonoverlapping(
                u_plane.get_unchecked(ux..).as_ptr(),
                u_buffer.as_mut_ptr().cast(),
                diff,
            );
            std::ptr::copy_nonoverlapping(
                v_plane.get_unchecked(ux..).as_ptr(),
                v_buffer.as_mut_ptr().cast(),
                diff,
            );
        } else {
            std::ptr::copy_nonoverlapping(
                u_plane.get_unchecked(ux..).as_ptr(),
                u_buffer.as_mut_ptr().cast(),
                diff.div_ceil(2),
            );
            std::ptr::copy_nonoverlapping(
                v_plane.get_unchecked(ux..).as_ptr(),
                v_buffer.as_mut_ptr().cast(),
                diff.div_ceil(2),
            );
        }

        let mut buffer: [u8; 8 * 4] = [0; 8 * 4];
        ycgco_ro_re_u16_to_rgba_neon::<SAMPLING, PRECISION, BIT_DEPTH, R_TYPE, DST_CHANS>(
            &y_buffer,
            &u_buffer,
            &v_buffer,
            &mut buffer,
            8,
            chroma_range,
            range_reduction_y,
        );

        std::ptr::copy_nonoverlapping(
            buffer.as_ptr().cast(),
            rgba_data.get_unchecked_mut(x * channels..).as_mut_ptr(),
            diff * channels,
        );
    }
}

#[target_feature(enable = "neon")]
pub(crate) unsafe fn ycgco_ro_re_u16_to_rgba_neon_full<
    const SAMPLING: u8,
    const PRECISION: i32,
    const BIT_DEPTH: usize,
    const R_TYPE: usize,
    const DST_CHANS: u8,
>(
    y_plane: &[u16],
    u_plane: &[u16],
    v_plane: &[u16],
    rgba_data: &mut [u8],
    width: usize,
    chroma_range: YuvChromaRange,
    range_reduction_y: i32,
) {
    use std::arch::aarch64::*;
    let sampling: YuvChromaSubsampling = SAMPLING.into();

    let dst_chans: YuvSourceChannels = DST_CHANS.into();
    let channels = dst_chans.get_channels_count();

    let max_colors = ((1u32 << BIT_DEPTH) - 1u32) as i32;

    let v_bias_y = vdupq_n_u16(chroma_range.bias_y as u16);
    let v_bias_uv = vdupq_n_s16(chroma_range.bias_uv as i16);

    let mut ux = 0usize;
    let mut x: usize = 0;

    macro_rules! decode8 {
        ($y_u16:expr, $cg_u16:expr, $co_u16:expr) => {{
            let y_val = vreinterpretq_s16_u16(vqsubq_u16($y_u16, v_bias_y));
            let cg_val = vsubq_s16($cg_u16, v_bias_uv);
            let co_val = vsubq_s16($co_u16, v_bias_uv);

            let cg_half = vshrq_n_s16::<1>(cg_val);
            let co_half = vshrq_n_s16::<1>(co_val);
            let t0 = vsubq_s16(y_val, cg_half);
            let bz0 = vsubq_s16(t0, co_half);

            let r_s16 = vaddq_s16(bz0, co_val);
            let g_s16 = vaddq_s16(t0, cg_val);
            let b_s16 = bz0;

            let r8 = vqmovun_s16(r_s16);
            let g8 = vqmovun_s16(g_s16);
            let b8 = vqmovun_s16(b_s16);
            (r8, g8, b8)
        }};
    }

    while x + 16 <= width {
        let y_u16_0 = vld1q_u16(y_plane.get_unchecked(x));
        let y_u16_1 = vld1q_u16(y_plane.get_unchecked(x + 8));
        let (cg_u16_0, cg_u16_1) = match sampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                let q = vld1q_u16(u_plane.get_unchecked(ux));
                (
                    vreinterpretq_s16_u16(vzip1q_u16(q, q)),
                    vreinterpretq_s16_u16(vzip2q_u16(q, q)),
                )
            }
            YuvChromaSubsampling::Yuv444 => (
                vreinterpretq_s16_u16(vld1q_u16(u_plane.get_unchecked(ux))),
                vreinterpretq_s16_u16(vld1q_u16(u_plane.get_unchecked(ux + 8))),
            ),
        };
        let (co_u16_0, co_u16_1) = match sampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                let q = vld1q_u16(v_plane.get_unchecked(ux));
                (
                    vreinterpretq_s16_u16(vzip1q_u16(q, q)),
                    vreinterpretq_s16_u16(vzip2q_u16(q, q)),
                )
            }
            YuvChromaSubsampling::Yuv444 => (
                vreinterpretq_s16_u16(vld1q_u16(v_plane.get_unchecked(ux))),
                vreinterpretq_s16_u16(vld1q_u16(v_plane.get_unchecked(ux + 8))),
            ),
        };

        let (r8_0, g8_0, b8_0) = decode8!(y_u16_0, cg_u16_0, co_u16_0);
        let (r8_1, g8_1, b8_1) = decode8!(y_u16_1, cg_u16_1, co_u16_1);

        let r8 = vcombine_u8(r8_0, r8_1);
        let g8 = vcombine_u8(g8_0, g8_1);
        let b8 = vcombine_u8(b8_0, b8_1);

        let dst = rgba_data.get_unchecked_mut(x * channels);

        match dst_chans {
            YuvSourceChannels::Rgb => {
                let rgb = uint8x16x3_t(r8, g8, b8);
                vst3q_u8(dst, rgb);
            }
            YuvSourceChannels::Rgba => {
                let a8 = vdupq_n_u8(max_colors as u8);
                let rgba = uint8x16x4_t(r8, g8, b8, a8);
                vst4q_u8(dst, rgba);
            }
            YuvSourceChannels::Bgr => {
                let bgr = uint8x16x3_t(b8, g8, r8);
                vst3q_u8(dst, bgr);
            }
            YuvSourceChannels::Bgra => {
                let a8 = vdupq_n_u8(max_colors as u8);
                let bgra = uint8x16x4_t(b8, g8, r8, a8);
                vst4q_u8(dst, bgra);
            }
        }

        x += 16;
        ux += match sampling {
            YuvChromaSubsampling::Yuv422 | YuvChromaSubsampling::Yuv420 => 8,
            YuvChromaSubsampling::Yuv444 => 16,
        };
    }

    while x + 8 <= width {
        let y_u16 = vld1q_u16(y_plane.get_unchecked(x));
        let cg_u16 = match sampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                let q = vld1_u16(u_plane.get_unchecked(ux));
                let r = vcombine_u16(q, q);
                vreinterpretq_s16_u16(vzip1q_u16(r, r))
            }
            YuvChromaSubsampling::Yuv444 => {
                vreinterpretq_s16_u16(vld1q_u16(u_plane.get_unchecked(ux)))
            }
        };
        let co_u16 = match sampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                let q = vld1_u16(v_plane.get_unchecked(ux));
                let r = vcombine_u16(q, q);
                vreinterpretq_s16_u16(vzip1q_u16(r, r))
            }
            YuvChromaSubsampling::Yuv444 => {
                vreinterpretq_s16_u16(vld1q_u16(v_plane.get_unchecked(ux)))
            }
        };

        let (r8, g8, b8) = decode8!(y_u16, cg_u16, co_u16);

        let dst = rgba_data.get_unchecked_mut(x * channels);

        match dst_chans {
            YuvSourceChannels::Rgb => {
                let rgb = uint8x8x3_t(r8, g8, b8);
                vst3_u8(dst, rgb);
            }
            YuvSourceChannels::Rgba => {
                let a8 = vdup_n_u8(max_colors as u8);
                let rgba = uint8x8x4_t(r8, g8, b8, a8);
                vst4_u8(dst, rgba);
            }
            YuvSourceChannels::Bgr => {
                let bgr = uint8x8x3_t(b8, g8, r8);
                vst3_u8(dst, bgr);
            }
            YuvSourceChannels::Bgra => {
                let a8 = vdup_n_u8(max_colors as u8);
                let bgra = uint8x8x4_t(b8, g8, r8, a8);
                vst4_u8(dst, bgra);
            }
        }

        x += 8;
        ux += match sampling {
            YuvChromaSubsampling::Yuv422 | YuvChromaSubsampling::Yuv420 => 4,
            YuvChromaSubsampling::Yuv444 => 8,
        };
    }

    if x < width {
        let diff = width - x;
        assert!(diff <= 8);

        let mut y_buffer: [u16; 8] = [0; 8];
        let mut u_buffer: [u16; 8] = [0; 8];
        let mut v_buffer: [u16; 8] = [0; 8];

        std::ptr::copy_nonoverlapping(
            y_plane.get_unchecked(x..).as_ptr(),
            y_buffer.as_mut_ptr().cast(),
            diff,
        );

        if sampling == YuvChromaSubsampling::Yuv444 {
            std::ptr::copy_nonoverlapping(
                u_plane.get_unchecked(ux..).as_ptr(),
                u_buffer.as_mut_ptr().cast(),
                diff,
            );
            std::ptr::copy_nonoverlapping(
                v_plane.get_unchecked(ux..).as_ptr(),
                v_buffer.as_mut_ptr().cast(),
                diff,
            );
        } else {
            std::ptr::copy_nonoverlapping(
                u_plane.get_unchecked(ux..).as_ptr(),
                u_buffer.as_mut_ptr().cast(),
                diff.div_ceil(2),
            );
            std::ptr::copy_nonoverlapping(
                v_plane.get_unchecked(ux..).as_ptr(),
                v_buffer.as_mut_ptr().cast(),
                diff.div_ceil(2),
            );
        }

        let mut buffer: [u8; 8 * 4] = [0; 8 * 4];
        ycgco_ro_re_u16_to_rgba_neon::<SAMPLING, PRECISION, BIT_DEPTH, R_TYPE, DST_CHANS>(
            &y_buffer,
            &u_buffer,
            &v_buffer,
            &mut buffer,
            8,
            chroma_range,
            range_reduction_y,
        );

        std::ptr::copy_nonoverlapping(
            buffer.as_ptr().cast(),
            rgba_data.get_unchecked_mut(x * channels..).as_mut_ptr(),
            diff * channels,
        );
    }
}
