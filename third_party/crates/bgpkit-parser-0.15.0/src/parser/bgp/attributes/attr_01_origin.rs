use crate::models::*;
use crate::parser::ReadUtils;
use crate::ParserError;
use bytes::Bytes;
use std::convert::TryFrom;

pub fn parse_origin(mut input: Bytes) -> Result<AttributeValue, ParserError> {
    match Origin::try_from(input.read_u8()?) {
        Ok(v) => Ok(AttributeValue::Origin(v)),
        Err(_) => Err(ParserError::ParseError(
            "Failed to parse attribute type: origin".to_string(),
        )),
    }
}

pub fn encode_origin(origin: &Origin) -> Bytes {
    Bytes::from(vec![*origin as u8])
}

#[cfg(test)]
mod tests {
    use super::*;

    /// test parse origin
    /// ```text
    /// ORIGIN is a well-known mandatory attribute that defines the
    ///        origin of the path information.  The data octet can assume
    ///        the following values:
    ///
    ///           Value      Meaning
    ///
    ///           0         IGP - Network Layer Reachability Information
    ///                        is interior to the originating AS
    ///
    ///           1         EGP - Network Layer Reachability Information
    ///                        learned via the EGP protocol [RFC904]
    ///
    ///           2         INCOMPLETE - Network Layer Reachability
    ///                        Information learned by some other means
    ///
    /// Usage of this attribute is defined in 5.1.1.
    /// ```
    #[test]
    fn test_parse_origin() {
        assert_eq!(
            AttributeValue::Origin(Origin::IGP),
            parse_origin(Bytes::from_static(&[0u8])).unwrap()
        );
        assert_eq!(
            AttributeValue::Origin(Origin::EGP),
            parse_origin(Bytes::from_static(&[1u8])).unwrap()
        );
        assert_eq!(
            AttributeValue::Origin(Origin::INCOMPLETE),
            parse_origin(Bytes::from_static(&[2u8])).unwrap()
        );
        assert!(matches!(
            parse_origin(Bytes::from_static(&[3u8])).unwrap_err(),
            ParserError::ParseError(_)
        ));
    }

    #[test]
    fn test_encode_origin() {
        let value = Origin::IGP;
        assert_eq!(
            AttributeValue::Origin(value),
            parse_origin(encode_origin(&value)).unwrap()
        );

        let value = Origin::EGP;
        assert_eq!(
            AttributeValue::Origin(value),
            parse_origin(encode_origin(&value)).unwrap()
        );

        let value = Origin::INCOMPLETE;
        assert_eq!(
            AttributeValue::Origin(value),
            parse_origin(encode_origin(&value)).unwrap()
        );
    }
}
