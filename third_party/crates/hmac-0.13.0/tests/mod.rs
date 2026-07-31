//! Test vectors.

macro_rules! new_test {
    ($name:ident, $digest:ty $(,)?) => {
        new_test!($name, $digest, digest::dev::MacTruncSide::None);
    };
    ($name:ident, $digest:ty, trunc_left $(,)?) => {
        new_test!($name, $digest, digest::dev::MacTruncSide::Left);
    };
    ($name:ident, $digest:ty, $trunc:expr $(,)?) => {
        #[test]
        fn $name() {
            use digest::dev::{MacTestVector, mac_test, reset_mac_test};

            digest::dev::blobby::parse_into_structs!(
                include_bytes!(concat!("data/", stringify!($name), ".blb"));
                static TEST_VECTORS: &[MacTestVector { key, input, tag }];
            );

            type Hmac = hmac::Hmac<$digest>;
            type HmacReset = hmac::HmacReset<$digest>;
            type SimpleHmac = hmac::SimpleHmac<$digest>;
            type SimpleHmacReset = hmac::SimpleHmacReset<$digest>;

            for (i, tv) in TEST_VECTORS.iter().enumerate() {
                if let Err(reason) = mac_test::<Hmac>(tv, $trunc) {
                    panic!(
                        "\n\
                        Failed `Hmac` test #{i}\n\
                        reason:\t{reason:?}\n\
                        test vector:\t{tv:?}\n"
                    );
                }
                if let Err(reason) = reset_mac_test::<HmacReset>(tv, $trunc) {
                    panic!(
                        "\n\
                        Failed `HmacReset` test #{i}\n\
                        reason:\t{reason:?}\n\
                        test vector:\t{tv:?}\n"
                    );
                }
                if let Err(reason) = mac_test::<SimpleHmac>(tv, $trunc) {
                    panic!(
                        "\n\
                        Failed `SimpleHmac` test #{i}\n\
                        reason:\t{reason:?}\n\
                        test vector:\t{tv:?}\n"
                    );
                }
                if let Err(reason) = reset_mac_test::<SimpleHmacReset>(tv, $trunc) {
                    panic!(
                        "\n\
                        Failed `SimpleHmacReset` test #{i}\n\
                        reason:\t{reason:?}\n\
                        test vector:\t{tv:?}\n"
                    );
                }
            }
        }
    };
}

// Test vectors from RFC 2104, plus Wikipedia test
new_test!(hmac_md5_rfc2104, md5::Md5);

// Test vectors from RFC 4231
new_test!(hmac_sha224_rfc4231, sha2::Sha224);
new_test!(hmac_sha256_rfc4231, sha2::Sha256);
new_test!(hmac_sha384_rfc4231, sha2::Sha384);
new_test!(hmac_sha512_rfc4231, sha2::Sha512);

// Test vectors from R 50.1.113-2016:
// https://tc26.ru/standard/rs/Р%2050.1.113-2016.pdf
new_test!(hmac_streebog256_gost, streebog::Streebog256);
new_test!(hmac_streebog512_gost, streebog::Streebog512);

// Tests from Project Wycheproof:
// https://github.com/google/wycheproof
new_test!(hmac_sha1_wycheproof, sha1::Sha1, trunc_left);
new_test!(hmac_sha256_wycheproof, sha2::Sha256, trunc_left);
new_test!(hmac_sha384_wycheproof, sha2::Sha384, trunc_left);
new_test!(hmac_sha512_wycheproof, sha2::Sha512, trunc_left);
