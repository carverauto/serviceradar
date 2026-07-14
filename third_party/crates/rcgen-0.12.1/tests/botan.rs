#![cfg(feature = "x509-parser")]

use rcgen::DnValue;
use rcgen::{BasicConstraints, Certificate, CertificateParams, DnType, IsCa};
use rcgen::{
	CertificateRevocationList, CertificateRevocationListParams, RevocationReason, RevokedCertParams,
};
use rcgen::{KeyUsagePurpose, SerialNumber};
use time::{Duration, OffsetDateTime};

mod util;

fn default_params() -> CertificateParams {
	let mut params = util::default_params();
	// Botan has a sanity check that enforces a maximum expiration date
	params.not_after = rcgen::date_time_ymd(3016, 1, 1);
	params
}

fn check_cert(cert_der: &[u8], cert: &Certificate) {
	println!("{}", cert.serialize_pem().unwrap());
	check_cert_ca(cert_der, cert, cert_der);
}

fn check_cert_ca(cert_der: &[u8], _cert: &Certificate, ca_der: &[u8]) {
	println!(
		"botan version: {}",
		botan::Version::current().unwrap().string
	);
	let trust_anchor = botan::Certificate::load(ca_der).unwrap();
	let end_entity_cert = botan::Certificate::load(cert_der).unwrap();

	// Set time to Jan 10, 2004
	const REFERENCE_TIME: Option<u64> = Some(0x40_00_00_00);

	// Verify the certificate
	end_entity_cert
		.verify(
			&[],
			&[&trust_anchor],
			None,
			Some("crabs.crabs"),
			REFERENCE_TIME,
		)
		.unwrap();

	// TODO perform a full handshake
}

#[test]
fn test_botan() {
	let params = default_params();
	let cert = Certificate::from_params(params).unwrap();

	// Now verify the certificate.
	let cert_der = cert.serialize_der().unwrap();

	check_cert(&cert_der, &cert);
}

#[test]
fn test_botan_256() {
	let mut params = default_params();
	params.alg = &rcgen::PKCS_ECDSA_P256_SHA256;

	let cert = Certificate::from_params(params).unwrap();

	// Now verify the certificate.
	let cert_der = cert.serialize_der().unwrap();

	check_cert(&cert_der, &cert);
}

#[test]
fn test_botan_384() {
	let mut params = default_params();
	params.alg = &rcgen::PKCS_ECDSA_P384_SHA384;

	let cert = Certificate::from_params(params).unwrap();

	// Now verify the certificate.
	let cert_der = cert.serialize_der().unwrap();

	check_cert(&cert_der, &cert);
}

#[test]
fn test_botan_25519() {
	let mut params = default_params();
	params.alg = &rcgen::PKCS_ED25519;

	let cert = Certificate::from_params(params).unwrap();

	// Now verify the certificate.
	let cert_der = cert.serialize_der().unwrap();

	check_cert(&cert_der, &cert);
}

#[test]
fn test_botan_25519_v1_given() {
	let mut params = default_params();
	params.alg = &rcgen::PKCS_ED25519;

	let kp = rcgen::KeyPair::from_pem(util::ED25519_TEST_KEY_PAIR_PEM_V1).unwrap();
	params.key_pair = Some(kp);

	let cert = Certificate::from_params(params).unwrap();

	// Now verify the certificate.
	let cert_der = cert.serialize_der().unwrap();

	check_cert(&cert_der, &cert);
}

#[test]
fn test_botan_25519_v2_given() {
	let mut params = default_params();
	params.alg = &rcgen::PKCS_ED25519;

	let kp = rcgen::KeyPair::from_pem(util::ED25519_TEST_KEY_PAIR_PEM_V2).unwrap();
	params.key_pair = Some(kp);

	let cert = Certificate::from_params(params).unwrap();

	// Now verify the certificate.
	let cert_der = cert.serialize_der().unwrap();

	check_cert(&cert_der, &cert);
}

#[test]
fn test_botan_rsa_given() {
	let mut params = default_params();
	params.alg = &rcgen::PKCS_RSA_SHA256;

	let kp = rcgen::KeyPair::from_pem(util::RSA_TEST_KEY_PAIR_PEM).unwrap();
	params.key_pair = Some(kp);

	let cert = Certificate::from_params(params).unwrap();

	// Now verify the certificate.
	let cert_der = cert.serialize_der().unwrap();

	check_cert(&cert_der, &cert);
}

#[test]
fn test_botan_separate_ca() {
	let mut params = default_params();
	params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
	let ca_cert = Certificate::from_params(params).unwrap();

	let ca_der = ca_cert.serialize_der().unwrap();

	let mut params = CertificateParams::new(vec!["crabs.crabs".to_string()]);
	params
		.distinguished_name
		.push(DnType::OrganizationName, "Crab widgits SE");
	params
		.distinguished_name
		.push(DnType::CommonName, "Dev domain");
	// Botan has a sanity check that enforces a maximum expiration date
	params.not_after = rcgen::date_time_ymd(3016, 1, 1);

	let cert = Certificate::from_params(params).unwrap();
	let cert_der = cert.serialize_der_with_signer(&ca_cert).unwrap();

	check_cert_ca(&cert_der, &cert, &ca_der);
}

