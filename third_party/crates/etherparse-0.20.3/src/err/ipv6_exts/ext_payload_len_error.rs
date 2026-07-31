/// Error when creating an [`crate::Ipv6RawExtHeader`] and the
/// payload len is non representable.
#[derive(Clone, Debug, Eq, PartialEq, Hash)]
pub enum ExtPayloadLenError {
    /// Error when the payload length is smaller then
    /// [`crate::Ipv6RawExtHeader::MIN_PAYLOAD_LEN`] (6).
    TooSmall(usize),

    /// Error when the payload length is bigger then
    /// [`crate::Ipv6RawExtHeader::MAX_PAYLOAD_LEN`] (2046).
    TooBig(usize),

    /// Error when the payload length can not be represented
    /// as a multiple of 8-bytes in the extension header
    /// (`0 == (payload.len() + 2) % 8` is not fulfilled).
    Unaligned(usize),
}

impl core::fmt::Display for ExtPayloadLenError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        use ExtPayloadLenError::*;
        match self {
            TooSmall(size) =>
                write!(f, "IPv6 extensions header payload length is too small. The payload size ({size} bytes) is less then 6 octets which is the minimum IPv6 extension header payload size."),
            TooBig(size) =>
                write!(f, "IPv6 extensions header payload length is too large. The payload size ({size} bytes) is larger then what can be be represented by the 'extended header size' field in an IPv6 extension header."),
            Unaligned(size) =>
                write!(f, "IPv6 extensions header 'payload length ({size} bytes) + 2' is not multiple of 8 (+ 2 for the `next_header` and `header_length` fields). This is required as the header length field can only express lengths in multiple of 8 bytes."),
        }
    }
}

impl core::error::Error for ExtPayloadLenError {
    fn source(&self) -> Option<&(dyn core::error::Error + 'static)> {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::ExtPayloadLenError::*;
    use crate::*;
    use alloc::format;
    use std::{
        collections::hash_map::DefaultHasher,
        error::Error,
        hash::{Hash, Hasher},
    };

    #[test]
    fn debug() {
        assert_eq!("TooBig(3000)", format!("{:?}", TooBig(3000)));
    }

    #[test]
    fn clone_eq_hash() {
        let err = TooBig(5000);
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
    }

    #[test]
    fn fmt() {
        assert_eq!(
            "IPv6 extensions header payload length is too small. The payload size (2 bytes) is less then 6 octets which is the minimum IPv6 extension header payload size.",
            format!("{}", TooSmall(2))
        );
        assert_eq!(
            "IPv6 extensions header payload length is too large. The payload size (4000 bytes) is larger then what can be be represented by the 'extended header size' field in an IPv6 extension header.",
            format!("{}", TooBig(4000))
        );
        assert_eq!(
            "IPv6 extensions header 'payload length (12 bytes) + 2' is not multiple of 8 (+ 2 for the `next_header` and `header_length` fields). This is required as the header length field can only express lengths in multiple of 8 bytes.",
            format!("{}", Unaligned(12))
        );
    }

    #[cfg(feature = "std")]
    #[test]
    fn source() {
        assert!(TooSmall(1).source().is_none());
        assert!(TooBig(4000).source().is_none());
        assert!(Unaligned(12).source().is_none());
    }
}
