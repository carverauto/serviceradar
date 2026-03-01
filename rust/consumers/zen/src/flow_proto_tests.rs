use super::*;

#[test]
fn test_bytes_to_ip_v4() {
    let bytes = vec![192, 168, 1, 1];
    assert_eq!(bytes_to_ip(&bytes), "192.168.1.1");
}

#[test]
fn test_bytes_to_ip_v6() {
    let bytes = vec![
        0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x01,
    ];
    assert_eq!(
        bytes_to_ip(&bytes),
        "2001:0db8:0000:0000:0000:0000:0000:0001"
    );
}

#[test]
fn test_bytes_to_ip_empty() {
    let bytes = vec![];
    assert_eq!(bytes_to_ip(&bytes), "");
}

#[test]
fn test_format_mac() {
    let mac = 0x001122334455u64;
    assert_eq!(format_mac(mac), "00:11:22:33:44:55");
}

#[test]
fn test_format_mac_zero() {
    assert_eq!(format_mac(0), "");
}

#[test]
fn test_flow_type_name() {
    assert_eq!(flow_type_name(0), "FLOWUNKNOWN");
    assert_eq!(flow_type_name(2), "NETFLOW_V5");
    assert_eq!(flow_type_name(3), "NETFLOW_V9");
    assert_eq!(flow_type_name(4), "IPFIX");
}
