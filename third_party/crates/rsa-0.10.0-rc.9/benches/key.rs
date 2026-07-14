#![feature(test)]

extern crate test;

use base64ct::{Base64, Encoding};
use crypto_bigint::BoxedUint;
use hex_literal::hex;
use rand_chacha::{rand_core::SeedableRng, ChaCha8Rng};
use rsa::{Pkcs1v15Encrypt, Pkcs1v15Sign, RsaPrivateKey};
use sha2::{Digest, Sha256};
use test::Bencher;

const DECRYPT_VAL: &str = "\
    XW4qfrpQDarEMBfPyIYE9UvuOFkbBi0tiGYbIOJPLMNe/LWuPD0BQ7ceqlOlPPcK\
    LinYz0DlnqW3It/V7ae59zw9afA3YIWdq0Ut2BnYL+aJixnqaP+PjsQNcHg6axCF\
    11iNQ4jpXrZDiQcI+q9EEzZDTMsiMxtjfgBQUd8LHT87YoQXDWaFPCVpliACMc8a\
    Uk442kH1tc4jEuXwjEjFErvAM/J7VizCdU/dnKrlq2mBDzvZ6hxY9TYHFB/zY6DZ\
    PJAgEMUxYWCR9xPJ7X256DV1Kt0Ht33DWoFcgh/pPLM1q9pK0HVxCdclXfZOeCql\
    rLgZ5Gxv5DM4BtV7Z4m85w==";

fn get_key() -> RsaPrivateKey {
    // 2048 bits

    let n = hex!(
        "7163c842b2190a8970942b2764aed42d4124647b6f30e09a2da1c0e2"
        "56aa2ee24e790c40c96a4bd66d75c371a915e0703c476b4e1a06f1bd"
        "38c5a3c10ae3bd30f4ef62a5aa4f512ad145a06c48e96469a22ce8e6"
        "21e052f0669a8c34155512d82e55447f0b7e18da94bd911ac7b3aabe"
        "706843668964593ee71b2e5e484bcf0c7834101ab5d61bba1e63e623"
        "7af40489ce36a260dab70add4fbec24d659db0f7cac099b0a3aa4549"
        "acde7fc858a793a975e6cf65ca276b743525f0883980f6ad069bec34"
        "6d787797386d50fe0c9734be967c7d84ae5b8f349b094079457c0c0c"
        "6fee34c42a0b832603804f71e49f3320081637512c6cbf2bb81b6f6b"
        "e239846d"
    );
    let d = hex!(
        "4b97dad7216607064b0d721a431f381e2b6d98524a2095bc1e6bd5ec"
        "39c6c9ec3450b2d5db9c328ef3a3d7a11b63eaf57d84f2341159f67e"
        "25d917d607427e20a34a41c3c6df8b71e0d9159d85f0ed9bc17345ee"
        "c140374aef11b2cd638e0c901ee382ff5cfebb3c63290b672fcd1c7e"
        "f59ad799b0ed90d49a121ee98587df5cc161c584bc5887ae2a15e787"
        "e86ab1e803366150561e0b3b3ae28ebdcf32cd46dff317ed3e1b7590"
        "cc300d1d57c9288462d06d9fbe097e52b70dc4fca313ae09906e5fab"
        "0c24729b54fe35cc38fe1496419a902f35f08460952bd4783e0e930b"
        "a8b520f83eafe6fa6589bbab6e4f4bc5c285672c99f5055eec6a2a30"
        "b06e786b"
    );

    let primes = [
        hex!(
            "ba69948f830c296242da6bf9ae3fddb76a63dbf0761ed3f644bc"
            "a96a2e1eb75fd1bbd9cd93c72330bcc2a97cfafd12ee27bfde0f"
            "b6ac152df2ec4ab12b11265b41bcb531e39f347fdf09e9562a6e"
            "5a7c020c6534df61c955dd772cc7b9d461fdeea2f3b83663302c"
            "fe5656c235d4ac94c81658ad179919cded8ab1be1e9aa369"
        ),
        hex!(
            "9bb7d344184526d29c689eddf0141bf65f013477e36b260e32ae"
            "42c680b2c5ada9181bff32b9f1bfbdd3c29f59fcc3f4b9ee4ce6"
            "766d18ca2fa4fe5c19d24b436c39a781f7a2972e59e616f58cab"
            "bb6132084008fe10ff4dddd054fd2e91cd7d043b8f9795a07881"
            "6cdb5f2e895394e29c37c3e12de41d4f67f17e64baf92c65"
        ),
    ];

    RsaPrivateKey::from_components(
        BoxedUint::from_be_slice(&n, 2048).unwrap(),
        BoxedUint::from(3u32),
        BoxedUint::from_be_slice(&d, 2048).unwrap(),
        vec![
            BoxedUint::from_be_slice(&primes[0], 1024).unwrap(),
            BoxedUint::from_be_slice(&primes[1], 1024).unwrap(),
        ],
    )
    .unwrap()
}

#[bench]
fn bench_rsa_1024_gen_key(b: &mut Bencher) {
    let mut rng = ChaCha8Rng::from_seed([42; 32]);

    b.iter(|| {
        let key = RsaPrivateKey::new(&mut rng, 1024).unwrap();
        test::black_box(key);
    });
}

#[bench]
fn bench_rsa_2048_gen_key(b: &mut Bencher) {
    let mut rng = ChaCha8Rng::from_seed([42; 32]);

    b.iter(|| {
        let key = RsaPrivateKey::new(&mut rng, 2048).unwrap();
        test::black_box(key);
    });
}

#[bench]
fn bench_rsa_2048_pkcsv1_decrypt(b: &mut Bencher) {
    let priv_key = get_key();
    let x = Base64::decode_vec(DECRYPT_VAL).unwrap();

    b.iter(|| {
        let res = priv_key.decrypt(Pkcs1v15Encrypt, &x).unwrap();
        test::black_box(res);
    });
}

#[bench]
fn bench_rsa_2048_pkcsv1_sign_blinded(b: &mut Bencher) {
    let priv_key = get_key();
    let digest = Sha256::digest(b"testing").to_vec();
    let mut rng = ChaCha8Rng::from_seed([42; 32]);

    b.iter(|| {
        let res = priv_key
            .sign_with_rng(&mut rng, Pkcs1v15Sign::new::<Sha256>(), &digest)
            .unwrap();
        test::black_box(res);
    });
}
