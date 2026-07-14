use aes::Aes128;
use cipher::{Key, KeyInit};
use hex_literal::hex;

#[test]
fn test_weak_key() {
    for k in &[
        hex!("00000000000000000000000000000000"),
        hex!("00000000000000000101010101010101"),
        hex!("00000000000000000100000000000000"),
    ] {
        let k = Key::<Aes128>::from(*k);
        assert!(Aes128::weak_key_test(&k).is_err());
    }

    for k in &[
        hex!("00000000010000000000000000000000"),
        hex!("00000000010000000101010101010101"),
        hex!("00000000010000000100000000000000"),
    ] {
        let k = Key::<Aes128>::from(*k);
        assert!(Aes128::weak_key_test(&k).is_ok());
    }
}
