use std::net::IpAddr;

use etherparse::{NetHeaders, PacketHeaders, TransportHeader};
use sha2::{Digest, Sha256};

const TLS_GREASE_VALUES: [u16; 16] = [
    0x0a0a, 0x1a1a, 0x2a2a, 0x3a3a, 0x4a4a, 0x5a5a, 0x6a6a, 0x7a7a, 0x8a8a, 0x9a9a, 0xaaaa, 0xbaba,
    0xcaca, 0xdada, 0xeaea, 0xfafa,
];

#[derive(Debug, PartialEq)]
pub(crate) struct TlsServerFingerprint {
    pub(crate) source_ip: IpAddr,
    pub(crate) ja4s: String,
}

pub(crate) fn fingerprint(packet: &[u8]) -> Option<TlsServerFingerprint> {
    let (source_ip, payload) = tcp_payload(packet)?;
    let ja4s = parse_ja4s(payload)?;

    Some(TlsServerFingerprint { source_ip, ja4s })
}

fn tcp_payload(packet: &[u8]) -> Option<(IpAddr, &[u8])> {
    let headers = if matches!(packet.first().map(|byte| byte >> 4), Some(4 | 6)) {
        PacketHeaders::from_ip_slice(packet).ok()?
    } else {
        PacketHeaders::from_ethernet_slice(packet).ok()?
    };
    let source_ip = match headers.net.as_ref()? {
        NetHeaders::Ipv4(header, _) => IpAddr::from(header.source),
        NetHeaders::Ipv6(header, _) => IpAddr::from(header.source),
        NetHeaders::Arp(_) => return None,
    };
    match headers.transport.as_ref()? {
        TransportHeader::Tcp(_) => Some((source_ip, headers.payload.slice())),
        _ => None,
    }
}

fn parse_ja4s(payload: &[u8]) -> Option<String> {
    let mut record_offset = 0;
    while record_offset + 5 <= payload.len() {
        if payload[record_offset] != 0x16 {
            return None;
        }

        let record_len = usize::from(u16::from_be_bytes([
            payload[record_offset + 3],
            payload[record_offset + 4],
        ]));
        let record_start = record_offset + 5;
        let record_end = record_start.checked_add(record_len)?;
        if record_end > payload.len() {
            return None;
        }

        if let Some(ja4s) = parse_handshake_record(&payload[record_start..record_end]) {
            return Some(ja4s);
        }

        record_offset = record_end;
    }

    None
}

fn parse_handshake_record(mut data: &[u8]) -> Option<String> {
    while data.len() >= 4 {
        let handshake_type = data[0];
        let handshake_len =
            (usize::from(data[1]) << 16) | (usize::from(data[2]) << 8) | usize::from(data[3]);
        if data.len() < 4 + handshake_len {
            return None;
        }

        if handshake_type == 0x02 {
            return parse_server_hello(&data[4..4 + handshake_len]);
        }

        data = &data[4 + handshake_len..];
    }

    None
}

fn parse_server_hello(body: &[u8]) -> Option<String> {
    if body.len() < 38 {
        return None;
    }

    let legacy_version = u16::from_be_bytes([body[0], body[1]]);
    let mut offset = 2 + 32;

    let session_id_len = usize::from(*body.get(offset)?);
    offset = offset.checked_add(1 + session_id_len)?;
    if body.len() < offset + 3 {
        return None;
    }

    let cipher = u16::from_be_bytes([body[offset], body[offset + 1]]);
    offset += 3; // cipher suite + compression method

    if body.len() < offset + 2 {
        return Some(ja4s(legacy_version, cipher, &[], None));
    }

    let extensions_len = usize::from(u16::from_be_bytes([body[offset], body[offset + 1]]));
    offset += 2;
    if body.len() < offset + extensions_len {
        return None;
    }

    let extensions = parse_extensions(&body[offset..offset + extensions_len])?;
    let version = extensions.supported_version.unwrap_or(legacy_version);

    Some(ja4s(
        version,
        cipher,
        &extensions.types,
        extensions.alpn.as_deref(),
    ))
}

#[derive(Debug, Default)]
struct ServerExtensions {
    types: Vec<u16>,
    supported_version: Option<u16>,
    alpn: Option<String>,
}

