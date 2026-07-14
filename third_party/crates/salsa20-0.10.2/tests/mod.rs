//! Salsa20 tests

use cipher::{KeyIvInit, StreamCipher, StreamCipherSeek};
use hex_literal::hex;
use salsa20::Salsa20;
use salsa20::XSalsa20;

cipher::stream_cipher_seek_test!(salsa20_seek, Salsa20);
cipher::stream_cipher_seek_test!(xsalsa20_seek, XSalsa20);

const KEY_BYTES: usize = 32;

const IV_BYTES: usize = 8;

const IV_BYTES_XSALSA20: usize = 24;

const KEY0: [u8; KEY_BYTES] = [0; KEY_BYTES];

const KEY1: [u8; KEY_BYTES] = hex!(
    "80000000000000000000000000000000"
    "00000000000000000000000000000000"
);

const KEY_LONG: [u8; KEY_BYTES] = hex!(
    "0102030405060708090A0B0C0D0E0F10"
    "1112131415161718191A1B1C1D1E1F20"
);

const KEY_XSALSA20: [u8; KEY_BYTES] = *b"this is 32-byte key for xsalsa20";

const IV0: [u8; IV_BYTES] = [0; IV_BYTES];

const IV1: [u8; IV_BYTES] = hex!("8000000000000000");

const IVHI: [u8; IV_BYTES] = hex!("0000000000000001");

const IV_LONG: [u8; IV_BYTES] = hex!("0301040105090206");

const IV_XSALSA20: [u8; IV_BYTES_XSALSA20] = *b"24-byte nonce for xsalsa";

const EXPECTED_KEY1_IV0: [u8; 64] = hex!(
    "e3be8fdd8beca2e3ea8ef9475b29a6e7"
    "003951e1097a5c38d23b7a5fad9f6844"
    "b22c97559e2723c7cbbd3fe4fc8d9a07"
    "44652a83e72a9c461876af4d7ef1a117"
);

const EXPECTED_KEY0_IV1: [u8; 64] = hex!(
    "2aba3dc45b4947007b14c851cd694456"
    "b303ad59a465662803006705673d6c3e"
    "29f1d3510dfc0405463c03414e0e07e3"
    "59f1f1816c68b2434a19d3eee0464873"
);

const EXPECTED_KEY0_IVHI: [u8; 64] = hex!(
    "b47f96aa96786135297a3c4ec56a613d"
    "0b80095324ff43239d684c57ffe42e1c"
    "44f3cc011613db6cdc880999a1e65aed"
    "1287fcb11c839c37120765afa73e5075"
);

const EXPECTED_LONG: [u8; 256] = hex!(
    "6ebcbdbf76fccc64ab05542bee8a67cb"
    "c28fa2e141fbefbb3a2f9b221909c8d7"
    "d4295258cb539770dd24d7ac3443769f"
    "fa27a50e60644264dc8b6b612683372e"
    "085d0a12bf240b189ce2b78289862b56"
    "fdc9fcffc33bef9325a2e81b98fb3fb9"
    "aa04cf434615ceffeb985c1cb08d8440"
    "e90b1d56ddeaea16d9e15affff1f698c"
    "483c7a466af1fe062574adfd2b06a62b"
    "4d98440719ea776385c470349a7ed696"
    "9583463ed5d26b8fefccb205da0f5bfa"
    "98c77812fe756b09eacc282aa42f4baf"
    "a79633189046e2b20f35b3e0e54aa3b9"
    "29e23c0f47dc7bcd4f928b2a9764be7d"
    "4b8a50f980a50b35ad8087375e0c556e"
    "cbe6a7161e8653ce9391e1e6710ed4f1"
);

const EXPECTED_XSALSA20_ZEROS: [u8; 64] = hex!(
    "4848297feb1fb52fb66d81609bd547fa"
    "bcbe7026edc8b5e5e449d088bfa69c08"
    "8f5d8da1d791267c2c195a7f8cae9c4b"
    "4050d08ce6d3a151ec265f3a58e47648"
);

const EXPECTED_XSALSA20_HELLO_WORLD: [u8; 12] = hex!("002d4513843fc240c401e541");

#[test]
fn salsa20_key1_iv0() {
    let mut cipher = Salsa20::new(&KEY1.into(), &IV0.into());
    let mut buf = [0; 64];

    cipher.apply_keystream(&mut buf);

    for i in 0..64 {
        assert_eq!(buf[i], EXPECTED_KEY1_IV0[i])
    }
}

#[test]
fn salsa20_key0_iv1() {
    let mut cipher = Salsa20::new(&KEY0.into(), &IV1.into());
    let mut buf = [0; 64];

    cipher.apply_keystream(&mut buf);

    for i in 0..64 {
        assert_eq!(buf[i], EXPECTED_KEY0_IV1[i])
    }
}

#[test]
fn salsa20_key0_ivhi() {
    let mut cipher = Salsa20::new(&KEY0.into(), &IVHI.into());
    let mut buf = [0; 64];

    cipher.apply_keystream(&mut buf);

    for i in 0..64 {
        assert_eq!(buf[i], EXPECTED_KEY0_IVHI[i])
    }
}

#[test]
fn salsa20_long() {
    let mut cipher = Salsa20::new(&KEY_LONG.into(), &IV_LONG.into());
    let mut buf = [0; 256];

    cipher.apply_keystream(&mut buf);

    for i in 0..256 {
        assert_eq!(buf[i], EXPECTED_LONG[i])
    }
}

#[test]
#[ignore]
fn salsa20_offsets() {
    for idx in 0..256 {
        for middle in idx..256 {
            for last in middle..256 {
                let mut cipher = Salsa20::new(&KEY_LONG.into(), &IV_LONG.into());
                let mut buf = [0; 256];

                cipher.seek(idx as u64);
                cipher.apply_keystream(&mut buf[idx..middle]);
                cipher.apply_keystream(&mut buf[middle..last]);

                for k in idx..last {
                    assert_eq!(buf[k], EXPECTED_LONG[k])
                }
            }
        }
    }
}

#[test]
fn xsalsa20_encrypt_zeros() {
    let mut cipher = XSalsa20::new(&KEY_XSALSA20.into(), &IV_XSALSA20.into());
    let mut buf = [0; 64];
    cipher.apply_keystream(&mut buf);

    for i in 0..64 {
        assert_eq!(buf[i], EXPECTED_XSALSA20_ZEROS[i]);
    }
}

#[test]
fn xsalsa20_encrypt_hello_world() {
    let mut cipher = XSalsa20::new(&KEY_XSALSA20.into(), &IV_XSALSA20.into());
    let mut buf = *b"Hello world!";
    cipher.apply_keystream(&mut buf);

    assert_eq!(buf, EXPECTED_XSALSA20_HELLO_WORLD);
}
