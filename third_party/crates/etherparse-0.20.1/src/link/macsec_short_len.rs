use crate::err::ValueTooBigError;

/// 6 bit unsigned integer containing the "MACsec short length".
/// (present in the [`crate::MacsecHeader`]).
#[derive(Copy, Clone, Default, Debug, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub struct MacsecShortLen(u8);

impl MacsecShortLen {
    /// MacsecShortLen with value 0.
    pub const ZERO: MacsecShortLen = MacsecShortLen(0);

    /// Maximum value of a "MACsec short length" as a [`u8`].
    pub const MAX_U8: u8 = 0b0011_1111;

    /// Maximum value of a "MACsec short length" as a [`usize`].
    pub const MAX_USIZE: usize = 0b0011_1111;

    /// Tries to create an [`MacsecShortLen`] and checks that the passed value
    /// is smaller or equal than [`MacsecShortLen::MAX_U8`] (6 bit unsigned integer).
    ///
    /// In case the passed value is bigger then what can be represented in an 6 bit
    /// integer an error is returned. Otherwise an `Ok` containing the [`MacsecShortLen`].
    ///
    /// ```
    /// use etherparse::MacsecShortLen;
    ///
    /// let an = MacsecShortLen::try_from_u8(2).unwrap();
    /// assert_eq!(an.value(), 2);
    ///
    /// // if a number that can not be represented in an 2 bit integer
    /// // gets passed in an error is returned
    /// use etherparse::err::{ValueTooBigError, ValueType};
    /// assert_eq!(
    ///     MacsecShortLen::try_from_u8(MacsecShortLen::MAX_U8 + 1),
    ///     Err(ValueTooBigError{
    ///         actual: MacsecShortLen::MAX_U8 + 1,
    ///         max_allowed: MacsecShortLen::MAX_U8,
    ///         value_type: ValueType::MacsecShortLen,
    ///     })
    /// );
    /// ```
    #[inline]
    pub const fn try_from_u8(value: u8) -> Result<MacsecShortLen, ValueTooBigError<u8>> {
        use crate::err::ValueType;
        if value <= MacsecShortLen::MAX_U8 {
            Ok(MacsecShortLen(value))
        } else {
            Err(ValueTooBigError {
                actual: value,
                max_allowed: MacsecShortLen::MAX_U8,
                value_type: ValueType::MacsecShortLen,
            })
        }
    }

    /// Creates an [`MacsecShortLen`] without checking that the value
    /// is smaller or equal than [`MacsecShortLen::MAX_U8`] (6 bit unsigned integer).
    /// The caller must guarantee that `value <= MacsecShortLen::MAX_U8`.
    ///
    /// # Safety
    ///
    /// `value` must be smaller or equal than [`MacsecShortLen::MAX_U8`]
    /// otherwise the behavior of functions or data structures relying
    /// on this pre-requirement is undefined.
    #[inline]
    pub const unsafe fn from_u8_unchecked(value: u8) -> MacsecShortLen {
        debug_assert!(value <= MacsecShortLen::MAX_U8);
        MacsecShortLen(value)
    }

    /// Creates an [`MacsecShortLen`] from a length and automatically
    /// defaults to zero if too big. This mirrors the expected behavior
    /// of the `short_len` field in the [`crate::MacsecHeader`].
    ///
    /// # Example
    /// ```
    /// use etherparse::MacsecShortLen;
    ///
    /// // if the length is smaller than 64.
    /// let a = MacsecShortLen::from_len(34);
    /// assert_eq!(34, a.value());
    ///
    /// // if the length is greater than 64 [`MacsecShortLen::MAX_U8`]
    /// // zero is returned
    /// let b = MacsecShortLen::from_len(65);
    /// assert_eq!(0, b.value());
    /// ```
    #[inline]
    pub fn from_len(len: usize) -> MacsecShortLen {
        if len > 0b0011_1111 {
            MacsecShortLen::ZERO
        } else {
            MacsecShortLen(len as u8)
        }
    }

    /// Returns the underlying unsigned 6 bit value as an `u8` value.
    #[inline]
    pub const fn value(self) -> u8 {
        self.0
    }
}

impl core::fmt::Display for MacsecShortLen {
    #[inline]
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        self.0.fmt(f)
    }
}

impl From<MacsecShortLen> for u8 {
    #[inline]
    fn from(value: MacsecShortLen) -> Self {
        value.0
    }
}

impl TryFrom<u8> for MacsecShortLen {
    type Error = ValueTooBigError<u8>;

