//! BER-TLV writer and parser

use crate::command::{writer::Error as _, DataSource, DataStream, Writer};

#[derive(Debug, PartialEq, Eq, PartialOrd, Ord, Clone, Copy)]
pub struct Tag([u8; 3]);

impl Tag {
    pub const fn from_u8(value: u8) -> Self {
        Tag([0, 0, value])
    }

    pub const fn from_u16(value: u16) -> Self {
        Tag::from_2(value.to_be_bytes())
    }

    pub const fn from_2([b1, b2]: [u8; 2]) -> Self {
        if b1 == 0 {
            Tag([0, 0, b2])
        } else {
            Tag([0, b1, b2])
        }
    }
    pub const fn from_3([b1, b2, b3]: [u8; 3]) -> Self {
        if b1 == 0 {
            Self::from_2([b2, b3])
        } else {
            Tag([b1, b2, b3])
        }
    }
}

impl From<u8> for Tag {
    fn from(value: u8) -> Self {
        Self::from_u8(value)
    }
}

impl From<u16> for Tag {
    fn from(value: u16) -> Self {
        value.to_be_bytes().into()
    }
}

impl From<[u8; 1]> for Tag {
    fn from([value]: [u8; 1]) -> Self {
        value.into()
    }
}

impl From<[u8; 2]> for Tag {
    fn from(value: [u8; 2]) -> Self {
        Self::from_2(value)
    }
}

impl From<[u8; 3]> for Tag {
    fn from(value: [u8; 3]) -> Self {
        Self::from_3(value)
    }
}

impl Tag {
    pub fn serialize(&self) -> heapless::Vec<u8, 3> {
        let [b1, b2, b3] = self.0;
        if b1 == 0 {
            if b2 == 0 {
                debug_assert_ne!(b3 & 0b11111, 0b11111, "Invalid encoding for 1 byte tag");
                heapless::Vec::try_from([b3].as_slice()).unwrap()
            } else {
                debug_assert_eq!(
                    b3 & 0b11111,
                    0b11111,
                    "Invalid encoding for first byte of tag"
                );
                debug_assert!(
                    (0x1F..=0x7F).contains(&b3),
                    "Invalid encoding for first byte of tag"
                );
                heapless::Vec::try_from([b2, b3].as_slice()).unwrap()
            }
        } else {
            debug_assert_eq!(
                b1 & 0b11111,
                0b11111,
                "Invalid encoding for first byte of tag"
            );
            debug_assert!(b2 > 0x80);
            debug_assert!((0x00..0x7F).contains(&b3));
            heapless::Vec::try_from([b1, b2, b3].as_slice()).unwrap()
        }
    }
}

pub fn get_data_object<'input>(tag_path: &[Tag], data: &'input [u8]) -> Option<&'input [u8]> {
    let mut to_ret = data;
    let mut remainder = data;
    for tag in tag_path {
        loop {
            let (cur_tag, cur_value, cur_remainder) = take_data_object(remainder)?;
            remainder = cur_remainder;
            if *tag == cur_tag {
                to_ret = cur_value;
                remainder = cur_value;
                break;
            }
        }
    }
    Some(to_ret)
}

/// Returns (tag, data, remainder)
pub fn take_data_object(data: &[u8]) -> Option<(Tag, &[u8], &[u8])> {
    let (tag, remainder) = take_tag(data)?;
    let (len, remainder) = take_len(remainder)?;
    if remainder.len() < len {
        None
    } else {
        let (value, remainder) = remainder.split_at(len);
        Some((tag, value, remainder))
    }
}

