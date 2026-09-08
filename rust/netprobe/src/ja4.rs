use sha2::{Digest, Sha256};

const EXT_SNI: u16 = 0x0000;
const EXT_ALPN: u16 = 0x0010;
const EXT_SIGNATURE_ALGORITHMS: u16 = 0x000d;
const EXT_SUPPORTED_VERSIONS: u16 = 0x002b;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Ja4ClientHello {
    pub transport: Ja4Transport,
    pub protocol_version: u16,
    pub supported_versions: Vec<u16>,
    pub has_sni: bool,
    pub cipher_suites: Vec<u16>,
    pub extensions: Vec<u16>,
    pub signature_algorithms: Vec<u16>,
    pub alpn_first_value: Option<Vec<u8>>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Ja4Transport {
    TlsOverTcp,
    Quic,
    Dtls,
}

pub fn fingerprint_tls_client_hello(payload: &[u8]) -> Option<String> {
    parse_tls_client_hello(payload).map(|client_hello| fingerprint(&client_hello))
}

pub fn fingerprint(client_hello: &Ja4ClientHello) -> String {
    let ciphers = filtered_sorted(client_hello.cipher_suites.iter().copied());
    let extensions = filtered_extensions_for_count(&client_hello.extensions);
    let extensions_for_hash = filtered_sorted(
        client_hello
            .extensions
            .iter()
            .copied()
            .filter(|extension| *extension != EXT_SNI && *extension != EXT_ALPN),
    );
    let signature_algorithms = client_hello
        .signature_algorithms
        .iter()
        .copied()
        .filter(|value| !is_grease(*value))
        .collect::<Vec<_>>();

    format!(
        "{}{}{}{}{}{}_{}_{}",
        transport_prefix(client_hello.transport),
        version_code(client_hello),
        if client_hello.has_sni { "d" } else { "i" },
        capped_count(ciphers.len()),
        capped_count(extensions.len()),
        alpn_code(client_hello.alpn_first_value.as_deref()),
        hash_or_zero(&ciphers),
        extension_hash_or_zero(&extensions_for_hash, &signature_algorithms),
    )
}

pub fn parse_tls_client_hello(payload: &[u8]) -> Option<Ja4ClientHello> {
    if payload.len() < 9 || payload[0] != 0x16 || payload[5] != 0x01 {
        return None;
    }
    let record_len = u16::from_be_bytes([payload[3], payload[4]]) as usize;
    if payload.len() < 5 + record_len {
        return None;
    }

    let handshake_len =
        ((payload[6] as usize) << 16) | ((payload[7] as usize) << 8) | payload[8] as usize;
    let handshake_end = 9usize.checked_add(handshake_len)?;
    if handshake_len < 38 || handshake_end > payload.len() {
        return None;
    }

    let protocol_version = u16::from_be_bytes([payload[9], payload[10]]);
    let mut offset = 11 + 32;

    let session_len = usize::from(*payload.get(offset)?);
    offset = offset.checked_add(1 + session_len)?;
    if offset + 2 > handshake_end {
        return None;
    }

    let cipher_len = u16::from_be_bytes([payload[offset], payload[offset + 1]]) as usize;
    offset += 2;
    if cipher_len & 1 != 0 || offset + cipher_len > handshake_end {
        return None;
    }
    let cipher_suites = payload[offset..offset + cipher_len]
        .as_chunks::<2>()
        .0
        .iter()
        .map(|chunk| u16::from_be_bytes(*chunk))
        .collect::<Vec<_>>();
    offset += cipher_len;

    let compression_len = usize::from(*payload.get(offset)?);
    offset = offset.checked_add(1 + compression_len)?;
    if offset == handshake_end {
        return Some(Ja4ClientHello {
            transport: Ja4Transport::TlsOverTcp,
            protocol_version,
            supported_versions: Vec::new(),
            has_sni: false,
            cipher_suites,
            extensions: Vec::new(),
            signature_algorithms: Vec::new(),
            alpn_first_value: None,
        });
    }
    if offset + 2 > handshake_end {
        return None;
    }

    let extensions_len = u16::from_be_bytes([payload[offset], payload[offset + 1]]) as usize;
    offset += 2;
    let extensions_end = offset.checked_add(extensions_len)?;
    if extensions_end > handshake_end {
        return None;
    }

    let mut extensions = Vec::new();
    let mut supported_versions = Vec::new();
    let mut signature_algorithms = Vec::new();
    let mut alpn_first_value = None;
    let mut has_sni = false;

    while offset + 4 <= extensions_end {
        let extension_type = u16::from_be_bytes([payload[offset], payload[offset + 1]]);
        let extension_len = u16::from_be_bytes([payload[offset + 2], payload[offset + 3]]) as usize;
        offset += 4;
        let extension_end = offset.checked_add(extension_len)?;
        if extension_end > extensions_end {
            return None;
        }

        let extension_data = &payload[offset..extension_end];
        extensions.push(extension_type);
        match extension_type {
            EXT_SNI => has_sni = true,
            EXT_ALPN => {
                alpn_first_value = parse_first_alpn(extension_data).map(|value| value.to_vec());
            }
            EXT_SIGNATURE_ALGORITHMS => {
                signature_algorithms = parse_u16_list(extension_data, 2);
            }
            EXT_SUPPORTED_VERSIONS => {
                supported_versions = parse_supported_versions(extension_data);
            }
            _ => {}
        }

        offset = extension_end;
    }

    if offset != extensions_end {
        return None;
    }

    Some(Ja4ClientHello {
        transport: Ja4Transport::TlsOverTcp,
        protocol_version,
        supported_versions,
        has_sni,
        cipher_suites,
        extensions,
        signature_algorithms,
        alpn_first_value,
    })
}

fn transport_prefix(transport: Ja4Transport) -> &'static str {
    match transport {
        Ja4Transport::TlsOverTcp => "t",
        Ja4Transport::Quic => "q",
        Ja4Transport::Dtls => "d",
    }
}

