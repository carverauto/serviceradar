use crate::*;

#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub enum IpDefragError {
    /// Error if a payload lenght of a IP Fragment packet is not a multiple of 16
    /// and the "more fragments" flag is set.
    UnalignedFragmentPayloadLen {
        offset: IpFragOffset,
        payload_len: usize,
    },

    /// Error if a segment is bigger then the maximum allowed size.
    SegmentTooBig {
        offset: IpFragOffset,
        payload_len: usize,
        max: u16,
    },

    /// Error if multiple TP segments were received with the "more segment"
    /// unset and differing end points.
    ConflictingEnd {
        /// Offset + tp_payload.len() of the previous package with "more segment" unset.
        previous_end: u16,

        /// Offset + tp_payload.len() of the current package.
        conflicting_end: u16,
    },

    /// Error if not enough memory could be allocated to store the TP payload.
    AllocationFailure { len: usize },
}

impl core::fmt::Display for IpDefragError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        use IpDefragError::*;
        match self {
            UnalignedFragmentPayloadLen{ offset, payload_len } => write!(f, "Payload length {payload_len} of IP fragment (offset {offset}) is not a multiple of 8. This is only allowed for the last fragment packet."),
            SegmentTooBig{ offset, payload_len, max } => write!(f, "Overall length of IP fragment (offset {offset}, payload len: {payload_len}) bigger then the maximum allowed size of {max}."),
            ConflictingEnd { previous_end, conflicting_end } => write!(f, "Received a IP fragment (offset + len: {conflicting_end}) which conflicts a package that previously set the end to {previous_end}."),
            AllocationFailure { len } => write!(f, "Failed to allocate {len} bytes of memory to reconstruct the fragmented IP packets."),
        }
    }
}

impl core::error::Error for IpDefragError {}

#[cfg(test)]
mod tests {
    use super::IpDefragError::*;
    use super::*;
    use std::format;

    #[test]
    fn debug() {
        let err = UnalignedFragmentPayloadLen {
            offset: IpFragOffset::try_new(0).unwrap(),
            payload_len: 16,
        };
        let _ = format!("{err:?}");
    }

    #[test]
    fn clone_eq_hash_ord() {
        use core::cmp::Ordering;
        use std::collections::hash_map::DefaultHasher;
        use std::hash::{Hash, Hasher};

        let err = UnalignedFragmentPayloadLen {
            offset: IpFragOffset::try_new(0).unwrap(),
            payload_len: 16,
        };
        assert_eq!(err, err.clone());
        let hash_a = {
            let mut hasher = DefaultHasher::new();
            err.hash(&mut hasher);
            hasher.finish()
        };
        let hash_b = {
            let mut hasher = DefaultHasher::new();
            err.clone().hash(&mut hasher);
            hasher.finish()
        };
        assert_eq!(hash_a, hash_b);
        assert_eq!(Ordering::Equal, err.cmp(&err));
        assert_eq!(Some(Ordering::Equal), err.partial_cmp(&err));
    }

    #[test]
    fn fmt() {
        let tests = [
            (UnalignedFragmentPayloadLen { offset: IpFragOffset::try_new(0).unwrap(), payload_len: 2 }, "Payload length 2 of IP fragment (offset 0) is not a multiple of 8. This is only allowed for the last fragment packet."),
            (SegmentTooBig { offset: IpFragOffset::try_new(0).unwrap(), payload_len: 2, max: 3, }, "Overall length of IP fragment (offset 0, payload len: 2) bigger then the maximum allowed size of 3."),
            (ConflictingEnd { previous_end: 2, conflicting_end: 1 }, "Received a IP fragment (offset + len: 1) which conflicts a package that previously set the end to 2."),
            (AllocationFailure { len: 0 }, "Failed to allocate 0 bytes of memory to reconstruct the fragmented IP packets."),
        ];
        for test in tests {
            assert_eq!(format!("{}", test.0), test.1);
        }
    }

    #[test]
    fn source() {
        use core::error::Error;
        assert!(UnalignedFragmentPayloadLen {
            offset: IpFragOffset::try_new(0).unwrap(),
            payload_len: 16
        }
        .source()
        .is_none());
    }
}
