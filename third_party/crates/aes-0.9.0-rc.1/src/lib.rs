//! Pure Rust implementation of the [Advanced Encryption Standard][AES]
//! (AES, a.k.a. Rijndael).
//!
//! # ⚠️ Security Warning: Hazmat!
//!
//! This crate implements only the low-level block cipher function, and is intended
//! for use for implementing higher-level constructions *only*. It is NOT
//! intended for direct use in applications.
//!
//! USE AT YOUR OWN RISK!
//!
//! # Supported backends
//! This crate provides multiple backends including a portable pure Rust
//! backend as well as ones based on CPU intrinsics.
//!
//! By default, it performs runtime detection of CPU intrinsics and uses them
//! if they are available.
//!
//! ## "soft" portable backend
//! As a baseline implementation, this crate provides a constant-time pure Rust
//! implementation based on [fixslicing], a more advanced form of bitslicing
//! implemented entirely in terms of bitwise arithmetic with no use of any
//! lookup tables or data-dependent branches.
//!
//! Enabling the `aes_compact` configuration flag will reduce the code size of this
//! backend at the cost of decreased performance (using a modified form of
//! the fixslicing technique called "semi-fixslicing").
//!
//! ## ARMv8 intrinsics (Rust 1.61+)
//! On `aarch64` targets including `aarch64-apple-darwin` (Apple M1) and Linux
//! targets such as `aarch64-unknown-linux-gnu` and `aarch64-unknown-linux-musl`,
//! support for using AES intrinsics provided by the ARMv8 Cryptography Extensions.
//!
//! On Linux and macOS, support for ARMv8 AES intrinsics is autodetected at
//! runtime. On other platforms the `aes` target feature must be enabled via
//! RUSTFLAGS.
//!
//! ## `x86`/`x86_64` intrinsics (AES-NI)
//! By default this crate uses runtime detection on `i686`/`x86_64` targets
//! in order to determine if AES-NI is available, and if it is not, it will
//! fallback to using a constant-time software implementation.
//!
//! Passing `RUSTFLAGS=-C target-feature=+aes,+ssse3` explicitly at compile-time
//! will override runtime detection and ensure that AES-NI is always used.
//! Programs built in this manner will crash with an illegal instruction on
//! CPUs which do not have AES-NI enabled.
//!
//! Note: runtime detection is not possible on SGX targets. Please use the
//! aforementioned `RUSTFLAGS` to leverage AES-NI and VAES on these targets.
//!
//! # Examples
//! ```
//! use aes::Aes128;
//! use aes::cipher::{Array, BlockCipherEncrypt, BlockCipherDecrypt, KeyInit};
//!
//! let key = Array::from([0u8; 16]);
//! let mut block = Array::from([42u8; 16]);
//!
//! // Initialize cipher
//! let cipher = Aes128::new(&key);
//!
//! let block_copy = block.clone();
//!
//! // Encrypt block in-place
//! cipher.encrypt_block(&mut block);
//!
//! // And decrypt it back
//! cipher.decrypt_block(&mut block);
//! assert_eq!(block, block_copy);
//!
//! // Implementation supports parallel block processing. Number of blocks
//! // processed in parallel depends in general on hardware capabilities.
//! // This is achieved by instruction-level parallelism (ILP) on a single
//! // CPU core, which is different from multi-threaded parallelism.
//! let mut blocks = [block; 100];
//! cipher.encrypt_blocks(&mut blocks);
//!
//! for block in blocks.iter_mut() {
//!     cipher.decrypt_block(block);
//!     assert_eq!(block, &block_copy);
//! }
//!
//! // `decrypt_blocks` also supports parallel block processing.
//! cipher.decrypt_blocks(&mut blocks);
//!
//! for block in blocks.iter_mut() {
//!     cipher.encrypt_block(block);
//!     assert_eq!(block, &block_copy);
//! }
//! ```
//!
//! For implementation of block cipher modes of operation see
//! [`block-modes`] repository.
//!
//! # Configuration Flags
//!
//! You can modify crate using the following configuration flags:
//!
//! - `aes_force_soft`: force software implementation.
//! - `aes_compact`: reduce code size at the cost of slower performance
//!   (affects only software backend).
//!
//! It can be enabled using `RUSTFLAGS` environmental variable
//! (e.g. `RUSTFLAGS="--cfg aes_compact"`) or by modifying `.cargo/config`.
//!
//! [AES]: https://en.wikipedia.org/wiki/Advanced_Encryption_Standard
//! [fixslicing]: https://eprint.iacr.org/2020/1123.pdf
//! [AES-NI]: https://en.wikipedia.org/wiki/AES_instruction_set
//! [`block-modes`]: https://github.com/RustCrypto/block-modes/

#![no_std]
#![doc(
    html_logo_url = "https://raw.githubusercontent.com/RustCrypto/media/26acc39f/logo.svg",
    html_favicon_url = "https://raw.githubusercontent.com/RustCrypto/media/26acc39f/logo.svg"
)]
#![cfg_attr(docsrs, feature(doc_auto_cfg))]
#![warn(missing_docs, rust_2018_idioms)]

