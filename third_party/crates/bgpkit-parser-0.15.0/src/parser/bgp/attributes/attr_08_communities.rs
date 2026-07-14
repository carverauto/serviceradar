use crate::models::*;
use crate::parser::ReadUtils;
use crate::ParserError;
use bytes::{Buf, BufMut, Bytes, BytesMut};

const COMMUNITY_NO_EXPORT: u32 = 0xFFFFFF01;
const COMMUNITY_NO_ADVERTISE: u32 = 0xFFFFFF02;
const COMMUNITY_NO_EXPORT_SUBCONFED: u32 = 0xFFFFFF03;

pub fn parse_regular_communities(mut input: Bytes) -> Result<AttributeValue, ParserError> {
    // RFC 1997: [..] Communities are treated as 32 bit values [..]
    let mut communities = Vec::with_capacity(input.remaining() / 4);

    while input.remaining() > 0 {
        let community_val = input.read_u32()?;
        communities.push(match community_val {
            COMMUNITY_NO_EXPORT => Community::NoExport,
            COMMUNITY_NO_ADVERTISE => Community::NoAdvertise,
            COMMUNITY_NO_EXPORT_SUBCONFED => Community::NoExportSubConfed,
            value => {
                let asn = ((value >> 16) & 0xffff) as u16;
                let data = (value & 0xffff) as u16;
                Community::Custom(Asn::new_16bit(asn), data)
            }
        });
    }

    Ok(AttributeValue::Communities(communities))
}

pub fn encode_regular_communities(communities: &Vec<Community>) -> Bytes {
    let expected_len = 4 * communities.len();
    let mut bytes = BytesMut::with_capacity(expected_len);

    for community in communities {
        match community {
            Community::NoExport => bytes.put_u32(COMMUNITY_NO_EXPORT),
            Community::NoAdvertise => bytes.put_u32(COMMUNITY_NO_ADVERTISE),
            Community::NoExportSubConfed => bytes.put_u32(COMMUNITY_NO_EXPORT_SUBCONFED),
            Community::Custom(asn, value) => {
                bytes.put_u16(asn.into());
                bytes.put_u16(*value);
            }
        }
    }

    debug_assert!(bytes.len() == expected_len);
    bytes.freeze()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Test parsing of communities values, as defined in RFC1997.
    #[test]
    fn test_parse_communities() {
        if let Ok(AttributeValue::Communities(communities)) =
            parse_regular_communities(Bytes::from(vec![
                0xFF, 0xFF, 0xFF, 0x01, // NoExport
                0xFF, 0xFF, 0xFF, 0x02, // NoAdvertise
                0xFF, 0xFF, 0xFF, 0x03, // NoExportSubConfed
                0x00, 0x7B, 0x01, 0xC8, // Custom(123, 456)
            ]))
        {
            assert_eq!(communities.len(), 4);
            assert_eq!(communities[0], Community::NoExport);
            assert_eq!(communities[1], Community::NoAdvertise);
            assert_eq!(communities[2], Community::NoExportSubConfed);
            assert_eq!(communities[3], Community::Custom(Asn::from(123), 456));
        }
    }

    #[test]
    fn test_encode_communities() {
        let communities = vec![
            Community::NoExport,
            Community::NoAdvertise,
            Community::NoExportSubConfed,
            Community::Custom(Asn::from(123), 456),
        ];
        let bytes = encode_regular_communities(&communities);
        assert_eq!(
            bytes,
            Bytes::from(vec![
                0xFF, 0xFF, 0xFF, 0x01, // NoExport
                0xFF, 0xFF, 0xFF, 0x02, // NoAdvertise
                0xFF, 0xFF, 0xFF, 0x03, // NoExportSubConfed
                0x00, 0x7B, 0x01, 0xC8, // Custom(123, 456)
            ])
        );
    }
}
