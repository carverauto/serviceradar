use crate::models::*;
use crate::parser::ReadUtils;
use crate::ParserError;
use bytes::{Buf, Bytes};

/// <https://tools.ietf.org/html/rfc4456>
pub fn parse_clusters(mut input: Bytes) -> Result<AttributeValue, ParserError> {
    let mut clusters = Vec::with_capacity(input.remaining() / 4);
    while input.remaining() > 0 {
        clusters.push(input.read_u32()?);
    }
    Ok(AttributeValue::Clusters(clusters))
}

pub fn encode_clusters(clusters: &Vec<u32>) -> Bytes {
    let mut buf = Vec::new();
    for cluster in clusters {
        buf.extend(cluster.to_be_bytes());
    }
    Bytes::from(buf)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_clusters() {
        if let Ok(AttributeValue::Clusters(n)) = parse_clusters(Bytes::from(vec![
            0xC0, 0x00, 0x02, 0x01, 0xC0, 0x00, 0x02, 0x02,
        ])) {
            assert_eq!(n.len(), 2);
            assert_eq!(n[0], 0xC0000201);
            assert_eq!(n[1], 0xC0000202);
        }
    }

    #[test]
    fn test_encode_clusters() {
        let clusters: Vec<u32> = vec![
            0xC0000201, //
            0xC0000202, //
        ];
        assert_eq!(
            encode_clusters(&clusters),
            Bytes::from(vec![
                0xC0, 0x00, 0x02, 0x01, //
                0xC0, 0x00, 0x02, 0x02, //
            ])
        );
    }
}
