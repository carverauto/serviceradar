use rcgen::{
	BasicConstraints, Certificate, CertificateParams, DnType, Error, IsCa, KeyPair, RemoteKeyPair,
};
use rcgen::{
	CertificateRevocationList, CertificateRevocationListParams, RevocationReason, RevokedCertParams,
};
#[cfg(feature = "x509-parser")]
use rcgen::{CertificateSigningRequest, DnValue};
use rcgen::{ExtendedKeyUsagePurpose, KeyUsagePurpose, SerialNumber};
use webpki::SignatureAlgorithm;
use webpki::{
	BorrowedCertRevocationList, CertRevocationList, EndEntityCert, KeyUsage, TrustAnchor,
};
use webpki::{DnsNameRef, Time};

use ring::rand::SystemRandom;
use ring::signature::{self, EcdsaKeyPair, EcdsaSigningAlgorithm, Ed25519KeyPair, KeyPair as _};
#[cfg(feature = "pem")]
use ring::signature::{RsaEncoding, RsaKeyPair};

use std::convert::TryFrom;
use time::{Duration, OffsetDateTime};

mod util;

fn sign_msg_ecdsa(cert: &Certificate, msg: &[u8], alg: &'static EcdsaSigningAlgorithm) -> Vec<u8> {
	let pk_der = cert.serialize_private_key_der();
	let key_pair =
		EcdsaKeyPair::from_pkcs8(alg, &pk_der, &ring::rand::SystemRandom::new()).unwrap();
	let system_random = SystemRandom::new();
	let signature = key_pair.sign(&system_random, msg).unwrap();
	signature.as_ref().to_vec()
}

fn sign_msg_ed25519(cert: &Certificate, msg: &[u8]) -> Vec<u8> {
	let pk_der = cert.serialize_private_key_der();
	let key_pair = Ed25519KeyPair::from_pkcs8_maybe_unchecked(&pk_der).unwrap();
	let signature = key_pair.sign(msg);
	signature.as_ref().to_vec()
}

#[cfg(feature = "pem")]
fn sign_msg_rsa(cert: &Certificate, msg: &[u8], encoding: &'static dyn RsaEncoding) -> Vec<u8> {
	let pk_der = cert.serialize_private_key_der();
	let key_pair = RsaKeyPair::from_pkcs8(&pk_der).unwrap();
	let system_random = SystemRandom::new();
	let mut signature = vec![0; key_pair.public().modulus_len()];
	key_pair
		.sign(encoding, &system_random, msg, &mut signature)
		.unwrap();
	signature
}

fn check_cert<'a, 'b>(
	cert_der: &[u8],
	cert: &'a Certificate,
	alg: &SignatureAlgorithm,
	sign_fn: impl FnOnce(&'a Certificate, &'b [u8]) -> Vec<u8>,
) {
	#[cfg(feature = "pem")]
	{
		println!("{}", cert.serialize_pem().unwrap());
	}
	check_cert_ca(cert_der, cert, cert_der, alg, alg, sign_fn);
}

fn check_cert_ca<'a, 'b>(
	cert_der: &[u8],
	cert: &'a Certificate,
	ca_der: &[u8],
	cert_alg: &SignatureAlgorithm,
	ca_alg: &SignatureAlgorithm,
	sign_fn: impl FnOnce(&'a Certificate, &'b [u8]) -> Vec<u8>,
) {
	let trust_anchor = TrustAnchor::try_from_cert_der(ca_der).unwrap();
	let trust_anchor_list = &[trust_anchor];
	let end_entity_cert = EndEntityCert::try_from(cert_der).unwrap();

	// Set time to Jan 10, 2004
	let time = Time::from_seconds_since_unix_epoch(0x40_00_00_00);

	// (1/3) Check whether the cert is valid
	end_entity_cert
		.verify_for_usage(
			&[cert_alg, ca_alg],
			&trust_anchor_list[..],
			&[],
			time,
			KeyUsage::server_auth(),
			&[],
		)
		.expect("valid TLS server cert");

	// (2/3) Check that the cert is valid for the given DNS name
	let dns_name = DnsNameRef::try_from_ascii_str("crabs.crabs").unwrap();
	end_entity_cert
		.verify_is_valid_for_subject_name(webpki::SubjectNameRef::from(dns_name))
		.expect("valid for DNS name");

	// (3/3) Check that a message signed by the cert is valid.
	let msg = b"Hello, World! This message is signed.";
	let signature = sign_fn(cert, msg);
	end_entity_cert
		.verify_signature(cert_alg, msg, &signature)
		.expect("signature is valid");
}