fn parse_extensions(mut data: &[u8]) -> Option<ServerExtensions> {
    let mut extensions = ServerExtensions::default();

    while !data.is_empty() {
        if data.len() < 4 {
            return None;
        }

        let extension_type = u16::from_be_bytes([data[0], data[1]]);
        let extension_len = usize::from(u16::from_be_bytes([data[2], data[3]]));
        if data.len() < 4 + extension_len {
            return None;
        }

        let extension_data = &data[4..4 + extension_len];
        extensions.types.push(extension_type);
        match extension_type {
            0x0010 => {
                extensions.alpn = parse_alpn(extension_data);
            }
            0x002b if extension_data.len() == 2 => {
                extensions.supported_version =
                    Some(u16::from_be_bytes([extension_data[0], extension_data[1]]));
            }
            _ => {}
        }

        data = &data[4 + extension_len..];
    }

    Some(extensions)
}

fn parse_alpn(data: &[u8]) -> Option<String> {
    if data.len() < 3 {
        return None;
    }

    let protocol_list_len = usize::from(u16::from_be_bytes([data[0], data[1]]));
    if data.len() < 2 + protocol_list_len || protocol_list_len == 0 {
        return None;
    }

    let protocol_len = usize::from(data[2]);
    if protocol_len == 0 || data.len() < 3 + protocol_len {
        return None;
    }

    std::str::from_utf8(&data[3..3 + protocol_len])
        .ok()
        .map(ToOwned::to_owned)
}

fn ja4s(version: u16, cipher: u16, extension_types: &[u16], alpn: Option<&str>) -> String {
    let filtered_extensions = extension_types
        .iter()
        .copied()
        .filter(|extension| !TLS_GREASE_VALUES.contains(extension))
        .collect::<Vec<_>>();

    let extension_hash_input = filtered_extensions
        .iter()
        .copied()
        .filter(|extension| *extension != 0x0000 && *extension != 0x0010)
        .map(|extension| format!("{extension:04x}"))
        .collect::<Vec<_>>()
        .join(",");

    let (alpn_first, alpn_last) = alpn.map(first_last_alpn).unwrap_or(('0', '0'));

    format!(
        "t{}{:02}{alpn_first}{alpn_last}_{cipher:04x}_{}",
        tls_version(version),
        filtered_extensions.len().min(99),
        hash12(&extension_hash_input)
    )
}

fn first_last_alpn(alpn: &str) -> (char, char) {
    let bytes = alpn.as_bytes();
    let first = bytes.first().copied().unwrap_or(b'0');
    let last = bytes.last().copied().unwrap_or(first);
    (alpn_char(first), alpn_char(last))
}

fn alpn_char(value: u8) -> char {
    if value.is_ascii_alphanumeric() {
        value as char
    } else {
        const HEX: &[u8; 16] = b"0123456789abcdef";
        HEX[usize::from(value & 0x0f)] as char
    }
}

fn hash12(input: &str) -> String {
    let digest = Sha256::digest(input.as_bytes());
    digest
        .iter()
        .take(6)
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn tls_version(version: u16) -> &'static str {
    match version {
        0x0304 => "13",
        0x0303 => "12",
        0x0302 => "11",
        0x0301 => "10",
        0x0300 => "s3",
        _ => "00",
    }
}

#[cfg(test)]
mod tests {
    use super::{fingerprint, parse_ja4s};

    #[test]
    fn parses_tls13_server_hello_ja4s() {
        let ja4s = parse_ja4s(&tls_server_hello_payload()).unwrap();

        assert_eq!(ja4s, "t1302h2_1301_b9a491fefe05");
    }

    #[test]
    fn emits_server_fingerprint_from_ipv4_packet() {
        let event = fingerprint(&tls_server_hello_packet()).unwrap();

        assert_eq!(event.source_ip.to_string(), "198.51.100.40");
        assert_eq!(event.ja4s, "t1302h2_1301_b9a491fefe05");
    }

    #[test]
    fn ignores_client_hello() {
        assert!(parse_ja4s(&tls_client_hello_payload()).is_none());
    }

    #[test]
    fn malformed_payloads_do_not_panic() {
        let seeds = [
            Vec::new(),
            vec![0x16],
            vec![0x16, 0x03, 0x03, 0xff, 0xff],
            tls_server_hello_payload()[..12].to_vec(),
        ];

        for seed in seeds {
            assert!(parse_ja4s(&seed).is_none());
        }

        let mut payload = Vec::new();
        for len in 0..512 {
            payload.clear();
            for index in 0..len {
                payload.push(((index * 31 + len * 17) & 0xff) as u8);
            }
            let _ = parse_ja4s(&payload);
        }
    }

