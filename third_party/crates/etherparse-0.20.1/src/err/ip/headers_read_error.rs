use super::HeadersError;
use crate::err::LenError;

/// Error when decoding an IP header via a `std::io::Read` source.
#[cfg(feature = "std")]
#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
#[derive(Debug)]
pub enum HeaderReadError {
    /// IO error was encountered while reading header.
    Io(std::io::Error),

    /// Errors caused by conflicts with the lengths defined
    /// in the headers (i.e. IPv4 length too small to read the
    /// lower layer headers)
    Len(LenError),

    /// Error caused by the contents of the header.
    Content(HeadersError),
}

#[cfg(feature = "std")]
#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl HeaderReadError {
    /// Returns the `std::io::Error` value if the `HeaderReadError` is `Io`.
    /// Otherwise `None` is returned.
    #[inline]
    pub fn io(self) -> Option<std::io::Error> {
        use HeaderReadError::*;
        match self {
            Io(value) => Some(value),
            _ => None,
        }
    }

    /// Returns the `err::LenError` value if the `HeaderReadError` is `Len`.
    /// Otherwise `None` is returned.
    #[inline]
    pub fn len(self) -> Option<LenError> {
        use HeaderReadError::*;
        match self {
            Len(value) => Some(value),
            _ => None,
        }
    }

    /// Returns the `err::ip::HeaderError` value if the `HeaderReadError` is `Content`.
    /// Otherwise `None` is returned.
    #[inline]
    pub fn content(self) -> Option<HeadersError> {
        use HeaderReadError::*;
        match self {
            Content(value) => Some(value),
            _ => None,
        }
    }
}

#[cfg(feature = "std")]
#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl core::fmt::Display for HeaderReadError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        use HeaderReadError::*;
        match self {
            Io(err) => write!(f, "IP Header IO Error: {err}"),
            Len(err) => err.fmt(f),
            Content(err) => err.fmt(f),
        }
    }
}

impl core::error::Error for HeaderReadError {
    fn source(&self) -> Option<&(dyn core::error::Error + 'static)> {
        use HeaderReadError::*;
        match self {
            Io(err) => Some(err),
            Len(err) => Some(err),
            Content(err) => Some(err),
        }
    }
}

#[cfg(all(test, feature = "std"))]
mod test {
    use super::{super::HeaderError::*, super::HeadersError::*, HeaderReadError::*, *};
    use crate::{err::Layer, LenSource};
    use alloc::format;

    #[test]
    fn debug() {
        let err = HeadersError::Ip(UnsupportedIpVersion { version_number: 6 });
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
                format!("IP Header IO Error: {}", err),
                format!("{}", Io(err))
            );
        }
        {
            let err = LenError {
                required_len: 2,
                len: 1,
                len_source: LenSource::Slice,
                layer: Layer::Icmpv4,
                layer_start_offset: 3,
            };
            assert_eq!(format!("{}", Len(err.clone())), format!("{}", err));
        }
        {
            let err = Ip(UnsupportedIpVersion { version_number: 6 });
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
            layer: Layer::Icmpv4,
            layer_start_offset: 3,
        })
        .source()
        .is_some());
        assert!(Content(Ip(UnsupportedIpVersion { version_number: 6 }))
            .source()
            .is_some());
    }

    #[test]
    fn io() {
        assert!(Io(std::io::Error::new(
            std::io::ErrorKind::UnexpectedEof,
            "failed to fill whole buffer",
        ))
        .io()
        .is_some());
        assert!(Content(Ip(UnsupportedIpVersion { version_number: 6 }))
            .io()
            .is_none());
    }

    #[test]
    fn len() {
        {
            let err = LenError {
                required_len: 2,
                len: 1,
                len_source: LenSource::Slice,
                layer: Layer::Icmpv4,
                layer_start_offset: 3,
            };
            assert_eq!(Len(err.clone()).len(), Some(err));
        }
        assert!(Io(std::io::Error::new(
            std::io::ErrorKind::UnexpectedEof,
            "failed to fill whole buffer",
        ))
        .len()
        .is_none());
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
            let err = Ip(UnsupportedIpVersion { version_number: 6 });
            assert_eq!(Some(err.clone()), Content(err.clone()).content());
        }
    }
}
