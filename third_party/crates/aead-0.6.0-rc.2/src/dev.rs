//! Development-related functionality
use crate::{
    Aead, AeadInOut, Payload, Tag, TagPosition, array::typenum::Unsigned, inout::InOutBuf,
};
pub use blobby;
use crypto_common::KeyInit;

/// AEAD test vector
#[derive(Debug, Clone, Copy)]
pub struct TestVector {
    /// Initialization key
    pub key: &'static [u8],
    /// Nonce
    pub nonce: &'static [u8],
    /// Additional associated data
    pub aad: &'static [u8],
    /// Plaintext
    pub plaintext: &'static [u8],
    /// Ciphertext
    pub ciphertext: &'static [u8],
    /// Whether the test vector should pass (`[1]`) or fail (`[0]`)
    pub pass: &'static [u8],
}

/// Run AEAD test for the provided passing test vector
pub fn pass_test<C: AeadInOut + KeyInit>(
    &TestVector {
        key,
        nonce,
        aad,
        plaintext,
        ciphertext,
        pass,
    }: &TestVector,
) -> Result<(), &'static str> {
    assert_eq!(pass, &[1]);
    let nonce = nonce.try_into().expect("wrong nonce size");
    let cipher = <C as KeyInit>::new_from_slice(key).expect("failed to initialize the cipher");

    let res = cipher
        .encrypt(
            nonce,
            Payload {
                aad,
                msg: plaintext,
            },
        )
        .map_err(|_| "encryption failure")?;
    if res != ciphertext {
        return Err("encrypted data is different from target ciphertext");
    }

    let res = cipher
        .decrypt(
            nonce,
            Payload {
                aad,
                msg: ciphertext,
            },
        )
        .map_err(|_| "decryption failure")?;
    if res != plaintext {
        return Err("decrypted data is different from target plaintext");
    }

    let (ct, tag) = match C::TAG_POSITION {
        TagPosition::Prefix => {
            let (tag, ct) = ciphertext.split_at(C::TagSize::USIZE);
            (ct, tag)
        }
        TagPosition::Postfix => ciphertext.split_at(plaintext.len()),
    };
    let tag: &Tag<C> = tag.try_into().expect("tag has correct length");

    // Fill output buffer with "garbage" to test that its data does not get read during encryption
    let mut buf: alloc::vec::Vec<u8> = (0..plaintext.len()).map(|i| i as u8).collect();
    let inout_buf = InOutBuf::new(plaintext, &mut buf).expect("pt and buf have the same length");

    let calc_tag = cipher
        .encrypt_inout_detached(nonce, aad, inout_buf)
        .map_err(|_| "encrypt_inout_detached: encryption failure")?;
    if tag != &calc_tag {
        return Err("encrypt_inout_detached: tag mismatch");
    }
    if ct != buf {
        return Err("encrypt_inout_detached: ciphertext mismatch");
    }

    // Fill output buffer with "garbage"
    buf.iter_mut()
        .enumerate()
        .for_each(|(i, v): (usize, &mut u8)| *v = i as u8);

    let inout_buf = InOutBuf::new(ct, &mut buf).expect("ct and buf have the same length");
    cipher
        .decrypt_inout_detached(nonce, aad, inout_buf, tag)
        .map_err(|_| "decrypt_inout_detached: decryption failure")?;
    if plaintext != buf {
        return Err("decrypt_inout_detached: plaintext mismatch");
    }

    Ok(())
}

/// Run AEAD test for the provided failing test vector
pub fn fail_test<C: AeadInOut + KeyInit>(
    &TestVector {
        key,
        nonce,
        aad,
        ciphertext,
        pass,
        ..
    }: &TestVector,
) -> Result<(), &'static str> {
    assert_eq!(pass, &[0]);
    let nonce = nonce.try_into().expect("wrong nonce size");
    let cipher = <C as KeyInit>::new_from_slice(key).expect("failed to initialize the cipher");

    let res = cipher.decrypt(
        nonce,
        Payload {
            aad,
            msg: ciphertext,
        },
    );
    if res.is_ok() {
        Err("decryption must return error")
    } else {
        Ok(())
    }
}

/// Define AEAD test
#[macro_export]
macro_rules! new_test {
    ($name:ident, $test_name:expr, $cipher:ty $(,)?) => {
        #[test]
        fn $name() {
            use $crate::dev::TestVector;

            $crate::dev::blobby::parse_into_structs!(
                include_bytes!(concat!("data/", $test_name, ".blb"));
                static TEST_VECTORS: &[
                    TestVector { key, nonce, aad, plaintext, ciphertext, pass }
                ];
            );

            for (i, tv) in TEST_VECTORS.iter().enumerate() {
                let pass = tv.pass[0] == 1;
                let res = if pass {
                    $crate::dev::pass_test::<$cipher>(tv)
                } else {
                    $crate::dev::fail_test::<$cipher>(tv)
                };

                if let Err(reason) = res {
                    panic!(
                        "\n\
                        Failed test #{i}\n\
                        reason:\t{reason:?}\n\
                        test vector:\t{tv:?}\n"
                    );
                }
            }
        }
    };
}
