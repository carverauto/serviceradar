// Invented RFC 7011 messages, no captured exporter traffic.
pub fn ipfix(domain: u32, template: Option<&[(u16, u16)]>, data: &[u8]) -> Vec<u8> {
    let mut bytes = vec![0, 10, 0, 0];
    for value in [1_893_456_000u32, 1, domain] {
        bytes.extend(value.to_be_bytes());
    }
    if let Some(fields) = template {
        bytes.extend(2u16.to_be_bytes());
        bytes.extend((8 + fields.len() as u16 * 4).to_be_bytes());
        bytes.extend(256u16.to_be_bytes());
        bytes.extend((fields.len() as u16).to_be_bytes());
        for (kind, length) in fields {
            bytes.extend(kind.to_be_bytes());
            bytes.extend(length.to_be_bytes());
        }
    }
    if !data.is_empty() {
        bytes.extend(256u16.to_be_bytes());
        bytes.extend((4 + data.len() as u16).to_be_bytes());
        bytes.extend(data);
    }
    let length = (bytes.len() as u16).to_be_bytes();
    bytes[2..4].copy_from_slice(&length);
    bytes
}

// Invented fixed-layout NetFlow v5/v7 control; no captured packets.
pub fn legacy(version: u16) -> Vec<u8> {
    let mut bytes = vec![0u8; if version == 7 { 76 } else { 72 }];
    bytes[..2].copy_from_slice(&version.to_be_bytes());
    bytes[2..4].copy_from_slice(&1u16.to_be_bytes());
    bytes[8..12].copy_from_slice(&1_893_456_000u32.to_be_bytes());
    bytes[24..28].copy_from_slice(&[192, 0, 2, 10]);
    bytes[28..32].copy_from_slice(&[198, 51, 100, 20]);
    bytes[40..44].copy_from_slice(&1u32.to_be_bytes());
    bytes[44..48].copy_from_slice(&111u32.to_be_bytes());
    bytes
}