    pub(crate) fn tls_server_hello_packet() -> Vec<u8> {
        ipv4_tcp_packet(
            [198, 51, 100, 40],
            [192, 0, 2, 22],
            443,
            49_153,
            &tls_server_hello_payload(),
        )
    }

    fn tls_server_hello_payload() -> Vec<u8> {
        let mut body = Vec::new();
        body.extend_from_slice(&[0x03, 0x03]);
        body.extend_from_slice(&[0u8; 32]);
        body.push(0x00);
        body.extend_from_slice(&0x1301u16.to_be_bytes());
        body.push(0x00);

        let mut extensions = Vec::new();
        extensions.extend_from_slice(&0x002bu16.to_be_bytes());
        extensions.extend_from_slice(&2u16.to_be_bytes());
        extensions.extend_from_slice(&0x0304u16.to_be_bytes());
        extensions.extend_from_slice(&0x0010u16.to_be_bytes());
        extensions.extend_from_slice(&5u16.to_be_bytes());
        extensions.extend_from_slice(&3u16.to_be_bytes());
        extensions.push(2);
        extensions.extend_from_slice(b"h2");

        body.extend_from_slice(&(extensions.len() as u16).to_be_bytes());
        body.extend_from_slice(&extensions);

        let body_len = body.len() as u32;
        let mut handshake = vec![
            0x02,
            ((body_len >> 16) & 0xff) as u8,
            ((body_len >> 8) & 0xff) as u8,
            (body_len & 0xff) as u8,
        ];
        handshake.extend_from_slice(&body);

        let record_len = handshake.len() as u16;
        let mut record = vec![0x16, 0x03, 0x03];
        record.extend_from_slice(&record_len.to_be_bytes());
        record.extend_from_slice(&handshake);
        record
    }

    fn tls_client_hello_payload() -> Vec<u8> {
        let mut body = Vec::new();
        body.extend_from_slice(&[0x03, 0x03]);
        body.extend_from_slice(&[0u8; 32]);
        body.push(0x00);
        body.extend_from_slice(&2u16.to_be_bytes());
        body.extend_from_slice(&0x1301u16.to_be_bytes());
        body.push(0x01);
        body.push(0x00);
        body.extend_from_slice(&0u16.to_be_bytes());

        let body_len = body.len() as u32;
        let mut handshake = vec![
            0x01,
            ((body_len >> 16) & 0xff) as u8,
            ((body_len >> 8) & 0xff) as u8,
            (body_len & 0xff) as u8,
        ];
        handshake.extend_from_slice(&body);

        let record_len = handshake.len() as u16;
        let mut record = vec![0x16, 0x03, 0x03];
        record.extend_from_slice(&record_len.to_be_bytes());
        record.extend_from_slice(&handshake);
        record
    }

    fn ipv4_tcp_packet(
        source_ip: [u8; 4],
        destination_ip: [u8; 4],
        source_port: u16,
        destination_port: u16,
        payload: &[u8],
    ) -> Vec<u8> {
        let total_len = 20 + 20 + payload.len();
        let mut packet = Vec::with_capacity(total_len);
        packet.extend_from_slice(&[
            0x45,
            0x00,
            ((total_len >> 8) & 0xff) as u8,
            (total_len & 0xff) as u8,
            0x12,
            0x34,
            0x40,
            0x00,
            0x40,
            0x06,
            0x00,
            0x00,
        ]);
        packet.extend_from_slice(&source_ip);
        packet.extend_from_slice(&destination_ip);
        packet.extend_from_slice(&source_port.to_be_bytes());
        packet.extend_from_slice(&destination_port.to_be_bytes());
        packet.extend_from_slice(&[0x01, 0x02, 0x03, 0x04]);
        packet.extend_from_slice(&[0x00, 0x00, 0x00, 0x01]);
        packet.extend_from_slice(&[0x50, 0x18]);
        packet.extend_from_slice(&0xfa_f0u16.to_be_bytes());
        packet.extend_from_slice(&0u16.to_be_bytes());
        packet.extend_from_slice(&0u16.to_be_bytes());
        packet.extend_from_slice(payload);
        packet
    }
}
