use crate::*;
use std::vec::Vec;

/// Payload of an IP packet.
#[derive(Clone, Debug, Eq, PartialEq, Hash, PartialOrd, Ord)]
pub struct IpDefragPayloadVec {
    /// Identifying content of the payload.
    pub ip_number: IpNumber,

    /// Length field that was used to determine the length
    /// of the payload (e.g. IPv6 "payload_length" field).
    pub len_source: LenSource,

    /// Payload
    pub payload: Vec<u8>,
}

#[cfg(test)]
mod test {
    use super::*;
    use std::{format, vec};

    #[test]
    fn debug() {
        let s = IpDefragPayloadVec {
            ip_number: IpNumber::UDP,
            len_source: LenSource::Slice,
            payload: vec![],
        };
        assert_eq!(
            format!(
                "IpDefragPayloadVec {{ ip_number: {:?}, len_source: {:?}, payload: {:?} }}",
                s.ip_number, s.len_source, s.payload
            ),
            format!("{:?}", s)
        );
    }

    #[test]
    fn clone_eq_hash_ord() {
        let s = IpDefragPayloadVec {
            ip_number: IpNumber::UDP,
            len_source: LenSource::Slice,
            payload: vec![],
        };
        assert_eq!(s.clone(), s);

        use std::collections::hash_map::DefaultHasher;
        use std::hash::{Hash, Hasher};

        let a_hash = {
            let mut hasher = DefaultHasher::new();
            s.hash(&mut hasher);
            hasher.finish()
        };
        let b_hash = {
            let mut hasher = DefaultHasher::new();
            s.clone().hash(&mut hasher);
            hasher.finish()
        };
        assert_eq!(a_hash, b_hash);

        use std::cmp::Ordering;
        assert_eq!(s.clone().cmp(&s), Ordering::Equal);
        assert_eq!(s.clone().partial_cmp(&s), Some(Ordering::Equal));
    }
}
