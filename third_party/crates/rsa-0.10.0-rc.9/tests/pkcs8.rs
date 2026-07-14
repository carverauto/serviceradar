//! PKCS#8 encoding tests

#![cfg(feature = "encoding")]

use crypto_bigint::BoxedUint;
use hex_literal::hex;
use rsa::{
    pkcs1v15,
    pkcs8::{DecodePrivateKey, DecodePublicKey, EncodePrivateKey, EncodePublicKey},
    pss,
    traits::{PrivateKeyParts, PublicKeyParts},
    RsaPrivateKey, RsaPublicKey,
};
use sha2::Sha256;
use subtle::ConstantTimeEq;

#[cfg(feature = "encoding")]
use rsa::pkcs8::LineEnding;

/// RSA-2048 PKCS#8 private key encoded as ASN.1 DER
const RSA_2048_PRIV_DER: &[u8] = include_bytes!("examples/pkcs8/rsa2048-priv.der");

/// RSA-2048 `SubjectPublicKeyInfo` encoded as ASN.1 DER
const RSA_2048_PUB_DER: &[u8] = include_bytes!("examples/pkcs8/rsa2048-pub.der");

/// RSA-2048 PKCS#8 private key encoded as PEM
#[cfg(feature = "encoding")]
const RSA_2048_PRIV_PEM: &str = include_str!("examples/pkcs8/rsa2048-priv.pem");

/// RSA-2048 PKCS#8 public key encoded as PEM
#[cfg(feature = "encoding")]
const RSA_2048_PUB_PEM: &str = include_str!("examples/pkcs8/rsa2048-pub.pem");

/// RSA-2048 PSS PKCS#8 private key encoded as DER
const RSA_2048_PSS_PRIV_DER: &[u8] = include_bytes!("examples/pkcs8/rsa2048-rfc9421-priv.der");

/// RSA-2048 PSS PKCS#8 public key encoded as DER
const RSA_2048_PSS_PUB_DER: &[u8] = include_bytes!("examples/pkcs8/rsa2048-rfc9421-pub.der");

#[test]
fn decode_rsa2048_priv_der() {
    let key = RsaPrivateKey::from_pkcs8_der(RSA_2048_PRIV_DER).unwrap();

    // Note: matches PKCS#1 test vectors
    assert_eq!(
        &key.n().to_be_bytes()[..],
        &hex!(
            "B6C42C515F10A6AAF282C63EDBE24243A170F3FA2633BD4833637F47CA4F6F36"
            "E03A5D29EFC3191AC80F390D874B39E30F414FCEC1FCA0ED81E547EDC2CD382C"
            "76F61C9018973DB9FA537972A7C701F6B77E0982DFC15FC01927EE5E7CD94B4F"
            "599FF07013A7C8281BDF22DCBC9AD7CABB7C4311C982F58EDB7213AD4558B332"
            "266D743AED8192D1884CADB8B14739A8DADA66DC970806D9C7AC450CB13D0D7C"
            "575FB198534FC61BC41BC0F0574E0E0130C7BBBFBDFDC9F6A6E2E3E2AFF1CBEA"
            "C89BA57884528D55CFB08327A1E8C89F4E003CF2888E933241D9D695BCBBACDC"
            "90B44E3E095FA37058EA25B13F5E295CBEAC6DE838AB8C50AF61E298975B872F"
        )
    );
    let expected_e = BoxedUint::from_be_slice(&hex!("010001"), 32).unwrap();
    assert!(bool::from(key.e().ct_eq(&expected_e)));
    assert_eq!(
        &key.d().to_be_bytes()[..],
        &hex!(
            "7ECC8362C0EDB0741164215E22F74AB9D91BA06900700CF63690E5114D8EE6BD"
            "CFBB2E3F9614692A677A083F168A5E52E5968E6407B9D97C6E0E4064F82DA0B7"
            "58A14F17B9B7D41F5F48E28D6551704F56E69E7AA9FA630FC76428C06D25E455"
            "DCFC55B7AC2B4F76643FDED3FE15FF78ABB27E65ACC4AAD0BDF6DB27EF60A691"
            "0C5C4A085ED43275AB19C1D997A32C6EFFCE7DF2D1935F6E601EEDE161A12B5C"
            "C27CA21F81D2C99C3D1EA08E90E3053AB09BEFA724DEF0D0C3A3C1E9740C0D9F"
            "76126A149EC0AA7D8078205484254D951DB07C4CF91FB6454C096588FD5924DB"
            "ABEB359CA2025268D004F9D66EB3D6F7ADC1139BAD40F16DDE639E11647376C1"
        )
    );
    let expected_prime = BoxedUint::from_be_slice(
        &hex!(
            "DCC061242D4E92AFAEE72AC513CA65B9F77036F9BD7E0E6E61461A7EF7654225"
            "EC153C7E5C31A6157A6E5A13FF6E178E8758C1CB33D9D6BBE3179EF18998E422"
            "ECDCBED78F4ECFDBE5F4FCD8AEC2C9D0DC86473CA9BD16D9D238D21FB5DDEFBE"
            "B143CA61D0BD6AA8D91F33A097790E9640DBC91085DC5F26343BA3138F6B2D67"
        ),
        1024,
    )
    .unwrap();
    assert!(bool::from(key.primes()[0].ct_eq(&expected_prime)));

    let expected_prime = BoxedUint::from_be_slice(
        &hex!(
            "D3F314757E40E954836F92BE24236AF2F0DA04A34653C180AF67E960086D93FD"
            "E65CB23EFD9D09374762F5981E361849AF68CDD75394FF6A4E06EB69B209E422"
            "8DB2DFA70E40F7F9750A528176647B788D0E5777A2CB8B22E3CD267FF70B4F3B"
            "02D3AAFB0E18C590A564B03188B0AA5FC48156B07622214243BD1227EFA7F2F9"
        ),
        1024,
    )
    .unwrap();
    assert!(bool::from(key.primes()[1].ct_eq(&expected_prime)));

    let _ = pkcs1v15::SigningKey::<Sha256>::from_pkcs8_der(RSA_2048_PRIV_DER).unwrap();
}

