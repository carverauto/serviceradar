use netflow_parser::variable_versions::v9::{
    Data, FlowSet, FlowSetBody, FlowSetHeader, Header, V9,
};
use netflow_parser::{NetflowPacket, NetflowParser, PendingFlowsConfig};

fn v9_header(count: u16) -> Vec<u8> {
    let mut packet = Vec::new();
    packet.extend_from_slice(&9u16.to_be_bytes());
    packet.extend_from_slice(&count.to_be_bytes());
    packet.extend_from_slice(&0u32.to_be_bytes());
    packet.extend_from_slice(&0u32.to_be_bytes());
    packet.extend_from_slice(&1u32.to_be_bytes());
    packet.extend_from_slice(&1u32.to_be_bytes());
    packet
}

fn append_flowset(packet: &mut Vec<u8>, id: u16, body: &[u8]) {
    packet.extend_from_slice(&id.to_be_bytes());
    packet.extend_from_slice(&u16::try_from(4 + body.len()).unwrap().to_be_bytes());
    packet.extend_from_slice(body);
}

fn template_record(template_id: u16, field_type: u16) -> Vec<u8> {
    let mut record = Vec::new();
    record.extend_from_slice(&template_id.to_be_bytes());
    record.extend_from_slice(&1u16.to_be_bytes());
    record.extend_from_slice(&field_type.to_be_bytes());
    record.extend_from_slice(&4u16.to_be_bytes());
    record
}

fn two_template_packet(count: u16) -> Vec<u8> {
    let mut packet = v9_header(count);
    let mut templates = template_record(256, 1);
    templates.extend_from_slice(&template_record(257, 2));
    append_flowset(&mut packet, 0, &templates);
    packet
}

fn mixed_record_packet() -> Vec<u8> {
    let mut packet = v9_header(6);

    append_flowset(&mut packet, 0, &template_record(256, 1));

    let mut options_template = Vec::new();
    options_template.extend_from_slice(&257u16.to_be_bytes());
    options_template.extend_from_slice(&4u16.to_be_bytes());
    options_template.extend_from_slice(&4u16.to_be_bytes());
    options_template.extend_from_slice(&1u16.to_be_bytes());
    options_template.extend_from_slice(&4u16.to_be_bytes());
    options_template.extend_from_slice(&42u16.to_be_bytes());
    options_template.extend_from_slice(&4u16.to_be_bytes());
    options_template.extend_from_slice(&[0; 2]);
    append_flowset(&mut packet, 1, &options_template);

    let mut data = Vec::new();
    data.extend_from_slice(&11u32.to_be_bytes());
    data.extend_from_slice(&22u32.to_be_bytes());
    append_flowset(&mut packet, 256, &data);

    let mut options_data = Vec::new();
    for value in [1u32, 2, 3, 4] {
        options_data.extend_from_slice(&value.to_be_bytes());
    }
    append_flowset(&mut packet, 257, &options_data);

    packet
}

fn reserved_frame(size: usize) -> Vec<u8> {
    assert!((24..=65_555).contains(&size));
    let mut packet = v9_header(0);
    let body_len = size - 24;
    append_flowset(&mut packet, 2, &vec![0; body_len]);
    assert_eq!(packet.len(), size);
    packet
}

fn parsed_v9(result: &netflow_parser::ParseResult) -> &V9 {
    assert!(result.error.is_none(), "{:?}", result.error);
    assert_eq!(result.packets.len(), 1);
    let NetflowPacket::V9(packet) = &result.packets[0] else {
        panic!("expected NetFlow v9 packet");
    };
    packet
}

#[test]
fn parses_flowsets_to_the_caller_delimited_frame_boundary() {
    let result = NetflowParser::default().parse_bytes(&two_template_packet(0));
    let packet = parsed_v9(&result);

    assert_eq!(packet.header.count, 0);
    assert_eq!(packet.flowsets.len(), 1);
    let FlowSetBody::Template(templates) = &packet.flowsets[0].body else {
        panic!("expected template flowset");
    };
    assert_eq!(templates.templates.len(), 2);
}

#[test]
fn pending_flow_processing_preserves_the_exporter_declared_count() {
    let mut parser = NetflowParser::builder()
        .with_pending_flows(PendingFlowsConfig::default())
        .build()
        .unwrap();

    let result = parser.parse_bytes(&two_template_packet(2));
    let packet = parsed_v9(&result);

    assert_eq!(packet.header.count, 2);
    assert_eq!(packet.flowsets.len(), 1);
}

#[test]
fn serializer_counts_records_instead_of_flowsets() {
    let result = NetflowParser::default().parse_bytes(&mixed_record_packet());
    let packet = parsed_v9(&result);
    assert_eq!(packet.flowsets.len(), 4);

    let serialized = packet.to_be_bytes().unwrap();
    assert_eq!(u16::from_be_bytes([serialized[2], serialized[3]]), 6);
}

#[test]
fn serializer_rejects_record_count_overflow() {
    let packet = V9 {
        header: Header {
            version: 9,
            count: 0,
            sys_up_time: 0,
            unix_secs: 0,
            sequence_number: 0,
            source_id: 0,
        },
        flowsets: vec![FlowSet {
            header: FlowSetHeader {
                flowset_id: 256,
                length: 4,
            },
            body: FlowSetBody::Data(Data::new(vec![Vec::new(); 65_536])),
        }],
    };

    assert!(packet.to_be_bytes().is_err());
}

#[test]
fn parser_and_serializer_reject_header_only_v9_packets() {
    let result = NetflowParser::default().parse_bytes(&v9_header(0));
    assert!(result.packets.is_empty());
    assert!(result.error.is_some());

    let packet = V9 {
        header: Header {
            version: 9,
            count: 0,
            sys_up_time: 0,
            unix_secs: 0,
            sequence_number: 0,
            source_id: 0,
        },
        flowsets: Vec::new(),
    };
    assert!(packet.to_be_bytes().is_err());
}

#[test]
fn default_v9_frame_limit_accepts_the_limit_and_rejects_one_more_byte() {
    let accepted = NetflowParser::default().parse_bytes(&reserved_frame(65_535));
    assert!(accepted.error.is_none(), "{:?}", accepted.error);

    let rejected = NetflowParser::default().parse_bytes(&reserved_frame(65_536));
    assert!(rejected.packets.is_empty());
    assert!(rejected.error.is_some());
}

#[test]
fn configured_v9_frame_limit_accepts_larger_caller_delimited_frames() {
    let mut parser = NetflowParser::builder()
        .with_v9_max_frame_size_bytes(65_536)
        .build()
        .unwrap();

    let result = parser.parse_bytes(&reserved_frame(65_536));
    assert!(result.error.is_none(), "{:?}", result.error);
}

#[test]
fn zero_v9_frame_limit_is_rejected() {
    let result = NetflowParser::builder()
        .with_v9_max_frame_size_bytes(0)
        .build();
    assert!(result.is_err());
}

#[test]
fn oversized_v9_frame_is_rejected_before_learning_templates() {
    let packet = two_template_packet(2);
    let mut parser = NetflowParser::builder()
        .with_v9_max_frame_size_bytes(packet.len() - 1)
        .build()
        .unwrap();

    let result = parser.parse_bytes(&packet);
    assert!(result.packets.is_empty());
    assert!(result.error.is_some());
    assert!(!parser.has_v9_template(256));
    assert!(!parser.has_v9_template(257));
}
