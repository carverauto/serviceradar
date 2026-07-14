//! Certification request (`CertReq`) tests

use der::asn1::{PrintableStringRef, Utf8StringRef};
use der::{Decode, Encode, Tag, Tagged};
use hex_literal::hex;
use x509_cert::request::{CertReq, Version};

const RSA_KEY: &[u8] = &hex!("3082010A0282010100BF59F7FE716DDE47C73579CA846EFA8D30AB3612E0D6A524204A72CA8E50C9F459513DF0D73331BED3D7A2DA7A362719E471EE6A9D87827D1024ED44605AB9B48F3B808C5E173B9F3EC4003D57F1718489F5C7A0421C46FBD527A40AB4BA6B9DB16A545D1ECF6E2A5633BD80594EBA4AFEE71F63E1D357C64E9A3FF6B83746A885C373F3527987E4C2B4AF7FE4D4EA16405E5E15285DD938823AA18E2634BAFE847A761CAFABB0401D3FA03A07A9D097CBB0C77156CCFE36131DADF1C109C2823972F0AF21A35F358E788304C0C78B951739D91FABFFD07AA8CD4F69746B3D0EB4587469F9D39F4FBDC761200DFB27DAF69562311D8B191B7EEFAAE2F8D6F8EB0203010001");
const RSA_SIG: &[u8] = &hex!("2B053CFE81C6542176BD70B373A5FC8DC1F1806A5AB10D25E36690EED1DF57AD5F18EC0CCF165F000245B14157141224B431EC6715EFE937F66B892D11EDF8858EDF67ACCAE9701A2244BECA80705D7CC292BAD9B02001E4572EE492B08473D5AF59CC83DDA1DE5C2BF470FD784495070A9C5AF8EA9A4060C1DBC5C4690CC8DF6D528C55D82EC9C0DF3046BBCAE7542025D7EE170788C9C234132703290A31AC2700E55339590226D5E582EC61869862769FD85B45F287FFDD6DB530995D31F94D7D2C26EF3F48A182C3026CC698F382A72F1A11E3C689953055DAC0DFEBE9CDB163CA3AF33FFC4DA0F6B84B9D7CDD4321CCECD4BAC528DEFF9715FFD9D4731E");

/// RSA-2048 `CertReq` encoded as ASN.1 DER
const RSA_2048_DER_EXAMPLE: &[u8] = include_bytes!("examples/rsa2048-csr.der");

const NAMES: &[(&str, &str)] = &[
    ("2.5.4.3", "example.com"),
    ("2.5.4.7", "Los Angeles"),
    ("2.5.4.8", "California"),
    ("2.5.4.10", "Example Inc"),
    ("2.5.4.6", "US"),
];

#[rustfmt::skip]
const EXTENSIONS: &[(&str, &[u8])] = &[
    ("2.5.29.19", &hex!("3000")),     // basicConstraints
    ("2.5.29.15", &hex!("030205A0")), // keyUsage
    ("2.5.29.37", &hex!("301406082B0601050507030106082B06010505070302")), // extKeyUsage
    ("2.5.29.17", &hex!("300D820B6578616D706C652E636F6D")), // subjectAltNamec
];

#[test]
fn decode_rsa_2048_der() {
    let cr = CertReq::from_der(RSA_2048_DER_EXAMPLE).unwrap();

    // Check the version.
    assert_eq!(cr.info.version, Version::V1);

    // Check all the RDNs.
    assert_eq!(cr.info.subject.0.len(), NAMES.len());
    for (name, (oid, val)) in cr.info.subject.0.iter().zip(NAMES) {
        let kind = name.0.get(0).unwrap();
        let value = match kind.value.tag() {
            Tag::Utf8String => Utf8StringRef::try_from(&kind.value).unwrap().as_str(),
            Tag::PrintableString => PrintableStringRef::try_from(&kind.value).unwrap().as_str(),
            _ => panic!("unexpected tag"),
        };

        assert_eq!(kind.oid, oid.parse().unwrap());
        assert_eq!(name.0.len(), 1);
        assert_eq!(value, *val);
    }

    // Check the public key.
    let alg = cr.info.public_key.algorithm;
    assert_eq!(alg.oid, "1.2.840.113549.1.1.1".parse().unwrap());
    assert!(alg.parameters.unwrap().is_null());
    assert_eq!(cr.info.public_key.subject_public_key.raw_bytes(), RSA_KEY);

    // Check the attributes (just one; contains extensions).
    assert_eq!(cr.info.attributes.len(), 1);
    let attribute = cr.info.attributes.get(0).unwrap();
    assert_eq!(attribute.oid, "1.2.840.113549.1.9.14".parse().unwrap()); // extensionRequest
    assert_eq!(attribute.values.len(), 1);

    // Check the extensions.
    let extensions: x509_cert::ext::Extensions =
        attribute.values.get(0).unwrap().decode_as().unwrap();
    for (ext, (oid, val)) in extensions.iter().zip(EXTENSIONS) {
        assert_eq!(ext.extn_id, oid.parse().unwrap());
        assert_eq!(ext.extn_value.as_bytes(), *val);
        assert!(!ext.critical);
    }

    // Check the signature value.
    assert_eq!(cr.algorithm.oid, "1.2.840.113549.1.1.11".parse().unwrap());
    assert!(cr.algorithm.parameters.unwrap().is_null());
    assert_eq!(cr.signature.as_bytes().unwrap(), RSA_SIG);
}

// The following tests currently fail because of a bug in the `der` crate;
// specifically, the `IMPLICIT` tagging on `CertReqInfo::attributes`.

#[test]
fn encode_rsa_2048_der() {
    let cr = CertReq::from_der(RSA_2048_DER_EXAMPLE).unwrap();
    let cr_encoded = cr.to_der().unwrap();
    assert_eq!(RSA_2048_DER_EXAMPLE, cr_encoded.as_slice());
}
