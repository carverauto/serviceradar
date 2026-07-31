use super::*;

/// Code values for ICMPv6 time exceeded message.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Ord, PartialOrd, Hash)]
pub enum TimeExceededCode {
    /// "hop limit exceeded in transit"
    HopLimitExceeded = 0,
    /// "fragment reassembly time exceeded"
    FragmentReassemblyTimeExceeded = 1,
}

impl TimeExceededCode {
    /// Tries to convert a code [`u8`] value to a [`TimeExceededCode`] value.
    ///
    /// Returns [`None`] in case the code value is not known as a time exceeded code.
    #[inline]
    pub fn from_u8(code_u8: u8) -> Option<TimeExceededCode> {
        use TimeExceededCode::*;
        match code_u8 {
            CODE_TIME_EXCEEDED_HOP_LIMIT_EXCEEDED => Some(HopLimitExceeded),
            CODE_TIME_EXCEEDED_FRAGMENT_REASSEMBLY_TIME_EXCEEDED => {
                Some(FragmentReassemblyTimeExceeded)
            }
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
pub(crate) mod time_exceeded_code_test_consts {
    use super::{TimeExceededCode::*, *};

    pub const VALID_VALUES: [(TimeExceededCode, u8); 2] = [
        (HopLimitExceeded, CODE_TIME_EXCEEDED_HOP_LIMIT_EXCEEDED),
        (
            FragmentReassemblyTimeExceeded,
            CODE_TIME_EXCEEDED_FRAGMENT_REASSEMBLY_TIME_EXCEEDED,
        ),
    ];
}

#[cfg(test)]
mod test {
    use super::{time_exceeded_code_test_consts::*, TimeExceededCode::*, *};
    use alloc::format;

    #[test]
    fn from_u8() {
        for (code, code_u8) in VALID_VALUES {
            assert_eq!(Some(code), TimeExceededCode::from_u8(code_u8));
        }
        for code_u8 in 2..=u8::MAX {
            assert_eq!(None, TimeExceededCode::from_u8(code_u8));
        }
    }

    #[test]
    fn from_enum() {
        for (code, code_u8) in VALID_VALUES {
            assert_eq!(code.code_u8(), code_u8);
        }
    }

    #[test]
    fn clone_eq() {
        for (code, _) in VALID_VALUES {
            assert_eq!(code.clone(), code);
        }
    }

    #[test]
    fn debug() {
        let tests = [
            (HopLimitExceeded, "HopLimitExceeded"),
            (
                FragmentReassemblyTimeExceeded,
                "FragmentReassemblyTimeExceeded",
            ),
        ];
        for test in tests {
            assert_eq!(format!("{:?}", test.0), test.1);
        }
    }
}
