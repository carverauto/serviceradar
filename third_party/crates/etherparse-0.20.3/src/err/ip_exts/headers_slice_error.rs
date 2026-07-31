use super::HeaderError;
use crate::err::LenError;

/// Error when decoding IP extension headers from a slice.
#[derive(Clone, Debug, Eq, PartialEq, Hash)]
pub enum HeadersSliceError {
    /// Error when an length error is encountered (e.g. unexpected
    /// end of slice).
    Len(LenError),

    /// Error caused by the contents of a header.
    Content(HeaderError),
}

impl HeadersSliceError {
    /// Returns the [`crate::err::LenError`] if the error is an Len.
    pub fn len_error(&self) -> Option<&LenError> {
        use HeadersSliceError::*;
        match self {
            Len(err) => Some(err),
            Content(_) => None,
        }
    }

    /// Returns the [`crate::err::ipv6_exts::HeaderError`] if the error is an Len.
    pub fn content(&self) -> Option<&HeaderError> {
        use HeadersSliceError::*;
        match self {
            Len(_) => None,
            Content(err) => Some(err),
        }
    }
}

impl core::fmt::Display for HeadersSliceError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        use HeadersSliceError::*;
        match self {
            Len(err) => err.fmt(f),
            Content(err) => err.fmt(f),
        }
    }
}

impl core::error::Error for HeadersSliceError {
    fn source(&self) -> Option<&(dyn core::error::Error + 'static)> {
        use HeadersSliceError::*;
        match self {
            Len(err) => Some(err),
            Content(err) => Some(err),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{HeadersSliceError::*, *};
    use crate::{
        err::{ipv6_exts::HeaderError::*, Layer},
        LenSource,
    };
    use alloc::format;
    use std::{
        collections::hash_map::DefaultHasher,
        error::Error,
        hash::{Hash, Hasher},
    };

    #[test]
    fn len_error() {
        assert_eq!(
            Len(LenError {
                required_len: 1,
                layer: Layer::Icmpv4,
                len: 2,
                len_source: LenSource::Slice,
                layer_start_offset: 3
            })
            .len_error(),
            Some(&LenError {
                required_len: 1,
                layer: Layer::Icmpv4,
                len: 2,
                len_source: LenSource::Slice,
                layer_start_offset: 3
            })
        );
        assert_eq!(
            Content(HeaderError::Ipv6Ext(HopByHopNotAtStart)).len_error(),
            None
        );
    }

    #[test]
    fn content() {
        assert_eq!(
            Len(LenError {
                required_len: 1,
                layer: Layer::Icmpv4,
                len: 2,
                len_source: LenSource::Slice,
                layer_start_offset: 3
            })
            .content(),
            None
        );
        assert_eq!(
            Content(HeaderError::Ipv6Ext(HopByHopNotAtStart)).content(),
            Some(&HeaderError::Ipv6Ext(HopByHopNotAtStart))
        );
    }

    #[test]
    fn debug() {
        let err = HeaderError::Ipv6Ext(HopByHopNotAtStart);
        assert_eq!(
            format!("Content({:?})", err.clone()),
            format!("{:?}", Content(err))
        );
    }

    #[test]
    fn clone_eq_hash() {
        let err = Content(HeaderError::Ipv6Ext(HopByHopNotAtStart));
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
        {
            let err = LenError {
                required_len: 1,
                layer: Layer::Icmpv4,
                len: 2,
                len_source: LenSource::Slice,
                layer_start_offset: 3,
            };
            assert_eq!(format!("{}", &err), format!("{}", Len(err)));
        }
        {
            let err = HeaderError::Ipv6Ext(HopByHopNotAtStart);
            assert_eq!(format!("{}", &err), format!("{}", Content(err.clone())));
        }
    }

    #[cfg(feature = "std")]
    #[test]
    fn source() {
        assert!(Len(LenError {
            required_len: 1,
            layer: Layer::Icmpv4,
            len: 2,
            len_source: LenSource::Slice,
            layer_start_offset: 3
        })
        .source()
        .is_some());
        assert!(Content(HeaderError::Ipv6Ext(HopByHopNotAtStart))
            .source()
            .is_some());
    }
}
