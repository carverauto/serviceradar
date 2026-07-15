//! Development-related functionality

#![allow(clippy::missing_errors_doc)]

pub use blobby;

mod fixed;
#[cfg(feature = "mac")]
mod mac;
mod rng;
mod xof;

pub use fixed::*;
#[cfg(feature = "mac")]
pub use mac::*;
pub use xof::*;

/// Test vector for hash functions
#[derive(Debug, Clone, Copy)]
pub struct TestVector {
    /// Input data
    pub input: &'static [u8],
    /// Output hash
    pub output: &'static [u8],
}

/// Define hash function test
#[macro_export]
macro_rules! new_test {
    ($name:ident, $hasher:ty, $test_fn:ident $(,)?) => {
        #[test]
        fn $name() {
            use $crate::dev::TestVector;

            $crate::dev::blobby::parse_into_structs!(
                include_bytes!(concat!("data/", stringify!($name), ".blb"));
                static TEST_VECTORS: &[TestVector { input, output }];
            );

            for (i, tv) in TEST_VECTORS.iter().enumerate() {
                if let Err(reason) = $test_fn::<$hasher>(tv) {
                    panic!(
                        "\n\
                        Failed test #{i}:\n\
                        reason:\t{reason}\n\
                        test vector:\t{tv:?}\n"
                    );
                }
            }
        }
    };
}

/// Define hash function serialization test
#[macro_export]
macro_rules! hash_serialization_test {
    ($name:ident, $hasher:ty $(,)?) => {
        #[test]
        fn $name() {
            use digest::{
                Digest,
                common::{BlockSizeUser, hazmat::SerializableState},
                typenum::Unsigned,
            };

            let mut h = <$hasher>::new();

            h.update(&[0x13; <$hasher as BlockSizeUser>::BlockSize::USIZE + 1]);

            let serialized_state = h.serialize();
            let expected = include_bytes!(concat!("data/", stringify!($name), ".bin"));
            assert_eq!(serialized_state.as_slice(), expected);

            let mut h = <$hasher>::deserialize(&serialized_state).unwrap();

            h.update(&[0x13; <$hasher as BlockSizeUser>::BlockSize::USIZE + 1]);
            let output1 = h.finalize();

            let mut h = <$hasher>::new();
            h.update(&[0x13; 2 * (<$hasher as BlockSizeUser>::BlockSize::USIZE + 1)]);
            let output2 = h.finalize();

            assert_eq!(output1, output2);
        }
    };
}

/// Define hash function serialization test
#[macro_export]
macro_rules! hash_rt_outsize_serialization_test {
    ($name:ident, $hasher:ty, $expected_serialized_state:expr) => {
        #[test]
        fn $name() {
            use digest::{
                Digest, Update, VariableOutput,
                common::{BlockSizeUser, hazmat::SerializableState},
                typenum::Unsigned,
            };
            const HASH_OUTPUT_SIZE: usize = <$hasher>::MAX_OUTPUT_SIZE - 1;

            let mut h = <$hasher>::new(HASH_OUTPUT_SIZE).unwrap();

            h.update(&[0x13; <$hasher as BlockSizeUser>::BlockSize::USIZE + 1]);

            let serialized_state = h.serialize();
            assert_eq!(serialized_state.as_slice(), $expected_serialized_state);

            let mut h = <$hasher>::deserialize(&serialized_state).unwrap();

            h.update(&[0x13; <$hasher as BlockSizeUser>::BlockSize::USIZE + 1]);
            let mut output1 = [0; HASH_OUTPUT_SIZE];
            h.finalize_variable(&mut output1).unwrap();

            let mut h = <$hasher>::new(HASH_OUTPUT_SIZE).unwrap();
            h.update(&[0x13; 2 * (<$hasher as BlockSizeUser>::BlockSize::USIZE + 1)]);
            let mut output2 = [0; HASH_OUTPUT_SIZE];
            h.finalize_variable(&mut output2).unwrap();

            assert_eq!(output1, output2);
        }
    };
}

/// Define [`Update`][crate::Update] impl benchmark
#[macro_export]
macro_rules! bench_update {
    (
        $init:expr;
        $($name:ident $bs:expr;)*
    ) => {
        $(
            #[bench]
            fn $name(b: &mut Bencher) {
                let mut d = $init;
                let data = [0; $bs];

                b.iter(|| {
                    digest::Update::update(&mut d, &data[..]);
                });

                b.bytes = $bs;
            }
        )*
    };
}

/// Feed ~1 MiB of pseudorandom data to an updatable state.
pub fn feed_rand_16mib<D: crate::Update>(d: &mut D) {
    let buf = &mut [0u8; 1024];
    let mut rng = rng::RNG;
    let n = 16 * (1 << 20) / buf.len();
    for _ in 0..n {
        rng.fill(buf);
        d.update(buf);
        // additional byte, so size of fed data
        // will not be multiple of block size
        d.update(&[42]);
    }
}
