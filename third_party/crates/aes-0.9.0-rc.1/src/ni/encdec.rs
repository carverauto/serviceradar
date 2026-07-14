#![allow(unsafe_op_in_unsafe_fn)]

use super::arch::*;
use crate::Block;
use cipher::{
    array::{Array, ArraySize},
    inout::InOut,
};

#[target_feature(enable = "aes")]
pub(super) unsafe fn encrypt<const KEYS: usize>(
    keys: &[__m128i; KEYS],
    block: InOut<'_, '_, Block>,
) {
    assert!(KEYS == 11 || KEYS == 13 || KEYS == 15);

    let (block_in, block_out) = block.into_raw();
    let mut b = _mm_loadu_si128(block_in.cast());
    b = _mm_xor_si128(b, keys[0]);
    for &key in &keys[1..KEYS - 1] {
        b = _mm_aesenc_si128(b, key);
    }
    b = _mm_aesenclast_si128(b, keys[KEYS - 1]);
    _mm_storeu_si128(block_out.cast(), b);
}

#[target_feature(enable = "aes")]
pub(super) unsafe fn decrypt<const KEYS: usize>(
    keys: &[__m128i; KEYS],
    block: InOut<'_, '_, Block>,
) {
    assert!(KEYS == 11 || KEYS == 13 || KEYS == 15);

    let (block_in, block_out) = block.into_raw();
    let mut b = _mm_loadu_si128(block_in.cast());
    b = _mm_xor_si128(b, keys[0]);
    for &key in &keys[1..KEYS - 1] {
        b = _mm_aesdec_si128(b, key);
    }
    b = _mm_aesdeclast_si128(b, keys[KEYS - 1]);
    _mm_storeu_si128(block_out.cast(), b);
}

#[target_feature(enable = "aes")]
pub(super) unsafe fn encrypt_par<const KEYS: usize, ParBlocks: ArraySize>(
    keys: &[__m128i; KEYS],
    blocks: InOut<'_, '_, Array<Block, ParBlocks>>,
) {
    assert!(KEYS == 11 || KEYS == 13 || KEYS == 15);

    let (blocks_in, blocks_out) = blocks.into_raw();
    let mut b = load(blocks_in);

    // Loop over keys is intentionally not used here to force inlining
    xor(&mut b, keys[0]);
    aesenc(&mut b, keys[1]);
    aesenc(&mut b, keys[2]);
    aesenc(&mut b, keys[3]);
    aesenc(&mut b, keys[4]);
    aesenc(&mut b, keys[5]);
    aesenc(&mut b, keys[6]);
    aesenc(&mut b, keys[7]);
    aesenc(&mut b, keys[8]);
    aesenc(&mut b, keys[9]);
    if KEYS >= 13 {
        aesenc(&mut b, keys[10]);
        aesenc(&mut b, keys[11]);
    }
    if KEYS == 15 {
        aesenc(&mut b, keys[12]);
        aesenc(&mut b, keys[13]);
    }
    aesenclast(&mut b, keys[KEYS - 1]);
    store(blocks_out, b);
}

#[target_feature(enable = "aes")]
pub(super) unsafe fn decrypt_par<const KEYS: usize, ParBlocks: ArraySize>(
    keys: &[__m128i; KEYS],
    blocks: InOut<'_, '_, Array<Block, ParBlocks>>,
) {
    assert!(KEYS == 11 || KEYS == 13 || KEYS == 15);

    let (blocks_in, blocks_out) = blocks.into_raw();
    let mut b = load(blocks_in);

    // Loop over keys is intentionally not used here to force inlining
    xor(&mut b, keys[0]);
    aesdec(&mut b, keys[1]);
    aesdec(&mut b, keys[2]);
    aesdec(&mut b, keys[3]);
    aesdec(&mut b, keys[4]);
    aesdec(&mut b, keys[5]);
    aesdec(&mut b, keys[6]);
    aesdec(&mut b, keys[7]);
    aesdec(&mut b, keys[8]);
    aesdec(&mut b, keys[9]);
    if KEYS >= 13 {
        aesdec(&mut b, keys[10]);
        aesdec(&mut b, keys[11]);
    }
    if KEYS == 15 {
        aesdec(&mut b, keys[12]);
        aesdec(&mut b, keys[13]);
    }
    aesdeclast(&mut b, keys[KEYS - 1]);
    store(blocks_out, b);
}

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

#[target_feature(enable = "sse2")]
pub(crate) unsafe fn xor<N: ArraySize>(blocks: &mut Array<__m128i, N>, key: __m128i) {
    for block in blocks {
        *block = _mm_xor_si128(*block, key);
    }
}

#[target_feature(enable = "aes")]
pub(crate) unsafe fn aesenc<N: ArraySize>(blocks: &mut Array<__m128i, N>, key: __m128i) {
    for block in blocks {
        *block = _mm_aesenc_si128(*block, key);
    }
}

#[target_feature(enable = "aes")]
pub(crate) unsafe fn aesenclast<N: ArraySize>(blocks: &mut Array<__m128i, N>, key: __m128i) {
    for block in blocks {
        *block = _mm_aesenclast_si128(*block, key);
    }
}

#[target_feature(enable = "aes")]
pub(crate) unsafe fn aesdec<N: ArraySize>(blocks: &mut Array<__m128i, N>, key: __m128i) {
    for block in blocks {
        *block = _mm_aesdec_si128(*block, key);
    }
}

#[target_feature(enable = "aes")]
pub(crate) unsafe fn aesdeclast<N: ArraySize>(blocks: &mut Array<__m128i, N>, key: __m128i) {
    for block in blocks {
        *block = _mm_aesdeclast_si128(*block, key);
    }
}
