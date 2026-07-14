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

#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

#[inline(always)]
pub(crate) unsafe fn _v512_set_epu32(
    a15: i64,
    a14: i64,
    a13: i64,
    a12: i64,
    a11: i64,
    a10: i64,
    a9: i64,
    a8: i64,
    a7: i64,
    a6: i64,
    a5: i64,
    a4: i64,
    a3: i64,
    a2: i64,
    a1: i64,
    a0: i64,
) -> __m512i {
    _mm512_set_epi64(
        ((a15) << 32) | (a14),
        ((a13) << 32) | (a12),
        ((a11) << 32) | (a10),
        ((a9) << 32) | (a8),
        ((a7) << 32) | (a6),
        ((a5) << 32) | (a4),
        ((a3) << 32) | (a2),
        ((a1) << 32) | (a0),
    )
}

#[inline(always)]
pub(crate) unsafe fn _v512_set_epu16(
    a31: i64,
    a30: i64,
    a29: i64,
    a28: i64,
    a27: i64,
    a26: i64,
    a25: i64,
    a24: i64,
    a23: i64,
    a22: i64,
    a21: i64,
    a20: i64,
    a19: i64,
    a18: i64,
    a17: i64,
    a16: i64,
    a15: i64,
    a14: i64,
    a13: i64,
    a12: i64,
    a11: i64,
    a10: i64,
    a9: i64,
    a8: i64,
    a7: i64,
    a6: i64,
    a5: i64,
    a4: i64,
    a3: i64,
    a2: i64,
    a1: i64,
    a0: i64,
) -> __m512i {
    _v512_set_epu32(
        ((a31) << 16) | (a30),
        ((a29) << 16) | (a28),
        ((a27) << 16) | (a26),
        ((a25) << 16) | (a24),
        ((a23) << 16) | (a22),
        ((a21) << 16) | (a20),
        ((a19) << 16) | (a18),
        ((a17) << 16) | (a16),
        ((a15) << 16) | (a14),
        ((a13) << 16) | (a12),
        ((a11) << 16) | (a10),
        ((a9) << 16) | (a8),
        ((a7) << 16) | (a6),
        ((a5) << 16) | (a4),
        ((a3) << 16) | (a2),
        ((a1) << 16) | (a0),
    )
}

#[inline(always)]
pub(crate) unsafe fn _v512_set_epu8(
    a63: i64,
    a62: i64,
    a61: i64,
    a60: i64,
    a59: i64,
    a58: i64,
    a57: i64,
    a56: i64,
    a55: i64,
    a54: i64,
    a53: i64,
    a52: i64,
    a51: i64,
    a50: i64,
    a49: i64,
    a48: i64,
    a47: i64,
    a46: i64,
    a45: i64,
    a44: i64,
    a43: i64,
    a42: i64,
    a41: i64,
    a40: i64,
    a39: i64,
    a38: i64,
    a37: i64,
    a36: i64,
    a35: i64,
    a34: i64,
    a33: i64,
    a32: i64,
    a31: i64,
    a30: i64,
    a29: i64,
    a28: i64,
    a27: i64,
    a26: i64,
    a25: i64,
    a24: i64,
    a23: i64,
    a22: i64,
    a21: i64,
    a20: i64,
    a19: i64,
    a18: i64,
    a17: i64,
    a16: i64,
    a15: i64,
    a14: i64,
    a13: i64,
    a12: i64,
    a11: i64,
    a10: i64,
    a9: i64,
    a8: i64,
    a7: i64,
    a6: i64,
    a5: i64,
    a4: i64,
    a3: i64,
    a2: i64,
    a1: i64,
    a0: i64,
) -> __m512i {
    _v512_set_epu32(
        ((a63) << 24) | ((a62) << 16) | ((a61) << 8) | (a60),
        ((a59) << 24) | ((a58) << 16) | ((a57) << 8) | (a56),
        ((a55) << 24) | ((a54) << 16) | ((a53) << 8) | (a52),
        ((a51) << 24) | ((a50) << 16) | ((a49) << 8) | (a48),
        ((a47) << 24) | ((a46) << 16) | ((a45) << 8) | (a44),
        ((a43) << 24) | ((a42) << 16) | ((a41) << 8) | (a40),
        ((a39) << 24) | ((a38) << 16) | ((a37) << 8) | (a36),
        ((a35) << 24) | ((a34) << 16) | ((a33) << 8) | (a32),
        ((a31) << 24) | ((a30) << 16) | ((a29) << 8) | (a28),
        ((a27) << 24) | ((a26) << 16) | ((a25) << 8) | (a24),
        ((a23) << 24) | ((a22) << 16) | (((a21) << 8) | (a20)),
        ((a19) << 24) | ((a18) << 16) | ((a17) << 8) | (a16),
        ((a15) << 24) | ((a14) << 16) | ((a13) << 8) | (a12),
        ((a11) << 24) | ((a10) << 16) | ((a9) << 8) | (a8),
        ((a7) << 24) | ((a6) << 16) | ((a5) << 8) | (a4),
        ((a3) << 24) | ((a2) << 16) | ((a1) << 8) | (a0),
    )
}

