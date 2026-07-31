use super::*;

/// Code values for ICMPv4 time exceeded message.
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub enum TimeExceededCode {
    /// Time-to-live exceeded in transit.
    TtlExceededInTransit = 0,
    /// Fragment reassembly time exceeded.
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
            CODE_TIME_EXCEEDED_TTL_EXCEEDED_IN_TRANSIT => Some(TtlExceededInTransit),
            CODE_TIME_EXCEEDED_FRAG_REASSEMBLY_TIME_EXCEEDED => {
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
mod test {
    use crate::icmpv4::{TimeExceededCode::*, *};
    use alloc::format;

    #[test]
    fn from_u8() {
        assert_eq!(
            TimeExceededCode::from_u8(CODE_TIME_EXCEEDED_TTL_EXCEEDED_IN_TRANSIT),
            Some(TtlExceededInTransit)
        );
        assert_eq!(
            TimeExceededCode::from_u8(CODE_TIME_EXCEEDED_FRAG_REASSEMBLY_TIME_EXCEEDED),
            Some(FragmentReassemblyTimeExceeded)
        );

        for code_u8 in 2..=u8::MAX {
            assert_eq!(None, TimeExceededCode::from_u8(code_u8));
        }
    }

    #[test]
    fn code_u8() {
        assert_eq!(
            TtlExceededInTransit.code_u8(),
            CODE_TIME_EXCEEDED_TTL_EXCEEDED_IN_TRANSIT
        );
        assert_eq!(
            FragmentReassemblyTimeExceeded.code_u8(),
            CODE_TIME_EXCEEDED_FRAG_REASSEMBLY_TIME_EXCEEDED
        );
    }

    #[test]
    fn debug() {
        let values = [
            ("TtlExceededInTransit", TtlExceededInTransit),
            (
                "FragmentReassemblyTimeExceeded",
                FragmentReassemblyTimeExceeded,
            ),
        ];
        for (expected, input) in values {
            assert_eq!(expected, format!("{:?}", input));
        }
    }

    #[test]
    fn clone_eq() {
        let values = [TtlExceededInTransit, FragmentReassemblyTimeExceeded];
        for value in values {
            assert_eq!(value.clone(), value);
        }
    }
}
