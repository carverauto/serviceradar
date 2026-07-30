use crate::*;

/// Laxly identified payload of an IP packet (potentially incomplete).
///
/// To check if the payload is complete check the `incomplete` field.
#[derive(Clone, Debug, Eq, PartialEq, Hash, PartialOrd, Ord)]
pub struct LaxIpPayloadSlice<'a> {
    /// True if the length field in the IP header indicates more data
    /// should be present but it was not (aka the packet data is cut off).
    ///
    /// Note that this different from fragmentation. If a packet is
    /// fragmented the length field in the individual IP headers is
    /// still correctly set.
    pub incomplete: bool,

    /// Identifying content of the payload.
    pub ip_number: IpNumber,

    /// True if the payload is not complete and has been fragmented.
    ///
    /// This can occur if the IPv4 incdicates that the payload
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
        let s = LaxIpPayloadSlice {
            incomplete: false,
            ip_number: IpNumber::UDP,
            fragmented: true,
            len_source: LenSource::Slice,
            payload: &[],
        };
        assert_eq!(
            format!(
                "LaxIpPayloadSlice {{ incomplete: {:?}, ip_number: {:?}, fragmented: {:?}, len_source: {:?}, payload: {:?} }}",
                s.incomplete,
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
        let s = LaxIpPayloadSlice {
            incomplete: false,
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
