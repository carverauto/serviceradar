#![cfg(all(feature = "builder", feature = "pem"))]

use der::{asn1::PrintableString, pem::LineEnding, Decode, Encode, EncodePem};
use p256::{ecdsa::DerSignature, pkcs8::DecodePrivateKey, NistP256};
use rsa::pkcs1::DecodeRsaPrivateKey;
use rsa::pkcs1v15::SigningKey;
use sha2::Sha256;
use spki::SubjectPublicKeyInfoOwned;
use std::{str::FromStr, time::Duration};
use x509_cert::{
    builder::{Builder, CertificateBuilder, Profile, RequestBuilder},
    ext::pkix::{
        name::{DirectoryString, GeneralName},
        SubjectAltName,
    },
    name::Name,
    request,
    serial_number::SerialNumber,
    time::Validity,
};
use x509_cert_test_support::{openssl, zlint};

const RSA_2048_DER_EXAMPLE: &[u8] = include_bytes!("examples/rsa2048-pub.der");
const PKCS8_PUBLIC_KEY_DER: &[u8] = include_bytes!("examples/p256-pub.der");

#[test]
fn root_ca_certificate() {
    let serial_number = SerialNumber::from(42u32);
    let validity = Validity::from_now(Duration::new(5, 0)).unwrap();
    let profile = Profile::Root;
    let subject = Name::from_str("CN=World domination corporation,O=World domination Inc,C=US")
        .unwrap()
        .to_der()
        .unwrap();
    let subject = Name::from_der(&subject).unwrap();
    let pub_key =
        SubjectPublicKeyInfoOwned::try_from(RSA_2048_DER_EXAMPLE).expect("get rsa pub key");

    let signer = rsa_signer();
    let builder =
        CertificateBuilder::new(profile, serial_number, validity, subject, pub_key, &signer)
            .expect("Create certificate");

    let certificate = builder.build().unwrap();

    let pem = certificate.to_pem(LineEnding::LF).expect("generate pem");
    println!("{}", openssl::check_certificate(pem.as_bytes()));

    let ignored = &[];
    zlint::check_certificate(pem.as_bytes(), ignored);
}

#[test]
fn root_ca_certificate_ecdsa() {
    let serial_number = SerialNumber::from(42u32);
    let validity = Validity::from_now(Duration::new(5, 0)).unwrap();
    let profile = Profile::Root;
    let subject = Name::from_str("CN=World domination corporation,O=World domination Inc,C=US")
        .unwrap()
        .to_der()
        .unwrap();
    let subject = Name::from_der(&subject).unwrap();
    let pub_key =
        SubjectPublicKeyInfoOwned::try_from(PKCS8_PUBLIC_KEY_DER).expect("get ecdsa pub key");

    let signer = ecdsa_signer();
    let builder =
        CertificateBuilder::new(profile, serial_number, validity, subject, pub_key, &signer)
            .expect("Create certificate");

    let certificate = builder.build::<DerSignature>().unwrap();

    let pem = certificate.to_pem(LineEnding::LF).expect("generate pem");
    println!("{}", openssl::check_certificate(pem.as_bytes()));

    let ignored = &[];
    zlint::check_certificate(pem.as_bytes(), ignored);
}

#[test]
fn sub_ca_certificate() {
    let serial_number = SerialNumber::from(42u32);
    let validity = Validity::from_now(Duration::new(5, 0)).unwrap();

    let issuer =
        Name::from_str("CN=World domination corporation,O=World domination Inc,C=US").unwrap();
    let profile = Profile::SubCA {
        issuer,
        path_len_constraint: Some(0),
    };

    let subject =
        Name::from_str("CN=World domination task force,O=World domination Inc,C=US").unwrap();
    let pub_key =
        SubjectPublicKeyInfoOwned::try_from(RSA_2048_DER_EXAMPLE).expect("get rsa pub key");

    let signer = ecdsa_signer();
    let builder =
        CertificateBuilder::new(profile, serial_number, validity, subject, pub_key, &signer)
            .expect("Create certificate");

    let certificate = builder.build::<DerSignature>().unwrap();

    let pem = certificate.to_pem(LineEnding::LF).expect("generate pem");
    println!("{}", openssl::check_certificate(pem.as_bytes()));

    // TODO(baloo): not too sure we should tackle those in this API.
    let ignored = &[
        "w_sub_ca_aia_missing",
        "e_sub_ca_crl_distribution_points_missing",
        "e_sub_ca_certificate_policies_missing",
        "w_sub_ca_aia_does_not_contain_issuing_ca_url",
    ];

    zlint::check_certificate(pem.as_bytes(), ignored);
}

