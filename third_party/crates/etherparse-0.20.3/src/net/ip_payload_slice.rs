use crate::*;

/// Payload of an IP packet.
#[derive(Clone, Debug, Eq, PartialEq, Hash, PartialOrd, Ord)]
pub struct IpPayloadSlice<'a> {
    /// Identifying content of the payload.
    pub ip_number: IpNumber,

    /// True if the payload is not complete and has been fragmented.
    ///
    /// This can occur if the IPv4 indicates that the payload
    /// has been fragmented or if there is an IPv6 fragmentation
    /// header indicating that the payload has been fragmented.
    pub fragmented: bool,

    /// Length field that was used to determine the length
    /// of the payload (e.g. IPv6 "payload_length" field).
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
        let s = IpPayloadSlice {
            ip_number: IpNumber::UDP,
            fragmented: true,
            len_source: LenSource::Slice,
            payload: &[],
        };
        assert_eq!(
            format!(
                "IpPayloadSlice {{ ip_number: {:?}, fragmented: {:?}, len_source: {:?}, payload: {:?} }}",
                s.ip_number,
                s.fragmented,
                s.len_source,
                s.payload
            ),
            format!("{:?}", s)
        );
    }

    #[test]
    fn clone_eq_hash_ord() {
        let s = IpPayloadSlice {
            ip_number: IpNumber::UDP,
            fragmented: true,
            len_source: LenSource::Slice,
            payload: &[],
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