#[test]
fn decode_rsa2048_pub_der() {
    let key = RsaPublicKey::from_public_key_der(RSA_2048_PUB_DER).unwrap();

    // Note: matches PKCS#1 test vectors
    assert_eq!(
        &key.n().to_be_bytes()[..],
        &hex!(
            "B6C42C515F10A6AAF282C63EDBE24243A170F3FA2633BD4833637F47CA4F6F36"
            "E03A5D29EFC3191AC80F390D874B39E30F414FCEC1FCA0ED81E547EDC2CD382C"
            "76F61C9018973DB9FA537972A7C701F6B77E0982DFC15FC01927EE5E7CD94B4F"
            "599FF07013A7C8281BDF22DCBC9AD7CABB7C4311C982F58EDB7213AD4558B332"
            "266D743AED8192D1884CADB8B14739A8DADA66DC970806D9C7AC450CB13D0D7C"
            "575FB198534FC61BC41BC0F0574E0E0130C7BBBFBDFDC9F6A6E2E3E2AFF1CBEA"
            "C89BA57884528D55CFB08327A1E8C89F4E003CF2888E933241D9D695BCBBACDC"
            "90B44E3E095FA37058EA25B13F5E295CBEAC6DE838AB8C50AF61E298975B872F"
        )
    );
    let expected_e = BoxedUint::from_be_slice(&hex!("010001"), 128).unwrap();
    assert!(bool::from(key.e().ct_eq(&expected_e)));

    let _ = pkcs1v15::VerifyingKey::<Sha256>::from_public_key_der(RSA_2048_PUB_DER).unwrap();
}

