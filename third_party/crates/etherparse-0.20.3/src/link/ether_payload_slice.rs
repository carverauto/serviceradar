use crate::*;

/// Payload of an link layer packet.
#[derive(Clone, Debug, Eq, PartialEq, Hash, PartialOrd, Ord)]
pub struct EtherPayloadSlice<'a> {
    /// Identifying content of the payload.
    pub ether_type: EtherType,

    /// Length field that was used to determine the length
    /// of the payload (e.g. MACsec "short length" field).
    pub len_source: LenSource,

    /// Payload
    pub payload: &'a [u8],
}

#[cfg(test)]
mod test {
    use super::*;
    use alloc::format;

    #[test]
    fn debug() {
        let s = EtherPayloadSlice {
            ether_type: EtherType::IPV4,
            payload: &[],
            len_source: LenSource::MacsecShortLength,
        };
        assert_eq!(
            format!(
                "EtherPayloadSlice {{ ether_type: {:?}, len_source: {:?}, payload: {:?} }}",
                s.ether_type, s.len_source, s.payload
            ),
            format!("{:?}", s)
        );
    }

    #[test]
    fn clone_eq_hash_ord() {
        let s = EtherPayloadSlice {
            ether_type: EtherType::IPV4,
            payload: &[],
            len_source: LenSource::MacsecShortLength,
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
