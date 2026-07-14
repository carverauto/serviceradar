/// Compare a Rust hash to the C implementation, and the COMPACT version.
macro_rules! compare_to_c {
    ($test:ident, $rust_fn:path, $compact_fn:path, $cc_fn:ident) => {
        #[test]
        fn $test() {
            use rand::Rng;
            use rapidhash_c::$cc_fn;

            // test zero-length input
            let rust_hash = $rust_fn(&[], &DEFAULT_RAPID_SECRETS);
            let compact_hash = $compact_fn(&[], &DEFAULT_RAPID_SECRETS);
            let c_hash = $cc_fn(&[], DEFAULT_SEED);
            assert_eq!(rust_hash, c_hash, "Mismatch with C on zero len input");
            assert_eq!(rust_hash, compact_hash, "Mismatch with COMPACT on zero len input");

            // test up to 512 bytes
            for len in 0..=512 {
                let mut data = std::vec![0; len];
                rand::rng().fill(&mut data[..]);

                for byte in 0..len {
                    for bit in 0..8 {
                        let mut data = data.clone();
                        data[byte] ^= 1 << bit;

                        let rust_hash = $rust_fn(&data, &DEFAULT_RAPID_SECRETS);
                        let compact_hash = $compact_fn(&data, &DEFAULT_RAPID_SECRETS);
                        let c_hash = $cc_fn(&data, DEFAULT_SEED);
                        assert_eq!(rust_hash, c_hash, "Mismatch with C on input {} byte {} bit {}", len, byte, bit);
                        assert_eq!(rust_hash, compact_hash, "Mismatch with COMPACT on input {} byte {} bit {}", len, byte, bit);
                    }
                }
            }
        }
    };
}

/// Check that flipping a single bit changes enough bits of output.
macro_rules! flip_bit_trial {
    ($test:ident, $hash:path) => {
        #[test]
        fn $test() {
            use rand::Rng;

            let mut flips = std::vec![];

            for len in 1..=256 {
                let mut data = std::vec![0; len];
                rand::rng().fill(&mut data[..]);

                let hash = $hash(&data, &DEFAULT_RAPID_SECRETS);
                for byte in 0..len {
                    for bit in 0..8 {
                        let mut data = data.clone();
                        data[byte] ^= 1 << bit;
                        let new_hash = $hash(&data, &DEFAULT_RAPID_SECRETS);
                        assert_ne!(hash, new_hash, "Flipping byte {} bit {} did not change hash for input len {}", byte, bit, len);
                        let xor = hash ^ new_hash;
                        let flipped = xor.count_ones() as u64;
                        assert!(xor.count_ones() >= 8, "Flipping bit {byte}:{bit} changed only {flipped} bits");

                        flips.push(flipped);
                    }
                }
            }

            let average = flips.iter().sum::<u64>() as f64 / flips.len() as f64;
            assert!(average > 31.95 && average < 32.05, "Did not flip an average of half the bits. average: {average}, expected: 32.0");

            let mut hashes_seen = std::collections::HashSet::new();

            // "ray casting" -> flip a single bit across the whole range, using a repeating pattern
            // which simulates swapped bits. The previous part of the test uses randomized data
            // which would not simulate bytes swapping positions.
            for len in 1..=512 {
                // should ensure that the patterns won't collide when we flip a bit, eg. 0x00 and
                // 0x01 will naturally collide when we flip the last bit of 0x00
                for pattern in [0x00, 0xAA, 0x53] {
                    let data = std::vec![pattern; len];

                    for byte in 0..len {
                        for bit in 0..8 {
                            // cast a single bit along the whole data
                            let mut data = data.clone();
                            data[byte] ^= 1 << bit;

                            // ensure hash is unique
                            let new_hash = $hash(&data, &DEFAULT_RAPID_SECRETS);
                            assert!(!hashes_seen.contains(&new_hash), "Hash collision detected for input len vec![{pattern}; {len}] at pos {byte}:{bit}: hash {new_hash} already seen");
                            hashes_seen.insert(new_hash);
                        }
                    }
                }
            }
        }
    };
}

macro_rules! compare_rapidhash_file {
    ($test:ident, $hash:path, $file:path) => {
        #[test]
        fn $test() {
            use rand::RngCore;

            const LENGTH: usize = 1024;
            for len in 1..=LENGTH {
                let mut data = vec![0u8; len];
                rand::rng().fill_bytes(&mut data);

                let mut file = tempfile::tempfile().unwrap();
                file.write_all(&data).unwrap();
                file.seek(SeekFrom::Start(0)).unwrap();

                assert_eq!(
                    $hash(&data, &DEFAULT_RAPID_SECRETS),
                    $file(&mut file, &DEFAULT_RAPID_SECRETS).unwrap(),
                    "Mismatch for input len: {}", &data.len()
                );
            }
        }
    };
}

macro_rules! compare_rapid_stream_hasher {
    ($test:ident, $hash:path, $hasher:path) => {
        #[test]
        fn $test() {
            extern crate alloc;
            use rand::RngCore;

            type H<'a> = $hasher;

            // test every length and every chunking size for the stream hasher
            for len in 0..1024 {
                let mut data = alloc::vec![0u8; len];
                rand::rng().fill_bytes(&mut data);

                let expected_hash = $hash(&data, &DEFAULT_RAPID_SECRETS);

                let mut hasher = H::new(&DEFAULT_RAPID_SECRETS);

                for chunk_size in 1..512 {
                    for chunk in data.chunks(chunk_size) {
                        hasher.write(chunk);
                    }

                    let actual_hash = hasher.finish();
                    assert_eq!(expected_hash, actual_hash, "Mismatch for input len: {} and chunk size: {}", len, chunk_size);

                    hasher.reset();
                }
            }
        }
    };
}

pub(crate) use compare_to_c;
pub(crate) use flip_bit_trial;
pub(crate) use compare_rapidhash_file;
pub(crate) use compare_rapid_stream_hasher;