#[cfg(feature = "x509-parser")]
#[test]
fn test_botan_imported_ca() {
	use std::convert::TryInto;
	let mut params = default_params();
	params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
	let ca_cert = Certificate::from_params(params).unwrap();

	let (ca_cert_der, ca_key_der) = (
		ca_cert.serialize_der().unwrap(),
		ca_cert.serialize_private_key_der(),
	);

	let ca_key_pair = ca_key_der.as_slice().try_into().unwrap();
	let imported_ca_cert_params =
		CertificateParams::from_ca_cert_der(ca_cert_der.as_slice(), ca_key_pair).unwrap();
	let imported_ca_cert = Certificate::from_params(imported_ca_cert_params).unwrap();

	let mut params = CertificateParams::new(vec!["crabs.crabs".to_string()]);
	params
		.distinguished_name
		.push(DnType::OrganizationName, "Crab widgits SE");
	params
		.distinguished_name
		.push(DnType::CommonName, "Dev domain");
	// Botan has a sanity check that enforces a maximum expiration date
	params.not_after = rcgen::date_time_ymd(3016, 1, 1);
	let cert = Certificate::from_params(params).unwrap();
	let cert_der = cert.serialize_der_with_signer(&imported_ca_cert).unwrap();

	check_cert_ca(&cert_der, &cert, &ca_cert_der);
}

#[cfg(feature = "x509-parser")]
#[test]
fn test_botan_imported_ca_with_printable_string() {
	use std::convert::TryInto;
	let mut params = default_params();
	params.distinguished_name.push(
		DnType::CountryName,
		DnValue::PrintableString("US".to_string()),
	);
	params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
	let ca_cert = Certificate::from_params(params).unwrap();

	let (ca_cert_der, ca_key_der) = (
		ca_cert.serialize_der().unwrap(),
		ca_cert.serialize_private_key_der(),
	);

	let ca_key_pair = ca_key_der.as_slice().try_into().unwrap();
	let imported_ca_cert_params =
		CertificateParams::from_ca_cert_der(ca_cert_der.as_slice(), ca_key_pair).unwrap();
	let imported_ca_cert = Certificate::from_params(imported_ca_cert_params).unwrap();

	let mut params = CertificateParams::new(vec!["crabs.crabs".to_string()]);
	params
		.distinguished_name
		.push(DnType::OrganizationName, "Crab widgits SE");
	params
		.distinguished_name
		.push(DnType::CommonName, "Dev domain");
	// Botan has a sanity check that enforces a maximum expiration date
	params.not_after = rcgen::date_time_ymd(3016, 1, 1);
	let cert = Certificate::from_params(params).unwrap();
	let cert_der = cert.serialize_der_with_signer(&imported_ca_cert).unwrap();

	check_cert_ca(&cert_der, &cert, &ca_cert_der);
}

#[test]
fn test_botan_crl_parse() {
	// Create an issuer CA.
	let alg = &rcgen::PKCS_ECDSA_P256_SHA256;
	let mut issuer = util::default_params();
	issuer.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
	issuer.key_usages = vec![
		KeyUsagePurpose::KeyCertSign,
		KeyUsagePurpose::DigitalSignature,
		KeyUsagePurpose::CrlSign,
	];
	issuer.alg = alg;
	let issuer = Certificate::from_params(issuer).unwrap();

	// Create an end entity cert issued by the issuer.
	let mut ee = util::default_params();
	ee.alg = alg;
	ee.is_ca = IsCa::NoCa;
	ee.serial_number = Some(SerialNumber::from(99999));
	// Botan has a sanity check that enforces a maximum expiration date
	ee.not_after = rcgen::date_time_ymd(3016, 1, 1);
	let ee = Certificate::from_params(ee).unwrap();
	let ee_der = ee.serialize_der_with_signer(&issuer).unwrap();
	let botan_ee = botan::Certificate::load(ee_der.as_ref()).unwrap();

	// Generate a CRL with the issuer that revokes the EE cert.
	let now = OffsetDateTime::now_utc();
	let crl = CertificateRevocationListParams {
		this_update: now,
		next_update: now + Duration::weeks(1),
		crl_number: rcgen::SerialNumber::from(1234),
		issuing_distribution_point: None,
		revoked_certs: vec![RevokedCertParams {
			serial_number: ee.get_params().serial_number.clone().unwrap(),
			revocation_time: now,
			reason_code: Some(RevocationReason::KeyCompromise),
			invalidity_date: None,
		}],
		key_identifier_method: rcgen::KeyIdMethod::Sha256,
		alg,
	};
	let crl = CertificateRevocationList::from_params(crl).unwrap();

	// Serialize to both DER and PEM.
	let crl_der = crl.serialize_der_with_signer(&issuer).unwrap();
	let crl_pem = crl.serialize_pem_with_signer(&issuer).unwrap();

	// We should be able to load the CRL in both serializations.
	botan::CRL::load(crl_pem.as_ref()).unwrap();
	let crl = botan::CRL::load(crl_der.as_ref()).unwrap();

	// We should find the EE cert revoked.
	assert!(crl.is_revoked(&botan_ee).unwrap());
}