#[test]
fn decode_rsa2048_pss_priv_der() {
    let key = RsaPrivateKey::from_pkcs8_der(RSA_2048_PSS_PRIV_DER).unwrap();

    assert_eq!(
        &key.n().to_be_bytes()[..],
        &hex!(
            "AF8B669B7AF6D1677F3DBAAF3F5B36F9012DBE9B91695F18AB8D208D447CCB64"
            "63C5AE9DA46D865C76CF7EF32CF1CB7E2E1D461F8E71DBC470DD1CB9DE69BEA0"
            "05E3C90F3A3A70E467937C9586E0803E0EDF0E8CEA902F2E4864F79027753AE2"
            "7DB2053CD53C3CF30EECECAB1401EA803B339E33C59933AD08470DD99D45A568"
            "1C870B982CF2FE5A892A96D775D67AAACE2F9B27D72F48A00361D50000DE5652"
            "DCDDA62CBA2DB4E04B13FBA1C894E139F483923A683649EC0F0BCE8D0A4B2658"
            "A00E3CE66A9C3B419501D570F65AB868E4FDBFA77E9DBE1B9CD91056494B4377"
            "D502F266FB17433A9F4B08D08DE3C576A670CE90557AF94F67579A3273A5C8DB"

        )
    );
    let expected_e = BoxedUint::from_be_slice(&hex!("010001"), 128).unwrap();
    assert!(bool::from(key.e().ct_eq(&expected_e)));
    assert_eq!(
        &key.d().to_be_bytes()[..],
        &hex!(
            "9407C8A9FA426289954A17C02A7C1FDA50FD234C0A8E41EC0AD64289FE24025C"
            "10AAA5BA37EB482F76DD391F9559FD10D590480EDA4EF7552B1BBA5A9ECCAB3C"
            "445B36B44994F8981323D31E4093D670FE9768ACBA2C862CD04D9C5A0A7C1800"
            "E0A01B3C96506AD14857D0A7DF82521E7A4DE7ED9E86B7860581ED9301C5B659"
            "B3785DF2BB96EA45CA8E871F25918981CC3004505CB25E3927539F968C04FD0F"
            "3B86D0CA4E4E4714D449E39C88F254164B501E4BC66F29BB2ABC847F01FC4E4B"
            "342FB5A1CF23FAD0F2F7C52F4534E262F66FB3CEDC1821718342E28CD860EC21"
            "3783DA6236A07A0F332003D30748EC1C12556D7CA7587E8E07DCE1D95EC4A611"
        )
    );
    let expected_prime = BoxedUint::from_be_slice(
        &hex!(
            "E55FBA212239C846821579BE7E4D44336C700167A478F542032BEBF506D39453"
            "82670B7D5B08D48E1B4A46EB22E54ABE21867FB6AD96444E00B386FF14710CB6"
            "9D80111E3721CBE65CFA8A141A1492D5434BB7538481EBB27462D54EDD1EA55D"
            "C2230431EE63C4A3609EC28BA67ABEE0DCA1A12E8E796BB5485A331BD27DC509"
        ),
        1024,
    )
    .unwrap();
    assert!(bool::from(key.primes()[0].ct_eq(&expected_prime)));

    let expected_prime = BoxedUint::from_be_slice(
        &hex!(
            "C3EC0875ED7B5B96340A9869DD9674B8CF0E52AD4092B57620A6AEA981DA0F10"
            "13DF610CE1C8B630C111DA7214128E20FF8DA55B4CD8A2E145A8E370BF4F87C8"
            "EB203E9752A8A442E562E09F455769B8DA35CCBA2A134F5DE274020B6A7620F0"
            "3DE276FCBFDE2B0356438DD17DD40152AB80C1277B4849A643CB158AA07ADBC3"
        ),
        1024,
    )
    .unwrap();
    assert!(bool::from(key.primes()[1].ct_eq(&expected_prime)));

    let _ = pss::SigningKey::<Sha256>::from_pkcs8_der(RSA_2048_PSS_PRIV_DER).unwrap();
}

#[test]
fn decode_rsa2048_pss_pub_der() {
    let key = RsaPublicKey::from_public_key_der(RSA_2048_PSS_PUB_DER).unwrap();

    assert_eq!(
        &key.n().to_be_bytes()[..],
        &hex!(
            "AF8B669B7AF6D1677F3DBAAF3F5B36F9012DBE9B91695F18AB8D208D447CCB64"
            "63C5AE9DA46D865C76CF7EF32CF1CB7E2E1D461F8E71DBC470DD1CB9DE69BEA0"
            "05E3C90F3A3A70E467937C9586E0803E0EDF0E8CEA902F2E4864F79027753AE2"
            "7DB2053CD53C3CF30EECECAB1401EA803B339E33C59933AD08470DD99D45A568"
            "1C870B982CF2FE5A892A96D775D67AAACE2F9B27D72F48A00361D50000DE5652"
            "DCDDA62CBA2DB4E04B13FBA1C894E139F483923A683649EC0F0BCE8D0A4B2658"
            "A00E3CE66A9C3B419501D570F65AB868E4FDBFA77E9DBE1B9CD91056494B4377"
            "D502F266FB17433A9F4B08D08DE3C576A670CE90557AF94F67579A3273A5C8DB"
        )
    );
    let expected_e = BoxedUint::from_be_slice(&hex!("010001"), 128).unwrap();
    assert!(bool::from(key.e().ct_eq(&expected_e)));

    let _ = pss::VerifyingKey::<Sha256>::from_public_key_der(RSA_2048_PSS_PUB_DER).unwrap();
}

