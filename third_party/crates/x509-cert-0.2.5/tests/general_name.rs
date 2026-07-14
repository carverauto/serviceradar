use x509_cert::ext::pkix::name::{GeneralName, GeneralNames};

use der::{Decode, Encode};
use hex_literal::hex;
use rstest::rstest;

const OTHER_NAME: &[u8] = &hex!("A01B060560865E0202A0120C105249462D472D32303030343033362D30");
const RFC822_NAME: &[u8] = &hex!("8117456D61696C5F353238343037373733406468732E676F76");
const DNS_NAME: &[u8] =
    &hex!("8222756E7465726E65686D656E736E616368666F6C67652D696E2D62617965726E2E6465");
const DIRECTORY_NAME: &[u8] =
    &hex!("A43B3039310B3009060355040613024445310F300D06035504080C0642617965726E31193017060355040A0C104672656973746161742042617965726E");
// TODO: EdiPartyName
const URI: &[u8] = &hex!(
    "862A687474703A2F2F63726C2E71756F7661646973676C6F62616C2E636F6D2F71767263613267332E63726C"
);
const IPADDR: &[u8] = &hex!("87202A02102C000000000000000000000000FFFFFFFF000000000000000000000000");
// TODO: RegisteredId

const OTHER_NAMES: &[u8] = &hex!("301da01b060560865e0202a0120c105249462d472d32303030343033362d30");
const RFC822_NAMES: &[u8] = &hex!("30198117456D61696C5F353238343037373733406468732E676F76");
const DNS_NAMES: &[u8] =
    &hex!("30248222756E7465726E65686D656E736E616368666F6C67652D696E2D62617965726E2E6465");
const DIRECTORY_NAMES: &[u8] = &hex!("303DA43B3039310B3009060355040613024445310F300D06035504080C0642617965726E31193017060355040A0C104672656973746161742042617965726E");
// TODO: EdiPartyName
const URIS: &[u8] = &hex!(
    "302C862A687474703A2F2F63726C2E71756F7661646973676C6F62616C2E636F6D2F71767263613267332E63726C"
);
const IPADDRS: &[u8] =
    &hex!("302287202A02102C000000000000000000000000FFFFFFFF000000000000000000000000");
// TODO: RegisteredId

#[rstest]
#[case(1, OTHER_NAME)]
#[case(2, RFC822_NAME)]
#[case(3, DNS_NAME)]
#[case(4, DIRECTORY_NAME)]
#[case(5, URI)]
#[case(6, IPADDR)]
fn singular(#[case] idx: usize, #[case] value: &[u8]) {
    let decoded = GeneralName::from_der(value).unwrap();

    match (idx, &decoded) {
        (1, GeneralName::OtherName(..)) => (),
        (2, GeneralName::Rfc822Name(..)) => (),
        (3, GeneralName::DnsName(..)) => (),
        (4, GeneralName::DirectoryName(..)) => (),
        (5, GeneralName::UniformResourceIdentifier(..)) => (),
        (6, GeneralName::IpAddress(..)) => (),
        _ => panic!("unexpected decoded value"),
    }

    let encoded = decoded.to_der().unwrap();
    assert_eq!(value, encoded);
}

#[rstest]
#[case(1, OTHER_NAMES)]
#[case(2, RFC822_NAMES)]
#[case(3, DNS_NAMES)]
#[case(4, DIRECTORY_NAMES)]
#[case(5, URIS)]
#[case(6, IPADDRS)]
fn plural(#[case] idx: usize, #[case] value: &[u8]) {
    let decoded = GeneralNames::from_der(value).unwrap();

    assert_eq!(1, decoded.len());
    match (idx, &decoded[0]) {
        (1, GeneralName::OtherName(..)) => (),
        (2, GeneralName::Rfc822Name(..)) => (),
        (3, GeneralName::DnsName(..)) => (),
        (4, GeneralName::DirectoryName(..)) => (),
        (5, GeneralName::UniformResourceIdentifier(..)) => (),
        (6, GeneralName::IpAddress(..)) => (),
        _ => panic!("unexpected decoded value"),
    }

    let encoded = decoded.to_der().unwrap();
    assert_eq!(value, encoded);
}
