//! Userspace p0f TCP-SYN signature encoder.
//!
//! Builds the canonical p0f v3 signature string from the raw fields the eBPF
//! captures in a `TcpSynSignatureRecord` (see `rust/netprobe/ebpf/src/lib.rs`).
//! This logic used to run inside the eBPF program, but the option/quirk string
//! building blew past the BPF verifier's complexity limit, so it now runs in
//! userspace from the raw record. The encoder is deliberately allocation-free
//! (fixed `[u8; P0F_SIGNATURE_MAX_LEN]` output buffer) and `core`-only so the
//! cost stays negligible.
//!
//! The quirk bit values MUST stay in sync with the `TCP_SYN_QUIRK_*` constants
//! in the eBPF source.

#![allow(clippy::cast_possible_truncation)]

pub const P0F_SIGNATURE_MAX_LEN: usize = 96;

const QUIRK_MALFORMED_OPTIONS: u32 = 1 << 0; // "bad"
const QUIRK_DF: u32 = 1 << 1; // "df"
const QUIRK_ID_PLUS: u32 = 1 << 2; // "id+"
const QUIRK_ID_MINUS: u32 = 1 << 3; // "id-"
const TCP_PAYLOAD_CLASS_NON_EMPTY: u8 = 1;

#[allow(clippy::too_many_arguments)]
pub fn encode(
    out: &mut [u8; P0F_SIGNATURE_MAX_LEN],
    ip_version: u16,
    ttl: u8,
    window_size: u16,
    mss: u16,
    options_layout: &[u8; 32],
    options_len: u8,
    window_scale: u8,
    payload_class: u8,
    quirks: u32,
) -> u8 {
    clear(out);

    let mut writer = Writer { out, len: 0 };
    writer.push_decimal_u16(ip_version);
    writer.push_byte(b':');
    writer.push_decimal_u8(ttl);
    writer.push_byte(b':');
    writer.push_byte(b'0');
    writer.push_byte(b':');
    writer.push_decimal_u16(mss);
    writer.push_byte(b':');
    writer.push_decimal_u16(window_size);
    writer.push_byte(b',');
    writer.push_decimal_u8(window_scale);
    writer.push_byte(b':');
    writer.push_option_layout(options_layout, options_len);
    writer.push_byte(b':');
    writer.push_quirks(quirks);
    writer.push_byte(b':');
    writer.push_payload_class(payload_class);
    writer.len_u8()
}

fn clear(out: &mut [u8; P0F_SIGNATURE_MAX_LEN]) {
    let mut index = 0usize;
    while index < P0F_SIGNATURE_MAX_LEN {
        out[index] = 0;
        index += 1;
    }
}

struct Writer<'a> {
    out: &'a mut [u8; P0F_SIGNATURE_MAX_LEN],
    len: usize,
}

