/// Errors that can occour when setting the options of a tcp header.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TcpOptionWriteError {
    /// There is not enough memory to store all options in the options section of the header (maximum 40 bytes).
    ///
    /// The options size is limited by the 4 bit data_offset field in the header which describes
    /// the total tcp header size in multiple of 4 bytes. This leads to a maximum size for the options
    /// part of the header of 4*(15 - 5) (minus 5 for the size of the tcp header itself).
    NotEnoughSpace(usize),
}

impl core::error::Error for TcpOptionWriteError {
    fn source(&self) -> Option<&(dyn core::error::Error + 'static)> {
        None
    }
}

impl core::fmt::Display for TcpOptionWriteError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        use TcpOptionWriteError::*;
        match self {
            NotEnoughSpace(size) => {
                write!(f, "TcpOptionWriteError: Not enough memory to store all options in the options section of a tcp header (maximum 40 bytes can be stored, the options would have needed {size} bytes).")
            }
        }
    }
}

#[cfg(test)]
mod test {
    use crate::*;
    use alloc::format;
    use proptest::prelude::*;

    #[test]
    fn debug() {
        use TcpOptionWriteError::*;
        assert_eq!("NotEnoughSpace(0)", format!("{:?}", NotEnoughSpace(0)));
    }

    #[test]
    fn clone_eq() {
        use TcpOptionWriteError::*;
        let value = NotEnoughSpace(123);
        assert_eq!(value, value.clone());
    }

    #[cfg(feature = "std")]
    proptest! {
        #[test]
        fn source(arg_usize in any::<usize>()) {
            use core::error::Error;
            use crate::TcpOptionWriteError::*;

            assert!(NotEnoughSpace(arg_usize).source().is_none());
        }
    }

    proptest! {
        #[test]
        fn fmt(arg_usize in any::<usize>()) {
            use crate::TcpOptionWriteError::*;

            assert_eq!(
                &format!("TcpOptionWriteError: Not enough memory to store all options in the options section of a tcp header (maximum 40 bytes can be stored, the options would have needed {} bytes).", arg_usize),
                &format!("{}", NotEnoughSpace(arg_usize))
            );
        }
    }
}
