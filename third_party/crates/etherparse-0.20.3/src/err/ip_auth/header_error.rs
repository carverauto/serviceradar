/// Errors that can be encountered while decoding an IP
/// authentication header.
#[derive(Clone, Debug, Eq, PartialEq, Hash)]
pub enum HeaderError {
    /// Error when the payload length is zero and therefor
    /// too small to contain the minimum fields of the IP
    /// authentication itself.
    ZeroPayloadLen,
}

impl core::fmt::Display for HeaderError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        use HeaderError::*;
        match self {
            ZeroPayloadLen => write!(f, "IP Authentication Header Error: Payload Length too small (0). The payload length must be at least 1."),
        }
    }
}

impl core::error::Error for HeaderError {
    fn source(&self) -> Option<&(dyn core::error::Error + 'static)> {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::HeaderError::*;
    use alloc::format;
    use std::{
        collections::hash_map::DefaultHasher,
        error::Error,
        hash::{Hash, Hasher},
    };

    #[test]
    fn debug() {
        assert_eq!("ZeroPayloadLen", format!("{:?}", ZeroPayloadLen));
    }

    #[test]
    fn clone_eq_hash() {
        let err = ZeroPayloadLen;
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
            "IP Authentication Header Error: Payload Length too small (0). The payload length must be at least 1.",
            format!("{}", ZeroPayloadLen)
        );
    }

    #[cfg(feature = "std")]
    #[test]
    fn source() {
        assert!(ZeroPayloadLen.source().is_none());
    }
}
