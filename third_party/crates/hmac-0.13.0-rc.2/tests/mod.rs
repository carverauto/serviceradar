macro_rules! test {
    ($mod_name:ident, $test_name:expr, $hash:ty $(, $t:ident)?) => {
        mod $mod_name {
            // TODO(tarcieri): update tests to support RustCrypto/traits#1916
            // digest::new_mac_test!(hmac, $test_name, hmac::Hmac<$hash> $(, $t)?);
            // digest::new_mac_test!(simple_hmac, $test_name, hmac::SimpleHmac<$hash> $(, $t)?);
            // digest::new_resettable_mac_test!(
            //     hmac_reset,
            //     $test_name,
            //     hmac::HmacReset<$hash>
            //     $(, $t)?
            // );
            // digest::new_resettable_mac_test!(
            //     simple_reset_hmac,
            //     $test_name,
            //     hmac::SimpleHmacReset<$hash>
            //     $(, $t)?
            // );
        }
    };
}

// Test vectors from RFC 2104, plus wiki test
test!(md5_rfc2104, "md5", md5::Md5);

// Test vectors from RFC 4231
test!(sha224_rfc4231, "sha224", sha2::Sha224);
test!(sha256_rfc4231, "sha256", sha2::Sha256);
test!(sha384_rfc4231, "sha384", sha2::Sha384);
test!(sha512_rfc4231, "sha512", sha2::Sha512);

// Test vectors from R 50.1.113-2016:
// https://tc26.ru/standard/rs/Р%2050.1.113-2016.pdf
test!(treebog256, "streebog256", streebog::Streebog256);
test!(streebog512, "streebog512", streebog::Streebog512);

// Tests from Project Wycheproof:
// https://github.com/google/wycheproof
test!(sha1_wycheproof, "wycheproof-sha1", sha1::Sha1, trunc_left);
test!(
    sha256_wycheproof,
    "wycheproof-sha256",
    sha2::Sha256,
    trunc_left
);
test!(
    sha384_wycheproof,
    "wycheproof-sha384",
    sha2::Sha384,
    trunc_left
);
test!(
    sha512_wycheproof,
    "wycheproof-sha512",
    sha2::Sha512,
    trunc_left
);
