use crate::err::ValueTooBigError;

/// 2 bit unsigned integer containing the "MACsec association number".
/// (present in the [`crate::MacsecHeader`]).
///
/// Identifies up to four SAs within the context of an SC.
#[derive(Copy, Clone, Default, Debug, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub struct MacsecAn(u8);

impl MacsecAn {
    /// MacsecAn with value 0.
    pub const ZERO: MacsecAn = MacsecAn(0);

    /// Maximum value of a "MACsec association number".
    pub const MAX_U8: u8 = 0b0000_0011;

    /// Tries to create an [`MacsecAn`] and checks that the passed value
    /// is smaller or equal than [`MacsecAn::MAX_U8`] (2 bit unsigned integer).
    ///
    /// In case the passed value is bigger then what can be represented in an 2 bit
    /// integer an error is returned. Otherwise an `Ok` containing the [`MacsecAn`].
    ///
    /// ```
    /// use etherparse::MacsecAn;
    ///
    /// let an = MacsecAn::try_new(2).unwrap();
    /// assert_eq!(an.value(), 2);
    ///
    /// // if a number that can not be represented in an 2 bit integer
    /// // gets passed in an error is returned
    /// use etherparse::err::{ValueTooBigError, ValueType};
    /// assert_eq!(
    ///     MacsecAn::try_new(MacsecAn::MAX_U8 + 1),
    ///     Err(ValueTooBigError{
    ///         actual: MacsecAn::MAX_U8 + 1,
    ///         max_allowed: MacsecAn::MAX_U8,
    ///         value_type: ValueType::MacsecAn,
    ///     })
    /// );
    /// ```
    #[inline]
    pub const fn try_new(value: u8) -> Result<MacsecAn, ValueTooBigError<u8>> {
        use crate::err::ValueType;
        if value <= MacsecAn::MAX_U8 {
            Ok(MacsecAn(value))
        } else {
            Err(ValueTooBigError {
                actual: value,
                max_allowed: MacsecAn::MAX_U8,
                value_type: ValueType::MacsecAn,
            })
        }
    }

    /// Creates an [`MacsecAn`] without checking that the value
    /// is smaller or equal than [`MacsecAn::MAX_U8`] (2 bit unsigned integer).
    /// The caller must guarantee that `value <= MacsecAn::MAX_U8`.
    ///
    /// # Safety
    ///
    /// `value` must be smaller or equal than [`MacsecAn::MAX_U8`]
    /// otherwise the behavior of functions or data structures relying
    /// on this pre-requirement is undefined.
    #[inline]
    pub const unsafe fn new_unchecked(value: u8) -> MacsecAn {
        debug_assert!(value <= MacsecAn::MAX_U8);
        MacsecAn(value)
    }

    /// Returns the underlying unsigned 2 bit value as an `u8` value.
    #[inline]
    pub const fn value(self) -> u8 {
        self.0
    }
}

impl core::fmt::Display for MacsecAn {
    #[inline]
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        self.0.fmt(f)
    }
}

impl From<MacsecAn> for u8 {
    #[inline]
    fn from(value: MacsecAn) -> Self {
        value.0
    }
}

impl TryFrom<u8> for MacsecAn {
    type Error = ValueTooBigError<u8>;

    #[inline]
    fn try_from(value: u8) -> Result<Self, Self::Error> {
        use crate::err::ValueType;
        if value <= MacsecAn::MAX_U8 {
            Ok(MacsecAn(value))
        } else {
            Err(Self::Error {
                actual: value,
                max_allowed: MacsecAn::MAX_U8,
                value_type: ValueType::MacsecAn,
            })
        }
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use core::hash::{Hash, Hasher};
    use proptest::prelude::*;
    use std::format;

    #[test]
    fn derived_traits() {
        // copy & clone
        {
            let a = MacsecAn(2);
            let b = a;
            assert_eq!(a, b);
            assert_eq!(a.clone(), a);
        }

        // default
        {
            let actual: MacsecAn = Default::default();
            assert_eq!(actual.value(), 0);
        }

        // debug
        {
            let a = MacsecAn(2);
            assert_eq!(format!("{:?}", a), format!("MacsecAn(2)"));
        }

        // ord & partial ord
        {
            use core::cmp::Ordering;
            let a = MacsecAn(2);
            let b = a;
            assert_eq!(a.cmp(&b), Ordering::Equal);
            assert_eq!(a.partial_cmp(&b), Some(Ordering::Equal));
        }

        // hash
        {
            use std::collections::hash_map::DefaultHasher;
            let a = {
                let mut hasher = DefaultHasher::new();
                MacsecAn(2).hash(&mut hasher);
                hasher.finish()
            };
            let b = {
                let mut hasher = DefaultHasher::new();
                MacsecAn(2).hash(&mut hasher);
                hasher.finish()
            };
            assert_eq!(a, b);
        }
    }

    proptest! {
        #[test]
        fn try_new(
            valid_value in 0..=0b0000_0011u8,
            invalid_value in 0b0000_0100u8..=u8::MAX
        ) {
            use crate::err::{ValueType, ValueTooBigError};
            assert_eq!(
                valid_value,
                MacsecAn::try_new(valid_value).unwrap().value()
            );
            assert_eq!(
                MacsecAn::try_new(invalid_value).unwrap_err(),
                ValueTooBigError{
                    actual: invalid_value,
                    max_allowed: 0b0000_0011,
                    value_type:  ValueType::MacsecAn
                }
            );
        }
    }

    proptest! {
        #[test]
        fn try_from(
            valid_value in 0..=0b0000_0011u8,
            invalid_value in 0b0000_0100u8..=u8::MAX
        ) {
            use crate::err::{ValueType, ValueTooBigError};
            // try_into
            {
                let actual: MacsecAn = valid_value.try_into().unwrap();
                assert_eq!(actual.value(), valid_value);

                let err: Result<MacsecAn, ValueTooBigError<u8>> = invalid_value.try_into();
                assert_eq!(
                    err.unwrap_err(),
                    ValueTooBigError{
                        actual: invalid_value,
                        max_allowed: 0b0000_0011,
                        value_type:  ValueType::MacsecAn
                    }
                );
            }
            // try_from
            {
                assert_eq!(
                    MacsecAn::try_from(valid_value).unwrap().value(),
                    valid_value
                );

                assert_eq!(
                    MacsecAn::try_from(invalid_value).unwrap_err(),
                    ValueTooBigError{
                        actual: invalid_value,
                        max_allowed: 0b0000_0011,
                        value_type:  ValueType::MacsecAn
                    }
                );
            }
        }
    }

    proptest! {
        #[test]
        fn new_unchecked(valid_value in 0..=0b0000_0011u8) {
            assert_eq!(
                valid_value,
                unsafe {
                    MacsecAn::new_unchecked(valid_value).value()
                }
            );
        }
    }

    proptest! {
        #[test]
        fn fmt(valid_value in 0..=0b0000_0011u8) {
            assert_eq!(format!("{}", MacsecAn(valid_value)), format!("{}", valid_value));
        }
    }

    proptest! {
        #[test]
        fn from(valid_value in 0..=0b0000_0011u8,) {
            let pcp = MacsecAn::try_new(valid_value).unwrap();
            let actual: u8 = pcp.into();
            assert_eq!(actual, valid_value);
        }
    }
}
