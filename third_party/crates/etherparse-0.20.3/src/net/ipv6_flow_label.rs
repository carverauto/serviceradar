use crate::err::ValueTooBigError;

/// The IPv6 "Flow Label" is a 20 bit unsigned integer present in
/// the [`crate::Ipv6Header`].
///
/// # Example Usage:
///
/// ```
/// use etherparse::Ipv6FlowLabel;
///
/// // try into
/// {
///     let flow_label: Ipv6FlowLabel = 123.try_into().unwrap();
///     assert_eq!(flow_label.value(), 123);
///
///     // fragment offset can always be converted back to an u32
///     let value: u32 = flow_label.into();
///     assert_eq!(123, value);
/// }
///
/// // via try_new
/// {
///     let flow_label = Ipv6FlowLabel::try_new(123).unwrap();
///     assert_eq!(flow_label.value(), 123);
///
///     // note that only 20 bit numbers are allowed (meaning
///     // 0b1111_11111111_11111111 is the maximum allowed value)
///     use etherparse::err::{ValueTooBigError, ValueType};
///     assert_eq!(
///         Ipv6FlowLabel::try_new(Ipv6FlowLabel::MAX_U32 + 1),
///         Err(ValueTooBigError{
///             actual: Ipv6FlowLabel::MAX_U32 + 1,
///             max_allowed: Ipv6FlowLabel::MAX_U32,
///             value_type: ValueType::Ipv6FlowLabel,
///         })
///     );
/// }
///
/// // via new_unchecked
/// {
///     // in case you are sure the number does not exceed the max
///     // you can use the unsafe new_unchecked function
///     let flow_label = unsafe {
///         // please make sure that the value is not greater than Ipv6FlowLabel::MAX_U32
///         // before calling this method
///         Ipv6FlowLabel::new_unchecked(123)
///     };
///     assert_eq!(flow_label.value(), 123);
/// }
/// ```
#[derive(Copy, Clone, Default, Debug, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub struct Ipv6FlowLabel(u32);

impl Ipv6FlowLabel {
    /// Ipv6FlowLabel with value 0.
    pub const ZERO: Ipv6FlowLabel = Ipv6FlowLabel(0);

    /// Maximum value of an IPv6 Flow Label.
    pub const MAX_U32: u32 = 0b1111_1111_1111_1111_1111;

    /// Tries to create an [`Ipv6FlowLabel`] and checks that the passed value
    /// is smaller or equal than [`Ipv6FlowLabel::MAX_U32`] (20 bit unsigned integer).
    ///
    /// In case the passed value is bigger then what can be represented in an 20 bit
    /// integer an error is returned. Otherwise an `Ok` containing the [`Ipv6FlowLabel`].
    ///
    /// ```
    /// use etherparse::Ipv6FlowLabel;
    ///
    /// let frag_offset = Ipv6FlowLabel::try_new(123).unwrap();
    /// assert_eq!(frag_offset.value(), 123);
    ///
    /// // if a number that can not be represented in an 20 bit integer
    /// // gets passed in an error is returned
    /// use etherparse::err::{ValueTooBigError, ValueType};
    /// assert_eq!(
    ///     Ipv6FlowLabel::try_new(Ipv6FlowLabel::MAX_U32 + 1),
    ///     Err(ValueTooBigError{
    ///         actual: Ipv6FlowLabel::MAX_U32 + 1,
    ///         max_allowed: Ipv6FlowLabel::MAX_U32,
    ///         value_type: ValueType::Ipv6FlowLabel,
    ///     })
    /// );
    /// ```
    #[inline]
    pub const fn try_new(value: u32) -> Result<Ipv6FlowLabel, ValueTooBigError<u32>> {
        use crate::err::ValueType;
        if value <= Ipv6FlowLabel::MAX_U32 {
            Ok(Ipv6FlowLabel(value))
        } else {
            Err(ValueTooBigError {
                actual: value,
                max_allowed: Ipv6FlowLabel::MAX_U32,
                value_type: ValueType::Ipv6FlowLabel,
            })
        }
    }

    /// Creates an [`Ipv6FlowLabel`] without checking that the value
    /// is smaller or equal than [`Ipv6FlowLabel::MAX_U32`] (20 bit unsigned integer).
    /// The caller must guarantee that `value <= Ipv6FlowLabel::MAX_U32`.
    ///
    /// # Safety
    ///
    /// `value` must be smaller or equal than [`Ipv6FlowLabel::MAX_U32`]
    /// otherwise the behavior of functions or data structures relying
    /// on this pre-requirement is undefined.
    #[inline]
    pub const unsafe fn new_unchecked(value: u32) -> Ipv6FlowLabel {
        debug_assert!(value <= Ipv6FlowLabel::MAX_U32);
        Ipv6FlowLabel(value)
    }

    /// Returns the underlying unsigned 20 bit value as an `u32` value.
    #[inline]
    pub const fn value(self) -> u32 {
        self.0
    }
}