#[test]
fn leaf_certificate() {
    let serial_number = SerialNumber::from(42u32);
    let validity = Validity::from_now(Duration::new(5, 0)).unwrap();

    let issuer =
        Name::from_str("CN=World domination corporation,O=World domination Inc,C=US").unwrap();
    let profile = Profile::Leaf {
        issuer: issuer.clone(),
        enable_key_agreement: false,
        enable_key_encipherment: false,
        #[cfg(feature = "hazmat")]
        include_subject_key_identifier: true,
    };

    let subject = Name::from_str("CN=service.domination.world").unwrap();
    let pub_key =
        SubjectPublicKeyInfoOwned::try_from(RSA_2048_DER_EXAMPLE).expect("get rsa pub key");

    let signer = ecdsa_signer();
    let builder = CertificateBuilder::new(
        profile,
        serial_number.clone(),
        validity,
        subject.clone(),
        pub_key.clone(),
        &signer,
    )
    .expect("Create certificate");

    let certificate = builder.build::<DerSignature>().unwrap();

    let pem = certificate.to_pem(LineEnding::LF).expect("generate pem");
    println!("{}", openssl::check_certificate(pem.as_bytes()));

    // TODO(baloo): not too sure we should tackle those in this API.
    let ignored = vec![
        "e_sub_cert_aia_missing",
        "e_sub_cert_crl_distribution_points_missing",
        "w_sub_cert_aia_does_not_contain_issuing_ca_url",
        // Missing policies
        "e_sub_cert_certificate_policies_missing",
        "e_sub_cert_cert_policy_empty",
        // Needs to be added by the end-user
        "e_sub_cert_aia_does_not_contain_ocsp_url",
        // SAN needs to include DNS name (if used)
        "e_ext_san_missing",
        "e_subject_common_name_not_exactly_from_san",
        // Extended key usage needs to be added by end-user and is use-case dependent
        "e_sub_cert_eku_missing",
    ];

    zlint::check_certificate(pem.as_bytes(), &ignored);

    #[cfg(feature = "hazmat")]
    {
        let profile = Profile::Leaf {
            issuer,
            enable_key_agreement: false,
            enable_key_encipherment: false,
            include_subject_key_identifier: false,
        };
        let builder =
            CertificateBuilder::new(profile, serial_number, validity, subject, pub_key, &signer)
                .expect("Create certificate");

        let certificate = builder.build::<DerSignature>().unwrap();

        let pem = certificate.to_pem(LineEnding::LF).expect("generate pem");
        println!("{}", openssl::check_certificate(pem.as_bytes()));

        // Ignore warning about leaf not having SKI extension (this is a warning not a fail, as
        // denoted by the `w_` prefix.
        let mut ignored = ignored;
        ignored.push("w_ext_subject_key_identifier_missing_sub_cert");
        zlint::check_certificate(pem.as_bytes(), &ignored);
    }
}

