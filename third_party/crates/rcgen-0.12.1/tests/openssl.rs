#![cfg(feature = "pem")]
use openssl::asn1::{Asn1Integer, Asn1Time};
use openssl::bn::BigNum;
use openssl::pkey::PKey;
use openssl::ssl::{HandshakeError, SslAcceptor, SslConnector, SslMethod};
use openssl::stack::Stack;
use openssl::x509::store::{X509Store, X509StoreBuilder};
use openssl::x509::{CrlStatus, X509Crl, X509Req, X509StoreContext, X509};
use rcgen::{
	BasicConstraints, Certificate, CertificateParams, DnType, DnValue, GeneralSubtree, IsCa,
	NameConstraints,
};
use std::cell::RefCell;
use std::io::{Error, ErrorKind, Read, Result as ioResult, Write};
use std::rc::Rc;

mod util;

fn verify_cert_basic(cert: &Certificate) {
	let cert_pem = cert.serialize_pem().unwrap();
	println!("{cert_pem}");

	let x509 = X509::from_pem(cert_pem.as_bytes()).unwrap();
	let mut builder = X509StoreBuilder::new().unwrap();
	builder.add_cert(x509.clone()).unwrap();

	let store: X509Store = builder.build();
	let mut ctx = X509StoreContext::new().unwrap();
	let mut stack = Stack::new().unwrap();
	stack.push(x509.clone()).unwrap();
	ctx.init(&store, &x509, stack.as_ref(), |ctx| {
		ctx.verify_cert().unwrap();
		Ok(())
	})
	.unwrap();
}

// TODO implement Debug manually instead of
// deriving it
#[derive(Debug)]
struct PipeInner([Vec<u8>; 2]);

#[derive(Debug)]
struct PipeEnd {
	read_pos: usize,
	/// Which end of the pipe
	end_idx: usize,
	inner: Rc<RefCell<PipeInner>>,
}

fn create_pipe() -> (PipeEnd, PipeEnd) {
	let pipe_inner = PipeInner([Vec::new(), Vec::new()]);
	let inner = Rc::new(RefCell::new(pipe_inner));
	(
		PipeEnd {
			read_pos: 0,
			end_idx: 0,
			inner: inner.clone(),
		},
		PipeEnd {
			read_pos: 0,
			end_idx: 1,
			inner,
		},
	)
}

impl Write for PipeEnd {
	fn write(&mut self, buf: &[u8]) -> ioResult<usize> {
		self.inner.borrow_mut().0[self.end_idx].extend_from_slice(buf);
		Ok(buf.len())
	}
	fn flush(&mut self) -> ioResult<()> {
		Ok(())
	}
}

impl Read for PipeEnd {
	fn read(&mut self, mut buf: &mut [u8]) -> ioResult<usize> {
		let inner = self.inner.borrow_mut();
		let r_sl = &inner.0[1 - self.end_idx][self.read_pos..];
		if r_sl.is_empty() {
			return Err(Error::new(ErrorKind::WouldBlock, "oh no!"));
		}
		let r = buf.len().min(r_sl.len());
		std::io::copy(&mut &r_sl[..r], &mut buf)?;
		self.read_pos += r;
		Ok(r)
	}
}

fn verify_cert(cert: &Certificate) {
	verify_cert_basic(cert);
	let cert_pem = cert.serialize_pem().unwrap();
	let key = cert.serialize_private_key_der();

	verify_cert_ca(&cert_pem, &key, &cert_pem);
}

