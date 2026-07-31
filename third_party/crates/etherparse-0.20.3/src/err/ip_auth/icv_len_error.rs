/// Error when creating an [`crate::IpAuthHeader`] and the
/// length of the raw ICV is non representable in an IP authentication
/// header.
#[derive(Clone, Debug, Eq, PartialEq, Hash)]
pub enum IcvLenError {
    /// Error when the payload length is bigger then
    /// [`crate::IpAuthHeader::MAX_ICV_LEN`] (1016).
    TooBig(usize),

    /// Error when the ICV length can not be represented
    /// as a multiple of 4-bytes in the authentication header
    /// (`0 == raw_icv.len() % 4` is not fulfilled).
    Unaligned(usize),
}

impl core::fmt::Display for IcvLenError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        use IcvLenError::*;
        match self {
            TooBig(size) =>
                write!(f, "Error the IP authentication header ICV length is too large. The ICV size ({size} bytes) is larger then what can be be represented by the 'payload len' field in an IP authentication header."),
            Unaligned(size) =>
                write!(f, "Error the IP authentication header ICV length of {size} bytes is not a multiple of 4. This is required as the payload length field can only express lengths in multiple of 4 bytes."),
        }
    }
}

impl core::error::Error for IcvLenError {
    fn source(&self) -> Option<&(dyn core::error::Error + 'static)> {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::IcvLenError::*;
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
            "Error the IP authentication header ICV length is too large. The ICV size (4000 bytes) is larger then what can be be represented by the 'payload len' field in an IP authentication header.",
            format!("{}", TooBig(4000))
        );
        assert_eq!(
            "Error the IP authentication header ICV length of 12 bytes is not a multiple of 4. This is required as the payload length field can only express lengths in multiple of 4 bytes.",
            format!("{}", Unaligned(12))
        );
    }

    #[cfg(feature = "std")]
    #[test]
    fn source() {
        assert!(TooBig(4000).source().is_none());
        assert!(Unaligned(12).source().is_none());
    }
}
