use hex_literal::hex;
use hkdf::{Hkdf, hmac::EagerHash};
use sha1::Sha1;
use sha2::Sha256;

struct Test<'a> {
    ikm: &'a [u8],
    salt: &'a [u8],
    info: &'a [u8],
    prk: &'a [u8],
    okm: &'a [u8],
}

fn rfc_test<H: EagerHash>(tests: &[Test]) {
    let mut buf = [0u8; 128];
    for test in tests.iter() {
        let salt = if test.salt.is_empty() {
            None
        } else {
            Some(test.salt)
        };
        let (prk2, hkdf) = Hkdf::<H>::extract(salt, test.ikm);
        let okm = &mut buf[..test.okm.len()];
        assert!(hkdf.expand(test.info, okm).is_ok());

        assert_eq!(prk2[..], test.prk[..]);
        assert_eq!(okm, test.okm);

        okm.fill(0);
        let hkdf = Hkdf::<H>::from_prk(test.prk).unwrap();
        assert!(hkdf.expand(test.info, okm).is_ok());
        assert_eq!(okm, test.okm);
    }
}

// Test Vectors from https://tools.ietf.org/html/rfc5869.
#[test]
fn test_rfc5869_sha256() {
    rfc_test::<Sha256>(&[
        // Test Case 1
        Test {
            ikm: &hex!("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"),
            salt: &hex!("000102030405060708090a0b0c"),
            info: &hex!("f0f1f2f3f4f5f6f7f8f9"),
            prk: &hex!(
                "077709362c2e32df0ddc3f0dc47bba63"
                "90b6c73bb50f9c3122ec844ad7c2b3e5"
            ),
            okm: &hex!(
                "3cb25f25faacd57a90434f64d0362f2a"
                "2d2d0a90cf1a5a4c5db02d56ecc4c5bf"
                "34007208d5b887185865"
            ),
        },
        // Test Case 2
        Test {
            ikm: &hex!(
                "000102030405060708090a0b0c0d0e0f"
                "101112131415161718191a1b1c1d1e1f"
                "202122232425262728292a2b2c2d2e2f"
                "303132333435363738393a3b3c3d3e3f"
                "404142434445464748494a4b4c4d4e4f"
            ),
            salt: &hex!(
                "606162636465666768696a6b6c6d6e6f"
                "707172737475767778797a7b7c7d7e7f"
                "808182838485868788898a8b8c8d8e8f"
                "909192939495969798999a9b9c9d9e9f"
                "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf"
            ),
            info: &hex!(
                "b0b1b2b3b4b5b6b7b8b9babbbcbdbebf"
                "c0c1c2c3c4c5c6c7c8c9cacbcccdcecf"
                "d0d1d2d3d4d5d6d7d8d9dadbdcdddedf"
                "e0e1e2e3e4e5e6e7e8e9eaebecedeeef"
                "f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff"
            ),
            prk: &hex!(
                "06a6b88c5853361a06104c9ceb35b45c"
                "ef760014904671014a193f40c15fc244"
            ),
            okm: &hex!(
                "b11e398dc80327a1c8e7f78c596a4934"
                "4f012eda2d4efad8a050cc4c19afa97c"
                "59045a99cac7827271cb41c65e590e09"
                "da3275600c2f09b8367793a9aca3db71"
                "cc30c58179ec3e87c14c01d5c1f3434f"
                "1d87"
            ),
        },
        // Test Case 3
        Test {
            ikm: &hex!("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"),
            salt: &hex!(""),
            info: &hex!(""),
            prk: &hex!(
                "19ef24a32c717b167f33a91d6f648bdf"
                "96596776afdb6377ac434c1c293ccb04"
            ),
            okm: &hex!(
                "8da4e775a563c18f715f802a063c5a31"
                "b8a11f5c5ee1879ec3454e5f3c738d2d"
                "9d201395faa4b61a96c8"
            ),
        },
    ]);
}

#[test]
fn test_rfc5869_sha1() {
    rfc_test::<Sha1>(&[
        // Test Case 4
        Test {
            ikm: &hex!("0b0b0b0b0b0b0b0b0b0b0b"),
            salt: &hex!("000102030405060708090a0b0c"),
            info: &hex!("f0f1f2f3f4f5f6f7f8f9"),
            prk: &hex!("9b6c18c432a7bf8f0e71c8eb88f4b30baa2ba243"),
            okm: &hex!(
                "085a01ea1b10f36933068b56efa5ad81"
                "a4f14b822f5b091568a9cdd4f155fda2"
                "c22e422478d305f3f896"
            ),
        },
        // Test Case 5
        Test {
            ikm: &hex!(
                "000102030405060708090a0b0c0d0e0f"
                "101112131415161718191a1b1c1d1e1f"
                "202122232425262728292a2b2c2d2e2f"
                "303132333435363738393a3b3c3d3e3f"
                "404142434445464748494a4b4c4d4e4f"
            ),
            salt: &hex!(
                "606162636465666768696a6b6c6d6e6f"
                "707172737475767778797a7b7c7d7e7f"
                "808182838485868788898a8b8c8d8e8f"
                "909192939495969798999a9b9c9d9e9f"
                "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf"
            ),
            info: &hex!(
                "b0b1b2b3b4b5b6b7b8b9babbbcbdbebf"
                "c0c1c2c3c4c5c6c7c8c9cacbcccdcecf"
                "d0d1d2d3d4d5d6d7d8d9dadbdcdddedf"
                "e0e1e2e3e4e5e6e7e8e9eaebecedeeef"
                "f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff"
            ),
            prk: &hex!("8adae09a2a307059478d309b26c4115a224cfaf6"),
            okm: &hex!(
                "0bd770a74d1160f7c9f12cd5912a06eb"
                "ff6adcae899d92191fe4305673ba2ffe"
                "8fa3f1a4e5ad79f3f334b3b202b2173c"
                "486ea37ce3d397ed034c7f9dfeb15c5e"
                "927336d0441f4c4300e2cff0d0900b52"
                "d3b4"
            ),
        },
        // Test Case 6
        Test {
            ikm: &hex!("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"),
            salt: &hex!(""),
            info: &hex!(""),
            prk: &hex!("da8c8a73c7fa77288ec6f5e7c297786aa0d32d01"),
            okm: &hex!(
                "0ac1af7002b3d761d1e55298da9d0506"
                "b9ae52057220a306e07b6b87e8df21d0"
                "ea00033de03984d34918"
            ),
        },
        // Test Case 7
        Test {
            ikm: &hex!("0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c"),
            salt: &hex!(""), // "Not Provided"
            info: &hex!(""),
            prk: &hex!("2adccada18779e7c2077ad2eb19d3f3e731385dd"),
            okm: &hex!(
                "2c91117204d745f3500d636a62f64f0a"
                "b3bae548aa53d423b0d1f27ebba6f5e5"
                "673a081d70cce7acfc48"
            ),
        },
    ]);
}
