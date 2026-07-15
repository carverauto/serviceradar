//! [Cipher feedback][1] (CFB) mode with full block feedback.
//!
//! <img src="https://raw.githubusercontent.com/RustCrypto/media/26acc39f/img/block-modes/cfb_enc.svg" width="49%" />
//! <img src="https://raw.githubusercontent.com/RustCrypto/media/26acc39f/img/block-modes/cfb_dec.svg" width="49%"/>
//!
//! Mode functionality is accessed using traits from re-exported [`cipher`] crate.
//!
//! # ⚠️ Security Warning: Hazmat!
//!
//! This crate does not ensure ciphertexts are authentic! Thus ciphertext integrity
//! is not verified, which can lead to serious vulnerabilities!
//!
//! # Example
//! ```
//! use aes::cipher::{AsyncStreamCipher, KeyIvInit};
//! use hex_literal::hex;
//!
//! type Aes128CfbEnc = cfb_mode::Encryptor<aes::Aes128>;
//! type Aes128CfbDec = cfb_mode::Decryptor<aes::Aes128>;
//!
//! let key = [0x42; 16];
//! let iv = [0x24; 16];
//! let plaintext = *b"hello world! this is my plaintext.";
//! let ciphertext = hex!(
//!     "3357121ebb5a29468bd861467596ce3d6f99e251cc2d9f0a598032ae386d0ab995b3"
//! );
//!
//! // encrypt/decrypt in-place
//! let mut buf = plaintext.to_vec();
//! Aes128CfbEnc::new(&key.into(), &iv.into()).encrypt(&mut buf);
//! assert_eq!(buf[..], ciphertext[..]);
//!
//! Aes128CfbDec::new(&key.into(), &iv.into()).decrypt(&mut buf);
//! assert_eq!(buf[..], plaintext[..]);
//!
//! // encrypt/decrypt from buffer to buffer
//! // buffer length must be equal to input length
//! let mut buf1 = [0u8; 34];
//! Aes128CfbEnc::new(&key.into(), &iv.into())
//!     .encrypt_b2b(&plaintext, &mut buf1)
//!     .unwrap();
//! assert_eq!(buf1[..], ciphertext[..]);
//!
//! let mut buf2 = [0u8; 34];
//! Aes128CfbDec::new(&key.into(), &iv.into())
//!     .decrypt_b2b(&buf1, &mut buf2)
//!     .unwrap();
//! assert_eq!(buf2[..], plaintext[..]);
//! ```
//!
//! [1]: https://en.wikipedia.org/wiki/Block_cipher_mode_of_operation#Cipher_feedback_(CFB)

#![no_std]
#![doc(
    html_logo_url = "https://raw.githubusercontent.com/RustCrypto/media/6ee8e381/logo.svg",
    html_favicon_url = "https://raw.githubusercontent.com/RustCrypto/media/6ee8e381/logo.svg"
)]
#![forbid(unsafe_code)]
#![cfg_attr(docsrs, feature(doc_cfg))]
#![warn(missing_docs, rust_2018_idioms)]

mod decrypt;
mod encrypt;

pub use cipher;
pub use decrypt::{BufDecryptor, Decryptor};
pub use encrypt::{BufEncryptor, Encryptor};
