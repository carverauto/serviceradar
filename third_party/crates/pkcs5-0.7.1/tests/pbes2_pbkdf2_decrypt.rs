//! PBES2 PBKDF2 decryption tests

#[cfg(feature = "pbes2")]
use std::fs;

#[cfg(feature = "pbes2")]
fn run_combinations(prfs: &[&str]) {
    /// Password used to encrypt the keys.
    const PASSWORD: &[u8] = b"hunter2"; // Bad password; don't actually use outside tests!

    let sk_path = "./tests/examples/rsa_sk.pkcs8.der";
    let sk_bytes = fs::read(&sk_path).expect(&format!("Failed to read from {}", &sk_path));

    for aes_mode in ["aes-128-cbc", "aes-192-cbc", "aes-256-cbc"] {
        for prf in prfs {
            let algid_path = format!("./tests/examples/pbes2_{}_{}_algid.der", aes_mode, prf);
            let algid_bytes =
                fs::read(&algid_path).expect(&format!("Failed to read from {}", &algid_path));
            let scheme = pkcs5::EncryptionScheme::try_from(algid_bytes.as_slice())
                .expect(&format!("Failed to interpret scheme {} {}", aes_mode, prf));

            let ciphertext_path =
                format!("./tests/examples/pbes2_{}_{}_ciphertext.bin", aes_mode, prf);
            let mut ciphertext_bytes = fs::read(&ciphertext_path)
                .expect(&format!("Failed to read from {}", &ciphertext_path));

            assert_eq!(640, ciphertext_bytes.len());

            let plaintext = scheme
                .decrypt_in_place(PASSWORD, &mut ciphertext_bytes)
                .expect(&format!("pbes2 decryption of {} {}", aes_mode, prf));

            assert_eq!(sk_bytes, plaintext);
        }
    }
}

#[cfg(feature = "sha1-insecure")]
#[test]
fn all_combinations_with_sha1() {
    let prfs = vec!["hmacWithSHA1"];
    run_combinations(&prfs);
}

#[cfg(feature = "pbes2")]
#[test]
fn all_combinations_with_sha2() {
    let prfs = vec![
        "hmacWithSHA224",
        "hmacWithSHA256",
        "hmacWithSHA384",
        "hmacWithSHA512",
    ];

    run_combinations(&prfs);
}