fn verify_cert_ca(cert_pem: &str, key: &[u8], ca_cert_pem: &str) {
	println!("{cert_pem}");
	println!("{ca_cert_pem}");

	let x509 = X509::from_pem(cert_pem.as_bytes()).unwrap();

	let ca_x509 = X509::from_pem(ca_cert_pem.as_bytes()).unwrap();

	let mut builder = X509StoreBuilder::new().unwrap();
	builder.add_cert(ca_x509).unwrap();

	let store: X509Store = builder.build();

	let srv = SslMethod::tls_server();
	let mut ssl_srv_ctx = SslAcceptor::mozilla_modern(srv).unwrap();
	//let key = cert.serialize_private_key_der();
	let pkey = PKey::private_key_from_der(key).unwrap();
	ssl_srv_ctx.set_private_key(&pkey).unwrap();

	ssl_srv_ctx.set_certificate(&x509).unwrap();

	let cln = SslMethod::tls_client();
	let mut ssl_cln_ctx = SslConnector::builder(cln).unwrap();
	ssl_cln_ctx.set_cert_store(store);

	let ssl_srv_ctx = ssl_srv_ctx.build();
	let ssl_cln_ctx = ssl_cln_ctx.build();

	let (pipe_end_1, pipe_end_2) = create_pipe();

	let (mut ssl_srv_stream, mut ssl_cln_stream) = {
		let mut srv_res = ssl_srv_ctx.accept(pipe_end_1);
		let mut cln_res = ssl_cln_ctx.connect("crabs.crabs", pipe_end_2);
		let mut ready = 0u8;
		let mut iter_budget = 100;
		loop {
			match cln_res {
				Ok(_) => ready |= 2,
				Err(HandshakeError::WouldBlock(mh)) => cln_res = mh.handshake(),
				Err(e) => panic!("Error: {:?}", e),
			}
			match srv_res {
				Ok(_) => ready |= 1,
				Err(HandshakeError::WouldBlock(mh)) => srv_res = mh.handshake(),
				Err(e) => panic!("Error: {:?}", e),
			}
			if ready == 3 {
				break (cln_res.unwrap(), srv_res.unwrap());
			}
			if iter_budget == 0 {
				panic!("iter budget exhausted");
			}
			iter_budget -= 1;
		}
	};

	const HELLO_FROM_SRV: &[u8] = b"hello from server";
	const HELLO_FROM_CLN: &[u8] = b"hello from client";

	ssl_srv_stream.ssl_write(HELLO_FROM_SRV).unwrap();
	ssl_cln_stream.ssl_write(HELLO_FROM_CLN).unwrap();

	// TODO read the data we just wrote from the streams
}

fn verify_csr(cert: &Certificate) {
	let csr = cert.serialize_request_pem().unwrap();
	println!("{csr}");
	let key = cert.serialize_private_key_der();
	let pkey = PKey::private_key_from_der(&key).unwrap();

	let req = X509Req::from_pem(csr.as_bytes()).unwrap();
	req.verify(&pkey).unwrap();
}

#[test]
fn test_openssl() {
	let params = util::default_params();
	let cert = Certificate::from_params(params).unwrap();

	// Now verify the certificate.
	verify_cert(&cert);
}

#[test]
fn test_request() {
	let params = util::default_params();
	let cert = Certificate::from_params(params).unwrap();

	verify_csr(&cert);
}

#[test]
fn test_openssl_256() {
	let mut params = util::default_params();
	params.alg = &rcgen::PKCS_ECDSA_P256_SHA256;

	let cert = Certificate::from_params(params).unwrap();

	// Now verify the certificate.
	verify_cert(&cert);
	verify_csr(&cert);
}

#[test]
fn test_openssl_384() {
	let mut params = util::default_params();
	params.alg = &rcgen::PKCS_ECDSA_P384_SHA384;

	let cert = Certificate::from_params(params).unwrap();

	// Now verify the certificate.
	verify_cert(&cert);
	verify_csr(&cert);
}

#[test]
fn test_openssl_25519() {
	let mut params = util::default_params();
	params.alg = &rcgen::PKCS_ED25519;

	let cert = Certificate::from_params(params).unwrap();

	// Now verify the certificate.
	// TODO openssl doesn't support v2 keys (yet)
	// https://github.com/est31/rcgen/issues/11
	// https://github.com/openssl/openssl/issues/10468
	verify_cert_basic(&cert);
	//verify_csr(&cert);
}

#[test]
fn test_openssl_25519_v1_given() {
	let mut params = util::default_params();
	params.alg = &rcgen::PKCS_ED25519;

	let kp = rcgen::KeyPair::from_pem(util::ED25519_TEST_KEY_PAIR_PEM_V1).unwrap();
	params.key_pair = Some(kp);

	let cert = Certificate::from_params(params).unwrap();

	// Now verify the certificate as well as CSR,
	// but only on OpenSSL >= 1.1.1
	// On prior versions, only do basic verification
	#[allow(clippy::unusual_byte_groupings)]
	if openssl::version::number() >= 0x1_01_01_00_f {
		verify_cert(&cert);
		verify_csr(&cert);
	} else {
		verify_cert_basic(&cert);
	}
}

#[test]
fn test_openssl_25519_v2_given() {
	let mut params = util::default_params();
	params.alg = &rcgen::PKCS_ED25519;

	let kp = rcgen::KeyPair::from_pem(util::ED25519_TEST_KEY_PAIR_PEM_V2).unwrap();
	params.key_pair = Some(kp);

	let cert = Certificate::from_params(params).unwrap();

	// Now verify the certificate.
	// TODO openssl doesn't support v2 keys (yet)
	// https://github.com/est31/rcgen/issues/11
	// https://github.com/openssl/openssl/issues/10468
	verify_cert_basic(&cert);
	//verify_csr(&cert);
}

