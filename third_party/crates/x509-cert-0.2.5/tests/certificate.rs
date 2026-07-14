//! Certificate tests

use der::{
    asn1::{BitStringRef, ContextSpecific, ObjectIdentifier, PrintableStringRef, Utf8StringRef},
    Decode, DecodeValue, Encode, FixedTag, Header, Reader, Tag, Tagged,
};
use hex_literal::hex;
use spki::AlgorithmIdentifierRef;
use x509_cert::serial_number::SerialNumber;
use x509_cert::Certificate;
use x509_cert::*;

#[cfg(feature = "pem")]
use der::DecodePem;

// TODO - parse and compare extension values
const EXTENSIONS: &[(&str, bool)] = &[
    ("2.5.29.15", true),
    ("2.5.29.19", true),
    ("2.5.29.33", false),
    ("2.5.29.32", false),
    ("2.5.29.14", false),
    ("2.5.29.31", false),
    ("1.3.6.1.5.5.7.1.11", false),
    ("1.3.6.1.5.5.7.1.1", false),
    ("2.5.29.54", false),
    ("2.5.29.35", false),
];

///Structure supporting deferred decoding of fields in the Certificate SEQUENCE
pub struct DeferDecodeCertificate<'a> {
    /// tbsCertificate       TBSCertificate,
    pub tbs_certificate: &'a [u8],
    /// signatureAlgorithm   AlgorithmIdentifier,
    pub signature_algorithm: &'a [u8],
    /// signature            BIT STRING
    pub signature: &'a [u8],
}

impl<'a> DecodeValue<'a> for DeferDecodeCertificate<'a> {
    fn decode_value<R: Reader<'a>>(
        reader: &mut R,
        header: Header,
    ) -> der::Result<DeferDecodeCertificate<'a>> {
        reader.read_nested(header.length, |reader| {
            Ok(Self {
                tbs_certificate: reader.tlv_bytes()?,
                signature_algorithm: reader.tlv_bytes()?,
                signature: reader.tlv_bytes()?,
            })
        })
    }
}

impl FixedTag for DeferDecodeCertificate<'_> {
    const TAG: Tag = Tag::Sequence;
}

///Structure supporting deferred decoding of fields in the TBSCertificate SEQUENCE
pub struct DeferDecodeTbsCertificate<'a> {
    /// Decoded field
    pub version: u8,
    /// Defer decoded field
    pub serial_number: &'a [u8],
    /// Defer decoded field
    pub signature: &'a [u8],
    /// Defer decoded field
    pub issuer: &'a [u8],
    /// Defer decoded field
    pub validity: &'a [u8],
    /// Defer decoded field
    pub subject: &'a [u8],
    /// Defer decoded field
    pub subject_public_key_info: &'a [u8],
    /// Decoded field (never present)
    pub issuer_unique_id: Option<BitStringRef<'a>>,
    /// Decoded field (never present)
    pub subject_unique_id: Option<BitStringRef<'a>>,
    /// Defer decoded field
    pub extensions: &'a [u8],
}

impl<'a> DecodeValue<'a> for DeferDecodeTbsCertificate<'a> {
    fn decode_value<R: Reader<'a>>(
        reader: &mut R,
        header: Header,
    ) -> der::Result<DeferDecodeTbsCertificate<'a>> {
        reader.read_nested(header.length, |reader| {
            let version = ContextSpecific::decode_explicit(reader, ::der::TagNumber::N0)?
                .map(|cs| cs.value)
                .unwrap_or_else(Default::default);

            Ok(Self {
                version,
                serial_number: reader.tlv_bytes()?,
                signature: reader.tlv_bytes()?,
                issuer: reader.tlv_bytes()?,
                validity: reader.tlv_bytes()?,
                subject: reader.tlv_bytes()?,
                subject_public_key_info: reader.tlv_bytes()?,
                issuer_unique_id: reader.decode()?,
                subject_unique_id: reader.decode()?,
                extensions: reader.tlv_bytes()?,
            })
        })
    }
}

impl FixedTag for DeferDecodeTbsCertificate<'_> {
    const TAG: Tag = Tag::Sequence;
}

