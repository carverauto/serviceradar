use super::*;

#[test]
fn write_capabilities_reports_connector_not_ready() {
    let mut output = Vec::new();

    write_capabilities(&mut output).expect("write capabilities");

    let payload = String::from_utf8(output).expect("utf8 capabilities");
    assert!(payload.contains(HELPER_CAPABILITIES_SCHEMA));
    assert!(payload.contains("\"protocol\":\"rdp\""));
    assert!(payload.contains("\"helper_protocol_version\":1"));
    assert!(payload.contains("\"connector_ready\":false"));
    let expected_reason = if cfg!(feature = "ironrdp-backend") {
        HELPER_CONNECTOR_NOT_READY_REASON
    } else {
        HELPER_BACKEND_NOT_LINKED_REASON
    };
    assert!(payload.contains(&format!("\"connector_ready_reason\":\"{expected_reason}\"")));
}
