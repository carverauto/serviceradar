use super::*;

/// Code values for ICMPv6 parameter problem messages.
///
/// Source: <https://www.iana.org/assignments/icmpv6-parameters/icmpv6-parameters.xhtml#icmpv6-parameters-codes-5>
#[derive(Clone, Copy, Debug, PartialEq, Eq, Ord, PartialOrd, Hash)]
pub enum ParameterProblemCode {
    /// Erroneous header field encountered (from [RFC 4443](https://tools.ietf.org/html/rfc4443))
    ErroneousHeaderField = 0,
    /// Unrecognized Next Header type encountered (from [RFC 4443](https://tools.ietf.org/html/rfc4443))
    UnrecognizedNextHeader = 1,
    /// Unrecognized IPv6 option encountered (from [RFC 4443](https://tools.ietf.org/html/rfc4443))
    UnrecognizedIpv6Option = 2,
    /// IPv6 First Fragment has incomplete IPv6 Header Chain (from [RFC 7112](https://tools.ietf.org/html/rfc7112))
    Ipv6FirstFragmentIncompleteHeaderChain = 3,
    /// SR Upper-layer Header Error (from [RFC 8754](https://tools.ietf.org/html/rfc8754)).
    SrUpperLayerHeaderError = 4,
    /// Unrecognized Next Header type encountered by intermediate node (from [RFC 8883](https://tools.ietf.org/html/rfc8883))
    UnrecognizedNextHeaderByIntermediateNode = 5,
    /// Extension header too big (from [RFC 8883](https://tools.ietf.org/html/rfc8883))
    ExtensionHeaderTooBig = 6,
    /// Extension header chain too long (from [RFC 8883](https://tools.ietf.org/html/rfc8883))
    ExtensionHeaderChainTooLong = 7,
    /// Too many extension headers (from [RFC 8883](https://tools.ietf.org/html/rfc8883))
    TooManyExtensionHeaders = 8,
    /// Too many options in extension header (from [RFC 8883](https://tools.ietf.org/html/rfc8883))
    TooManyOptionsInExtensionHeader = 9,
    /// Option too big (from [RFC 8883](https://tools.ietf.org/html/rfc8883))
    OptionTooBig = 10,
}

impl ParameterProblemCode {
    /// Tries to convert a code [`u8`] value to a [`ParameterProblemCode`] value.
    ///
    /// Returns [`None`] in case the code value is not known as a parameter problem code.
    pub fn from_u8(code_u8: u8) -> Option<ParameterProblemCode> {
        use ParameterProblemCode::*;
        match code_u8 {
            CODE_PARAM_PROBLEM_ERR_HEADER_FIELD => Some(ErroneousHeaderField),
            CODE_PARAM_PROBLEM_UNRECOG_NEXT_HEADER => Some(UnrecognizedNextHeader),
            CODE_PARAM_PROBLEM_UNRECOG_IPV6_OPTION => Some(UnrecognizedIpv6Option),
            CODE_PARAM_PROBLEM_IPV6_FIRST_FRAG_INCOMP_HEADER_CHAIN => {
                Some(Ipv6FirstFragmentIncompleteHeaderChain)
            }
            CODE_PARAM_PROBLEM_SR_UPPER_LAYER_HEADER_ERROR => Some(SrUpperLayerHeaderError),
            CODE_PARAM_PROBLEM_UNRECOG_NEXT_HEADER_BY_INTERMEDIATE_NODE => {
                Some(UnrecognizedNextHeaderByIntermediateNode)
            }
            CODE_PARAM_PROBLEM_EXT_HEADER_TOO_BIG => Some(ExtensionHeaderTooBig),
            CODE_PARAM_PROBLEM_EXT_HEADER_CHAIN_TOO_LONG => Some(ExtensionHeaderChainTooLong),
            CODE_PARAM_PROBLEM_TOO_MANY_EXT_HEADERS => Some(TooManyExtensionHeaders),
            CODE_PARAM_PROBLEM_TOO_MANY_OPTIONS_EXT_HEADER => Some(TooManyOptionsInExtensionHeader),
            CODE_PARAM_PROBLEM_OPTION_TOO_BIG => Some(OptionTooBig),
            _ => None,
        }
    }

