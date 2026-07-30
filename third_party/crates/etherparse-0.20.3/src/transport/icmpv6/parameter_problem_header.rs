use super::*;

/// ICMPv6 parameter problem header.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Ord, PartialOrd, Hash)]
pub struct ParameterProblemHeader {
    /// The code can offer additional informations about what kind of parameter
    /// problem caused the error.
    pub code: ParameterProblemCode,
    /// Identifies the octet offset within the
    /// invoking packet where the error was detected.
    ///
    /// The pointer will point beyond the end of the ICMPv6
    /// packet if the field in error is beyond what can fit
    /// in the maximum size of an ICMPv6 error message.
    pub pointer: u32,
}

#[cfg(test)]
mod test {
    use super::*;
    use alloc::format;

    #[test]
    fn clone_eq() {
        let value = ParameterProblemHeader {
            code: ParameterProblemCode::ErroneousHeaderField,
            pointer: 0,
        };
        assert_eq!(value.clone(), value);
    }

    #[test]
    fn debug() {
        let value = ParameterProblemHeader {
            code: ParameterProblemCode::ErroneousHeaderField,
            pointer: 0,
        };

        assert_eq!(
            format!("{:?}", value),
            format!(
                "ParameterProblemHeader {{ code: {:?}, pointer: {:?} }}",
                value.code, value.pointer
            )
        );
    }
}
