use rcgen::{
	BasicConstraints, Certificate, CertificateParams, DnType, DnValue::PrintableString,
	ExtendedKeyUsagePurpose, IsCa, KeyUsagePurpose,
};
use time::{Duration, OffsetDateTime};

/// Example demonstrating signing end-endity certificate with ca
fn main() {
	let ca = new_ca();
	let end_entity = new_end_entity();

	let end_entity_pem = end_entity.serialize_pem_with_signer(&ca).unwrap();
	println!("directly signed end-entity certificate: {end_entity_pem}");

	let ca_cert_pem = ca.serialize_pem().unwrap();
	println!("ca certificate: {ca_cert_pem}",);
}

fn new_ca() -> Certificate {
	let mut params = CertificateParams::new(Vec::default());
	let (yesterday, tomorrow) = validity_period();
	params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
	params
		.distinguished_name
		.push(DnType::CountryName, PrintableString("BR".into()));
	params
		.distinguished_name
		.push(DnType::OrganizationName, "Crab widgits SE");
	params.key_usages.push(KeyUsagePurpose::DigitalSignature);
	params.key_usages.push(KeyUsagePurpose::KeyCertSign);
	params.key_usages.push(KeyUsagePurpose::CrlSign);

	params.not_before = yesterday;
	params.not_after = tomorrow;
	Certificate::from_params(params).unwrap()
}

fn new_end_entity() -> Certificate {
	let name = "entity.other.host";
	let mut params = CertificateParams::new(vec![name.into()]);
	let (yesterday, tomorrow) = validity_period();
	params.distinguished_name.push(DnType::CommonName, name);
	params.use_authority_key_identifier_extension = true;
	params.key_usages.push(KeyUsagePurpose::DigitalSignature);
	params
		.extended_key_usages
		.push(ExtendedKeyUsagePurpose::ServerAuth);
	params.not_before = yesterday;
	params.not_after = tomorrow;
	Certificate::from_params(params).unwrap()
}

fn validity_period() -> (OffsetDateTime, OffsetDateTime) {
	let day = Duration::new(86400, 0);
	let yesterday = OffsetDateTime::now_utc().checked_sub(day).unwrap();
	let tomorrow = OffsetDateTime::now_utc().checked_add(day).unwrap();
	(yesterday, tomorrow)
}
