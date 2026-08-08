use super::HeaderError;
use crate::err::LenError;

/// Error when decoding IPv6 extension headers via a `std::io::Read` source.
#[cfg(feature = "std")]
#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
#[derive(Debug)]
pub enum HeaderLimitedReadError {
    /// IO error was encountered while reading header.
    Io(std::io::Error),

    /// Error when parsing had to be aborted because a
    /// length limit specified by an upper layer has been
    /// exceeded.
    Len(LenError),

    /// Error caused by the contents of the header.
    Content(HeaderError),
}

#[cfg(feature = "std")]
#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl HeaderLimitedReadError {
    /// Returns the [`std::io::Error`] value if the [`HeaderLimitedReadError`] is `Io`.
    /// Otherwise `None` is returned.
    #[inline]
    pub fn io(self) -> Option<std::io::Error> {
        use HeaderLimitedReadError::*;
        match self {
            Io(value) => Some(value),
            _ => None,
        }
    }

    /// Returns the [`crate::err::LenError`] value if it is of value `Len`.
    /// Otherwise `None` is returned.
    #[inline]
    pub fn len(self) -> Option<LenError> {
        use HeaderLimitedReadError::*;
        match self {
            Len(value) => Some(value),
            _ => None,
        }
    }

    /// Returns the [`crate::err::ip_auth::HeaderError`] value if it is of value `Content`.
    /// Otherwise `None` is returned.
    #[inline]
    pub fn content(self) -> Option<HeaderError> {
        use HeaderLimitedReadError::*;
        match self {
            Content(value) => Some(value),
            _ => None,
        }
    }
}

#[cfg(feature = "std")]
#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl core::fmt::Display for HeaderLimitedReadError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        use HeaderLimitedReadError::*;
        match self {
            Io(err) => write!(f, "IPv6 Extension Header IO Error: {err}"),
            Len(err) => err.fmt(f),
            Content(err) => err.fmt(f),
        }
    }
}

impl core::error::Error for HeaderLimitedReadError {
    fn source(&self) -> Option<&(dyn core::error::Error + 'static)> {
        use HeaderLimitedReadError::*;
        match self {
            Io(err) => Some(err),
            Len(err) => Some(err),
            Content(err) => Some(err),
        }
    }
}

#[cfg(all(test, feature = "std"))]
mod test {
    use crate::{err::Layer, LenSource};

    use super::{HeaderLimitedReadError::*, *};
    use alloc::format;

    #[test]
    fn debug() {
        let err = HeaderError::HopByHopNotAtStart;
        assert_eq!(
            format!("Content({:?})", err.clone()),
            format!("{:?}", Content(err))
        );
    }

    #[test]
    fn fmt() {
        {
            let err = std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                "failed to fill whole buffer",
            );
            assert_eq!(
                format!("IPv6 Extension Header IO Error: {}", err),
                format!("{}", Io(err))
            );
        }
        {
            let err = LenError {
                required_len: 2,
                len: 1,
                len_source: LenSource::Slice,
                layer: Layer::IpAuthHeader,
                layer_start_offset: 3,
            };
            assert_eq!(format!("{}", &err), format!("{}", Len(err.clone())));
        }
        {
            let err = HeaderError::HopByHopNotAtStart;
            assert_eq!(format!("{}", &err), format!("{}", Content(err.clone())));
        }
    }

    #[test]
    fn source() {
        use core::error::Error;
        assert!(Io(std::io::Error::new(
            std::io::ErrorKind::UnexpectedEof,
            "failed to fill whole buffer",
        ))
        .source()
        .is_some());
        assert!(Len(LenError {
            required_len: 2,
            len: 1,
            len_source: LenSource::Slice,
            layer: Layer::IpAuthHeader,
            layer_start_offset: 3,
        })
        .source()
        .is_some());
        assert!(Content(HeaderError::HopByHopNotAtStart).source().is_some());
    }

    #[test]
    fn io() {
        assert!(Io(std::io::Error::new(
            std::io::ErrorKind::UnexpectedEof,
            "failed to fill whole buffer",
        ))
        .io()
        .is_some());
        assert!(Content(HeaderError::HopByHopNotAtStart).io().is_none());
    }

    #[test]
    fn len() {
        assert_eq!(
            None,
            Io(std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                "failed to fill whole buffer",
            ))
            .len()
        );
        {
            let err = LenError {
                required_len: 2,
                len: 1,
                len_source: LenSource::Slice,
                layer: Layer::IpAuthHeader,
                layer_start_offset: 3,
            };
            assert_eq!(Some(err.clone()), Len(err.clone()).len());
        }
    }

    #[test]
    fn content() {
        assert_eq!(
            None,
            Io(std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                "failed to fill whole buffer",
            ))
            .content()
        );
        {
            let err = HeaderError::HopByHopNotAtStart;
            assert_eq!(Some(err.clone()), Content(err.clone()).content());
        }
    }
}