#[test]
fn pss_certificate() {
    let serial_number = SerialNumber::from(42u32);
    let validity = Validity::from_now(Duration::new(5, 0)).unwrap();

    let issuer =
        Name::from_str("CN=World domination corporation,O=World domination Inc,C=US").unwrap();
    let profile = Profile::Leaf {
        issuer,
        enable_key_agreement: false,
        enable_key_encipherment: false,
        #[cfg(feature = "hazmat")]
        include_subject_key_identifier: true,
    };

    let subject = Name::from_str("CN=service.domination.world").unwrap();
    let pub_key =
        SubjectPublicKeyInfoOwned::try_from(RSA_2048_DER_EXAMPLE).expect("get rsa pub key");

    let signer = rsa_pss_signer();
    let builder =
        CertificateBuilder::new(profile, serial_number, validity, subject, pub_key, &signer)
            .expect("Create certificate");

    let certificate = builder
        .build_with_rng::<rsa::pss::Signature>(&mut rand::thread_rng())
        .unwrap();

    let pem = certificate.to_pem(LineEnding::LF).expect("generate pem");
    println!("{}", openssl::check_certificate(pem.as_bytes()));

    // TODO(baloo): not too sure we should tackle those in this API.
    let ignored = &[
        "e_sub_cert_aia_missing",
        "e_sub_cert_crl_distribution_points_missing",
        "w_sub_cert_aia_does_not_contain_issuing_ca_url",
        // Missing policies
        "e_sub_cert_certificate_policies_missing",
        "e_sub_cert_cert_policy_empty",
        // Needs to be added by the end-user
        "e_sub_cert_aia_does_not_contain_ocsp_url",
        // SAN needs to include DNS name (if used)
        "e_ext_san_missing",
        "e_subject_common_name_not_exactly_from_san",
        // Extended key usage needs to be added by end-user and is use-case dependent
        "e_sub_cert_eku_missing",
        // zlint warns on RSAPSS signature algorithms
        "e_signature_algorithm_not_supported",
    ];

    zlint::check_certificate(pem.as_bytes(), ignored);
}

const RSA_2048_PRIV_DER_EXAMPLE: &[u8] = include_bytes!("examples/rsa2048-priv.der");

fn rsa_signer() -> SigningKey<Sha256> {
    let private_key = rsa::RsaPrivateKey::from_pkcs1_der(RSA_2048_PRIV_DER_EXAMPLE).unwrap();
    SigningKey::<Sha256>::new(private_key)
}

fn rsa_pss_signer() -> rsa::pss::SigningKey<Sha256> {
    let private_key = rsa::RsaPrivateKey::from_pkcs1_der(RSA_2048_PRIV_DER_EXAMPLE).unwrap();
    rsa::pss::SigningKey::<Sha256>::new(private_key)
}

const PKCS8_PRIVATE_KEY_DER: &[u8] = include_bytes!("examples/p256-priv.der");

fn ecdsa_signer() -> ecdsa::SigningKey<NistP256> {
    let secret_key = p256::SecretKey::from_pkcs8_der(PKCS8_PRIVATE_KEY_DER).unwrap();
    ecdsa::SigningKey::from(secret_key)
}

#[test]
fn certificate_request() {
    use std::net::{IpAddr, Ipv4Addr};
    let subject = Name::from_str("CN=service.domination.world").unwrap();

    let signer = ecdsa_signer();
    let mut builder = RequestBuilder::new(subject, &signer).expect("Create certificate request");
    builder
        .add_extension(&SubjectAltName(vec![GeneralName::from(IpAddr::V4(
            Ipv4Addr::new(192, 0, 2, 0),
        ))]))
        .unwrap();

    let cert_req = builder.build::<DerSignature>().unwrap();
    let pem = cert_req.to_pem(LineEnding::LF).expect("generate pem");
    use std::fs::File;
    use std::io::Write;
    let mut file = File::create("/tmp/ecdsa.csr").expect("create pem file");
    file.write_all(pem.as_bytes()).expect("Create pem file");
    println!("{}", openssl::check_request(pem.as_bytes()));
}

#[test]
fn certificate_request_attributes() {
    let subject = Name::from_str("CN=service.domination.world").unwrap();

    let signer = ecdsa_signer();
    let mut builder = RequestBuilder::new(subject, &signer).expect("Create certificate request");
    builder
        .add_attribute(&request::attributes::ChallengePassword(
            DirectoryString::PrintableString(
                PrintableString::new(b"password1234")
                    .expect("create printable string with password"),
            ),
        ))
        .expect("unable to add attribute");

    let cert_req = builder.build::<DerSignature>().unwrap();
    let pem = cert_req.to_pem(LineEnding::LF).expect("generate pem");
    use std::fs::File;
    use std::io::Write;
    let mut file = File::create("/tmp/ecdsa.csr").expect("create pem file");
    file.write_all(pem.as_bytes()).expect("Create pem file");
    println!("{}", openssl::check_request(pem.as_bytes()));
}