#[test]
fn test_openssl_rsa_given() {
	let mut params = util::default_params();
	params.alg = &rcgen::PKCS_RSA_SHA256;

	let kp = rcgen::KeyPair::from_pem(util::RSA_TEST_KEY_PAIR_PEM).unwrap();
	params.key_pair = Some(kp);

	let cert = Certificate::from_params(params).unwrap();

	// Now verify the certificate.
	verify_cert(&cert);
	verify_csr(&cert);
}

#[test]
fn test_openssl_rsa_combinations_given() {
	let alg_list = [
		&rcgen::PKCS_RSA_SHA256,
		&rcgen::PKCS_RSA_SHA384,
		&rcgen::PKCS_RSA_SHA512,
		//&rcgen::PKCS_RSA_PSS_SHA256,
	];
	for (i, alg) in alg_list.iter().enumerate() {
		let mut params = util::default_params();
		params.alg = alg;

		let kp = rcgen::KeyPair::from_pem_and_sign_algo(util::RSA_TEST_KEY_PAIR_PEM, alg).unwrap();
		params.key_pair = Some(kp);

		let cert = Certificate::from_params(params).unwrap();

		// Now verify the certificate.
		if i >= 4 {
			verify_cert(&cert);
			verify_csr(&cert);
		} else {
			// The PSS key types are not fully supported.
			// An attempt to use them gives a handshake error.
			verify_cert_basic(&cert);
		}
	}
}

#[test]
fn test_openssl_separate_ca() {
	let mut params = util::default_params();
	params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
	let ca_cert = Certificate::from_params(params).unwrap();
	let ca_cert_pem = ca_cert.serialize_pem().unwrap();

	let mut params = CertificateParams::new(vec!["crabs.crabs".to_string()]);
	params
		.distinguished_name
		.push(DnType::OrganizationName, "Crab widgits SE");
	params
		.distinguished_name
		.push(DnType::CommonName, "Dev domain");
	let cert = Certificate::from_params(params).unwrap();
	let cert_pem = cert.serialize_pem_with_signer(&ca_cert).unwrap();
	let key = cert.serialize_private_key_der();

	verify_cert_ca(&cert_pem, &key, &ca_cert_pem);
}

#[test]
fn test_openssl_separate_ca_with_printable_string() {
	let mut params = util::default_params();
	params.distinguished_name.push(
		DnType::CountryName,
		DnValue::PrintableString("US".to_string()),
	);
	params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
	let ca_cert = Certificate::from_params(params).unwrap();
	let ca_cert_pem = ca_cert.serialize_pem().unwrap();

	let mut params = CertificateParams::new(vec!["crabs.crabs".to_string()]);
	params
		.distinguished_name
		.push(DnType::OrganizationName, "Crab widgits SE");
	params
		.distinguished_name
		.push(DnType::CommonName, "Dev domain");
	let cert = Certificate::from_params(params).unwrap();
	let cert_pem = cert.serialize_pem_with_signer(&ca_cert).unwrap();
	let key = cert.serialize_private_key_der();

	verify_cert_ca(&cert_pem, &key, &ca_cert_pem);
}

#[test]
fn test_openssl_separate_ca_with_other_signing_alg() {
	let mut params = util::default_params();
	params.alg = &rcgen::PKCS_ECDSA_P256_SHA256;
	params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
	let ca_cert = Certificate::from_params(params).unwrap();
	let ca_cert_pem = ca_cert.serialize_pem().unwrap();

	let mut params = CertificateParams::new(vec!["crabs.crabs".to_string()]);
	params.alg = &rcgen::PKCS_ECDSA_P384_SHA384;
	params
		.distinguished_name
		.push(DnType::OrganizationName, "Crab widgits SE");
	params
		.distinguished_name
		.push(DnType::CommonName, "Dev domain");
	let cert = Certificate::from_params(params).unwrap();
	let cert_pem = cert.serialize_pem_with_signer(&ca_cert).unwrap();
	let key = cert.serialize_private_key_der();

	verify_cert_ca(&cert_pem, &key, &ca_cert_pem);
}

