use der::Decode;
use x509_cert::crl::CertificateList;

#[test]
fn decode_crl() {
    // vanilla CRL from PKITS
    let der_encoded_cert = include_bytes!("examples/GoodCACRL.crl");
    let crl = CertificateList::from_der(der_encoded_cert).unwrap();
    assert_eq!(2, crl.tbs_cert_list.crl_extensions.unwrap().len());
    assert_eq!(2, crl.tbs_cert_list.revoked_certificates.unwrap().len());

    // CRL with an entry with no entry extensions
    let der_encoded_cert = include_bytes!("examples/tscpbcasha256.crl");
    let crl = CertificateList::from_der(der_encoded_cert).unwrap();
    assert_eq!(2, crl.tbs_cert_list.crl_extensions.unwrap().len());
    assert_eq!(4, crl.tbs_cert_list.revoked_certificates.unwrap().len());
}
