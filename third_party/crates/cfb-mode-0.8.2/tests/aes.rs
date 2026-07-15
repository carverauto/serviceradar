use aes::*;
use cfb_mode::{BufDecryptor, BufEncryptor, Decryptor, Encryptor};
use cipher::{block_mode_dec_test, block_mode_enc_test, iv_state_test, KeyInit};

iv_state_test!(aes128_cfb_enc_iv_state, Encryptor<Aes128>, encrypt);
iv_state_test!(aes128_cfb_dec_iv_state, Decryptor<Aes128>, decrypt);
iv_state_test!(aes192_cfb_enc_iv_state, Encryptor<Aes192>, encrypt);
iv_state_test!(aes192_cfb_dec_iv_state, Decryptor<Aes192>, decrypt);
iv_state_test!(aes256_cfb_enc_iv_state, Encryptor<Aes256>, encrypt);
iv_state_test!(aes256_cfb_dec_iv_state, Decryptor<Aes256>, decrypt);

// Test vectors from CVAP "AES Multiblock Message Test (MMT) Sample Vectors":
// <https://csrc.nist.gov/Projects/Cryptographic-Algorithm-Validation-Program/Block-Ciphers>
block_mode_enc_test!(aes128_cfb_enc_test, "aes128", Encryptor<Aes128>);
block_mode_dec_test!(aes128_cfb_dec_test, "aes128", Decryptor<Aes128>);
block_mode_enc_test!(aes128enc_cfb_enc_test, "aes128", Encryptor<Aes128Enc>);
block_mode_dec_test!(aes128enc_cfb_dec_test, "aes128", Decryptor<Aes128Enc>);
block_mode_enc_test!(aes192_cfb_enc_test, "aes192", Encryptor<Aes192>);
block_mode_dec_test!(aes192_cfb_dec_test, "aes192", Decryptor<Aes192>);
block_mode_enc_test!(aes192enc_cfb_enc_test, "aes192", Encryptor<Aes192Enc>);
block_mode_dec_test!(aes192dec_cfb_dec_test, "aes192", Decryptor<Aes192Enc>);
block_mode_enc_test!(aes256_cfb_enc_test, "aes256", Encryptor<Aes256>);
block_mode_dec_test!(aes256_cfb_dec_test, "aes256", Decryptor<Aes256>);
block_mode_enc_test!(aes256enc_cfb_enc_test, "aes256", Encryptor<Aes256Enc>);
block_mode_dec_test!(aes256dec_cfb_dec_test, "aes256", Decryptor<Aes256Enc>);

/// Test methods from the `AsyncStreamCipher` trait.
#[test]
fn aes128_cfb_async_test() {
    use cipher::{AsyncStreamCipher, KeyIvInit};

    type Enc = Encryptor<Aes128>;
    type Dec = Decryptor<Aes128>;

    let key = [42; 16];
    let iv = [24; 16];
    let mut pt = [0u8; 101];
    for (i, b) in pt.iter_mut().enumerate() {
        *b = (i % 11) as u8;
    }
    let enc = Enc::new_from_slices(&key, &iv).unwrap();
    let mut ct = pt.clone();
    enc.encrypt(&mut ct);
    for i in 1..100 {
        let enc = Enc::new_from_slices(&key, &iv).unwrap();
        let mut t = pt.clone();
        let t = &mut t[..i];
        enc.encrypt(t);
        assert_eq!(t, &ct[..i]);

        let dec = Dec::new_from_slices(&key, &iv).unwrap();
        dec.decrypt(t);
        assert_eq!(t, &pt[..i]);
    }
}

#[test]
fn aes128_cfb_buffered_test() {
    use cipher::{AsyncStreamCipher, KeyIvInit};

    type Enc = Encryptor<Aes128>;

    type BufEnc = BufEncryptor<Aes128>;
    type BufDec = BufDecryptor<Aes128>;

    let key = [42; 16];
    let iv = [24; 16];
    let mut pt = [0u8; 101];
    for (i, b) in pt.iter_mut().enumerate() {
        *b = (i % 11) as u8;
    }

    // unbuffered
    let enc = Enc::new_from_slices(&key, &iv).unwrap();
    let mut ct = pt.clone();
    enc.encrypt(&mut ct);

    // buffered
    for i in 1..100 {
        let mut buf_enc = BufEnc::new_from_slices(&key, &iv).unwrap();
        let mut ct2 = pt.clone();
        for chunk in ct2.chunks_mut(i) {
            buf_enc.encrypt(chunk);
        }
        assert_eq!(ct2, ct);

        let mut buf_dec = BufDec::new_from_slices(&key, &iv).unwrap();
        for chunk in ct2.chunks_mut(i) {
            buf_dec.decrypt(chunk);
        }
        assert_eq!(ct2, pt);
    }

    // buffered with restore
    for i in 1..100 {
        let mut buf_enc = BufEnc::new_from_slices(&key, &iv).unwrap();
        let mut ct2 = pt.clone();
        for chunk in ct2.chunks_mut(i) {
            let (iv, pos) = buf_enc.get_state();
            let cipher = Aes128::new_from_slice(&key).unwrap();
            buf_enc = BufEnc::from_state(cipher, iv, pos);

            buf_enc.encrypt(chunk);
        }
        assert_eq!(ct2, ct);

        let mut buf_dec = BufDec::new_from_slices(&key, &iv).unwrap();
        for chunk in ct2.chunks_mut(i) {
            let (iv, pos) = buf_dec.get_state();
            let cipher = Aes128::new_from_slice(&key).unwrap();
            buf_dec = BufDec::from_state(cipher, iv, pos);

            buf_dec.decrypt(chunk);
        }
        assert_eq!(ct2, pt);
    }
}
