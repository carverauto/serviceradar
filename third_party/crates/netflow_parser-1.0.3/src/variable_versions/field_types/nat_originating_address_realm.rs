//! NAT Originating Address Realm field decoding (IPFIX field ID 229).
//!
//! Indicates whether a session was created because traffic originated
//! in the private or public address realm.

use nom::IResult;
use nom_derive::Parse;
use serde::Serialize;

/// Decoded NAT originating address realm from an IPFIX field (ID 229).
#[derive(Debug, PartialEq, Eq, Clone, Copy, Serialize)]
pub enum NatOriginatingAddressRealm {
    /// 1: Private address realm.
    Private,
    /// 2: Public address realm.
    Public,
    /// Reserved or unassigned realm.
    Unknown(u8),
}

impl NatOriginatingAddressRealm {
    /// Parse a `NatOriginatingAddressRealm` from a byte slice by reading a single `u8`.
    pub fn parse(input: &[u8]) -> IResult<&[u8], Self> {
        let (remaining, value) = u8::parse(input)?;
        Ok((remaining, Self::from(value)))
    }
}

impl std::fmt::Display for NatOriginatingAddressRealm {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            NatOriginatingAddressRealm::Private => write!(f, "Private"),
            NatOriginatingAddressRealm::Public => write!(f, "Public"),
            NatOriginatingAddressRealm::Unknown(v) => write!(f, "Unknown({v})"),
        }
    }
}

impl From<u8> for NatOriginatingAddressRealm {
    fn from(value: u8) -> Self {
        match value {
            1 => NatOriginatingAddressRealm::Private,
            2 => NatOriginatingAddressRealm::Public,
            v => NatOriginatingAddressRealm::Unknown(v),
        }
    }
}

impl From<NatOriginatingAddressRealm> for u8 {
    fn from(realm: NatOriginatingAddressRealm) -> Self {
        match realm {
            NatOriginatingAddressRealm::Private => 1,
            NatOriginatingAddressRealm::Public => 2,
            NatOriginatingAddressRealm::Unknown(v) => v,
        }
    }
}

impl PartialOrd for NatOriginatingAddressRealm {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for NatOriginatingAddressRealm {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        u8::from(*self).cmp(&u8::from(*other))
    }
}

#[cfg(test)]
mod nat_originating_address_realm_tests {
    use super::NatOriginatingAddressRealm;

    #[test]
    fn test_display() {
        assert_eq!(NatOriginatingAddressRealm::from(1).to_string(), "Private");
        assert_eq!(NatOriginatingAddressRealm::from(2).to_string(), "Public");
        assert_eq!(
            NatOriginatingAddressRealm::from(0).to_string(),
            "Unknown(0)"
        );
    }

    #[test]
    fn test_round_trip() {
        for byte in 0..=255u8 {
            let realm = NatOriginatingAddressRealm::from(byte);
            let back = u8::from(realm);
            assert_eq!(byte, back, "round-trip failed for {byte}");
        }
    }

    #[test]
    fn test_known_values() {
        assert_eq!(
            NatOriginatingAddressRealm::from(1),
            NatOriginatingAddressRealm::Private
        );
        assert_eq!(
            NatOriginatingAddressRealm::from(2),
            NatOriginatingAddressRealm::Public
        );
        assert_eq!(
            NatOriginatingAddressRealm::from(0),
            NatOriginatingAddressRealm::Unknown(0)
        );
    }
}