#[test]
fn reencode_cert() {
    let der_encoded_cert =
        include_bytes!("examples/026EDA6FA1EDFA8C253936C75B5EEBD954BFF452.fake.der");
    let defer_cert = DeferDecodeCertificate::from_der(der_encoded_cert).unwrap();

    let parsed_tbs = TbsCertificate::from_der(defer_cert.tbs_certificate).unwrap();
    let reencoded_tbs = parsed_tbs.to_der().unwrap();
    assert_eq!(defer_cert.tbs_certificate, reencoded_tbs);

    let parsed_sigalg = AlgorithmIdentifierRef::from_der(defer_cert.signature_algorithm).unwrap();
    let reencoded_sigalg = parsed_sigalg.to_der().unwrap();
    assert_eq!(defer_cert.signature_algorithm, reencoded_sigalg);

    let parsed_sig = BitStringRef::from_der(defer_cert.signature).unwrap();
    let reencoded_sig = parsed_sig.to_der().unwrap();
    assert_eq!(defer_cert.signature, reencoded_sig);

    let parsed_coverage_tbs =
        DeferDecodeTbsCertificate::from_der(defer_cert.tbs_certificate).unwrap();

    // TODO - defer decode then re-encode version field

    let encoded_serial = parsed_tbs.serial_number.to_der().unwrap();
    assert_eq!(parsed_coverage_tbs.serial_number, encoded_serial);

    let encoded_signature = parsed_tbs.signature.to_der().unwrap();
    assert_eq!(parsed_coverage_tbs.signature, encoded_signature);

    let encoded_issuer = parsed_tbs.issuer.to_der().unwrap();
    assert_eq!(parsed_coverage_tbs.issuer, encoded_issuer);

    let encoded_validity = parsed_tbs.validity.to_der().unwrap();
    assert_eq!(parsed_coverage_tbs.validity, encoded_validity);

    let encoded_subject = parsed_tbs.subject.to_der().unwrap();
    assert_eq!(parsed_coverage_tbs.subject, encoded_subject);

    let encoded_subject_public_key_info = parsed_tbs.subject_public_key_info.to_der().unwrap();
    assert_eq!(
        parsed_coverage_tbs.subject_public_key_info,
        encoded_subject_public_key_info
    );

    // TODO - either encode as context specific or decode to sequence. for know lop off context
    // specific tag and length
    let encoded_extensions = parsed_tbs.extensions.to_der().unwrap();
    assert_eq!(&parsed_coverage_tbs.extensions[4..], encoded_extensions);
}

#[test]
fn decode_oversized_oids() {
    let o1parse = ObjectIdentifier::from_der(&hex!(
        "06252B060104018237150885C8B86B87AFF00383A99F3C96C34081ADE6494D82B0E91D85B2873D"
    ))
    .unwrap();
    let o1str = o1parse.to_string();
    assert_eq!(
        o1str,
        "1.3.6.1.4.1.311.21.8.11672683.15464451.6967228.369088.2847561.77.4994205.11305917"
    );
    let o1 = ObjectIdentifier::new_unwrap(
        "1.3.6.1.4.1.311.21.8.11672683.15464451.6967228.369088.2847561.77.4994205.11305917",
    );
    assert_eq!(
        o1.to_string(),
        "1.3.6.1.4.1.311.21.8.11672683.15464451.6967228.369088.2847561.77.4994205.11305917"
    );
    let enc_oid = o1.to_der().unwrap();
    assert_eq!(
        &hex!("06252B060104018237150885C8B86B87AFF00383A99F3C96C34081ADE6494D82B0E91D85B2873D"),
        enc_oid.as_slice()
    );
}