    #[inline]
    fn try_from(value: u8) -> Result<Self, Self::Error> {
        use crate::err::ValueType;
        if value <= MacsecShortLen::MAX_U8 {
            Ok(MacsecShortLen(value))
        } else {
            Err(Self::Error {
                actual: value,
                max_allowed: MacsecShortLen::MAX_U8,
                value_type: ValueType::MacsecShortLen,
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
            let a = MacsecShortLen(2);
            let b = a;
            assert_eq!(a, b);
            assert_eq!(a.clone(), a);
        }

        // default
        {
            let actual: MacsecShortLen = Default::default();
            assert_eq!(actual.value(), 0);
        }

        // debug
        {
            let a = MacsecShortLen(2);
            assert_eq!(format!("{:?}", a), format!("MacsecShortLen(2)"));
        }

        // ord & partial ord
        {
            use core::cmp::Ordering;
            let a = MacsecShortLen(2);
            let b = a;
            assert_eq!(a.cmp(&b), Ordering::Equal);
            assert_eq!(a.partial_cmp(&b), Some(Ordering::Equal));
        }

        // hash
        {
            use std::collections::hash_map::DefaultHasher;
            let a = {
                let mut hasher = DefaultHasher::new();
                MacsecShortLen(2).hash(&mut hasher);
                hasher.finish()
            };
            let b = {
                let mut hasher = DefaultHasher::new();
                MacsecShortLen(2).hash(&mut hasher);
                hasher.finish()
            };
            assert_eq!(a, b);
        }
    }

    proptest! {
        #[test]
        fn try_from_u8(
            valid_value in 0..=0b0011_1111u8,
            invalid_value in 0b0100_0000u8..=u8::MAX
        ) {
            use crate::err::{ValueType, ValueTooBigError};
            assert_eq!(
                valid_value,
                MacsecShortLen::try_from_u8(valid_value).unwrap().value()
            );
            assert_eq!(
                MacsecShortLen::try_from_u8(invalid_value).unwrap_err(),
                ValueTooBigError{
                    actual: invalid_value,
                    max_allowed: 0b0011_1111,
                    value_type:  ValueType::MacsecShortLen
                }
            );
        }
    }

    proptest! {
        #[test]
        fn try_from(
            valid_value in 0..=0b0011_1111u8,
            invalid_value in 0b0100_0000u8..=u8::MAX
        ) {
            use crate::err::{ValueType, ValueTooBigError};
            // try_into
            {
                let actual: MacsecShortLen = valid_value.try_into().unwrap();
                assert_eq!(actual.value(), valid_value);

                let err: Result<MacsecShortLen, ValueTooBigError<u8>> = invalid_value.try_into();
                assert_eq!(
                    err.unwrap_err(),
                    ValueTooBigError{
                        actual: invalid_value,
                        max_allowed: 0b0011_1111,
                        value_type:  ValueType::MacsecShortLen
                    }
                );
            }
            // try_from
            {
                assert_eq!(
                    MacsecShortLen::try_from(valid_value).unwrap().value(),
                    valid_value
                );

                assert_eq!(
                    MacsecShortLen::try_from(invalid_value).unwrap_err(),
                    ValueTooBigError{
                        actual: invalid_value,
                        max_allowed: 0b0011_1111,
                        value_type:  ValueType::MacsecShortLen
                    }
                );
            }
        }
    }

    proptest! {
        #[test]
        fn from_u8_unchecked(valid_value in 0..=0b0011_1111u8) {
            assert_eq!(
                valid_value,
                unsafe {
                    MacsecShortLen::from_u8_unchecked(valid_value).value()
                }
            );
        }
    }

    proptest! {
        #[test]
        fn from_len(
            valid_value in 0..=0b0011_1111usize,
            zero_values in 0b0100_0000usize..=usize::MAX,
        ) {
            assert_eq!(
                valid_value as u8,
                MacsecShortLen::from_len(valid_value).value()
            );
            assert_eq!(
                0,
                MacsecShortLen::from_len(zero_values).value()
            );
        }
    }

    proptest! {
        #[test]
        fn fmt(valid_value in 0..=0b0011_1111u8) {
            assert_eq!(format!("{}", MacsecShortLen(valid_value)), format!("{}", valid_value));
        }
    }

    proptest! {
        #[test]
        fn from(valid_value in 0..=0b0011_1111u8,) {
            let pcp = MacsecShortLen::try_from_u8(valid_value).unwrap();
            let actual: u8 = pcp.into();
            assert_eq!(actual, valid_value);
        }
    }
}
