#[cfg(feature = "std")]
use super::ExtsWalkError;

/// Error when writing IPv6 extension headers.
#[cfg(feature = "std")]
#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
#[derive(Debug)]
pub enum HeaderWriteError {
    /// IO error encountered while writing.
    Io(std::io::Error),
    /// Data was not serializable because of its content.
    Content(ExtsWalkError),
}

#[cfg(feature = "std")]
#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl HeaderWriteError {
    /// Returns a reference to the [`std::io::Error`] if the value is an [`HeaderWriteError::Io`].
    pub fn io(&self) -> Option<&std::io::Error> {
        match self {
            HeaderWriteError::Io(err) => Some(err),
            HeaderWriteError::Content(_) => None,
        }
    }

    /// Returns a reference to the [`crate::err::ipv6_exts::ExtsWalkError`] if the value is an [`HeaderWriteError::Content`].
    pub fn content(&self) -> Option<&ExtsWalkError> {
        match self {
            HeaderWriteError::Io(_) => None,
            HeaderWriteError::Content(err) => Some(err),
        }
    }
}

#[cfg(feature = "std")]
#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl core::fmt::Display for HeaderWriteError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        use HeaderWriteError::*;
        match self {
            Io(err) => err.fmt(f),
            Content(err) => err.fmt(f),
        }
    }
}

impl core::error::Error for HeaderWriteError {
    fn source(&self) -> Option<&(dyn core::error::Error + 'static)> {
        use HeaderWriteError::*;
        match self {
            Io(ref err) => Some(err),
            Content(ref err) => Some(err),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{ExtsWalkError::*, HeaderWriteError::*};
    use crate::*;
    use alloc::format;
    use core::error::Error;

    #[test]
    fn io() {
        assert!(Io(std::io::Error::new(
            std::io::ErrorKind::UnexpectedEof,
            "failed to fill whole buffer",
        ))
        .io()
        .is_some());
        assert!(Content(ExtNotReferenced {
            missing_ext: IpNumber::AUTHENTICATION_HEADER,
        })
        .io()
        .is_none());
    }

    #[test]
    fn content() {
        assert!(Io(std::io::Error::new(
            std::io::ErrorKind::UnexpectedEof,
            "failed to fill whole buffer",
        ))
        .content()
        .is_none());
        {
            let err = ExtNotReferenced {
                missing_ext: IpNumber::AUTHENTICATION_HEADER,
            };
            assert_eq!(Some(&err), Content(err.clone()).content());
        }
    }

    #[test]
    fn debug() {
        let err = ExtNotReferenced {
            missing_ext: IpNumber::AUTHENTICATION_HEADER,
        };
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
            assert_eq!(format!("{}", err), format!("{}", Io(err)));
        }
        {
            let err = ExtNotReferenced {
                missing_ext: IpNumber::AUTHENTICATION_HEADER,
            };
            assert_eq!(format!("{}", Content(err.clone())), format!("{}", err));
        }
    }

    #[cfg(feature = "std")]
    #[test]
    fn source() {
        assert!(Io(std::io::Error::new(
            std::io::ErrorKind::UnexpectedEof,
            "failed to fill whole buffer",
        ))
        .source()
        .is_some());
        assert!(Content(ExtNotReferenced {
            missing_ext: IpNumber::AUTHENTICATION_HEADER,
        })
        .source()
        .is_some());
    }
}
