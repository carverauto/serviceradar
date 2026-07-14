use core::iter;

use hex_literal::hex;
use hkdf::{Hkdf, HkdfExtract, SimpleHkdfExtract};
use sha1::Sha1;
use sha2::Sha256;

const MAX_SHA256_LENGTH: usize = 255 * (256 / 8); // =8160
static COMPONENTS: &[&[u8]] = &[
    b"09090909090909090909090909090909090909090909",
    b"8a8a8a8a8a8a8a8a8a8a8a8a8a8a8a8a8a8a8a8a8a",
    b"0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0",
    b"4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4",
    b"1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d",
];

#[test]
fn test_lengths() {
    let hkdf = Hkdf::<Sha256>::new(None, &[]);
    let mut longest = vec![0u8; MAX_SHA256_LENGTH];
    assert!(hkdf.expand(&[], &mut longest).is_ok());
    // Runtime is O(length), so exhaustively testing all legal lengths
    // would take too long (at least without --release). Only test a
    // subset: the first 500, the last 10, and every 100th in between.
    let range = 500..MAX_SHA256_LENGTH - 10;
    let lengths = (0..MAX_SHA256_LENGTH + 1).filter(|len| !range.contains(len) || *len % 100 == 0);

    for length in lengths {
        let mut okm = vec![0u8; length];
        assert!(hkdf.expand(&[], &mut okm).is_ok());
        assert_eq!(okm.len(), length);
        assert_eq!(okm[..], longest[..length]);
    }
}

#[test]
fn test_max_length() {
    let hkdf = Hkdf::<Sha256>::new(Some(&[]), &[]);
    let mut okm = vec![0u8; MAX_SHA256_LENGTH];
    assert!(hkdf.expand(&[], &mut okm).is_ok());
}

#[test]
fn test_max_length_exceeded() {
    let hkdf = Hkdf::<Sha256>::new(Some(&[]), &[]);
    let mut okm = vec![0u8; MAX_SHA256_LENGTH + 1];
    assert!(hkdf.expand(&[], &mut okm).is_err());
}

#[test]
fn test_unsupported_length() {
    let hkdf = Hkdf::<Sha256>::new(Some(&[]), &[]);
    let mut okm = vec![0u8; 90000];
    assert!(hkdf.expand(&[], &mut okm).is_err());
}

#[test]
fn test_prk_too_short() {
    use sha2::digest::Digest;

    let output_len = Sha256::output_size();
    let prk = vec![0; output_len - 1];
    assert!(Hkdf::<Sha256>::from_prk(&prk).is_err());
}

#[test]
#[rustfmt::skip]
fn test_derive_sha1_with_none() {
    let ikm = hex!("0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c");
    let salt = None;
    let info = hex!("");
    let (prk, hkdf) = Hkdf::<Sha1>::extract(salt, &ikm[..]);
    let mut okm = [0u8; 42];
    assert!(hkdf.expand(&info[..], &mut okm).is_ok());

    assert_eq!(
        prk[..],
        hex!("2adccada18779e7c2077ad2eb19d3f3e731385dd")[..]
    );
    assert_eq!(
        okm[..],
        hex!("
            2c91117204d745f3500d636a62f64f0a
            b3bae548aa53d423b0d1f27ebba6f5e5
            673a081d70cce7acfc48
        ")[..],
    );
}

#[test]
fn test_expand_multi_info() {
    let info_components = COMPONENTS;

    let (_, hkdf_ctx) = Hkdf::<Sha256>::extract(None, b"some ikm here");

    // Compute HKDF-Expand on the concatenation of all the info components
    let mut oneshot_res = [0u8; 16];
    hkdf_ctx
        .expand(&info_components.concat(), &mut oneshot_res)
        .unwrap();

    // Now iteratively join the components of info_components until it's all 1 component. The value
    // of HKDF-Expand should be the same throughout
    let mut num_concatted = 0;
    let mut info_head = Vec::new();

    while num_concatted < info_components.len() {
        info_head.extend(info_components[num_concatted]);

        // Build the new input to be the info head followed by the remaining components
        let input: Vec<&[u8]> = iter::once(info_head.as_slice())
            .chain(info_components.iter().cloned().skip(num_concatted + 1))
            .collect();

        // Compute and compare to the one-shot answer
        let mut multipart_res = [0u8; 16];
        hkdf_ctx
            .expand_multi_info(&input, &mut multipart_res)
            .unwrap();
        assert_eq!(multipart_res, oneshot_res);

        num_concatted += 1;
    }
}

#[test]
fn test_extract_streaming() {
    let ikm_components = COMPONENTS;
    let salt = b"mysalt";

    // Compute HKDF-Extract on the concatenation of all the IKM components
    let (oneshot_res, _) = Hkdf::<Sha256>::extract(Some(&salt[..]), &ikm_components.concat());

    // Now iteratively join the components of ikm_components until it's all 1 component. The value
    // of HKDF-Extract should be the same throughout
    let mut num_concatted = 0;
    let mut ikm_head = Vec::new();

    while num_concatted < ikm_components.len() {
        ikm_head.extend(ikm_components[num_concatted]);

        // Make a new extraction context and build the new input to be the IKM head followed by the
        // remaining components
        let mut extract_ctx = HkdfExtract::<Sha256>::new(Some(&salt[..]));
        let input = iter::once(ikm_head.as_slice())
            .chain(ikm_components.iter().cloned().skip(num_concatted + 1));

        // Stream in the IKM input in the chunks specified
        for ikm in input {
            extract_ctx.input_ikm(ikm);
        }

        // Finalize and compare to the one-shot answer
        let (multipart_res, _) = extract_ctx.finalize();
        assert_eq!(multipart_res, oneshot_res);

        num_concatted += 1;
    }

    let mut num_concatted = 0;
    let mut ikm_head = Vec::new();

    while num_concatted < ikm_components.len() {
        ikm_head.extend(ikm_components[num_concatted]);

        // Make a new extraction context and build the new input to be the IKM head followed by the
        // remaining components
        let mut extract_ctx = SimpleHkdfExtract::<Sha256>::new(Some(&salt[..]));
        let input = iter::once(ikm_head.as_slice())
            .chain(ikm_components.iter().cloned().skip(num_concatted + 1));

        // Stream in the IKM input in the chunks specified
        for ikm in input {
            extract_ctx.input_ikm(ikm);
        }

        // Finalize and compare to the one-shot answer
        let (multipart_res, _) = extract_ctx.finalize();
        assert_eq!(multipart_res, oneshot_res);

        num_concatted += 1;
    }
}

#[test]
fn test_debug_impls() {
    fn needs_debug<T: std::fmt::Debug>() {}
    needs_debug::<Hkdf<Sha256>>();
    needs_debug::<HkdfExtract<Sha256>>();
}
