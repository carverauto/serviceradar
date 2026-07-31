/// Errors that can occour while reading the options of a TCP header.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TcpOptionReadError {
    /// Returned if an option id was read, but there was not enough memory in the options left to completely read it.
    UnexpectedEndOfSlice {
        option_id: u8,
        expected_len: u8,
        actual_len: usize,
    },

    /// Returned if the option as an unexpected size argument (e.g. != 4 for maximum segment size).
    UnexpectedSize { option_id: u8, size: u8 },

    /// Returned if an unknown tcp header option is encountered.
    ///
    /// The first element is the identifier and the slice contains the rest of data left in the options.
    UnknownId(u8),
}

impl core::error::Error for TcpOptionReadError {
    fn source(&self) -> Option<&(dyn core::error::Error + 'static)> {
        None
    }
}

impl core::fmt::Display for TcpOptionReadError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        use TcpOptionReadError::*;
        match self {
            UnexpectedEndOfSlice {
                option_id,
                expected_len,
                actual_len,
            } => {
                write!(f, "TcpOptionReadError: Not enough memory left in slice to read option of kind {option_id} (expected at least {expected_len} bytes, only {actual_len} bytes available).")
            }
            UnexpectedSize { option_id, size } => {
                write!(f, "TcpOptionReadError: Length value of the option of kind {option_id} had unexpected value {size}.")
            }
            UnknownId(id) => {
                write!(f, "TcpOptionReadError: Unknown tcp option kind value {id}.")
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
        use TcpOptionReadError::*;
        assert_eq!(
            "UnexpectedEndOfSlice { option_id: 1, expected_len: 2, actual_len: 3 }",
            format!(
                "{:?}",
                UnexpectedEndOfSlice {
                    option_id: 1,
                    expected_len: 2,
                    actual_len: 3
                }
            )
        );
    }

    #[test]
    fn clone_eq() {
        use TcpOptionReadError::*;
        let value = UnexpectedEndOfSlice {
            option_id: 123,
            expected_len: 5,
            actual_len: 4,
        };
        assert_eq!(value, value.clone());
    }

    #[cfg(feature = "std")]
    proptest! {
        #[test]
        fn source(
            arg_u8_0 in any::<u8>(),
            arg_u8_1 in any::<u8>(),
            arg_usize in any::<usize>()
        ) {
            use core::error::Error;
            use crate::TcpOptionReadError::*;

            assert!(UnexpectedEndOfSlice{ option_id: arg_u8_0, expected_len: arg_u8_1, actual_len: arg_usize}.source().is_none());
            assert!(UnexpectedSize{ option_id: arg_u8_0, size: arg_u8_1 }.source().is_none());
            assert!(UnknownId(arg_u8_0).source().is_none());
        }
    }

    proptest! {
        #[test]
        fn fmt(
            arg_u8_0 in any::<u8>(),
            arg_u8_1 in any::<u8>(),
            arg_usize in any::<usize>()
        ) {
            use crate::TcpOptionReadError::*;

            assert_eq!(
                &format!("TcpOptionReadError: Not enough memory left in slice to read option of kind {} (expected at least {} bytes, only {} bytes available).", arg_u8_0, arg_u8_1, arg_usize),
                &format!("{}", UnexpectedEndOfSlice{ option_id: arg_u8_0, expected_len: arg_u8_1, actual_len: arg_usize})
            );
            assert_eq!(
                &format!("TcpOptionReadError: Length value of the option of kind {} had unexpected value {}.", arg_u8_0, arg_u8_1),
                &format!("{}", UnexpectedSize{ option_id: arg_u8_0, size: arg_u8_1 })
            );
            assert_eq!(
                &format!("TcpOptionReadError: Unknown tcp option kind value {}.", arg_u8_0),
                &format!("{}", UnknownId(arg_u8_0))
            );
        }
    }
}