// See
// https://www.emvco.com/wp-content/uploads/2017/05/EMV_v4.3_Book_3_Application_Specification_20120607062110791.pdf
// Annex B1
pub fn take_tag(data: &[u8]) -> Option<(Tag, &[u8])> {
    let b1 = *data.first()?;
    if (b1 & 0x1f) == 0x1f {
        let b2 = *data.get(1)?;
        if (0x00..0x1E).contains(&b2) || b2 == 0x80 {
            return None;
        }

        if (0x81..0xFF).contains(&b2) {
            let b3 = *data.get(2)?;
            if (0x81..0xFF).contains(&b3) {
                return None;
            }

            Some((Tag([b1, b2, b3]), &data[3..]))
        } else {
            Some((Tag([0, b1, b2]), &data[2..]))
        }
    } else {
        Some((Tag([0, 0, b1]), &data[1..]))
    }
}

pub fn take_len(data: &[u8]) -> Option<(usize, &[u8])> {
    let l1 = *data.first()?;
    if l1 <= 0x7F {
        Some((l1 as usize, &data[1..]))
    } else if l1 == 0x81 {
        Some((*data.get(1)? as usize, &data[2..]))
    } else {
        if l1 != 0x82 {
            return None;
        }
        let l2 = *data.get(1)?;
        let l3 = *data.get(2)?;
        let len = u16::from_be_bytes([l2, l3]) as usize;
        Some((len, &data[3..]))
    }
}

fn serialize_len(len: usize) -> Option<heapless::Vec<u8, 3>> {
    let mut buf = heapless::Vec::new();
    if let Ok(len) = u8::try_from(len) {
        if len <= 0x7f {
            buf.extend_from_slice(&[len]).ok();
        } else {
            buf.extend_from_slice(&[0x81, len]).ok();
        }
    } else if let Ok(len) = u16::try_from(len) {
        let [ar1, ar2] = len.to_be_bytes();
        buf.extend_from_slice(&[0x82, ar1, ar2]).ok();
    } else {
        return None;
    }
    Some(buf)
}

pub struct Tlv<S> {
    tag: Tag,
    data: S,
}

impl<S> Tlv<S> {
    pub fn new(tag: Tag, data: S) -> Self {
        Self { tag, data }
    }
}

impl<S: DataSource> DataSource for Tlv<S> {
    fn len(&self) -> usize {
        let tag = self.tag.serialize();
        let len = serialize_len(self.data.len())
            .map(|l| l.len())
            .unwrap_or_default();
        tag.len() + len + self.data.len()
    }

    fn is_empty(&self) -> bool {
        false
    }
}

impl<W: Writer, S: DataStream<W>> DataStream<W> for Tlv<S> {
    fn to_writer(&self, writer: &mut W) -> Result<(), <W as Writer>::Error> {
        writer.write_all(&self.tag.serialize())?;
        writer.write_all(
            &serialize_len(self.data.len()).ok_or_else(|| {
                W::Error::failed_serialization("Data is longer than 0xFFFF bytes")
            })?,
        )?;
        self.data.to_writer(writer)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use hex_literal::hex;

    #[test]
    fn dos() {
        assert_eq!(
            get_data_object(&[0x02u16].map(Tag::from), &hex!("02 02 1DB9 02 02 1DB9")),
            Some(hex!("1DB9").as_slice())
        );
        assert_eq!(
            get_data_object(&[0xA6u16, 0x7F49, 0x86].map(Tag::from), &hex!("A6 26 7F49 23 86 21 04 2525252525252525252525252525252525252525252525252525252525252525")),
            Some(hex!("04 2525252525252525252525252525252525252525252525252525252525252525").as_slice())
        );

        // Multiple nested
        assert_eq!(
            get_data_object(&[0xA6u16, 0x7F49, 0x86].map(Tag::from), &hex!("A6 2A 02 02 DEAD 7F49 23 86 21 04 2525252525252525252525252525252525252525252525252525252525252525")),
            Some(hex!("04 2525252525252525252525252525252525252525252525252525252525252525").as_slice())
        );
    }

    #[test]
    fn tlv() {
        let mut buf = [0u8; 4];
        Tlv::new(Tag::from_u8(0x41), hex!("012A"))
            .to_writer(&mut buf.as_mut_slice())
            .unwrap();
        assert_eq!(buf.as_slice(), &hex!("41 02 012A"))
    }
}
