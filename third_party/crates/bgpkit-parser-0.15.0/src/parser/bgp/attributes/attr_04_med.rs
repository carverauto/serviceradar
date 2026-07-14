use crate::models::*;
use crate::parser::ReadUtils;
use crate::ParserError;
use bytes::Bytes;

pub fn parse_med(mut input: Bytes) -> Result<AttributeValue, ParserError> {
    Ok(AttributeValue::MultiExitDiscriminator(input.read_u32()?))
}

pub fn encode_med(med: u32) -> Bytes {
    Bytes::from(med.to_be_bytes().to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_med() {
        assert_eq!(
            parse_med(Bytes::from(vec![0, 0, 0, 123])).unwrap(),
            AttributeValue::MultiExitDiscriminator(123)
        );
    }

    #[test]
    fn test_encode_med() {
        assert_eq!(encode_med(123), Bytes::from(vec![0, 0, 0, 123]));
    }
}
