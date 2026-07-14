#![feature(test)]
extern crate test;

use cipher::{block_decryptor_bench, block_encryptor_bench};
use rc2::Rc2;

block_encryptor_bench!(Key: Rc2, rc2_encrypt_block, rc2_encrypt_blocks);
block_decryptor_bench!(Key: Rc2, rc2_decrypt_block, rc2_decrypt_blocks);
