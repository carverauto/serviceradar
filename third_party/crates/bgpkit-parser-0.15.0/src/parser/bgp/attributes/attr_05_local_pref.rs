use crate::models::*;
use crate::parser::ReadUtils;
use crate::ParserError;
use bytes::Bytes;

pub fn parse_local_pref(mut input: Bytes) -> Result<AttributeValue, ParserError> {
    Ok(AttributeValue::LocalPreference(input.read_u32()?))
}

pub fn encode_local_pref(local_pref: u32) -> Bytes {
    Bytes::from(local_pref.to_be_bytes().to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_local_pref() {
        assert_eq!(
            parse_local_pref(Bytes::from(vec![0, 0, 0, 123])).unwrap(),
            AttributeValue::LocalPreference(123)
        );
    }

    #[test]
    fn test_encode_local_pref() {
        assert_eq!(encode_local_pref(123), Bytes::from(vec![0, 0, 0, 123]));
    }
}