    /// Returns the [`u8`] value of the code.
    #[inline]
    pub fn code_u8(&self) -> u8 {
        *self as u8
    }
}

#[cfg(test)]
pub(crate) mod parameter_problem_code_test_consts {
    use super::*;
    use ParameterProblemCode::*;

    pub const VALID_VALUES: [(ParameterProblemCode, u8); 11] = [
        (ErroneousHeaderField, CODE_PARAM_PROBLEM_ERR_HEADER_FIELD),
        (
            UnrecognizedNextHeader,
            CODE_PARAM_PROBLEM_UNRECOG_NEXT_HEADER,
        ),
        (
            UnrecognizedIpv6Option,
            CODE_PARAM_PROBLEM_UNRECOG_IPV6_OPTION,
        ),
        (
            Ipv6FirstFragmentIncompleteHeaderChain,
            CODE_PARAM_PROBLEM_IPV6_FIRST_FRAG_INCOMP_HEADER_CHAIN,
        ),
        (
            SrUpperLayerHeaderError,
            CODE_PARAM_PROBLEM_SR_UPPER_LAYER_HEADER_ERROR,
        ),
        (
            UnrecognizedNextHeaderByIntermediateNode,
            CODE_PARAM_PROBLEM_UNRECOG_NEXT_HEADER_BY_INTERMEDIATE_NODE,
        ),
        (ExtensionHeaderTooBig, CODE_PARAM_PROBLEM_EXT_HEADER_TOO_BIG),
        (
            ExtensionHeaderChainTooLong,
            CODE_PARAM_PROBLEM_EXT_HEADER_CHAIN_TOO_LONG,
        ),
        (
            TooManyExtensionHeaders,
            CODE_PARAM_PROBLEM_TOO_MANY_EXT_HEADERS,
        ),
        (
            TooManyOptionsInExtensionHeader,
            CODE_PARAM_PROBLEM_TOO_MANY_OPTIONS_EXT_HEADER,
        ),
        (OptionTooBig, CODE_PARAM_PROBLEM_OPTION_TOO_BIG),
    ];
}

#[cfg(test)]
mod test {
    use super::{parameter_problem_code_test_consts::*, ParameterProblemCode::*, *};
    use alloc::format;

    #[test]
    fn from_u8() {
        for t in VALID_VALUES {
            assert_eq!(Some(t.0), ParameterProblemCode::from_u8(t.1));
        }

        for code_u8 in 11..=u8::MAX {
            assert_eq!(None, ParameterProblemCode::from_u8(code_u8));
        }
    }

    #[test]
    fn code_u8() {
        for t in VALID_VALUES {
            assert_eq!(t.0.code_u8(), t.1);
        }
    }
    #[test]
    fn clone_eq() {
        for (value, _) in VALID_VALUES {
            assert_eq!(value.clone(), value);
        }
    }

    #[test]
    fn debug() {
        let tests = [
            (ErroneousHeaderField, "ErroneousHeaderField"),
            (UnrecognizedNextHeader, "UnrecognizedNextHeader"),
            (UnrecognizedIpv6Option, "UnrecognizedIpv6Option"),
            (UnrecognizedNextHeader, "UnrecognizedNextHeader"),
            (UnrecognizedIpv6Option, "UnrecognizedIpv6Option"),
            (
                Ipv6FirstFragmentIncompleteHeaderChain,
                "Ipv6FirstFragmentIncompleteHeaderChain",
            ),
            (SrUpperLayerHeaderError, "SrUpperLayerHeaderError"),
            (
                UnrecognizedNextHeaderByIntermediateNode,
                "UnrecognizedNextHeaderByIntermediateNode",
            ),
            (ExtensionHeaderTooBig, "ExtensionHeaderTooBig"),
            (ExtensionHeaderChainTooLong, "ExtensionHeaderChainTooLong"),
            (TooManyExtensionHeaders, "TooManyExtensionHeaders"),
            (
                TooManyOptionsInExtensionHeader,
                "TooManyOptionsInExtensionHeader",
            ),
            (OptionTooBig, "OptionTooBig"),
        ];
        for test in tests {
            assert_eq!(format!("{:?}", test.0), test.1);
        }
    }
}