#[test]
fn encode_rsa2048_priv_der() {
    let key = RsaPrivateKey::from_pkcs8_der(RSA_2048_PRIV_DER).unwrap();
    let der = key.to_pkcs8_der().unwrap();
    assert_eq!(der.as_bytes(), RSA_2048_PRIV_DER);

    let pkcs1v15_key = pkcs1v15::SigningKey::<Sha256>::from_pkcs8_der(RSA_2048_PRIV_DER).unwrap();
    let pkcs1v15_der = pkcs1v15_key.to_pkcs8_der().unwrap();
    assert_eq!(pkcs1v15_der.as_bytes(), RSA_2048_PRIV_DER);
}

#[test]
fn encode_rsa2048_pub_der() {
    let key = RsaPublicKey::from_public_key_der(RSA_2048_PUB_DER).unwrap();
    let der = key.to_public_key_der().unwrap();
    assert_eq!(der.as_ref(), RSA_2048_PUB_DER);

    let pkcs1v15_key =
        pkcs1v15::VerifyingKey::<Sha256>::from_public_key_der(RSA_2048_PUB_DER).unwrap();
    let pkcs1v15_der = pkcs1v15_key.to_public_key_der().unwrap();
    assert_eq!(pkcs1v15_der.as_ref(), RSA_2048_PUB_DER);
}

#[test]
#[cfg(feature = "encoding")]
fn decode_rsa2048_priv_pem() {
    let key = RsaPrivateKey::from_pkcs8_pem(RSA_2048_PRIV_PEM).unwrap();

    // Note: matches PKCS#1 test vectors
    assert_eq!(
        &key.n().to_be_bytes()[..],
        &hex!(
            "B6C42C515F10A6AAF282C63EDBE24243A170F3FA2633BD4833637F47CA4F6F36"
            "E03A5D29EFC3191AC80F390D874B39E30F414FCEC1FCA0ED81E547EDC2CD382C"
            "76F61C9018973DB9FA537972A7C701F6B77E0982DFC15FC01927EE5E7CD94B4F"
            "599FF07013A7C8281BDF22DCBC9AD7CABB7C4311C982F58EDB7213AD4558B332"
            "266D743AED8192D1884CADB8B14739A8DADA66DC970806D9C7AC450CB13D0D7C"
            "575FB198534FC61BC41BC0F0574E0E0130C7BBBFBDFDC9F6A6E2E3E2AFF1CBEA"
            "C89BA57884528D55CFB08327A1E8C89F4E003CF2888E933241D9D695BCBBACDC"
            "90B44E3E095FA37058EA25B13F5E295CBEAC6DE838AB8C50AF61E298975B872F"
        )
    );
    let expected_e = BoxedUint::from_be_slice(&hex!("010001"), 128).unwrap();
    assert!(bool::from(key.e().ct_eq(&expected_e)));
    assert_eq!(
        &key.d().to_be_bytes()[..],
        &hex!(
            "7ECC8362C0EDB0741164215E22F74AB9D91BA06900700CF63690E5114D8EE6BD"
            "CFBB2E3F9614692A677A083F168A5E52E5968E6407B9D97C6E0E4064F82DA0B7"
            "58A14F17B9B7D41F5F48E28D6551704F56E69E7AA9FA630FC76428C06D25E455"
            "DCFC55B7AC2B4F76643FDED3FE15FF78ABB27E65ACC4AAD0BDF6DB27EF60A691"
            "0C5C4A085ED43275AB19C1D997A32C6EFFCE7DF2D1935F6E601EEDE161A12B5C"
            "C27CA21F81D2C99C3D1EA08E90E3053AB09BEFA724DEF0D0C3A3C1E9740C0D9F"
            "76126A149EC0AA7D8078205484254D951DB07C4CF91FB6454C096588FD5924DB"
            "ABEB359CA2025268D004F9D66EB3D6F7ADC1139BAD40F16DDE639E11647376C1"
        )
    );
    let expected_prime = BoxedUint::from_be_slice(
        &hex!(
            "DCC061242D4E92AFAEE72AC513CA65B9F77036F9BD7E0E6E61461A7EF7654225"
            "EC153C7E5C31A6157A6E5A13FF6E178E8758C1CB33D9D6BBE3179EF18998E422"
            "ECDCBED78F4ECFDBE5F4FCD8AEC2C9D0DC86473CA9BD16D9D238D21FB5DDEFBE"
            "B143CA61D0BD6AA8D91F33A097790E9640DBC91085DC5F26343BA3138F6B2D67"
        ),
        1024,
    )
    .unwrap();
    assert!(bool::from(key.primes()[0].ct_eq(&expected_prime)));

    let expected_prime = BoxedUint::from_be_slice(
        &hex!(
            "D3F314757E40E954836F92BE24236AF2F0DA04A34653C180AF67E960086D93FD"
            "E65CB23EFD9D09374762F5981E361849AF68CDD75394FF6A4E06EB69B209E422"
            "8DB2DFA70E40F7F9750A528176647B788D0E5777A2CB8B22E3CD267FF70B4F3B"
            "02D3AAFB0E18C590A564B03188B0AA5FC48156B07622214243BD1227EFA7F2F9"
        ),
        1024,
    )
    .unwrap();
    assert!(bool::from(key.primes()[1].ct_eq(&expected_prime)));

    let _ = pkcs1v15::SigningKey::<Sha256>::from_pkcs8_pem(RSA_2048_PRIV_PEM).unwrap();
}

