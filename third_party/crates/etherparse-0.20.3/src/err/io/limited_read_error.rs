use crate::err::LenError;

/// Error that can occur when reading from a [`crate::io::LimitedReader`]
#[derive(Debug)]
#[cfg(feature = "std")]
#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
pub enum LimitedReadError {
    /// IO error was encountered while reading header or
    /// expected packet contents.
    Io(std::io::Error),

    /// Error when parsing had to be aborted because a
    /// length limit specified by an upper layer has been
    /// exceeded.
    Len(LenError),
}

#[cfg(feature = "std")]
#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl LimitedReadError {
    /// Returns the `std::io::Error` value if the `LimitedReadError` is `Io`.
    /// Otherwise `None` is returned.
    #[inline]
    pub fn io(self) -> Option<std::io::Error> {
        use LimitedReadError::*;
        match self {
            Io(err) => Some(err),
            _ => None,
        }
    }

    /// Returns the `err::LenError` value if it is of value `Len`.
    /// Otherwise `None` is returned.
    #[inline]
    pub fn len(self) -> Option<LenError> {
        use LimitedReadError::*;
        match self {
            Len(err) => Some(err),
            _ => None,
        }
    }
}

#[cfg(feature = "std")]
#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl core::fmt::Display for LimitedReadError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        use LimitedReadError::*;
        match self {
            Io(err) => err.fmt(f),
            Len(err) => err.fmt(f),
        }
    }
}

impl core::error::Error for LimitedReadError {
    fn source(&self) -> Option<&(dyn core::error::Error + 'static)> {
        use LimitedReadError::*;
        match self {
            Io(err) => Some(err),
            Len(err) => Some(err),
        }
    }
}

#[cfg(all(test, feature = "std"))]
mod test {
    use super::{LimitedReadError::*, *};
    use crate::{err::Layer, LenSource};
    use alloc::format;

    #[test]
    fn debug() {
        let err = LenError {
            required_len: 2,
            len: 1,
            len_source: LenSource::Slice,
            layer: Layer::Icmpv4,
            layer_start_offset: 3,
        };
        assert_eq!(format!("Len({:?})", err.clone()), format!("{:?}", Len(err)));
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
            let err = LenError {
                required_len: 2,
                len: 1,
                len_source: LenSource::Slice,
                layer: Layer::Icmpv4,
                layer_start_offset: 3,
            };
            assert_eq!(format!("{}", &err), format!("{}", Len(err.clone())));
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
        {
            let err = LenError {
                required_len: 2,
                len: 1,
                len_source: LenSource::Slice,
                layer: Layer::Icmpv4,
                layer_start_offset: 3,
            };
            assert!(Len(err).source().is_some());
        }
    }

    #[test]
    fn io() {
        assert!(Io(std::io::Error::new(
            std::io::ErrorKind::UnexpectedEof,
            "failed to fill whole buffer",
        ))
        .io()
        .is_some());
        {
            let err = LenError {
                required_len: 2,
                len: 1,
                len_source: LenSource::Slice,
                layer: Layer::Icmpv4,
                layer_start_offset: 3,
            };
            assert!(Len(err).io().is_none());
        }
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
                layer: Layer::Icmpv4,
                layer_start_offset: 3,
            };
            assert_eq!(Some(err.clone()), Len(err.clone()).len());
        }
    }
}
