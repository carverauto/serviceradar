#![allow(clippy::cast_possible_truncation)]

pub const P0F_SIGNATURE_MAX_LEN: usize = 96;

const QUIRK_MALFORMED_OPTIONS: u32 = 1 << 0;
const TCP_PAYLOAD_CLASS_NON_EMPTY: u8 = 1;

#[inline(always)]
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

#[inline(always)]
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
    #[inline(always)]
    fn len_u8(&self) -> u8 {
        if self.len > u8::MAX as usize {
            u8::MAX
        } else {
            self.len as u8
        }
    }

    #[inline(always)]
    fn push_byte(&mut self, byte: u8) {
        if self.len < P0F_SIGNATURE_MAX_LEN {
            self.out[self.len] = byte;
            self.len += 1;
        }
    }

    #[inline(always)]
    fn push_bytes(&mut self, bytes: &[u8]) {
        let mut index = 0usize;
        while index < bytes.len() {
            self.push_byte(bytes[index]);
            index += 1;
        }
    }

    #[inline(always)]
    fn push_decimal_u8(&mut self, value: u8) {
        self.push_decimal_u16(u16::from(value));
    }

    #[inline(always)]
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

    #[inline(always)]
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

    #[inline(always)]
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

    #[inline(always)]
    fn push_quirks(&mut self, quirks: u32) {
        if quirks & QUIRK_MALFORMED_OPTIONS != 0 {
            self.push_bytes(b"bad");
        }
    }

    #[inline(always)]
    fn push_payload_class(&mut self, payload_class: u8) {
        if payload_class == TCP_PAYLOAD_CLASS_NON_EMPTY {
            self.push_byte(b'+');
        } else {
            self.push_byte(b'0');
        }
    }
}

#[inline(always)]
fn min_usize(left: usize, right: usize) -> usize {
    if left < right {
        left
    } else {
        right
    }
}
