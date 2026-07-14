use crate::capture_from_test_file;

#[test]
fn test_pcap_version() {
    let capture = capture_from_test_file("packet_snaplen_65535.pcap");

    assert_eq!(capture.version(), (2, 4));
    assert_eq!(capture.major_version(), 2);
    assert_eq!(capture.minor_version(), 4);
}
