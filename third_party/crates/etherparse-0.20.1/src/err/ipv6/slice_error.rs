use crate::err::{ipv6, ipv6_exts, LenError};

/// Errors that can occur when slicing the IPv6 part of a packet.
#[derive(Clone, Debug, Eq, PartialEq, Hash)]
pub enum SliceError {
    /// Length related errors (e.g. not enough data in slice).
    Len(LenError),

    /// Error while slicing the header.
    Header(ipv6::HeaderError),

    /// Error while slicing an ipv6 extension header.
    Exts(ipv6_exts::HeaderError),
}

impl core::fmt::Display for SliceError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        use SliceError::*;
        match self {
            Len(value) => value.fmt(f),
            Header(err) => err.fmt(f),
            Exts(value) => value.fmt(f),
        }
    }
}

impl core::error::Error for SliceError {
    fn source(&self) -> Option<&(dyn core::error::Error + 'static)> {
        use SliceError::*;
        match self {
            Len(err) => Some(err),
            Header(err) => Some(err),
            Exts(err) => Some(err),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{super::HeaderError, SliceError::*, *};
    use crate::{
        err::{ip_auth, Layer},
        LenSource,
    };
    use alloc::format;
    use std::{
        collections::hash_map::DefaultHasher,
        error::Error,
        hash::{Hash, Hasher},
    };

    #[test]
    fn debug() {
        let err = HeaderError::UnexpectedVersion { version_number: 6 };
        assert_eq!(
            format!("Header({:?})", err.clone()),
            format!("{:?}", Header(err))
        );
    }

    #[test]
    fn clone_eq_hash() {
        let err = Header(HeaderError::UnexpectedVersion { version_number: 6 });
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
        // len
        {
            let err = LenError {
                required_len: 1,
                layer: Layer::Ipv6Packet,
                len: 2,
                len_source: LenSource::Slice,
                layer_start_offset: 3,
            };
            assert_eq!(format!("{}", &err), format!("{}", Len(err)));
        }
        // header
        {
            let err = HeaderError::UnexpectedVersion { version_number: 6 };
            assert_eq!(format!("{}", &err), format!("{}", Header(err.clone())));
        }
        // extensions
        {
            let err = ipv6_exts::HeaderError::IpAuth(ip_auth::HeaderError::ZeroPayloadLen);
            assert_eq!(format!("{}", &err), format!("{}", Exts(err.clone())));
        }
    }

    #[cfg(feature = "std")]
    #[test]
    fn source() {
        assert!(Len(LenError {
            required_len: 1,
            layer: Layer::Ipv4Packet,
            len: 2,
            len_source: LenSource::Slice,
            layer_start_offset: 3
        })
        .source()
        .is_some());
        assert!(Header(HeaderError::UnexpectedVersion { version_number: 6 })
            .source()
            .is_some());
        assert!(Exts(ipv6_exts::HeaderError::IpAuth(
            ip_auth::HeaderError::ZeroPayloadLen
        ))
        .source()
        .is_some());
    }
}
