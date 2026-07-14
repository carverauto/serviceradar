use crate::models::*;
use crate::parser::ReadUtils;
use crate::ParserError;
use bytes::Bytes;

/// parse RFC9234 OnlyToCustomer attribute.
///
/// RFC: https://www.rfc-editor.org/rfc/rfc9234.html#name-bgp-only-to-customer-otc-at
///
/// ```text
/// The OTC Attribute is an optional transitive Path Attribute of the UPDATE message with Attribute Type Code 35 and a length of 4 octets.
///
/// The following ingress procedure applies to the processing of the OTC Attribute on route receipt:
/// 1. If a route with the OTC Attribute is received from a Customer or an RS-Client, then it is a route leak and MUST be considered ineligible (see Section 3).
/// 2. If a route with the OTC Attribute is received from a Peer (i.e., remote AS with a Peer Role) and the Attribute has a value that is not equal to the remote (i.e., Peer's) AS number, then it is a route leak and MUST be considered ineligible.
/// 3. If a route is received from a Provider, a Peer, or an RS and the OTC Attribute is not present, then it MUST be added with a value equal to the AS number of the remote AS.
///
/// The following egress procedure applies to the processing of the OTC Attribute on route advertisement:
/// 1. If a route is to be advertised to a Customer, a Peer, or an RS-Client (when the sender is an RS), and the OTC Attribute is not present, then when advertising the route, an OTC Attribute MUST be added with a value equal to the AS number of the local AS.
/// 2. If a route already contains the OTC Attribute, it MUST NOT be propagated to Providers, Peers, or RSes.
/// ```
pub fn parse_only_to_customer(mut input: Bytes) -> Result<AttributeValue, ParserError> {
    let remote_asn = input.read_u32()?;
    Ok(AttributeValue::OnlyToCustomer(Asn::new_32bit(remote_asn)))
}

pub fn encode_only_to_customer(remote_asn: u32) -> Bytes {
    Bytes::from(remote_asn.to_be_bytes().to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_otc() {
        if let Ok(AttributeValue::OnlyToCustomer(asn)) =
            parse_only_to_customer(Bytes::from(vec![0, 0, 0, 123]))
        {
            assert_eq!(asn, 123);
        }
    }

    #[test]
    fn test_encode_otc() {
        assert_eq!(
            encode_only_to_customer(123),
            Bytes::from(vec![0, 0, 0, 123])
        );
    }
}
