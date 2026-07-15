#![feature(test)]
extern crate test;

use aes::Aes128;

cipher::block_encryptor_bench!(
    KeyIv: cfb_mode::Encryptor<Aes128>,
    cfb_aes128_encrypt_block,
    cfb_aes128_encrypt_blocks,
);

cipher::block_decryptor_bench!(
    KeyIv: cfb_mode::Decryptor<Aes128>,
    cfb_aes128_decrypt_block,
    cfb_aes128_decrypt_blocks,
);