#[test]
fn test_webpki() {
	let params = util::default_params();
	let cert = Certificate::from_params(params).unwrap();

	// Now verify the certificate.
	let cert_der = cert.serialize_der().unwrap();

	let sign_fn = |cert, msg| sign_msg_ecdsa(cert, msg, &signature::ECDSA_P256_SHA256_ASN1_SIGNING);
	check_cert(&cert_der, &cert, &webpki::ECDSA_P256_SHA256, sign_fn);
}

#[test]
fn test_webpki_256() {
	let mut params = util::default_params();
	params.alg = &rcgen::PKCS_ECDSA_P256_SHA256;

	let cert = Certificate::from_params(params).unwrap();

	// Now verify the certificate.
	let cert_der = cert.serialize_der().unwrap();

	let sign_fn = |cert, msg| sign_msg_ecdsa(cert, msg, &signature::ECDSA_P256_SHA256_ASN1_SIGNING);
	check_cert(&cert_der, &cert, &webpki::ECDSA_P256_SHA256, sign_fn);
}

#[test]
fn test_webpki_384() {
	let mut params = util::default_params();
	params.alg = &rcgen::PKCS_ECDSA_P384_SHA384;

	let cert = Certificate::from_params(params).unwrap();

	// Now verify the certificate.
	let cert_der = cert.serialize_der().unwrap();

	let sign_fn = |cert, msg| sign_msg_ecdsa(cert, msg, &signature::ECDSA_P384_SHA384_ASN1_SIGNING);
	check_cert(&cert_der, &cert, &webpki::ECDSA_P384_SHA384, sign_fn);
}

#[test]
fn test_webpki_25519() {
	let mut params = util::default_params();
	params.alg = &rcgen::PKCS_ED25519;

	let cert = Certificate::from_params(params).unwrap();

	// Now verify the certificate.
	let cert_der = cert.serialize_der().unwrap();

	check_cert(&cert_der, &cert, &webpki::ED25519, sign_msg_ed25519);
}

#[cfg(feature = "pem")]
#[test]
fn test_webpki_25519_v1_given() {
	let mut params = util::default_params();
	params.alg = &rcgen::PKCS_ED25519;

	let kp = rcgen::KeyPair::from_pem(util::ED25519_TEST_KEY_PAIR_PEM_V1).unwrap();
	params.key_pair = Some(kp);

	let cert = Certificate::from_params(params).unwrap();

	// Now verify the certificate.
	let cert_der = cert.serialize_der().unwrap();

	check_cert(&cert_der, &cert, &webpki::ED25519, sign_msg_ed25519);
}

#[cfg(feature = "pem")]
#[test]
fn test_webpki_25519_v2_given() {
	let mut params = util::default_params();
	params.alg = &rcgen::PKCS_ED25519;

	let kp = rcgen::KeyPair::from_pem(util::ED25519_TEST_KEY_PAIR_PEM_V2).unwrap();
	params.key_pair = Some(kp);

	let cert = Certificate::from_params(params).unwrap();

	// Now verify the certificate.
	let cert_der = cert.serialize_der().unwrap();

	check_cert(&cert_der, &cert, &webpki::ED25519, sign_msg_ed25519);
}

#[cfg(feature = "pem")]
#[test]
fn test_webpki_rsa_given() {
	let mut params = util::default_params();
	params.alg = &rcgen::PKCS_RSA_SHA256;

	let kp = rcgen::KeyPair::from_pem(util::RSA_TEST_KEY_PAIR_PEM).unwrap();
	params.key_pair = Some(kp);

	let cert = Certificate::from_params(params).unwrap();

	// Now verify the certificate.
	let cert_der = cert.serialize_der().unwrap();

	check_cert(
		&cert_der,
		&cert,
		&webpki::RSA_PKCS1_2048_8192_SHA256,
		|msg, cert| sign_msg_rsa(msg, cert, &signature::RSA_PKCS1_SHA256),
	);
}

