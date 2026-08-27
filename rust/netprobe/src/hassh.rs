const SSH_MSG_KEXINIT: u8 = 20;
const KEXINIT_COOKIE_LEN: usize = 16;
const SSH_PACKET_HEADER_LEN: usize = 5;
const MAX_SSH_PACKET_LEN: usize = 256 * 1024;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SshKexInit {
    pub kex_algorithms: String,
    pub server_host_key_algorithms: String,
    pub encryption_algorithms_client_to_server: String,
    pub encryption_algorithms_server_to_client: String,
    pub mac_algorithms_client_to_server: String,
    pub mac_algorithms_server_to_client: String,
    pub compression_algorithms_client_to_server: String,
    pub compression_algorithms_server_to_client: String,
}

pub fn fingerprint_client(kexinit: &SshKexInit) -> HasshFingerprint {
    let canonical = canonical_client_string(kexinit);
    HasshFingerprint {
        canonical_string: canonical.clone(),
        md5: md5_hex(&canonical),
    }
}

pub fn fingerprint_server(kexinit: &SshKexInit) -> HasshFingerprint {
    let canonical = canonical_server_string(kexinit);
    HasshFingerprint {
        canonical_string: canonical.clone(),
        md5: md5_hex(&canonical),
    }
}

pub fn fingerprint_ssh_kexinit(payload: &[u8]) -> Option<HasshPair> {
    let kexinit = parse_ssh_kexinit(payload)?;
    Some(HasshPair {
        client: fingerprint_client(&kexinit),
        server: fingerprint_server(&kexinit),
    })
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HasshFingerprint {
    pub canonical_string: String,
    pub md5: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HasshPair {
    pub client: HasshFingerprint,
    pub server: HasshFingerprint,
}

pub fn canonical_client_string(kexinit: &SshKexInit) -> String {
    // Corelight HASSH canonical strings use KEX, encryption, MAC, and
    // compression lists. The SSH server-host-key list is parsed for callers
    // that need the full KEXINIT shape, but it is not part of the hash input.
    canonical_string(
        &kexinit.kex_algorithms,
        &kexinit.encryption_algorithms_client_to_server,
        &kexinit.mac_algorithms_client_to_server,
        &kexinit.compression_algorithms_client_to_server,
    )
}

pub fn canonical_server_string(kexinit: &SshKexInit) -> String {
    canonical_string(
        &kexinit.kex_algorithms,
        &kexinit.encryption_algorithms_server_to_client,
        &kexinit.mac_algorithms_server_to_client,
        &kexinit.compression_algorithms_server_to_client,
    )
}

pub fn parse_ssh_kexinit(payload: &[u8]) -> Option<SshKexInit> {
    let packet = strip_optional_identification(payload)?;
    parse_binary_packet(packet)
}

fn canonical_string(kex: &str, encryption: &str, mac: &str, compression: &str) -> String {
    format!("{kex};{encryption};{mac};{compression}")
}

fn md5_hex(input: &str) -> String {
    md5_digest(input.as_bytes())
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn md5_digest(input: &[u8]) -> [u8; 16] {
    const S: [u32; 64] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 5, 9, 14, 20, 5, 9, 14, 20, 5,
        9, 14, 20, 5, 9, 14, 20, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 6, 10,
        15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ];
    const K: [u32; 64] = [
        0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613,
        0xfd469501, 0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193,
        0xa679438e, 0x49b40821, 0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d,
        0x02441453, 0xd8a1e681, 0xe7d3fbc8, 0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
        0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a, 0xfffa3942, 0x8771f681, 0x6d9d6122,
        0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70, 0x289b7ec6, 0xeaa127fa,
        0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665, 0xf4292244,
        0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
        0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb,
        0xeb86d391,
    ];

    let bit_len = (input.len() as u64).wrapping_mul(8);
    let mut message = Vec::with_capacity(input.len() + 72);
    message.extend_from_slice(input);
    message.push(0x80);
    while message.len() % 64 != 56 {
        message.push(0);
    }
    message.extend_from_slice(&bit_len.to_le_bytes());

    let mut a0 = 0x67452301u32;
    let mut b0 = 0xefcdab89u32;
    let mut c0 = 0x98badcfeu32;
    let mut d0 = 0x10325476u32;

    for chunk in message.as_chunks::<64>().0 {
        let mut words = [0u32; 16];
        for (word, bytes) in words.iter_mut().zip(chunk.as_chunks::<4>().0) {
            *word = u32::from_le_bytes(*bytes);
        }

        let mut a = a0;
        let mut b = b0;
        let mut c = c0;
        let mut d = d0;

        for i in 0..64 {
            let (f, g) = match i {
                0..=15 => ((b & c) | ((!b) & d), i),
                16..=31 => ((d & b) | ((!d) & c), (5 * i + 1) % 16),
                32..=47 => (b ^ c ^ d, (3 * i + 5) % 16),
                _ => (c ^ (b | (!d)), (7 * i) % 16),
            };

            let next = b.wrapping_add(
                a.wrapping_add(f)
                    .wrapping_add(K[i])
                    .wrapping_add(words[g])
                    .rotate_left(S[i]),
            );
            a = d;
            d = c;
            c = b;
            b = next;
        }

        a0 = a0.wrapping_add(a);
        b0 = b0.wrapping_add(b);
        c0 = c0.wrapping_add(c);
        d0 = d0.wrapping_add(d);
    }

    let mut out = [0u8; 16];
    out[0..4].copy_from_slice(&a0.to_le_bytes());
    out[4..8].copy_from_slice(&b0.to_le_bytes());
    out[8..12].copy_from_slice(&c0.to_le_bytes());
    out[12..16].copy_from_slice(&d0.to_le_bytes());
    out
}

fn strip_optional_identification(payload: &[u8]) -> Option<&[u8]> {
    if payload.len() >= SSH_PACKET_HEADER_LEN {
        let packet_len = u32::from_be_bytes(payload[0..4].try_into().ok()?) as usize;
        if packet_len <= MAX_SSH_PACKET_LEN && payload.len() >= 4 + packet_len {
            return Some(payload);
        }
    }

    let newline = payload.iter().position(|byte| *byte == b'\n')?;
    let ident = &payload[..newline];
    if !ident.starts_with(b"SSH-") {
        return None;
    }
    payload.get(newline + 1..)
}

fn parse_binary_packet(packet: &[u8]) -> Option<SshKexInit> {
    if packet.len() < SSH_PACKET_HEADER_LEN {
        return None;
    }

    let packet_len = u32::from_be_bytes(packet[0..4].try_into().ok()?) as usize;
    if !(2..=MAX_SSH_PACKET_LEN).contains(&packet_len) {
        return None;
    }
    let packet_end = 4usize.checked_add(packet_len)?;
    if packet_end > packet.len() {
        return None;
    }

    let padding_len = usize::from(packet[4]);
    if padding_len + 1 > packet_len {
        return None;
    }
    let payload_end = packet_end.checked_sub(padding_len)?;
    let payload = packet.get(SSH_PACKET_HEADER_LEN..payload_end)?;
    if payload.len() < 1 + KEXINIT_COOKIE_LEN || payload[0] != SSH_MSG_KEXINIT {
        return None;
    }

    let mut cursor = 1 + KEXINIT_COOKIE_LEN;
    let kex_algorithms = read_name_list(payload, &mut cursor)?;
    let server_host_key_algorithms = read_name_list(payload, &mut cursor)?;
    let encryption_algorithms_client_to_server = read_name_list(payload, &mut cursor)?;
    let encryption_algorithms_server_to_client = read_name_list(payload, &mut cursor)?;
    let mac_algorithms_client_to_server = read_name_list(payload, &mut cursor)?;
    let mac_algorithms_server_to_client = read_name_list(payload, &mut cursor)?;
    let compression_algorithms_client_to_server = read_name_list(payload, &mut cursor)?;
    let compression_algorithms_server_to_client = read_name_list(payload, &mut cursor)?;
    let _languages_client_to_server = read_name_list(payload, &mut cursor)?;
    let _languages_server_to_client = read_name_list(payload, &mut cursor)?;

    if payload.get(cursor).is_none() || payload.get(cursor + 1..cursor + 5).is_none() {
        return None;
    }

    Some(SshKexInit {
        kex_algorithms,
        server_host_key_algorithms,
        encryption_algorithms_client_to_server,
        encryption_algorithms_server_to_client,
        mac_algorithms_client_to_server,
        mac_algorithms_server_to_client,
        compression_algorithms_client_to_server,
        compression_algorithms_server_to_client,
    })
}

fn read_name_list(payload: &[u8], cursor: &mut usize) -> Option<String> {
    let len_bytes = payload.get(*cursor..cursor.checked_add(4)?)?;
    let len = u32::from_be_bytes(len_bytes.try_into().ok()?) as usize;
    *cursor = cursor.checked_add(4)?;
    let list = payload.get(*cursor..cursor.checked_add(len)?)?;
    *cursor = cursor.checked_add(len)?;

    let list = std::str::from_utf8(list).ok()?;
    if list.contains(';') || list.contains('\0') || !list.is_ascii() {
        return None;
    }

    Some(list.to_string())
}

#[cfg(test)]
mod tests {
    use super::{
        SshKexInit, canonical_client_string, canonical_server_string, fingerprint_client,
        fingerprint_server, fingerprint_ssh_kexinit, parse_ssh_kexinit,
    };

    const CYBERDUCK_KEX: &str = "curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256,ecdh-sha2-nistp521,ecdh-sha2-nistp384,ecdh-sha2-nistp256,diffie-hellman-group-exchange-sha1,diffie-hellman-group1-sha1,diffie-hellman-group14-sha1,diffie-hellman-group14-sha256,diffie-hellman-group15-sha512,diffie-hellman-group16-sha512,diffie-hellman-group17-sha512,diffie-hellman-group18-sha512,diffie-hellman-group14-sha256@ssh.com,diffie-hellman-group15-sha256,diffie-hellman-group15-sha256@ssh.com,diffie-hellman-group15-sha384@ssh.com,diffie-hellman-group16-sha256,diffie-hellman-group16-sha384@ssh.com,diffie-hellman-group16-sha512@ssh.com,diffie-hellman-group18-sha512@ssh.com";
    const CYBERDUCK_ENCRYPTION: &str = "aes128-cbc,aes128-ctr,aes192-cbc,aes192-ctr,aes256-cbc,aes256-ctr,blowfish-cbc,blowfish-ctr,cast128-cbc,cast128-ctr,idea-cbc,idea-ctr,serpent128-cbc,serpent128-ctr,serpent192-cbc,serpent192-ctr,serpent256-cbc,serpent256-ctr,3des-cbc,3des-ctr,twofish128-cbc,twofish128-ctr,twofish192-cbc,twofish192-ctr,twofish256-cbc,twofish256-ctr,twofish-cbc,arcfour,arcfour128,arcfour256";
    const CYBERDUCK_MAC: &str =
        "hmac-sha1,hmac-sha1-96,hmac-md5,hmac-md5-96,hmac-sha2-256,hmac-sha2-512";
    const CYBERDUCK_COMPRESSION: &str = "zlib@openssh.com,zlib,none";

    const OPENSSH_53_SERVER_KEX: &str = "diffie-hellman-group-exchange-sha256,diffie-hellman-group-exchange-sha1,diffie-hellman-group14-sha1,diffie-hellman-group1-sha1";
    const OPENSSH_53_SERVER_ENCRYPTION: &str = "aes128-ctr,aes192-ctr,aes256-ctr,arcfour256,arcfour128,aes128-cbc,3des-cbc,blowfish-cbc,cast128-cbc,aes192-cbc,aes256-cbc,arcfour,rijndael-cbc@lysator.liu.se";
    const OPENSSH_53_SERVER_MAC: &str = "hmac-md5,hmac-sha1,umac-64@openssh.com,hmac-ripemd160,hmac-ripemd160@openssh.com,hmac-sha1-96,hmac-md5-96";
    const OPENSSH_53_SERVER_COMPRESSION: &str = "none,zlib@openssh.com";

    #[test]
    fn matches_corelight_client_reference_vector() {
        let kexinit = cyberduck_kexinit();

        assert_eq!(
            canonical_client_string(&kexinit),
            format!(
                "{CYBERDUCK_KEX};{CYBERDUCK_ENCRYPTION};{CYBERDUCK_MAC};{CYBERDUCK_COMPRESSION}"
            )
        );
        assert_eq!(
            fingerprint_client(&kexinit).md5,
            "8a8ae540028bf433cd68356c1b9e8d5b"
        );
    }

    #[test]
    fn matches_corelight_server_reference_canonical_string() {
        let kexinit = openssh_53_server_kexinit();

        assert_eq!(
            canonical_server_string(&kexinit),
            format!(
                "{OPENSSH_53_SERVER_KEX};{OPENSSH_53_SERVER_ENCRYPTION};{OPENSSH_53_SERVER_MAC};{OPENSSH_53_SERVER_COMPRESSION}"
            )
        );
        assert_eq!(
            fingerprint_server(&kexinit).md5,
            "b1c6c0d56317555b85c7005a3de29325"
        );
    }

    #[test]
    fn parses_ssh_kexinit_binary_packet() {
        let expected = minimal_kexinit();
        let packet = ssh_kexinit_packet(&expected);

        assert_eq!(parse_ssh_kexinit(&packet), Some(expected.clone()));
        let pair = fingerprint_ssh_kexinit(&packet).unwrap();
        assert_eq!(pair.client.md5, fingerprint_client(&expected).md5);
        assert_eq!(pair.server.md5, fingerprint_server(&expected).md5);
    }

    #[test]
    fn parses_ssh_kexinit_after_identification_banner() {
        let expected = minimal_kexinit();
        let mut payload = b"SSH-2.0-OpenSSH_9.9\r\n".to_vec();
        payload.extend_from_slice(&ssh_kexinit_packet(&expected));

        assert_eq!(parse_ssh_kexinit(&payload), Some(expected));
    }

    #[test]
    fn rejects_malformed_packets() {
        assert_eq!(parse_ssh_kexinit(b"SSH-2.0-only-banner\r\n"), None);
        assert_eq!(parse_ssh_kexinit(&[0, 0, 0, 1, 0]), None);

        let mut packet = ssh_kexinit_packet(&minimal_kexinit());
        packet[5] = 99;
        assert_eq!(parse_ssh_kexinit(&packet), None);
    }

    #[test]
    fn md5_digest_matches_rfc_reference_vectors() {
        assert_eq!(super::md5_hex(""), "d41d8cd98f00b204e9800998ecf8427e");
        assert_eq!(super::md5_hex("abc"), "900150983cd24fb0d6963f7d28e17f72");
        assert_eq!(
            super::md5_hex("message digest"),
            "f96b697d7cb7938d525a2f31aaf161d0"
        );
    }

    fn cyberduck_kexinit() -> SshKexInit {
        SshKexInit {
            kex_algorithms: CYBERDUCK_KEX.to_string(),
            server_host_key_algorithms: "ssh-ed25519,rsa-sha2-512".to_string(),
            encryption_algorithms_client_to_server: CYBERDUCK_ENCRYPTION.to_string(),
            encryption_algorithms_server_to_client: CYBERDUCK_ENCRYPTION.to_string(),
            mac_algorithms_client_to_server: CYBERDUCK_MAC.to_string(),
            mac_algorithms_server_to_client: CYBERDUCK_MAC.to_string(),
            compression_algorithms_client_to_server: CYBERDUCK_COMPRESSION.to_string(),
            compression_algorithms_server_to_client: CYBERDUCK_COMPRESSION.to_string(),
        }
    }

    fn openssh_53_server_kexinit() -> SshKexInit {
        SshKexInit {
            kex_algorithms: OPENSSH_53_SERVER_KEX.to_string(),
            server_host_key_algorithms: "ssh-rsa,ssh-dss".to_string(),
            encryption_algorithms_client_to_server: "ignored-c2s".to_string(),
            encryption_algorithms_server_to_client: OPENSSH_53_SERVER_ENCRYPTION.to_string(),
            mac_algorithms_client_to_server: "ignored-c2s".to_string(),
            mac_algorithms_server_to_client: OPENSSH_53_SERVER_MAC.to_string(),
            compression_algorithms_client_to_server: "ignored-c2s".to_string(),
            compression_algorithms_server_to_client: OPENSSH_53_SERVER_COMPRESSION.to_string(),
        }
    }

    fn minimal_kexinit() -> SshKexInit {
        SshKexInit {
            kex_algorithms: "curve25519-sha256".to_string(),
            server_host_key_algorithms: "ssh-ed25519".to_string(),
            encryption_algorithms_client_to_server: "chacha20-poly1305@openssh.com".to_string(),
            encryption_algorithms_server_to_client: "aes128-ctr".to_string(),
            mac_algorithms_client_to_server: "hmac-sha2-256".to_string(),
            mac_algorithms_server_to_client: "hmac-sha1".to_string(),
            compression_algorithms_client_to_server: "none".to_string(),
            compression_algorithms_server_to_client: "zlib@openssh.com".to_string(),
        }
    }

    fn ssh_kexinit_packet(kexinit: &SshKexInit) -> Vec<u8> {
        let mut payload = vec![20];
        payload.extend_from_slice(&[7u8; 16]);
        push_name_list(&mut payload, &kexinit.kex_algorithms);
        push_name_list(&mut payload, &kexinit.server_host_key_algorithms);
        push_name_list(
            &mut payload,
            &kexinit.encryption_algorithms_client_to_server,
        );
        push_name_list(
            &mut payload,
            &kexinit.encryption_algorithms_server_to_client,
        );
        push_name_list(&mut payload, &kexinit.mac_algorithms_client_to_server);
        push_name_list(&mut payload, &kexinit.mac_algorithms_server_to_client);
        push_name_list(
            &mut payload,
            &kexinit.compression_algorithms_client_to_server,
        );
        push_name_list(
            &mut payload,
            &kexinit.compression_algorithms_server_to_client,
        );
        push_name_list(&mut payload, "");
        push_name_list(&mut payload, "");
        payload.push(0);
        payload.extend_from_slice(&0u32.to_be_bytes());

        let block_size = 8usize;
        let mut padding_len = block_size - ((payload.len() + 5) % block_size);
        if padding_len < 4 {
            padding_len += block_size;
        }
        let packet_len = payload.len() + padding_len + 1;

        let mut packet = Vec::new();
        packet.extend_from_slice(&(packet_len as u32).to_be_bytes());
        packet.push(padding_len as u8);
        packet.extend_from_slice(&payload);
        packet.extend(std::iter::repeat_n(0, padding_len));
        packet
    }

    fn push_name_list(output: &mut Vec<u8>, value: &str) {
        output.extend_from_slice(&(value.len() as u32).to_be_bytes());
        output.extend_from_slice(value.as_bytes());
    }
}
