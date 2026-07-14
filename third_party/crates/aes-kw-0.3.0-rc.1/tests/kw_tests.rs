use aes_kw::{
    Error, KeyInit, KwAes128, KwAes192, KwAes256,
    cipher::consts::{U16, U24, U32},
};
use hex_literal::hex;
use std::assert_eq;

macro_rules! test_aes_kw {
    ($name:ident, $kw_ty:ty, $n:ty, $key:expr, $pt:expr, $ct:expr) => {
        #[test]
        fn $name() {
            let kw = <$kw_ty>::new(&$key.into());
            let mut buf = [0u8; 64];
            let ct = kw.wrap_key(&$pt, &mut buf).unwrap();
            assert_eq!($ct, ct);
            let pt = kw.unwrap_key(&$ct, &mut buf).unwrap();
            assert_eq!($pt, pt);

            let ct = kw.wrap_fixed_key::<$n>((&$pt).try_into().unwrap());
            assert_eq!($ct, ct.0);
            let pt = kw.unwrap_fixed_key::<$n>(&ct).unwrap();
            assert_eq!($pt, pt.0);
        }
    };
}

test_aes_kw!(
    wrap_unwrap_128_key_128_kek,
    KwAes128,
    U16,
    hex!("000102030405060708090A0B0C0D0E0F"),
    hex!("00112233445566778899AABBCCDDEEFF"),
    hex!("1FA68B0A8112B447AEF34BD8FB5A7B829D3E862371D2CFE5")
);
test_aes_kw!(
    wrap_unwrap_128_key_192_kek,
    KwAes192,
    U16,
    hex!("000102030405060708090A0B0C0D0E0F1011121314151617"),
    hex!("00112233445566778899AABBCCDDEEFF"),
    hex!("96778B25AE6CA435F92B5B97C050AED2468AB8A17AD84E5D")
);
test_aes_kw!(
    wrap_unwrap_128_key_256_kek,
    KwAes256,
    U16,
    hex!("000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F"),
    hex!("00112233445566778899AABBCCDDEEFF"),
    hex!("64E8C3F9CE0F5BA263E9777905818A2A93C8191E7D6E8AE7")
);
test_aes_kw!(
    wrap_unwrap_192_key_192_kek,
    KwAes192,
    U24,
    hex!("000102030405060708090A0B0C0D0E0F1011121314151617"),
    hex!("00112233445566778899AABBCCDDEEFF0001020304050607"),
    hex!("031D33264E15D33268F24EC260743EDCE1C6C7DDEE725A936BA814915C6762D2")
);
test_aes_kw!(
    wrap_unwrap_192_key_256_kek,
    KwAes256,
    U24,
    hex!("000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F"),
    hex!("00112233445566778899AABBCCDDEEFF0001020304050607"),
    hex!("A8F9BC1612C68B3FF6E6F4FBE30E71E4769C8B80A32CB8958CD5D17D6B254DA1")
);
test_aes_kw!(
    wrap_unwrap_256_key_256_kek,
    KwAes256,
    U32,
    hex!("000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F"),
    hex!("00112233445566778899AABBCCDDEEFF000102030405060708090A0B0C0D0E0F"),
    hex!("28C9F404C4B810F4CBCCB35CFB87F8263F5786E2D80ED326CBC7F0E71A99F43BFB988B9B7A02DD21")
);

#[test]
fn error_invalid_data_size() {
    let key = hex!("000102030405060708090A0B0C0D0E0F");
    let input = hex!("00112233445566778899AABBCCDDEE");
    let output = hex!("1FA68B0A8112B447AEF34BD8FB5A7B829D3E862371D2CF");

    let kek = KwAes128::new(&key.into());
    let mut buf = [0u8; 24];

    let res = kek.wrap_key(&input, &mut buf);
    assert_eq!(res, Err(Error::InvalidDataSize));

    let res = kek.unwrap_key(&output, &mut buf);
    assert_eq!(res, Err(Error::InvalidDataSize));

    let res = kek.unwrap_key(&[], &mut buf);
    assert_eq!(res, Err(Error::InvalidDataSize));
}

#[test]
fn error_invalid_output_size() {
    let key = hex!("000102030405060708090A0B0C0D0E0F");
    let input = hex!("00112233445566778899AABBCCDDEEFF");
    let output = hex!("1FA68B0A8112B447AEF34BD8FB5A7B829D3E862371D2CFE5");

    let kek = KwAes128::new(&key.into());

    let mut buf = [0u8; 23];
    let res = kek.wrap_key(&input, &mut buf);
    assert_eq!(res, Err(Error::InvalidOutputSize { expected_len: 24 }));

    let mut buf = [0u8; 15];
    let res = kek.unwrap_key(&output, &mut buf);
    assert_eq!(res, Err(Error::InvalidOutputSize { expected_len: 16 }));
}

#[test]
fn error_integrity_check_failed() {
    let key = hex!("000102030405060708090A0B0C0D0E0F");
    let output = hex!("1FA68B0A8112B447AEF34BD8FB5A7B829D3E862371D2CFE6");

    let kek = KwAes128::new(&key.into());

    let mut buf = [0u8; 16];
    let res = kek.unwrap_key(&output, &mut buf);

    assert_eq!(res, Err(Error::IntegrityCheckFailed));
}
