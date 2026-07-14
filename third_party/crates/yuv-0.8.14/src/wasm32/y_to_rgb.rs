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

use crate::wasm32::utils::{i16x8_pack_sat_u8x16, wasm_store_rgb};
use crate::yuv_support::{CbCrInverseTransform, YuvChromaRange, YuvSourceChannels};
use std::arch::wasm32::*;

#[target_feature(enable = "simd128")]
pub(crate) unsafe fn wasm_y_to_rgb_row<const DESTINATION_CHANNELS: u8>(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
    y_plane: &[u8],
    rgba: &mut [u8],
    start_cx: usize,
    width: usize,
) {
    let destination_channels: YuvSourceChannels = DESTINATION_CHANNELS.into();
    let channels = destination_channels.get_channels_count();

    let y_corr = u8x16_splat(range.bias_y as u8);
    let v_luma_coeff = i16x8_splat(transform.y_coef as i16);
    let v_alpha = u8x16_splat(255u8);

    let mut cx = start_cx;

    const SCALE: u32 = 2;

    while cx + 16 < width {
        let y_values = u8x16_sub_sat(
            v128_load(y_plane.get_unchecked(cx..).as_ptr() as *const v128),
            y_corr,
        );

        let y_high = u16x8_shl(u16x8_extend_high_u8x16(y_values), SCALE);
        let r_high = i16x8_q15mulr_sat(y_high, v_luma_coeff);

        let y_low = u16x8_shl(u16x8_extend_low_u8x16(y_values), SCALE);
        let r_low = i16x8_q15mulr_sat(y_low, v_luma_coeff);

        let r_values = i16x8_pack_sat_u8x16(r_low, r_high);

        let dst_shift = cx * channels;

        wasm_store_rgb::<DESTINATION_CHANNELS>(
            rgba.get_unchecked_mut(dst_shift..).as_mut_ptr(),
            r_values,
            r_values,
            r_values,
            v_alpha,
        );

        cx += 16;
    }

    if cx < width {
        let diff = width - cx;
        assert!(diff <= 16);

        let mut y_buffer: [u8; 16] = [0; 16];
        let mut dst_buffer: [u8; 16 * 4] = [0; 16 * 4];
        std::ptr::copy_nonoverlapping(
            y_plane.get_unchecked(cx..).as_ptr(),
            y_buffer.as_mut_ptr(),
            diff,
        );

        let y_values = u8x16_sub_sat(v128_load(y_buffer.as_ptr() as *const v128), y_corr);

        let y_high = u16x8_shl(u16x8_extend_high_u8x16(y_values), SCALE);
        let r_high = i16x8_q15mulr_sat(y_high, v_luma_coeff);

        let y_low = u16x8_shl(u16x8_extend_low_u8x16(y_values), SCALE);
        let r_low = i16x8_q15mulr_sat(y_low, v_luma_coeff);

        let r_values = i16x8_pack_sat_u8x16(r_low, r_high);

        wasm_store_rgb::<DESTINATION_CHANNELS>(
            dst_buffer.as_mut_ptr(),
            r_values,
            r_values,
            r_values,
            v_alpha,
        );

        let dst_shift = cx * channels;

        std::ptr::copy_nonoverlapping(
            dst_buffer.as_ptr(),
            rgba.get_unchecked_mut(dst_shift..).as_mut_ptr(),
            diff * channels,
        );
    }
}