#[test]
fn decode_cert() {
    // cloned cert with variety of interesting bits, including subject DN encoded backwards, large
    // policy mapping set, large policy set (including one with qualifiers), fairly typical set of
    // extensions otherwise
    let der_encoded_cert =
        include_bytes!("examples/026EDA6FA1EDFA8C253936C75B5EEBD954BFF452.fake.der");
    let result = Certificate::from_der(der_encoded_cert);
    let cert: Certificate = result.unwrap();
    println!("{:?}", cert);
    let exts = cert.tbs_certificate.extensions.unwrap();
    for (ext, (oid, crit)) in exts.iter().zip(EXTENSIONS) {
        assert_eq!(ext.extn_id.to_string(), *oid);
        assert_eq!(ext.critical, *crit);
    }

    let result = Certificate::from_der(der_encoded_cert);
    let cert: Certificate = result.unwrap();

    assert_eq!(cert.tbs_certificate.version, Version::V3);
    let target_serial: [u8; 16] = [
        0x7F, 0x00, 0x00, 0x01, 0x00, 0x00, 0x01, 0x49, 0xCF, 0x70, 0x66, 0x4D, 0x00, 0x00, 0x00,
        0x02,
    ];
    assert_eq!(
        cert.tbs_certificate.serial_number,
        SerialNumber::new(&target_serial).unwrap()
    );
    assert_eq!(
        cert.tbs_certificate.signature.oid.to_string(),
        "1.2.840.113549.1.1.11"
    );
    assert_eq!(
        cert.tbs_certificate
            .signature
            .parameters
            .as_ref()
            .unwrap()
            .tag(),
        Tag::Null
    );
    assert!(cert
        .tbs_certificate
        .signature
        .parameters
        .as_ref()
        .unwrap()
        .is_null());

    let mut counter = 0;
    let i = cert.tbs_certificate.issuer.0.iter();
    for rdn in i {
        let i1 = rdn.0.iter();
        for atav in i1 {
            if 0 == counter {
                assert_eq!(atav.oid.to_string(), "2.5.4.6");
                assert_eq!(
                    PrintableStringRef::try_from(&atav.value)
                        .unwrap()
                        .to_string(),
                    "US"
                );
            } else if 1 == counter {
                assert_eq!(atav.oid.to_string(), "2.5.4.10");
                assert_eq!(
                    PrintableStringRef::try_from(&atav.value)
                        .unwrap()
                        .to_string(),
                    "Mock"
                );
            } else if 2 == counter {
                assert_eq!(atav.oid.to_string(), "2.5.4.10");
                assert_eq!(
                    Utf8StringRef::try_from(&atav.value).unwrap().to_string(),
                    "IdenTrust Services LLC"
                );
            } else if 3 == counter {
                assert_eq!(atav.oid.to_string(), "2.5.4.3");
                assert_eq!(
                    Utf8StringRef::try_from(&atav.value).unwrap().to_string(),
                    "PTE IdenTrust Global Common Root CA 1"
                );
            }
            counter += 1;
        }
    }

    assert_eq!(
        cert.tbs_certificate
            .validity
            .not_before
            .to_unix_duration()
            .as_secs(),
        1416524490
    );
    assert_eq!(
        cert.tbs_certificate
            .validity
            .not_after
            .to_unix_duration()
            .as_secs(),
        1516628593
    );

    counter = 0;
    let i = cert.tbs_certificate.subject.0.iter();
    for rdn in i {
        let i1 = rdn.0.iter();
        for atav in i1 {
            // Yes, this cert features RDNs encoded in reverse order
            if 0 == counter {
                assert_eq!(atav.oid.to_string(), "2.5.4.3");
                assert_eq!(
                    PrintableStringRef::try_from(&atav.value)
                        .unwrap()
                        .to_string(),
                    "Test Federal Bridge CA"
                );
            } else if 1 == counter {
                assert_eq!(atav.oid.to_string(), "2.5.4.11");
                assert_eq!(
                    PrintableStringRef::try_from(&atav.value)
                        .unwrap()
                        .to_string(),
                    "TestFPKI"
                );
            } else if 2 == counter {
                assert_eq!(atav.oid.to_string(), "2.5.4.10");
                assert_eq!(
                    PrintableStringRef::try_from(&atav.value)
                        .unwrap()
                        .to_string(),
                    "U.S. Government"
                );
            } else if 3 == counter {
                assert_eq!(atav.oid.to_string(), "2.5.4.6");
                assert_eq!(
                    PrintableStringRef::try_from(&atav.value)
                        .unwrap()
                        .to_string(),
                    "US"
                );
            }
            counter += 1;
        }
    }

    assert_eq!(
        cert.tbs_certificate
            .subject_public_key_info
            .algorithm
            .oid
            .to_string(),
        "1.2.840.113549.1.1.1"
    );
    assert_eq!(
        cert.tbs_certificate
            .subject_public_key_info
            .algorithm
            .parameters
            .as_ref()
            .unwrap()
            .tag(),
        Tag::Null
    );
    assert!(cert
        .tbs_certificate
        .subject_public_key_info
        .algorithm
        .parameters
        .as_ref()
        .unwrap()
        .is_null());

    // TODO - parse and compare public key

    let exts = cert.tbs_certificate.extensions.as_ref().unwrap();
    for (ext, (oid, crit)) in exts.iter().zip(EXTENSIONS) {
        assert_eq!(ext.extn_id.to_string(), *oid);
        assert_eq!(ext.critical, *crit);
    }

    assert_eq!(
        cert.signature_algorithm.oid.to_string(),
        "1.2.840.113549.1.1.11"
    );
    assert_eq!(
        cert.signature_algorithm.parameters.as_ref().unwrap().tag(),
        Tag::Null
    );
    assert!(cert
        .signature_algorithm
        .parameters
        .as_ref()
        .unwrap()
        .is_null());

    assert_eq!(
        &hex!("2A892F357BF3EF19E1211986106803FA18E66237802F1B1B0C6756CE678DB01D72CD0A4EB7171C2CDDF110ACD38AA65C35699E869C219AD7550AA4F287BB784F72EF8C9EA0E3DD103EFE5BF182EA36FFBCB45AAE65840263680534789C4F3215AF5454AD48CBC4B7A881E0135401A0BD5A849C11101DD1C66178E762C00DF59DD50F8DE9ED46FC6A0D742AE5697D87DD08DAC5291A75FB13C82FF2865C9E36799EA726137E1814E6A878C9532E8FC3D0A2A942D1CCC668FFCEAC255E6002FDE5ACDF2CE47556BB141C3A797A4BFDB673F6F1C229D7914FFEEF1505EE36F8038137D1B8F90106994BAB3E6FF0F60360A2E32F7A30B7ECEC1502DF3CC725BD6E436BA8F96A1847C9CEBB3F5A5906472292501D59BE1A98475BB1F30B677FAA8A45E351640C85B1B22661D33BD23EC6C0CA33DDD79E1120C7FC869EC4D0175ADB4A258AEAC5E8D2F0F578B8BF4B2C5DCC3269768AAA5B9E26D0592C5BB09C702C72E0A60F66D3EEB2B4983279634D59B0A2011B0E26AE796CC95D3243DF49615434E5CC06C374C3F936C005D360CAE6101F3AE7E97E29A157F5020770D4648D7877EBF8248CF3F3E68F9957A36F92D50616F2C60D3842327EF9BC0312CFF03A48C78E97254C2ADEADCA05069168443D833831FF66295A2EED685F164F1DBE01F8C897E1F63D42851682CBEE7B5A64D7BA2923D33644DBF1F7B3EDCE996F9928F043"),
        cert.signature.raw_bytes()
    );

    #[cfg(feature = "pem")]
    {
        let pem_encoded_cert =
            include_bytes!("examples/026EDA6FA1EDFA8C253936C75B5EEBD954BFF452.fake.pem");
        let result = Certificate::from_pem(pem_encoded_cert);
        let pem_cert: Certificate = result.unwrap();

        assert_eq!(pem_cert, cert);
    }
}

