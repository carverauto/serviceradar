use crate::icmpv6::NdpOptionType;

/// Error while decoding Neighbor Discovery options.
#[derive(Clone, Debug, Eq, PartialEq, Hash)]
#[non_exhaustive]
pub enum NdpOptionReadError {
    /// Not enough bytes are left to decode the option or its body.
    UnexpectedEndOfSlice {
        option_id: NdpOptionType,
        expected_size: usize,
        actual_size: usize,
    },
    /// An ND option with a length value of zero was encountered.
    ZeroLength { option_id: NdpOptionType },
    /// The option has a fixed encoded size and the received size differs.
    UnexpectedSize {
        option_id: NdpOptionType,
        expected_size: usize,
        actual_size: usize,
    },
    /// The option header `Type` and/or `Length` fields do not match expectations.
    UnexpectedHeader {
        expected_option_id: NdpOptionType,
        actual_option_id: NdpOptionType,
        expected_length_units: u8,
        actual_length_units: u8,
    },
}

impl core::fmt::Display for NdpOptionReadError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        use NdpOptionReadError::*;
        match self {
            UnexpectedEndOfSlice {
                option_id,
                expected_size: expected_len,
                actual_size: actual_len,
            } => write!(
                f,
                "NDP option error: Not enough bytes left to read option of type {} (expected at least {expected_len} bytes, only {actual_len} bytes available).",
                option_id.0,
            ),
            ZeroLength { option_id } => write!(
                f,
                "NDP option error: Encountered option of type {} with an invalid length of zero.",
                option_id.0,
            ),
            UnexpectedSize { option_id, expected_size, actual_size, } => write!(
                f,
                "NDP option error: Option of type {} had unexpected size value {actual_size} (expected {expected_size}).",
                option_id.0,
            ),
            UnexpectedHeader {
                expected_option_id,
                actual_option_id,
                expected_length_units,
                actual_length_units,
            } => write!(
                f,
                "NDP option error: Option header mismatch (expected type {} length {}, got type {} length {}).",
                expected_option_id.0,
                expected_length_units,
                actual_option_id.0,
                actual_length_units,
            ),
        }
    }
}

impl core::error::Error for NdpOptionReadError {
    fn source(&self) -> Option<&(dyn core::error::Error + 'static)> {
        None
    }
}
