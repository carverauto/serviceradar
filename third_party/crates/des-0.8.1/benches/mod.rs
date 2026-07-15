#![feature(test)]
extern crate test;

use cipher::{block_decryptor_bench, block_encryptor_bench};
use des::{Des, TdesEde3};

block_encryptor_bench!(Key: Des, des_encrypt_block, des_encrypt_blocks);
block_decryptor_bench!(Key: Des, des_decrypt_block, des_decrypt_blocks);

block_encryptor_bench!(
    Key: TdesEde3,
    tdes_ede3_encrypt_block,
    tdes_ede3_encrypt_blocks,
);
block_decryptor_bench!(
    Key: TdesEde3,
    tdes_ede3_decrypt_block,
    tdes_ede3_decrypt_blocks,
);