#[cfg(feature = "pem")]
#[test]
fn test_webpki_rsa_combinations_given() {
	let configs: &[(_, _, &'static dyn signature::RsaEncoding)] = &[
		(
			&rcgen::PKCS_RSA_SHA256,
			&webpki::RSA_PKCS1_2048_8192_SHA256,
			&signature::RSA_PKCS1_SHA256,
		),
		(
			&rcgen::PKCS_RSA_SHA384,
			&webpki::RSA_PKCS1_2048_8192_SHA384,
			&signature::RSA_PKCS1_SHA384,
		),
		(
			&rcgen::PKCS_RSA_SHA512,
			&webpki::RSA_PKCS1_2048_8192_SHA512,
			&signature::RSA_PKCS1_SHA512,
		),
		//(&rcgen::PKCS_RSA_PSS_SHA256, &webpki::RSA_PSS_2048_8192_SHA256_LEGACY_KEY, &signature::RSA_PSS_SHA256),
	];
	for c in configs {
		let mut params = util::default_params();
		params.alg = c.0;
		let kp = rcgen::KeyPair::from_pem_and_sign_algo(util::RSA_TEST_KEY_PAIR_PEM, c.0).unwrap();
		params.key_pair = Some(kp);

		let cert = Certificate::from_params(params).unwrap();

		// Now verify the certificate.
		let cert_der = cert.serialize_der().unwrap();

		check_cert(&cert_der, &cert, c.1, |msg, cert| {
			sign_msg_rsa(msg, cert, c.2)
		});
	}
}

#[test]
fn test_webpki_separate_ca() {
	let mut params = util::default_params();
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

	let cert = Certificate::from_params(params).unwrap();
	let cert_der = cert.serialize_der_with_signer(&ca_cert).unwrap();

	let sign_fn = |cert, msg| sign_msg_ecdsa(cert, msg, &signature::ECDSA_P256_SHA256_ASN1_SIGNING);
	check_cert_ca(
		&cert_der,
		&cert,
		&ca_der,
		&webpki::ECDSA_P256_SHA256,
		&webpki::ECDSA_P256_SHA256,
		sign_fn,
	);
}

#[test]
fn test_webpki_separate_ca_with_other_signing_alg() {
	let mut params = util::default_params();
	params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
	params.alg = &rcgen::PKCS_ECDSA_P256_SHA256;
	let ca_cert = Certificate::from_params(params).unwrap();

	let ca_der = ca_cert.serialize_der().unwrap();

	let mut params = CertificateParams::new(vec!["crabs.crabs".to_string()]);
	params.alg = &rcgen::PKCS_ED25519;
	params
		.distinguished_name
		.push(DnType::OrganizationName, "Crab widgits SE");
	params
		.distinguished_name
		.push(DnType::CommonName, "Dev domain");

	let cert = Certificate::from_params(params).unwrap();
	let cert_der = cert.serialize_der_with_signer(&ca_cert).unwrap();

	check_cert_ca(
		&cert_der,
		&cert,
		&ca_der,
		&webpki::ED25519,
		&webpki::ECDSA_P256_SHA256,
		sign_msg_ed25519,
	);
}

#[test]
fn from_remote() {
	struct Remote(EcdsaKeyPair);

	impl RemoteKeyPair for Remote {
		fn public_key(&self) -> &[u8] {
			self.0.public_key().as_ref()
		}

		fn sign(&self, msg: &[u8]) -> Result<Vec<u8>, rcgen::Error> {
			let system_random = SystemRandom::new();
			self.0
				.sign(&system_random, msg)
				.map(|s| s.as_ref().to_owned())
				.map_err(|_| Error::RingUnspecified)
		}

		fn algorithm(&self) -> &'static rcgen::SignatureAlgorithm {
			&rcgen::PKCS_ECDSA_P256_SHA256
		}
	}

	let rng = ring::rand::SystemRandom::new();
	let key_pair = KeyPair::generate(&rcgen::PKCS_ECDSA_P256_SHA256).unwrap();
	let remote = EcdsaKeyPair::from_pkcs8(
		&signature::ECDSA_P256_SHA256_ASN1_SIGNING,
		&key_pair.serialize_der(),
		&rng,
	)
	.unwrap();
	let key_pair = EcdsaKeyPair::from_pkcs8(
		&signature::ECDSA_P256_SHA256_ASN1_SIGNING,
		&key_pair.serialize_der(),
		&rng,
	)
	.unwrap();
	let remote = KeyPair::from_remote(Box::new(Remote(remote))).unwrap();

	let mut params = util::default_params();
	params.alg = &rcgen::PKCS_ECDSA_P256_SHA256;
	params.key_pair = Some(remote);
	let cert = Certificate::from_params(params).unwrap();

	// Now verify the certificate.
	let cert_der = cert.serialize_der().unwrap();

	let sign_fn = move |_, msg| {
		let system_random = SystemRandom::new();
		let signature = key_pair.sign(&system_random, msg).unwrap();
		signature.as_ref().to_vec()
	};
	check_cert(&cert_der, &cert, &webpki::ECDSA_P256_SHA256, sign_fn);
}