fn version_code(client_hello: &Ja4ClientHello) -> &'static str {
    let selected = client_hello
        .supported_versions
        .iter()
        .copied()
        .filter(|value| !is_grease(*value))
        .max()
        .unwrap_or(client_hello.protocol_version);

    match selected {
        0x0304 => "13",
        0x0303 => "12",
        0x0302 => "11",
        0x0301 => "10",
        0x0300 => "s3",
        0x0002 => "s2",
        0xfeff => "d1",
        0xfefd => "d2",
        0xfefc => "d3",
        _ => "00",
    }
}

fn capped_count(count: usize) -> String {
    format!("{:02}", count.min(99))
}

fn alpn_code(value: Option<&[u8]>) -> String {
    let Some(value) = value.filter(|value| !value.is_empty()) else {
        return "00".to_string();
    };
    let first = value[0];
    let last = *value.last().unwrap_or(&first);
    if first.is_ascii_alphanumeric() && last.is_ascii_alphanumeric() {
        return format!("{}{}", first as char, last as char);
    }
    let first_hex = hex_byte(first).as_bytes()[0] as char;
    let last_hex = hex_byte(last).as_bytes()[1] as char;
    format!("{first_hex}{last_hex}")
}

fn hash_or_zero(values: &[u16]) -> String {
    if values.is_empty() {
        return "000000000000".to_string();
    }
    hash12(&hex_list(values))
}

fn extension_hash_or_zero(extensions: &[u16], signature_algorithms: &[u16]) -> String {
    if extensions.is_empty() {
        return "000000000000".to_string();
    }

    let mut input = hex_list(extensions);
    if !signature_algorithms.is_empty() {
        input.push('_');
        input.push_str(&hex_list(signature_algorithms));
    }
    hash12(&input)
}

fn hash12(input: &str) -> String {
    let digest = Sha256::digest(input.as_bytes());
    digest
        .iter()
        .take(6)
        .map(|byte| hex_byte(*byte))
        .collect::<String>()
}

fn filtered_sorted(values: impl Iterator<Item = u16>) -> Vec<u16> {
    let mut values = values
        .filter(|value| !is_grease(*value))
        .collect::<Vec<_>>();
    values.sort_unstable();
    values
}

fn filtered_extensions_for_count(extensions: &[u16]) -> Vec<u16> {
    extensions
        .iter()
        .copied()
        .filter(|value| !is_grease(*value))
        .collect()
}

fn hex_list(values: &[u16]) -> String {
    values
        .iter()
        .map(|value| hex_u16(*value))
        .collect::<Vec<_>>()
        .join(",")
}

fn hex_u16(value: u16) -> String {
    format!("{value:04x}")
}

fn hex_byte(value: u8) -> String {
    format!("{value:02x}")
}

fn is_grease(value: u16) -> bool {
    value & 0x0f0f == 0x0a0a && ((value >> 8) as u8) == (value as u8)
}

fn parse_first_alpn(data: &[u8]) -> Option<&[u8]> {
    if data.len() < 3 {
        return None;
    }
    let list_len = u16::from_be_bytes([data[0], data[1]]) as usize;
    if data.len() < 2 + list_len || list_len == 0 {
        return None;
    }
    let value_len = usize::from(data[2]);
    if value_len == 0 || data.len() < 3 + value_len {
        return None;
    }
    Some(&data[3..3 + value_len])
}

fn parse_u16_list(data: &[u8], length_prefix_bytes: usize) -> Vec<u16> {
    let Some(list) = strip_length_prefix(data, length_prefix_bytes) else {
        return Vec::new();
    };
    list.as_chunks::<2>()
        .0
        .iter()
        .map(|chunk| u16::from_be_bytes(*chunk))
        .collect()
}

fn parse_supported_versions(data: &[u8]) -> Vec<u16> {
    let Some(list) = strip_length_prefix(data, 1) else {
        return Vec::new();
    };
    list.as_chunks::<2>()
        .0
        .iter()
        .map(|chunk| u16::from_be_bytes(*chunk))
        .collect()
}

