use crate::models::*;
use crate::parser::ReadUtils;
use crate::ParserError;
use bytes::{Buf, BufMut, Bytes, BytesMut};

pub fn parse_large_communities(mut input: Bytes) -> Result<AttributeValue, ParserError> {
    // RFC 8092, section 3: Each BGP Large Community value is encoded as a 12-octet quantity [..]
    let num_communities = input.remaining() / 12;

    let mut communities = Vec::with_capacity(num_communities);
    while input.remaining() > 0 {
        let global_administrator = input.read_u32()?;
        let local_data = [input.read_u32()?, input.read_u32()?];
        communities.push(LargeCommunity::new(global_administrator, local_data));
    }

    debug_assert!(communities.len() == num_communities);
    Ok(AttributeValue::LargeCommunities(communities))
}

pub fn encode_large_communities(communities: &[LargeCommunity]) -> Bytes {
    let expected_len = 12 * communities.len();
    let mut data = BytesMut::with_capacity(expected_len);
    for community in communities {
        data.put_u32(community.global_admin);
        data.put_u32(community.local_data[0]);
        data.put_u32(community.local_data[1]);
    }

    debug_assert!(data.len() == expected_len);
    data.freeze()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_large_communities() {
        let data: Vec<u8> = vec![
            0x00, 0x00, 0x00, 0x01, // global administrator
            0x00, 0x00, 0x00, 0x02, // local data
            0x00, 0x00, 0x00, 0x03, // local data
            0x00, 0x00, 0x00, 0x04, // global administrator
            0x00, 0x00, 0x00, 0x05, // local data
            0x00, 0x00, 0x00, 0x06, // local data
        ];

        if let Ok(AttributeValue::LargeCommunities(communities)) =
            parse_large_communities(Bytes::from(data))
        {
            assert_eq!(communities.len(), 2);
            assert_eq!(communities[0].global_admin, 1);
            assert_eq!(communities[0].local_data[0], 2);
            assert_eq!(communities[0].local_data[1], 3);
            assert_eq!(communities[1].global_admin, 4);
            assert_eq!(communities[1].local_data[0], 5);
            assert_eq!(communities[1].local_data[1], 6);
        }
    }

    #[test]
    fn test_encode_large_communities() {
        let communities = vec![
            LargeCommunity::new(1, [2, 3]),
            LargeCommunity::new(4, [5, 6]),
        ];
        let data = encode_large_communities(&communities);
        assert_eq!(data.len(), 24);
        assert_eq!(
            data,
            [0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0, 4, 0, 0, 0, 5, 0, 0, 0, 6].to_vec()
        );
    }
}
