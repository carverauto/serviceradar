//! AES encryption support
//!
//! Note that `aes` target feature implicitly enables `neon`, see:
//! https://doc.rust-lang.org/reference/attributes/codegen.html#aarch64
#![allow(unsafe_op_in_unsafe_fn)]

use crate::Block;
use cipher::{
    array::{Array, ArraySize},
    inout::InOut,
};
use core::{arch::aarch64::*, mem};

/// Perform AES encryption using the given expanded keys.
#[target_feature(enable = "aes")]
pub(super) unsafe fn encrypt<const KEYS: usize>(
    keys: &[uint8x16_t; KEYS],
    block: InOut<'_, '_, Block>,
) {
    assert!(KEYS == 11 || KEYS == 13 || KEYS == 15);
    let (in_ptr, out_ptr) = block.into_raw();
    let mut block = vld1q_u8(in_ptr.cast());

    for &key in &keys[..KEYS - 2] {
        // AES single round encryption
        block = vaeseq_u8(block, key);
        // Mix columns
        block = vaesmcq_u8(block);
    }

    // AES single round encryption
    block = vaeseq_u8(block, keys[KEYS - 2]);
    // Final add (bitwise XOR)
    block = veorq_u8(block, keys[KEYS - 1]);

    vst1q_u8(out_ptr.cast(), block);
}

/// Perform AES decryption using the given expanded keys.
#[target_feature(enable = "aes")]
pub(super) unsafe fn decrypt<const KEYS: usize>(
    keys: &[uint8x16_t; KEYS],
    block: InOut<'_, '_, Block>,
) {
    assert!(KEYS == 11 || KEYS == 13 || KEYS == 15);

    let (in_ptr, out_ptr) = block.into_raw();
    let mut block = vld1q_u8(in_ptr.cast());

    for &key in &keys[..KEYS - 2] {
        // AES single round decryption
        block = vaesdq_u8(block, key);
        // Inverse mix columns
        block = vaesimcq_u8(block);
    }

    // AES single round decryption
    block = vaesdq_u8(block, keys[KEYS - 2]);
    // Final add (bitwise XOR)
    block = veorq_u8(block, keys[KEYS - 1]);

    vst1q_u8(out_ptr.cast(), block);
}

/// Perform parallel AES encryption 8-blocks-at-a-time using the given expanded keys.
#[target_feature(enable = "aes")]
pub(super) unsafe fn encrypt_par<const KEYS: usize, ParBlocks: ArraySize>(
    keys: &[uint8x16_t; KEYS],
    blocks: InOut<'_, '_, Array<Block, ParBlocks>>,
) {
    #[inline(always)]
    unsafe fn par_round<ParBlocks: ArraySize>(
        key: uint8x16_t,
        blocks: &mut Array<uint8x16_t, ParBlocks>,
    ) {
        for block in blocks {
            // AES single round encryption and mix columns
            *block = vaesmcq_u8(vaeseq_u8(*block, key));
        }
    }

    assert!(KEYS == 11 || KEYS == 13 || KEYS == 15);

    let (in_ptr, out_ptr) = blocks.into_raw();
    let in_ptr: *const Block = in_ptr.cast();
    let out_ptr: *mut Block = out_ptr.cast();

    // Load plaintext blocks
    let mut blocks: Array<uint8x16_t, ParBlocks> = mem::zeroed();
    for i in 0..ParBlocks::USIZE {
        blocks[i] = vld1q_u8(in_ptr.add(i).cast());
    }

    // Loop is intentionally not used here to enforce inlining
    par_round(keys[0], &mut blocks);
    par_round(keys[1], &mut blocks);
    par_round(keys[2], &mut blocks);
    par_round(keys[3], &mut blocks);
    par_round(keys[4], &mut blocks);
    par_round(keys[5], &mut blocks);
    par_round(keys[6], &mut blocks);
    par_round(keys[7], &mut blocks);
    par_round(keys[8], &mut blocks);
    if KEYS >= 13 {
        par_round(keys[9], &mut blocks);
        par_round(keys[10], &mut blocks);
    }
    if KEYS == 15 {
        par_round(keys[11], &mut blocks);
        par_round(keys[12], &mut blocks);
    }

    for i in 0..ParBlocks::USIZE {
        // AES single round encryption
        blocks[i] = vaeseq_u8(blocks[i], keys[KEYS - 2]);
        // Final add (bitwise XOR)
        blocks[i] = veorq_u8(blocks[i], keys[KEYS - 1]);
        // Save encrypted blocks
        vst1q_u8(out_ptr.add(i).cast(), blocks[i]);
    }
}

/// Perform parallel AES decryption 8-blocks-at-a-time using the given expanded keys.
#[target_feature(enable = "aes")]
pub(super) unsafe fn decrypt_par<const KEYS: usize, ParBlocks: ArraySize>(
    keys: &[uint8x16_t; KEYS],
    blocks: InOut<'_, '_, Array<Block, ParBlocks>>,
) {
    #[inline(always)]
    unsafe fn par_round<ParBlocks: ArraySize>(
        key: uint8x16_t,
        blocks: &mut Array<uint8x16_t, ParBlocks>,
    ) {
        for block in blocks {
            // AES single round decryption and inverse mix columns
            *block = vaesimcq_u8(vaesdq_u8(*block, key));
        }
    }

    assert!(KEYS == 11 || KEYS == 13 || KEYS == 15);

    let (in_ptr, out_ptr) = blocks.into_raw();
    let in_ptr: *const Block = in_ptr.cast();
    let out_ptr: *mut Block = out_ptr.cast();

    // Load encrypted blocks
    let mut blocks: Array<uint8x16_t, ParBlocks> = mem::zeroed();
    for i in 0..ParBlocks::USIZE {
        blocks[i] = vld1q_u8(in_ptr.add(i).cast());
    }

    // Loop is intentionally not used here to enforce inlining
    par_round(keys[0], &mut blocks);
    par_round(keys[1], &mut blocks);
    par_round(keys[2], &mut blocks);
    par_round(keys[3], &mut blocks);
    par_round(keys[4], &mut blocks);
    par_round(keys[5], &mut blocks);
    par_round(keys[6], &mut blocks);
    par_round(keys[7], &mut blocks);
    par_round(keys[8], &mut blocks);
    if KEYS >= 13 {
        par_round(keys[9], &mut blocks);
        par_round(keys[10], &mut blocks);
    }
    if KEYS == 15 {
        par_round(keys[11], &mut blocks);
        par_round(keys[12], &mut blocks);
    }

    for i in 0..ParBlocks::USIZE {
        // AES single round decryption
        blocks[i] = vaesdq_u8(blocks[i], keys[KEYS - 2]);
        // Final add (bitwise XOR)
        blocks[i] = veorq_u8(blocks[i], keys[KEYS - 1]);
        // Save plaintext blocks
        vst1q_u8(out_ptr.add(i) as *mut u8, blocks[i]);
    }
}