#[inline(always)]
pub(crate) unsafe fn _v512_setr_epu8(
    a0: i64,
    a1: i64,
    a2: i64,
    a3: i64,
    a4: i64,
    a5: i64,
    a6: i64,
    a7: i64,
    a8: i64,
    a9: i64,
    a10: i64,
    a11: i64,
    a12: i64,
    a13: i64,
    a14: i64,
    a15: i64,
    a16: i64,
    a17: i64,
    a18: i64,
    a19: i64,
    a20: i64,
    a21: i64,
    a22: i64,
    a23: i64,
    a24: i64,
    a25: i64,
    a26: i64,
    a27: i64,
    a28: i64,
    a29: i64,
    a30: i64,
    a31: i64,
    a32: i64,
    a33: i64,
    a34: i64,
    a35: i64,
    a36: i64,
    a37: i64,
    a38: i64,
    a39: i64,
    a40: i64,
    a41: i64,
    a42: i64,
    a43: i64,
    a44: i64,
    a45: i64,
    a46: i64,
    a47: i64,
    a48: i64,
    a49: i64,
    a50: i64,
    a51: i64,
    a52: i64,
    a53: i64,
    a54: i64,
    a55: i64,
    a56: i64,
    a57: i64,
    a58: i64,
    a59: i64,
    a60: i64,
    a61: i64,
    a62: i64,
    a63: i64,
) -> __m512i {
    _v512_set_epu32(
        ((a63) << 24) | ((a62) << 16) | ((a61) << 8) | (a60),
        ((a59) << 24) | ((a58) << 16) | ((a57) << 8) | (a56),
        ((a55) << 24) | ((a54) << 16) | ((a53) << 8) | (a52),
        ((a51) << 24) | ((a50) << 16) | ((a49) << 8) | (a48),
        ((a47) << 24) | ((a46) << 16) | ((a45) << 8) | (a44),
        ((a43) << 24) | ((a42) << 16) | ((a41) << 8) | (a40),
        ((a39) << 24) | ((a38) << 16) | ((a37) << 8) | (a36),
        ((a35) << 24) | ((a34) << 16) | ((a33) << 8) | (a32),
        ((a31) << 24) | ((a30) << 16) | ((a29) << 8) | (a28),
        ((a27) << 24) | ((a26) << 16) | ((a25) << 8) | (a24),
        ((a23) << 24) | ((a22) << 16) | (((a21) << 8) | (a20)),
        ((a19) << 24) | ((a18) << 16) | ((a17) << 8) | (a16),
        ((a15) << 24) | ((a14) << 16) | ((a13) << 8) | (a12),
        ((a11) << 24) | ((a10) << 16) | ((a9) << 8) | (a8),
        ((a7) << 24) | ((a6) << 16) | ((a5) << 8) | (a4),
        ((a3) << 24) | ((a2) << 16) | ((a1) << 8) | (a0),
    )
}