impl core::fmt::Display for Ipv6FlowLabel {
    #[inline]
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        self.0.fmt(f)
    }
}

impl From<Ipv6FlowLabel> for u32 {
    #[inline]
    fn from(value: Ipv6FlowLabel) -> Self {
        value.0
    }
}

impl TryFrom<u32> for Ipv6FlowLabel {
    type Error = ValueTooBigError<u32>;

    #[inline]
    fn try_from(value: u32) -> Result<Self, Self::Error> {
        use crate::err::ValueType;
        if value <= Ipv6FlowLabel::MAX_U32 {
            Ok(Ipv6FlowLabel(value))
        } else {
            Err(Self::Error {
                actual: value,
                max_allowed: Ipv6FlowLabel::MAX_U32,
                value_type: ValueType::Ipv6FlowLabel,
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
            let a = Ipv6FlowLabel(123);
            let b = a;
            assert_eq!(a, b);
            assert_eq!(a.clone(), a);
        }

        // default
        {
            let actual: Ipv6FlowLabel = Default::default();
            assert_eq!(actual.value(), 0);
        }

        // debug
        {
            let a = Ipv6FlowLabel(123);
            assert_eq!(format!("{:?}", a), format!("Ipv6FlowLabel(123)"));
        }

        // ord & partial ord
        {
            use core::cmp::Ordering;
            let a = Ipv6FlowLabel(123);
            let b = a;
            assert_eq!(a.cmp(&b), Ordering::Equal);
            assert_eq!(a.partial_cmp(&b), Some(Ordering::Equal));
        }

        // hash
        {
            use std::collections::hash_map::DefaultHasher;
            let a = {
                let mut hasher = DefaultHasher::new();
                Ipv6FlowLabel(123).hash(&mut hasher);
                hasher.finish()
            };
            let b = {
                let mut hasher = DefaultHasher::new();
                Ipv6FlowLabel(123).hash(&mut hasher);
                hasher.finish()
            };
            assert_eq!(a, b);
        }
    }

    proptest! {
        #[test]
        fn try_new(
            valid_value in 0..=0b1111_11111111_11111111u32,
            invalid_value in 0b1_0000_00000000_00000000u32..=u32::MAX
        ) {
            use crate::err::{ValueType, ValueTooBigError};
            assert_eq!(
                valid_value,
                Ipv6FlowLabel::try_new(valid_value).unwrap().value()
            );
            assert_eq!(
                Ipv6FlowLabel::try_new(invalid_value).unwrap_err(),
                ValueTooBigError{
                    actual: invalid_value,
                    max_allowed: 0b1111_11111111_11111111,
                    value_type:  ValueType::Ipv6FlowLabel
                }
            );
        }
    }

    proptest! {
        #[test]
        fn try_from(
            valid_value in 0..=0b1111_11111111_11111111u32,
            invalid_value in 0b1_0000_00000000_00000000u32..=u32::MAX
        ) {
            use crate::err::{ValueType, ValueTooBigError};
            // try_into
            {
                let actual: Ipv6FlowLabel = valid_value.try_into().unwrap();
                assert_eq!(actual.value(), valid_value);

                let err: Result<Ipv6FlowLabel, ValueTooBigError<u32>> = invalid_value.try_into();
                assert_eq!(
                    err.unwrap_err(),
                    ValueTooBigError{
                        actual: invalid_value,
                        max_allowed: 0b1111_11111111_11111111,
                        value_type:  ValueType::Ipv6FlowLabel
                    }
                );
            }
            // try_from
            {
                assert_eq!(
                    Ipv6FlowLabel::try_from(valid_value).unwrap().value(),
                    valid_value
                );

                assert_eq!(
                    Ipv6FlowLabel::try_from(invalid_value).unwrap_err(),
                    ValueTooBigError{
                        actual: invalid_value,
                        max_allowed: 0b1111_11111111_11111111,
                        value_type:  ValueType::Ipv6FlowLabel
                    }
                );
            }
        }
    }

    proptest! {
        #[test]
        fn new_unchecked(valid_value in 0..=0b1111_11111111_11111111u32) {
            assert_eq!(
                valid_value,
                unsafe {
                    Ipv6FlowLabel::new_unchecked(valid_value).value()
                }
            );
        }
    }

    proptest! {
        #[test]
        fn fmt(valid_value in 0..=0b1111_11111111_11111111u32) {
            assert_eq!(format!("{}", Ipv6FlowLabel(valid_value)), format!("{}", valid_value));
        }
    }

    proptest! {
        #[test]
        fn from(valid_value in 0..=0b1111_11111111_11111111u32,) {
            let frag_offset = Ipv6FlowLabel::try_new(valid_value).unwrap();
            let actual: u32 = frag_offset.into();
            assert_eq!(actual, valid_value);
        }
    }
}