#[test]
fn test_openssl_separate_ca_name_constraints() {
	let mut params = util::default_params();
	params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);

	println!("openssl version: {:x}", openssl::version::number());

	params.name_constraints = Some(NameConstraints {
		permitted_subtrees: vec![GeneralSubtree::DnsName("crabs.crabs".to_string())],
		//permitted_subtrees : vec![GeneralSubtree::DnsName("".to_string())],
		//permitted_subtrees : Vec::new(),
		//excluded_subtrees : vec![GeneralSubtree::DnsName(".v".to_string())],
		excluded_subtrees: Vec::new(),
	});
	let ca_cert = Certificate::from_params(params).unwrap();
	let ca_cert_pem = ca_cert.serialize_pem().unwrap();

	let mut params = CertificateParams::new(vec!["crabs.crabs".to_string()]);
	params
		.distinguished_name
		.push(DnType::OrganizationName, "Crab widgits SE");
	params
		.distinguished_name
		.push(DnType::CommonName, "Dev domain");
	let cert = Certificate::from_params(params).unwrap();
	let cert_pem = cert.serialize_pem_with_signer(&ca_cert).unwrap();
	let key = cert.serialize_private_key_der();

	verify_cert_ca(&cert_pem, &key, &ca_cert_pem);
}

#[test]
fn test_openssl_crl_parse() {
	// Create a CRL with one revoked cert, and an issuer to sign the CRL.
	let (crl, issuer) = util::test_crl();
	let revoked_cert = crl.get_params().revoked_certs.first().unwrap();
	let revoked_cert_serial = &revoked_cert.serial_number;

	// Serialize the CRL signed by the issuer in both PEM and DER.
	let crl_pem = crl.serialize_pem_with_signer(&issuer).unwrap();
	let crl_der = crl.serialize_der_with_signer(&issuer).unwrap();

	// We should be able to parse the PEM form without error.
	assert!(X509Crl::from_pem(crl_pem.as_bytes()).is_ok());

	// We should also be able to parse the DER form without error.
	let openssl_crl = X509Crl::from_der(&crl_der).expect("failed to parse CRL DER");

	// The properties of the CRL should match expected.
	let openssl_issuer = X509::from_der(&issuer.serialize_der().unwrap()).unwrap();
	let expected_last_update =
		Asn1Time::from_unix(crl.get_params().this_update.unix_timestamp()).unwrap();
	assert!(openssl_crl.last_update().eq(&expected_last_update));
	let expected_next_update =
		Asn1Time::from_unix(crl.get_params().next_update.unix_timestamp()).unwrap();
	assert!(openssl_crl.next_update().unwrap().eq(&expected_next_update));
	assert!(matches!(
		openssl_crl
			.issuer_name()
			.try_cmp(openssl_issuer.issuer_name())
			.unwrap(),
		core::cmp::Ordering::Equal
	));

	// We should find the revoked certificate is revoked.
	let openssl_serial = BigNum::from_slice(revoked_cert_serial.as_ref()).unwrap();
	let openssl_serial = Asn1Integer::from_bn(&openssl_serial).unwrap();
	let openssl_crl_status = openssl_crl.get_by_serial(&openssl_serial);
	assert!(matches!(openssl_crl_status, CrlStatus::Revoked(_)));

	// We should be able to verify the CRL signature with the issuer's public key.
	let issuer_pkey = openssl_issuer.public_key().unwrap();
	assert!(openssl_crl
		.verify(&issuer_pkey)
		.expect("failed to verify CRL signature"));
}

#[test]
fn test_openssl_crl_dps_parse() {
	// Generate and parse a certificate that includes two CRL distribution points.
	let der = util::cert_with_crl_dps();
	let cert = X509::from_der(&der).expect("failed to parse cert DER");

	// We should find the CRL DPs extension.
	let dps = cert
		.crl_distribution_points()
		.expect("missing crl distribution points extension");
	assert!(!dps.is_empty());

	// We should find two distribution points, each with a distribution point name containing
	// a full name sequence of general names.
	let general_names = dps
		.iter()
		.flat_map(|dp| {
			dp.distpoint()
				.expect("distribution point missing distribution point name")
				.fullname()
				.expect("distribution point name missing general names")
				.iter()
		})
		.collect::<Vec<_>>();

	// Each general name should be a URI name.
	let uris = general_names
		.iter()
		.map(|general_name| {
			general_name
				.uri()
				.expect("general name is not a directory name")
		})
		.collect::<Vec<_>>();

	// We should find the expected URIs.
	assert_eq!(
		uris,
		&[
			"http://example.com/crl.der",
			"http://crls.example.com/1234",
			"ldap://example.com/crl.der"
		]
	);
}