#[cfg(feature = "hazmat")]
pub mod hazmat;

#[macro_use]
mod macros;
mod soft;

use cfg_if::cfg_if;

cfg_if! {
    if #[cfg(all(target_arch = "aarch64", not(aes_force_soft)))] {
        mod armv8;
        mod autodetect;
        pub use autodetect::*;
    } else if #[cfg(all(
        any(target_arch = "x86", target_arch = "x86_64"),
        not(aes_force_soft)
    ))] {
        mod autodetect;
        mod ni;
        pub use autodetect::*;
    } else {
        pub use soft::*;
    }
}

pub use cipher;
use cipher::{array::Array, consts::U16, crypto_common::WeakKeyError};

/// 128-bit AES block
pub type Block = Array<u8, U16>;

/// Check if any bit of the upper half of the key is set.
///
/// This follows the interpretation laid out in section `11.4.10.4 Reject of weak keys`
/// from the [TPM specification][0]:
/// ```text
/// In the case of AES, at least one bit in the upper half of the key must be set
/// ```
///
/// [0]: https://trustedcomputinggroup.org/wp-content/uploads/TPM-2.0-1.83-Part-1-Architecture.pdf#page=82
pub(crate) fn weak_key_test<const N: usize>(key: &[u8; N]) -> Result<(), WeakKeyError> {
    let t = match N {
        16 => u64::from_ne_bytes(key[..8].try_into().unwrap()),
        24 => {
            let t1 = u64::from_ne_bytes(key[..8].try_into().unwrap());
            let t2 = u32::from_ne_bytes(key[8..12].try_into().unwrap());
            t1 | u64::from(t2)
        }
        32 => {
            let t1 = u64::from_ne_bytes(key[..8].try_into().unwrap());
            let t2 = u64::from_ne_bytes(key[8..16].try_into().unwrap());
            t1 | t2
        }
        _ => unreachable!(),
    };
    match t {
        0 => Err(WeakKeyError),
        _ => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    #[cfg(feature = "zeroize")]
    #[test]
    fn zeroize_works() {
        use super::soft;

        fn test_for<T: zeroize::ZeroizeOnDrop>(val: T) {
            use core::mem::{ManuallyDrop, size_of};

            let mut val = ManuallyDrop::new(val);
            let ptr = &val as *const _ as *const u8;
            let len = size_of::<ManuallyDrop<T>>();

            unsafe { ManuallyDrop::drop(&mut val) };

            let slice = unsafe { core::slice::from_raw_parts(ptr, len) };

            assert!(slice.iter().all(|&byte| byte == 0));
        }

        let key_128 = [42; 16].into();
        let key_192 = [42; 24].into();
        let key_256 = [42; 32].into();

        use cipher::KeyInit as _;
        test_for(soft::Aes128::new(&key_128));
        test_for(soft::Aes128Enc::new(&key_128));
        test_for(soft::Aes128Dec::new(&key_128));
        test_for(soft::Aes192::new(&key_192));
        test_for(soft::Aes192Enc::new(&key_192));
        test_for(soft::Aes192Dec::new(&key_192));
        test_for(soft::Aes256::new(&key_256));
        test_for(soft::Aes256Enc::new(&key_256));
        test_for(soft::Aes256Dec::new(&key_256));

        #[cfg(all(any(target_arch = "x86", target_arch = "x86_64"), not(aes_force_soft)))]
        {
            use super::ni;

            cpufeatures::new!(aes_intrinsics, "aes");
            if aes_intrinsics::get() {
                test_for(ni::Aes128::new(&key_128));
                test_for(ni::Aes128Enc::new(&key_128));
                test_for(ni::Aes128Dec::new(&key_128));
                test_for(ni::Aes192::new(&key_192));
                test_for(ni::Aes192Enc::new(&key_192));
                test_for(ni::Aes192Dec::new(&key_192));
                test_for(ni::Aes256::new(&key_256));
                test_for(ni::Aes256Enc::new(&key_256));
                test_for(ni::Aes256Dec::new(&key_256));
            }
        }

        #[cfg(all(target_arch = "aarch64", not(aes_force_soft)))]
        {
            use super::armv8;

            cpufeatures::new!(aes_intrinsics, "aes");
            if aes_intrinsics::get() {
                test_for(armv8::Aes128::new(&key_128));
                test_for(armv8::Aes128Enc::new(&key_128));
                test_for(armv8::Aes128Dec::new(&key_128));
                test_for(armv8::Aes192::new(&key_192));
                test_for(armv8::Aes192Enc::new(&key_192));
                test_for(armv8::Aes192Dec::new(&key_192));
                test_for(armv8::Aes256::new(&key_256));
                test_for(armv8::Aes256Enc::new(&key_256));
                test_for(armv8::Aes256Dec::new(&key_256));
            }
        }
    }
}