#[test]
#[cfg(feature = "encoding")]
fn decode_rsa2048_pub_pem() {
    let key = RsaPublicKey::from_public_key_pem(RSA_2048_PUB_PEM).unwrap();

    // Note: matches PKCS#1 test vectors
    assert_eq!(
        &key.n().to_be_bytes()[..],
        &hex!(
            "B6C42C515F10A6AAF282C63EDBE24243A170F3FA2633BD4833637F47CA4F6F36"
            "E03A5D29EFC3191AC80F390D874B39E30F414FCEC1FCA0ED81E547EDC2CD382C"
            "76F61C9018973DB9FA537972A7C701F6B77E0982DFC15FC01927EE5E7CD94B4F"
            "599FF07013A7C8281BDF22DCBC9AD7CABB7C4311C982F58EDB7213AD4558B332"
            "266D743AED8192D1884CADB8B14739A8DADA66DC970806D9C7AC450CB13D0D7C"
            "575FB198534FC61BC41BC0F0574E0E0130C7BBBFBDFDC9F6A6E2E3E2AFF1CBEA"
            "C89BA57884528D55CFB08327A1E8C89F4E003CF2888E933241D9D695BCBBACDC"
            "90B44E3E095FA37058EA25B13F5E295CBEAC6DE838AB8C50AF61E298975B872F"
        )
    );
    let expected_e = BoxedUint::from_be_slice(&hex!("010001"), 128).unwrap();
    assert!(bool::from(key.e().ct_eq(&expected_e)));

    let _ = pkcs1v15::VerifyingKey::<Sha256>::from_public_key_pem(RSA_2048_PUB_PEM).unwrap();
}

#[test]
#[cfg(feature = "encoding")]
fn encode_rsa2048_priv_pem() {
    let key = RsaPrivateKey::from_pkcs8_pem(RSA_2048_PRIV_PEM).unwrap();
    let pem = key.to_pkcs8_pem(LineEnding::LF).unwrap();
    assert_eq!(&*pem, RSA_2048_PRIV_PEM)
}

#[test]
#[cfg(feature = "encoding")]
fn encode_rsa2048_pub_pem() {
    let key = RsaPublicKey::from_public_key_pem(RSA_2048_PUB_PEM).unwrap();
    let pem = key.to_public_key_pem(LineEnding::LF).unwrap();
    assert_eq!(&*pem, RSA_2048_PUB_PEM)
}
