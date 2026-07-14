fn main() -> Result<(), Box<dyn std::error::Error>> {
	use rcgen::{date_time_ymd, Certificate, CertificateParams, DistinguishedName};
	use std::fmt::Write;
	use std::fs;

	let mut params: CertificateParams = Default::default();
	params.not_before = date_time_ymd(2021, 5, 19);
	params.not_after = date_time_ymd(4096, 1, 1);
	params.distinguished_name = DistinguishedName::new();

	params.alg = &rcgen::PKCS_RSA_SHA256;

	let pkey: openssl::pkey::PKey<_> = openssl::rsa::Rsa::generate(2048)?.try_into()?;
	let key_pair_pem = String::from_utf8(pkey.private_key_to_pem_pkcs8()?)?;
	let key_pair = rcgen::KeyPair::from_pem(&key_pair_pem)?;
	params.key_pair = Some(key_pair);

	let cert = Certificate::from_params(params)?;
	let pem_serialized = cert.serialize_pem()?;
	let pem = pem::parse(&pem_serialized)?;
	let der_serialized = pem.contents();
	let hash = ring::digest::digest(&ring::digest::SHA512, der_serialized);
	let hash_hex = hash.as_ref().iter().fold(String::new(), |mut output, b| {
		let _ = write!(output, "{b:02x}");
		output
	});
	println!("sha-512 fingerprint: {hash_hex}");
	println!("{pem_serialized}");
	println!("{}", cert.serialize_private_key_pem());
	std::fs::create_dir_all("certs/")?;
	fs::write("certs/cert.pem", pem_serialized.as_bytes())?;
	fs::write("certs/cert.der", der_serialized)?;
	fs::write("certs/key.pem", cert.serialize_private_key_pem().as_bytes())?;
	fs::write("certs/key.der", cert.serialize_private_key_der())?;
	Ok(())
}
