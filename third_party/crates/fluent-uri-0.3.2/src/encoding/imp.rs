use alloc::{string::String, vec::Vec};

const fn gen_octet_table(hi: bool) -> [u8; 256] {
    let mut out = [0xff; 256];
    let shift = if hi { 4 } else { 0 };

    let mut i = 0;
    while i < 10 {
        out[(i + b'0') as usize] = i << shift;
        i += 1;
    }
    while i < 16 {
        out[(i - 10 + b'A') as usize] = i << shift;
        out[(i - 10 + b'a') as usize] = i << shift;
        i += 1;
    }
    out
}

const OCTET_TABLE_HI: &[u8; 256] = &gen_octet_table(true);
pub(crate) const OCTET_TABLE_LO: &[u8; 256] = &gen_octet_table(false);

/// Decodes a percent-encoded octet, assuming that the bytes are hexadecimal.
pub(crate) fn decode_octet(hi: u8, lo: u8) -> u8 {
    debug_assert!(hi.is_ascii_hexdigit() && lo.is_ascii_hexdigit());
    OCTET_TABLE_HI[hi as usize] | OCTET_TABLE_LO[lo as usize]
}

/// Decodes a percent-encoded string, assuming that the string is properly encoded.
pub(crate) fn decode(s: &[u8]) -> Option<Vec<u8>> {
    // Skip bytes that are not '%'.
    let mut i = s.iter().position(|&x| x == b'%')?;

    let mut buf = Vec::with_capacity(s.len());
    buf.extend_from_slice(&s[..i]);

    while i < s.len() {
        let x = s[i];
        if x == b'%' {
            buf.push(decode_octet(s[i + 1], s[i + 2]));
            i += 3;
        } else {
            buf.push(x);
            i += 1;
        }
    }
    Some(buf)
}

pub(crate) fn encode_byte(x: u8, buf: &mut String) {
    const HEX_TABLE: [u8; 512] = {
        const HEX_DIGITS: &[u8; 16] = b"0123456789ABCDEF";

        let mut i = 0;
        let mut table = [0; 512];
        while i < 256 {
            table[i * 2] = HEX_DIGITS[i >> 4];
            table[i * 2 + 1] = HEX_DIGITS[i & 0b1111];
            i += 1;
        }
        table
    };

    buf.push('%');
    buf.push(HEX_TABLE[x as usize * 2] as char);
    buf.push(HEX_TABLE[x as usize * 2 + 1] as char);
}
