use super::HeaderError;

/// Error when decoding an IP authentication header via a `std::io::Read` source.
#[cfg(feature = "std")]
#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
#[derive(Debug)]
pub enum HeaderReadError {
    /// IO error was encountered while reading header.
    Io(std::io::Error),

    /// Error caused by the contents of the header.
    Content(HeaderError),
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

    /// Returns the `err::ip_auth::HeaderError` value if it is of value `Content`.
    /// Otherwise `None` is returned.
    #[inline]
    pub fn content(self) -> Option<HeaderError> {
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
            Io(err) => write!(f, "IP Authentication Header IO Error: {err}"),
            Content(value) => value.fmt(f),
        }
    }
}

impl core::error::Error for HeaderReadError {
    fn source(&self) -> Option<&(dyn core::error::Error + 'static)> {
        use HeaderReadError::*;
        match self {
            Io(err) => Some(err),
            Content(err) => Some(err),
        }
    }
}

#[cfg(all(test, feature = "std"))]
mod test {
    use super::{HeaderReadError::*, *};
    use alloc::format;

    #[test]
    fn debug() {
        let err = HeaderError::ZeroPayloadLen;
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
                format!("IP Authentication Header IO Error: {}", err),
                format!("{}", Io(err))
            );
        }
        {
            let err = HeaderError::ZeroPayloadLen;
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
        assert!(Content(HeaderError::ZeroPayloadLen).source().is_some());
    }

    #[test]
    fn io() {
        assert!(Io(std::io::Error::new(
            std::io::ErrorKind::UnexpectedEof,
            "failed to fill whole buffer",
        ))
        .io()
        .is_some());
        assert!(Content(HeaderError::ZeroPayloadLen).io().is_none());
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
            let err = HeaderError::ZeroPayloadLen;
            assert_eq!(Some(err.clone()), Content(err.clone()).content());
        }
    }
}
