#![cfg(feature = "parse_unknown_fields")]

use netflow_parser::NetflowParser;

fn v9_message(flowset: &[u8]) -> Vec<u8> {
    let mut packet = vec![
        0, 9, // version
        0, 1, // one FlowSet
        0, 0, 0, 0, // system uptime
        0, 0, 0, 0, // export time
        0, 0, 0, 1, // sequence
        0, 0, 0, 1, // source ID
    ];
    packet.extend_from_slice(flowset);
    packet
}

fn v9_template(template_id: u16, fields: &[(u16, u16)]) -> Vec<u8> {
    let length = 8 + fields.len() * 4;
    let mut flowset = Vec::with_capacity(length);
    flowset.extend_from_slice(&0u16.to_be_bytes());
    flowset.extend_from_slice(&(length as u16).to_be_bytes());
    flowset.extend_from_slice(&template_id.to_be_bytes());
    flowset.extend_from_slice(&(fields.len() as u16).to_be_bytes());
    for (field_type, field_length) in fields {
        flowset.extend_from_slice(&field_type.to_be_bytes());
        flowset.extend_from_slice(&field_length.to_be_bytes());
    }
    flowset
}

fn v9_data(template_id: u16, body: &[u8]) -> Vec<u8> {
    let mut flowset = Vec::with_capacity(body.len() + 4);
    flowset.extend_from_slice(&template_id.to_be_bytes());
    flowset.extend_from_slice(&((body.len() + 4) as u16).to_be_bytes());
    flowset.extend_from_slice(body);
    flowset
}

#[test]
fn default_limits_reject_cumulative_decoded_output_amplification() {
    // Each one-byte wire record materializes 65 field values: 64 zero-width
    // unknown fields and one one-byte field. Across 1,009 records this creates
    // 65,585 values, just beyond the default cumulative limit of 65,536.
    let mut fields: Vec<(u16, u16)> = (1000..1064).map(|field| (field, 0)).collect();
    fields.push((1, 1));

    let mut parser = NetflowParser::default();
    let template = parser.parse_bytes(&v9_message(&v9_template(256, &fields)));
    assert!(template.is_ok(), "template failed: {:?}", template.error);

    let result = parser.parse_bytes(&v9_message(&v9_data(256, &[1; 1009])));
    assert!(result.packets.is_empty());
    assert!(result.error.is_some());
}