/*
// TODO https://github.com/briansmith/webpki/issues/134
// TODO https://github.com/briansmith/webpki/issues/135
#[test]
fn test_webpki_separate_ca_name_constraints() {
	let mut params = util::default_params();
	params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
	params.name_constraints = Some(NameConstraints {
		// TODO also add a test with non-empty permitted_subtrees that
		// doesn't contain a DirectoryName entry. This isn't possible
		// currently due to a limitation of webpki.
		permitted_subtrees : vec![GeneralSubtree::DnsName("dev".to_string()), GeneralSubtree::DirectoryName(rcgen::DistinguishedName::new())],
		//permitted_subtrees : vec![GeneralSubtree::DnsName("dev".to_string())],
		//permitted_subtrees : Vec::new(),
		//excluded_subtrees : vec![GeneralSubtree::DnsName("v".to_string())],
		excluded_subtrees : Vec::new(),
	});

	let ca_cert = Certificate::from_params(params).unwrap();
	println!("{}", ca_cert.serialize_pem().unwrap());

	let ca_der = ca_cert.serialize_der().unwrap();

	let mut params = CertificateParams::new(vec!["crabs.dev".to_string()]);
	params.distinguished_name = rcgen::DistinguishedName::new();
	//params.distinguished_name.push(DnType::OrganizationName, "Crab widgits SE");
	//params.distinguished_name.push(DnType::CommonName, "Dev domain");
	let cert = Certificate::from_params(params).unwrap();
	let cert_der = cert.serialize_der_with_signer(&ca_cert).unwrap();
	println!("{}", cert.serialize_pem_with_signer(&ca_cert).unwrap());

	let sign_fn = |cert, msg| sign_msg_ecdsa(cert, msg,
		&signature::ECDSA_P256_SHA256_ASN1_SIGNING);
	check_cert_ca(&cert_der, &cert, &ca_der,
		&webpki::ECDSA_P256_SHA256, &webpki::ECDSA_P256_SHA256, sign_fn);
}
*/

#[cfg(feature = "x509-parser")]
#[test]
fn test_webpki_imported_ca() {
	use std::convert::TryInto;
	let mut params = util::default_params();
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
	let cert = Certificate::from_params(params).unwrap();
	let cert_der = cert.serialize_der_with_signer(&imported_ca_cert).unwrap();

	let sign_fn = |cert, msg| sign_msg_ecdsa(cert, msg, &signature::ECDSA_P256_SHA256_ASN1_SIGNING);
	check_cert_ca(
		&cert_der,
		&cert,
		&ca_cert_der,
		&webpki::ECDSA_P256_SHA256,
		&webpki::ECDSA_P256_SHA256,
		sign_fn,
	);
}

#[cfg(feature = "x509-parser")]
#[test]
fn test_webpki_imported_ca_with_printable_string() {
	use std::convert::TryInto;
	let mut params = util::default_params();
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
	let cert = Certificate::from_params(params).unwrap();
	let cert_der = cert.serialize_der_with_signer(&imported_ca_cert).unwrap();

	let sign_fn = |cert, msg| sign_msg_ecdsa(cert, msg, &signature::ECDSA_P256_SHA256_ASN1_SIGNING);
	check_cert_ca(
		&cert_der,
		&cert,
		&ca_cert_der,
		&webpki::ECDSA_P256_SHA256,
		&webpki::ECDSA_P256_SHA256,
		sign_fn,
	);
}

#[cfg(feature = "x509-parser")]
#[test]
fn test_certificate_from_csr() {
	let mut params = CertificateParams::new(vec!["crabs.crabs".to_string()]);
	params
		.distinguished_name
		.push(DnType::OrganizationName, "Crab widgits SE");
	params
		.distinguished_name
		.push(DnType::CommonName, "Dev domain");
	let cert = Certificate::from_params(params).unwrap();
	let csr_der = cert.serialize_request_der().unwrap();
	let csr = CertificateSigningRequest::from_der(&csr_der).unwrap();

	let mut params = util::default_params();
	params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
	let ca_cert = Certificate::from_params(params).unwrap();
	let ca_cert_der = ca_cert.serialize_der().unwrap();
	let cert_der = csr.serialize_der_with_signer(&ca_cert).unwrap();

	let sign_fn = |cert, msg| sign_msg_ecdsa(cert, msg, &signature::ECDSA_P256_SHA256_ASN1_SIGNING);
	check_cert_ca(
		&cert_der,
		&cert,
		&ca_cert_der,
		&webpki::ECDSA_P256_SHA256,
		&webpki::ECDSA_P256_SHA256,
		sign_fn,
	);
}