fn strip_length_prefix(data: &[u8], length_prefix_bytes: usize) -> Option<&[u8]> {
    match length_prefix_bytes {
        1 => {
            let len = usize::from(*data.first()?);
            data.get(1..1 + len)
        }
        2 => {
            if data.len() < 2 {
                return None;
            }
            let len = u16::from_be_bytes([data[0], data[1]]) as usize;
            data.get(2..2 + len)
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::{Ja4ClientHello, Ja4Transport, fingerprint, fingerprint_tls_client_hello};

    #[test]
    fn matches_foxio_reference_vector() {
        let client_hello = Ja4ClientHello {
            transport: Ja4Transport::TlsOverTcp,
            protocol_version: 0x0303,
            supported_versions: vec![0x0304, 0x0303],
            has_sni: true,
            cipher_suites: vec![
                0x1301, 0x1302, 0x1303, 0xc02b, 0xc02f, 0xc02c, 0xc030, 0xcca9, 0xcca8, 0xc013,
                0xc014, 0x009c, 0x009d, 0x002f, 0x0035,
            ],
            extensions: vec![
                0x001b, 0x0000, 0x0033, 0x0010, 0x4469, 0x0017, 0x002d, 0x000d, 0x0005, 0x0023,
                0x0012, 0x002b, 0xff01, 0x000b, 0x000a, 0x0015,
            ],
            signature_algorithms: vec![
                0x0403, 0x0804, 0x0401, 0x0503, 0x0805, 0x0501, 0x0806, 0x0601,
            ],
            alpn_first_value: Some(b"h2".to_vec()),
        };

        assert_eq!(
            fingerprint(&client_hello),
            "t13d1516h2_8daaf6152771_e5627efa2ab1"
        );
    }

    #[test]
    fn ignores_grease_values() {
        let client_hello = Ja4ClientHello {
            transport: Ja4Transport::TlsOverTcp,
            protocol_version: 0x0303,
            supported_versions: vec![0x0a0a, 0x0304],
            has_sni: true,
            cipher_suites: vec![0x0a0a, 0x1301, 0x1302],
            extensions: vec![0x0a0a, 0x0000, 0x0010, 0x002b, 0x000d],
            signature_algorithms: vec![0x0a0a, 0x0403],
            alpn_first_value: Some(b"h2".to_vec()),
        };

        assert!(fingerprint(&client_hello).starts_with("t13d0204h2_"));
    }

    #[test]
    fn parses_tls_client_hello_record() {
        let record = tls_client_hello_record();

        assert_eq!(
            fingerprint_tls_client_hello(&record).unwrap(),
            fingerprint(&Ja4ClientHello {
                transport: Ja4Transport::TlsOverTcp,
                protocol_version: 0x0303,
                supported_versions: vec![0x0304],
                has_sni: true,
                cipher_suites: vec![0x1301, 0x1302, 0x1303],
                extensions: vec![0x0000, 0x0010, 0x002b, 0x000d],
                signature_algorithms: vec![0x0403, 0x0804],
                alpn_first_value: Some(b"h2".to_vec()),
            })
        );
    }

    fn tls_client_hello_record() -> Vec<u8> {
        let mut body = Vec::new();
        body.extend_from_slice(&0x0303u16.to_be_bytes());
        body.extend_from_slice(&[0u8; 32]);
        body.push(0);
        body.extend_from_slice(&6u16.to_be_bytes());
        body.extend_from_slice(&[0x13, 0x01, 0x13, 0x02, 0x13, 0x03]);
        body.push(1);
        body.push(0);

        let mut extensions = Vec::new();
        push_extension(&mut extensions, 0x0000, &[0x00, 0x00]);
        push_extension(&mut extensions, 0x0010, &[0x00, 0x03, 0x02, b'h', b'2']);
        push_extension(&mut extensions, 0x002b, &[0x02, 0x03, 0x04]);
        push_extension(
            &mut extensions,
            0x000d,
            &[0x00, 0x04, 0x04, 0x03, 0x08, 0x04],
        );
        body.extend_from_slice(&(extensions.len() as u16).to_be_bytes());
        body.extend_from_slice(&extensions);

        let mut handshake = vec![0x01];
        let len = body.len() as u32;
        handshake.extend_from_slice(&[
            ((len >> 16) & 0xff) as u8,
            ((len >> 8) & 0xff) as u8,
            (len & 0xff) as u8,
        ]);
        handshake.extend_from_slice(&body);

        let mut record = vec![0x16, 0x03, 0x03];
        record.extend_from_slice(&(handshake.len() as u16).to_be_bytes());
        record.extend_from_slice(&handshake);
        record
    }

    fn push_extension(output: &mut Vec<u8>, extension_type: u16, data: &[u8]) {
        output.extend_from_slice(&extension_type.to_be_bytes());
        output.extend_from_slice(&(data.len() as u16).to_be_bytes());
        output.extend_from_slice(data);
    }
}
