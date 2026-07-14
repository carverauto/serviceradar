#![no_std]
#![feature(test)]

extern crate test;

use test::Bencher;

#[bench]
pub fn scrypt_15_8_1(bh: &mut Bencher) {
    let password = b"my secure password";
    let salt = b"salty salt";
    let mut buf = [0u8; 32];
    let params = scrypt::Params::recommended();
    bh.iter(|| {
        scrypt::scrypt(password, salt, &params, &mut buf).unwrap();
        test::black_box(&buf);
    });
}
