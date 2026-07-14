/// The header of an ICMPv4 Parameter Problems (contents up to
/// the offending ip header).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ParameterProblemHeader {
    /// Identifies the octet where an error was detected.
    ///
    /// The value is the pointer pointing to the offending octet in
    /// the offending packet.
    PointerIndicatesError(u8),
    /// Missing a Required Option
    MissingRequiredOption,
    /// Bad Length
    BadLength,
}

impl ParameterProblemHeader {
    /// Tries to convert the code [`u8`] value and pointer to a [`ParameterProblemHeader`] value.
    ///
    /// Returns [`None`] in case the code value is not known as a parameter problem code.
    pub fn from_values(code_u8: u8, pointer: u8) -> Option<ParameterProblemHeader> {
        use super::{ParameterProblemHeader::*, *};
        match code_u8 {
            CODE_PARAMETER_PROBLEM_POINTER_INDICATES_ERROR => Some(PointerIndicatesError(pointer)),
            CODE_PARAMETER_PROBLEM_MISSING_REQUIRED_OPTION => Some(MissingRequiredOption),
            CODE_PARAMETER_PROBLEM_BAD_LENGTH => Some(BadLength),
            _ => None,
        }
    }
}

#[cfg(test)]
mod test {
    use crate::icmpv4::{ParameterProblemHeader::*, *};
    use alloc::format;
    use proptest::prelude::*;

    proptest! {
        #[test]
        fn from_values(pointer in any::<u8>()) {
            {
                let tests = [
                    (CODE_PARAMETER_PROBLEM_POINTER_INDICATES_ERROR, PointerIndicatesError(pointer)),
                    (CODE_PARAMETER_PROBLEM_MISSING_REQUIRED_OPTION, MissingRequiredOption),
                    (CODE_PARAMETER_PROBLEM_BAD_LENGTH, BadLength),
                ];
                for t in tests {
                    assert_eq!(Some(t.1), ParameterProblemHeader::from_values(t.0, pointer));
                }
            }
            for code_u8 in 3..=u8::MAX {
                assert_eq!(None, ParameterProblemHeader::from_values(code_u8, pointer));
            }
        }
    }

    #[test]
    fn clone_eq() {
        let tests = [PointerIndicatesError(0), MissingRequiredOption, BadLength];
        for t in tests {
            assert_eq!(t.clone(), t);
        }
    }

    #[test]
    fn debug() {
        let tests = [
            ("PointerIndicatesError(0)", PointerIndicatesError(0)),
            ("MissingRequiredOption", MissingRequiredOption),
            ("BadLength", BadLength),
        ];
        for t in tests {
            assert_eq!(t.0, format!("{:?}", t.1));
        }
    }
}