#[test]
fn test_webpki_serial_number() {
	let mut params = util::default_params();
	params.serial_number = Some(vec![0, 1, 2].into());
	let cert = Certificate::from_params(params).unwrap();

	// Now verify the certificate.
	let cert_der = cert.serialize_der().unwrap();

	let sign_fn = |cert, msg| sign_msg_ecdsa(cert, msg, &signature::ECDSA_P256_SHA256_ASN1_SIGNING);
	check_cert(&cert_der, &cert, &webpki::ECDSA_P256_SHA256, sign_fn);
}

#[test]
fn test_webpki_crl_parse() {
	// Create a CRL with one revoked cert, and an issuer to sign the CRL.
	let (crl, issuer) = util::test_crl();
	let revoked_cert = crl.get_params().revoked_certs.first().unwrap();

	// Serialize the CRL signed by the issuer to DER.
	let der = crl.serialize_der_with_signer(&issuer).unwrap();

	// We should be able to parse the CRL DER without error.
	let webpki_crl = BorrowedCertRevocationList::from_der(&der).expect("failed to parse CRL DER");

	// Webpki represents certificate SPKIs internally without the outer SEQUENCE.
	// We remove that here before calling verify_signature.
	let issuer_spki = issuer.get_key_pair().public_key_der();
	let raw_spki = yasna::parse_der(&issuer_spki, |reader| reader.read_tagged_der()).unwrap();

	// We should be able to verify the CRL signature with the issuer's raw SPKI.
	webpki_crl
		.verify_signature(&[&webpki::ECDSA_P256_SHA256], raw_spki.value())
		.expect("failed to validate CRL signature");

	// We should be able to find the revoked cert with the expected properties.
	let webpki_revoked_cert = webpki_crl
		.find_serial(revoked_cert.serial_number.as_ref())
		.expect("failed to parse revoked certs in CRL")
		.expect("failed to find expected revoked cert in CRL");
	assert_eq!(
		webpki_revoked_cert.serial_number,
		revoked_cert.serial_number.as_ref()
	);
	assert_eq!(
		webpki_revoked_cert.reason_code.unwrap() as u64,
		revoked_cert.reason_code.unwrap() as u64
	);
	assert_eq!(
		webpki_revoked_cert.revocation_date,
		Time::from_seconds_since_unix_epoch(revoked_cert.revocation_time.unix_timestamp() as u64)
	);
}

#[test]
fn test_webpki_crl_revoke() {
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
	let issuer_der = issuer.serialize_der().unwrap();

	// Create an end entity cert issued by the issuer.
	let mut ee = util::default_params();
	ee.is_ca = IsCa::NoCa;
	ee.extended_key_usages = vec![ExtendedKeyUsagePurpose::ClientAuth];
	ee.alg = alg;
	ee.serial_number = Some(SerialNumber::from(99999));
	let ee = Certificate::from_params(ee).unwrap();
	let ee_der = ee.serialize_der_with_signer(&issuer).unwrap();

	// Set up webpki's verification requirements.
	let trust_anchor = TrustAnchor::try_from_cert_der(issuer_der.as_ref()).unwrap();
	let trust_anchor_list = &[trust_anchor];
	let end_entity_cert = EndEntityCert::try_from(ee_der.as_ref()).unwrap();
	let unix_time = 0x40_00_00_00;
	let time = Time::from_seconds_since_unix_epoch(unix_time);

	// The end entity cert should validate with the issuer without error.
	end_entity_cert
		.verify_for_usage(
			&[&webpki::ECDSA_P256_SHA256],
			&trust_anchor_list[..],
			&[],
			time,
			KeyUsage::client_auth(),
			&[],
		)
		.expect("failed to validate ee cert with issuer");

	// Generate a CRL with the issuer that revokes the EE cert.
	let now = OffsetDateTime::from_unix_timestamp(unix_time as i64).unwrap();
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
	let crl_der = crl.serialize_der_with_signer(&issuer).unwrap();
	let crl = BorrowedCertRevocationList::from_der(&crl_der).unwrap();

	// The end entity cert should **not** validate when we provide a CRL that revokes the EE cert.
	let result = end_entity_cert.verify_for_usage(
		&[&webpki::ECDSA_P256_SHA256],
		&trust_anchor_list[..],
		&[],
		time,
		KeyUsage::client_auth(),
		&[&crl],
	);
	assert!(matches!(result, Err(webpki::Error::CertRevoked)));
}

#[test]
fn test_webpki_cert_crl_dps() {
	let der = util::cert_with_crl_dps();
	webpki::EndEntityCert::try_from(der.as_ref()).expect("failed to parse cert with CRL DPs ext");
	// Webpki doesn't expose the parsed CRL distribution extension, so we can't interrogate that
	// it matches the expected form. See `openssl.rs` for more extensive coverage.
}