impl Writer<'_> {
    fn len_u8(&self) -> u8 {
        if self.len > u8::MAX as usize {
            u8::MAX
        } else {
            self.len as u8
        }
    }

    fn push_byte(&mut self, byte: u8) {
        if self.len < P0F_SIGNATURE_MAX_LEN {
            self.out[self.len] = byte;
            self.len += 1;
        }
    }

    fn push_bytes(&mut self, bytes: &[u8]) {
        let mut index = 0usize;
        while index < bytes.len() {
            self.push_byte(bytes[index]);
            index += 1;
        }
    }

    fn push_decimal_u8(&mut self, value: u8) {
        self.push_decimal_u16(u16::from(value));
    }

    fn push_decimal_u16(&mut self, value: u16) {
        if value >= 10_000 {
            self.push_byte(b'0' + ((value / 10_000) % 10) as u8);
        }
        if value >= 1_000 {
            self.push_byte(b'0' + ((value / 1_000) % 10) as u8);
        }
        if value >= 100 {
            self.push_byte(b'0' + ((value / 100) % 10) as u8);
        }
        if value >= 10 {
            self.push_byte(b'0' + ((value / 10) % 10) as u8);
        }
        self.push_byte(b'0' + (value % 10) as u8);
    }

    fn push_option_layout(&mut self, options_layout: &[u8; 32], options_len: u8) {
        let mut index = 0usize;
        let max_options = min_usize(usize::from(options_len), options_layout.len());

        while index < max_options {
            if index > 0 {
                self.push_byte(b',');
            }

            self.push_option(options_layout[index]);
            index += 1;
        }
    }

    fn push_option(&mut self, kind: u8) {
        match kind {
            0 => self.push_bytes(b"eol"),
            1 => self.push_bytes(b"nop"),
            2 => self.push_bytes(b"mss"),
            3 => self.push_bytes(b"ws"),
            4 => self.push_bytes(b"sok"),
            5 => self.push_bytes(b"sack"),
            8 => self.push_bytes(b"ts"),
            _ => {
                self.push_byte(b'?');
                self.push_decimal_u8(kind);
            }
        }
    }

    // Emits the quirks in canonical p0f order, comma-separated. Matching is a
    // set membership test (p0f_matcher::quirks_match), so order is cosmetic, but
    // canonical order keeps the human-readable signature stable.
    fn push_quirks(&mut self, quirks: u32) {
        let mut wrote_any = false;
        for (bit, token) in [
            (QUIRK_DF, b"df".as_slice()),
            (QUIRK_ID_PLUS, b"id+".as_slice()),
            (QUIRK_ID_MINUS, b"id-".as_slice()),
            (QUIRK_MALFORMED_OPTIONS, b"bad".as_slice()),
        ] {
            if quirks & bit != 0 {
                if wrote_any {
                    self.push_byte(b',');
                }
                self.push_bytes(token);
                wrote_any = true;
            }
        }
    }

    fn push_payload_class(&mut self, payload_class: u8) {
        if payload_class == TCP_PAYLOAD_CLASS_NON_EMPTY {
            self.push_byte(b'+');
        } else {
            self.push_byte(b'0');
        }
    }
}

fn min_usize(left: usize, right: usize) -> usize {
    if left < right { left } else { right }
}

#[cfg(test)]
mod tests {
    use super::{P0F_SIGNATURE_MAX_LEN, encode};

    // Quirk bits mirrored from the eBPF TCP_SYN_QUIRK_* constants.
    const QUIRK_DF: u32 = 1 << 1;
    const QUIRK_ID_PLUS: u32 = 1 << 2;
    const QUIRK_MALFORMED_OPTIONS: u32 = 1 << 0;

    #[allow(clippy::too_many_arguments)]
    fn encode_to_string(
        ip_version: u16,
        ttl: u8,
        window_size: u16,
        mss: u16,
        options_layout: &[u8; 32],
        options_len: u8,
        window_scale: u8,
        payload_class: u8,
        quirks: u32,
    ) -> String {
        let mut out = [0u8; P0F_SIGNATURE_MAX_LEN];
        let len = encode(
            &mut out,
            ip_version,
            ttl,
            window_size,
            mss,
            options_layout,
            options_len,
            window_scale,
            payload_class,
            quirks,
        ) as usize;
        String::from_utf8(out[..len].to_vec()).unwrap()
    }

    fn options(kinds: &[u8]) -> ([u8; 32], u8) {
        let mut layout = [0u8; 32];
        layout[..kinds.len()].copy_from_slice(kinds);
        (layout, kinds.len() as u8)
    }

    #[test]
    fn encodes_linux_syn_signature_with_df_idplus() {
        // mss,sok,ts,nop,ws = kinds 2,4,8,1,3
        let (layout, len) = options(&[2, 4, 8, 1, 3]);
        let signature = encode_to_string(
            4,
            64,
            29_200,
            1_460,
            &layout,
            len,
            10,
            0,
            QUIRK_DF | QUIRK_ID_PLUS,
        );
        assert_eq!(signature, "4:64:0:1460:29200,10:mss,sok,ts,nop,ws:df,id+:0");
    }

    #[test]
    fn encodes_empty_quirks_and_nonempty_payload() {
        let (layout, len) = options(&[2, 1, 3]); // mss,nop,ws
        let signature = encode_to_string(4, 64, 1_024, 1_460, &layout, len, 0, 1, 0);
        assert_eq!(signature, "4:64:0:1460:1024,0:mss,nop,ws::+");
    }

    #[test]
    fn encodes_malformed_options_quirk() {
        let (layout, len) = options(&[2]);
        let signature = encode_to_string(
            4,
            64,
            1_024,
            1_460,
            &layout,
            len,
            0,
            0,
            QUIRK_MALFORMED_OPTIONS,
        );
        assert_eq!(signature, "4:64:0:1460:1024,0:mss:bad:0");
    }
}
