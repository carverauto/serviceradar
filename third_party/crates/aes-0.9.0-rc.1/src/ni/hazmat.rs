//! Low-level "hazmat" AES functions: AES-NI support.
//!
//! Note: this isn't actually used in the `Aes128`/`Aes192`/`Aes256`
//! implementations in this crate, but instead provides raw AES-NI accelerated
//! access to the AES round function gated under the `hazmat` crate feature.
#![allow(unsafe_op_in_unsafe_fn)]

use super::arch::*;
use crate::hazmat::{Block, Block8};
use cipher::array::{Array, ArraySize};

#[target_feature(enable = "sse2")]
pub(crate) unsafe fn load<N: ArraySize>(blocks: *const Array<Block, N>) -> Array<__m128i, N> {
    let p = blocks.cast::<__m128i>();
    let mut res: Array<__m128i, N> = core::mem::zeroed();
    for i in 0..N::USIZE {
        res[i] = _mm_loadu_si128(p.add(i));
    }
    res
}

#[target_feature(enable = "sse2")]
pub(crate) unsafe fn store<N: ArraySize>(blocks: *mut Array<Block, N>, b: Array<__m128i, N>) {
    let p = blocks.cast::<__m128i>();
    for i in 0..N::USIZE {
        _mm_storeu_si128(p.add(i), b[i]);
    }
}

/// AES cipher (encrypt) round function.
#[target_feature(enable = "aes")]
pub(crate) unsafe fn cipher_round(block: &mut Block, round_key: &Block) {
    // Safety: `loadu` and `storeu` support unaligned access
    let b = _mm_loadu_si128(block.as_ptr() as *const __m128i);
    let k = _mm_loadu_si128(round_key.as_ptr() as *const __m128i);
    let out = _mm_aesenc_si128(b, k);
    _mm_storeu_si128(block.as_mut_ptr() as *mut __m128i, out);
}

/// AES cipher (encrypt) round function: parallel version.
#[target_feature(enable = "aes")]
pub(crate) unsafe fn cipher_round_par(blocks: &mut Block8, round_keys: &Block8) {
    let xmm_keys = load(round_keys);
    let mut xmm_blocks = load(blocks);

    for i in 0..8 {
        xmm_blocks[i] = _mm_aesenc_si128(xmm_blocks[i], xmm_keys[i]);
    }

    store(blocks, xmm_blocks);
}

/// AES cipher (encrypt) round function.
#[target_feature(enable = "aes")]
pub(crate) unsafe fn equiv_inv_cipher_round(block: &mut Block, round_key: &Block) {
    // Safety: `loadu` and `storeu` support unaligned access
    let b = _mm_loadu_si128(block.as_ptr() as *const __m128i);
    let k = _mm_loadu_si128(round_key.as_ptr() as *const __m128i);
    let out = _mm_aesdec_si128(b, k);
    _mm_storeu_si128(block.as_mut_ptr() as *mut __m128i, out);
}

/// AES cipher (encrypt) round function: parallel version.
#[target_feature(enable = "aes")]
pub(crate) unsafe fn equiv_inv_cipher_round_par(blocks: &mut Block8, round_keys: &Block8) {
    let xmm_keys = load(round_keys);
    let mut xmm_blocks = load(blocks);

    for i in 0..8 {
        xmm_blocks[i] = _mm_aesdec_si128(xmm_blocks[i], xmm_keys[i]);
    }

    store(blocks, xmm_blocks);
}

/// AES mix columns function.
#[target_feature(enable = "aes")]
pub(crate) unsafe fn mix_columns(block: &mut Block) {
    // Safety: `loadu` and `storeu` support unaligned access
    let mut state = _mm_loadu_si128(block.as_ptr() as *const __m128i);

    // Emulate mix columns by performing three inverse mix columns operations
    state = _mm_aesimc_si128(state);
    state = _mm_aesimc_si128(state);
    state = _mm_aesimc_si128(state);

    _mm_storeu_si128(block.as_mut_ptr() as *mut __m128i, state);
}

/// AES inverse mix columns function.
#[target_feature(enable = "aes")]
pub(crate) unsafe fn inv_mix_columns(block: &mut Block) {
    // Safety: `loadu` and `storeu` support unaligned access
    let b = _mm_loadu_si128(block.as_ptr() as *const __m128i);
    let out = _mm_aesimc_si128(b);
    _mm_storeu_si128(block.as_mut_ptr() as *mut __m128i, out);
}