#[test]
fn decode_cert_negative_serial_number() {
    let der_encoded_cert = include_bytes!("examples/28903a635b5280fae6774c0b6da7d6baa64af2e8.der");

    let cert = Certificate::from_der(der_encoded_cert).unwrap();
    assert_eq!(
        cert.tbs_certificate.serial_number.as_bytes(),
        // INTEGER (125 bit) -2.370157924795571e+37
        &[238, 43, 61, 235, 212, 33, 222, 20, 168, 98, 172, 4, 243, 221, 196, 1]
    );

    let reencoded = cert.to_der().unwrap();
    assert_eq!(der_encoded_cert, reencoded.as_slice());
}

#[cfg(all(feature = "pem", feature = "hazmat"))]
#[test]
fn decode_cert_overlength_serial_number() {
    use der::{pem::LineEnding, DecodePem, EncodePem};
    use x509_cert::certificate::CertificateInner;

    let pem_encoded_cert = include_bytes!("examples/qualcomm.pem");

    assert!(Certificate::from_pem(pem_encoded_cert).is_err());

    let cert = CertificateInner::<x509_cert::certificate::Raw>::from_pem(pem_encoded_cert).unwrap();
    assert_eq!(
        cert.tbs_certificate.serial_number.as_bytes(),
        &[
            0, 132, 206, 11, 246, 160, 254, 130, 78, 229, 229, 6, 202, 168, 157, 120, 198, 21, 1,
            98, 87, 113
        ]
    );
    assert_eq!(cert.tbs_certificate.serial_number.as_bytes().len(), 22);

    let reencoded = cert.to_pem(LineEnding::LF).unwrap();
    assert_eq!(pem_encoded_cert, reencoded.as_bytes());
}

#[cfg(feature = "pem")]
#[test]
fn load_certificate_chains() {
    let pem_encoded_chain = include_bytes!("examples/crates.io-chain.pem");

    let chain = Certificate::load_pem_chain(pem_encoded_chain).expect("parse certificate chain");

    assert_eq!(chain.len(), 4, "4 certificates are expected in this chain");
}

#[cfg(feature = "arbitrary")]
#[test]
// Purpose of this check is to ensure the arbitraty trait is provided for certificate variants
#[allow(unused)]
fn certificate_arbitrary() {
    fn check_arbitrary<'a>(_arbitrary: impl arbitrary::Arbitrary<'a>) {}

    fn check_certificate(certificate: x509_cert::Certificate) {
        check_arbitrary(certificate);
    }

    #[cfg(feature = "hazmat")]
    fn check_raw_certificate(
        certificate: x509_cert::certificate::CertificateInner<x509_cert::certificate::Raw>,
    ) {
        check_arbitrary(certificate);
    }
}
