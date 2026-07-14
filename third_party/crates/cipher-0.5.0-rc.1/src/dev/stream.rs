//! Development-related functionality for stream ciphers
use crate::{KeyIvInit, StreamCipher};

/// Stream cipher test vector
#[derive(Clone, Copy, Debug)]
pub struct TestVector {
    /// Initialization key
    pub key: &'static [u8],
    /// Initialization vector
    pub iv: &'static [u8],
    /// Plaintext
    pub plaintext: &'static [u8],
    /// Ciphertext
    pub ciphertext: &'static [u8],
}

/// Run stream cipher test
pub fn stream_cipher_test<C: KeyIvInit + StreamCipher>(
    tv: &TestVector,
) -> Result<(), &'static str> {
    if tv.plaintext.len() != tv.ciphertext.len() {
        return Err("mismatch of plaintext and ciphertext lengths");
    }
    let mut buf = [0u8; 256];
    for chunk_len in 1..256 {
        let Ok(mut mode) = C::new_from_slices(tv.key, tv.iv) else {
            return Err("cipher initialization failure");
        };
        let pt_chunks = tv.plaintext.chunks(chunk_len);
        let ct_chunks = tv.ciphertext.chunks(chunk_len);
        for (pt_chunk, ct_chunk) in pt_chunks.zip(ct_chunks) {
            let buf = &mut buf[..pt_chunk.len()];
            buf.copy_from_slice(pt_chunk);
            mode.apply_keystream(buf);

            if buf != ct_chunk {
                return Err("ciphertext mismatch");
            }
        }
    }
    Ok(())
}

/// Test core functionality of synchronous stream cipher
#[macro_export]
macro_rules! stream_cipher_test {
    ($name:ident, $test_name:expr, $cipher:ty $(,)?) => {
        #[test]
        fn $name() {
            use $crate::dev::stream::TestVector;

            $crate::dev::blobby::parse_into_structs!(
                include_bytes!(concat!("data/", $test_name, ".blb"));
                static TEST_VECTORS: &[
                    TestVector { key, iv, plaintext, ciphertext }
                ];
            );

            for (i, tv) in TEST_VECTORS.iter().enumerate() {
                let res = $crate::dev::stream::stream_cipher_test::<$cipher>(tv);
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

/// Test stream synchronous stream cipher seeking capabilities
#[macro_export]
macro_rules! stream_cipher_seek_test {
    ($name:ident, $cipher:ty) => {
        #[test]
        fn $name() {
            use cipher::array::Array;
            use cipher::{KeyIvInit, StreamCipher, StreamCipherSeek};

            fn get_cipher() -> $cipher {
                <$cipher>::new(&Default::default(), &Default::default())
            }

            const MAX_SEEK: usize = 512;

            let mut ct = [0u8; MAX_SEEK];
            get_cipher().apply_keystream(&mut ct[..]);

            for n in 0..MAX_SEEK {
                let mut cipher = get_cipher();
                assert_eq!(cipher.current_pos::<usize>(), 0);
                cipher.seek(n);
                assert_eq!(cipher.current_pos::<usize>(), n);
                let mut buf = [0u8; MAX_SEEK];
                cipher.apply_keystream(&mut buf[n..]);
                assert_eq!(cipher.current_pos::<usize>(), MAX_SEEK);
                assert_eq!(&buf[n..], &ct[n..]);
            }

            const MAX_CHUNK: usize = 128;
            const MAX_LEN: usize = 1024;

            let mut buf = [0u8; MAX_CHUNK];
            let mut cipher = get_cipher();
            assert_eq!(cipher.current_pos::<usize>(), 0);
            cipher.apply_keystream(&mut []);
            assert_eq!(cipher.current_pos::<usize>(), 0);
            for n in 1..MAX_CHUNK {
                assert_eq!(cipher.current_pos::<usize>(), 0);
                for m in 1.. {
                    cipher.apply_keystream(&mut buf[..n]);
                    assert_eq!(cipher.current_pos::<usize>(), n * m);
                    if n * m > MAX_LEN {
                        break;
                    }
                }
                cipher.seek(0);
            }
        }
    };
}

/// Create stream cipher benchmarks
#[macro_export]
macro_rules! stream_cipher_bench {
    (
        $cipher:ty;
        $($name:ident $bs:expr;)*
    ) => {
        $crate::stream_cipher_bench!(
            Init: {
                use $crate::KeyIvInit;
                let key = test::black_box(Default::default());
                let iv = test::black_box(Default::default());
                <$cipher>::new(&key, &iv)
            };
            $($name $bs;)*
        );
    };
    (
        Key: $cipher:ty;
        $($name:ident $bs:expr;)*
    ) => {
        $crate::stream_cipher_bench!(
            Init: {
                use $crate::KeyInit;
                let key = test::black_box(Default::default());
                let iv = test::black_box(Default::default());
                <$cipher>::new(&key, &iv)
            };
            $($name $bs;)*
        );
    };
    (
        Init: $init:expr;
        $($name:ident $bs:expr;)*
    ) => {
        $(
            #[bench]
            fn $name(b: &mut test::Bencher) {
                use $crate::StreamCipher;

                let mut cipher = $init;
                let mut buf = vec![0; $bs];

                b.iter(|| {
                    cipher.apply_keystream(&mut buf);
                    test::black_box(&buf);
                });

                b.bytes = $bs;
            }
        )*
    };
}
