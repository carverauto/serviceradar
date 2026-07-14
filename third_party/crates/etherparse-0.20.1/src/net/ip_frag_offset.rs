use crate::err::ValueTooBigError;

/// The fragment offset is a 13 bit unsigned integer indicating the stating
/// position of the payload of a packet relative to the originally fragmented
/// packet payload.
///
/// This value can be present in an [`crate::Ipv4Header`] or an
/// [`crate::Ipv6FragmentHeader`].
///
/// # Example Usage:
///
/// ```
/// use etherparse::IpFragOffset;
///
/// // try into
/// {
///     let frag_offset: IpFragOffset = 123.try_into().unwrap();
///     assert_eq!(frag_offset.value(), 123);
///
///     // fragment offset can always be converted back to an u16
///     let value: u16 = frag_offset.into();
///     assert_eq!(123, value);
/// }
///
/// // via try_new
/// {
///     let frag_offset = IpFragOffset::try_new(123).unwrap();
///     assert_eq!(frag_offset.value(), 123);
///
///     // note that only 13 bit numbers are allowed (meaning
///     // 0b0001_1111_1111_1111 is the maximum allowed value)
///     use etherparse::err::{ValueTooBigError, ValueType};
///     assert_eq!(
///         IpFragOffset::try_new(IpFragOffset::MAX_U16 + 1),
///         Err(ValueTooBigError{
///             actual: IpFragOffset::MAX_U16 + 1,
///             max_allowed: IpFragOffset::MAX_U16,
///             value_type: ValueType::IpFragmentOffset,
///         })
///     );
/// }
///
/// // via new_unchecked
/// {
///     // in case you are sure the number does not exceed the max
///     // you can use the unsafe new_unchecked function
///     let frag_offset = unsafe {
///         // please make sure that the value is not greater than IpFragOffset::MAX_U16
///         // before calling this method
///         IpFragOffset::new_unchecked(123)
///     };
///     assert_eq!(frag_offset.value(), 123);
/// }
/// ```
#[derive(Copy, Clone, Default, Debug, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub struct IpFragOffset(u16);

impl IpFragOffset {
    /// IpFragOffset with value 0.
    pub const ZERO: IpFragOffset = IpFragOffset(0);

    /// Maximum value of an IP fragmentation offset.
    pub const MAX_U16: u16 = 0b0001_1111_1111_1111;

    /// Tries to create an [`IpFragOffset`] and checks that the passed value
    /// is smaller or equal than [`IpFragOffset::MAX_U16`] (13 bit unsigned integer).
    ///
    /// In case the passed value is bigger then what can be represented in an 13 bit
    /// integer an error is returned. Otherwise an `Ok` containing the [`IpFragOffset`].
    ///
    /// ```
    /// use etherparse::IpFragOffset;
    ///
    /// let frag_offset = IpFragOffset::try_new(123).unwrap();
    /// assert_eq!(frag_offset.value(), 123);
    ///
    /// // if a number that can not be represented in an 13 bit integer
    /// // gets passed in an error is returned
    /// use etherparse::err::{ValueTooBigError, ValueType};
    /// assert_eq!(
    ///     IpFragOffset::try_new(IpFragOffset::MAX_U16 + 1),
    ///     Err(ValueTooBigError{
    ///         actual: IpFragOffset::MAX_U16 + 1,
    ///         max_allowed: IpFragOffset::MAX_U16,
    ///         value_type: ValueType::IpFragmentOffset,
    ///     })
    /// );
    /// ```
    #[inline]
    pub const fn try_new(value: u16) -> Result<IpFragOffset, ValueTooBigError<u16>> {
        use crate::err::ValueType::IpFragmentOffset;
        if value <= IpFragOffset::MAX_U16 {
            Ok(IpFragOffset(value))
        } else {
            Err(ValueTooBigError {
                actual: value,
                max_allowed: IpFragOffset::MAX_U16,
                value_type: IpFragmentOffset,
            })
        }
    }

    /// Creates an [`IpFragOffset`] without checking that the value
    /// is smaller or equal than [`IpFragOffset::MAX_U16`] (13 bit unsigned integer).
    /// The caller must guarantee that `value <= IpFragOffset::MAX_U16`.
    ///
    /// # Safety
    ///
    /// `value` must be smaller or equal than [`IpFragOffset::MAX_U16`]
    /// otherwise the behavior of functions or data structures relying
    /// on this pre-requirement is undefined.
    #[inline]
    pub const unsafe fn new_unchecked(value: u16) -> IpFragOffset {
        debug_assert!(value <= IpFragOffset::MAX_U16);
        IpFragOffset(value)
    }

    /// Returns the underlying unsigned 13 bit value as an `u16` value.
    #[inline]
    pub const fn value(self) -> u16 {
        self.0
    }

    /// Returns the offset in bytes (offset raw value multiplied by 8).
    #[inline]
    pub const fn byte_offset(self) -> u16 {
        self.0 << 3
    }
}

impl core::fmt::Display for IpFragOffset {
    #[inline]
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        self.0.fmt(f)
    }
}

impl From<IpFragOffset> for u16 {
    #[inline]
    fn from(value: IpFragOffset) -> Self {
        value.0
    }
}

impl TryFrom<u16> for IpFragOffset {
    type Error = ValueTooBigError<u16>;

    #[inline]
    fn try_from(value: u16) -> Result<Self, Self::Error> {
        use crate::err::ValueType::IpFragmentOffset;
        if value <= IpFragOffset::MAX_U16 {
            Ok(IpFragOffset(value))
        } else {
            Err(Self::Error {
                actual: value,
                max_allowed: IpFragOffset::MAX_U16,
                value_type: IpFragmentOffset,
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
            let a = IpFragOffset(123);
            let b = a;
            assert_eq!(a, b);
            assert_eq!(a.clone(), a);
        }

        // default
        {
            let actual: IpFragOffset = Default::default();
            assert_eq!(actual.value(), 0);
        }

        // debug
        {
            let a = IpFragOffset(123);
            assert_eq!(format!("{:?}", a), format!("IpFragOffset(123)"));
        }

        // ord & partial ord
        {
            use core::cmp::Ordering;
            let a = IpFragOffset(123);
            let b = a;
            assert_eq!(a.cmp(&b), Ordering::Equal);
            assert_eq!(a.partial_cmp(&b), Some(Ordering::Equal));
        }

        // hash
        {
            use std::collections::hash_map::DefaultHasher;
            let a = {
                let mut hasher = DefaultHasher::new();
                IpFragOffset(123).hash(&mut hasher);
                hasher.finish()
            };
            let b = {
                let mut hasher = DefaultHasher::new();
                IpFragOffset(123).hash(&mut hasher);
                hasher.finish()
            };
            assert_eq!(a, b);
        }
    }

    proptest! {
        #[test]
        fn try_new(
            valid_value in 0..=0b0001_1111_1111_1111u16,
            invalid_value in 0b0010_0000_0000_0000u16..=u16::MAX
        ) {
            use crate::err::{ValueType, ValueTooBigError};
            assert_eq!(
                valid_value,
                IpFragOffset::try_new(valid_value).unwrap().value()
            );
            assert_eq!(
                IpFragOffset::try_new(invalid_value).unwrap_err(),
                ValueTooBigError{
                    actual: invalid_value,
                    max_allowed: 0b0001_1111_1111_1111,
                    value_type:  ValueType::IpFragmentOffset
                }
            );
        }
    }

    proptest! {
        #[test]
        fn try_from(
            valid_value in 0..=0b0001_1111_1111_1111u16,
            invalid_value in 0b0010_0000_0000_0000u16..=u16::MAX
        ) {
            use crate::err::{ValueType, ValueTooBigError};
            // try_into
            {
                let actual: IpFragOffset = valid_value.try_into().unwrap();
                assert_eq!(actual.value(), valid_value);

                let err: Result<IpFragOffset, ValueTooBigError<u16>> = invalid_value.try_into();
                assert_eq!(
                    err.unwrap_err(),
                    ValueTooBigError{
                        actual: invalid_value,
                        max_allowed: 0b0001_1111_1111_1111,
                        value_type:  ValueType::IpFragmentOffset
                    }
                );
            }
            // try_from
            {
                assert_eq!(
                    IpFragOffset::try_from(valid_value).unwrap().value(),
                    valid_value
                );

                assert_eq!(
                    IpFragOffset::try_from(invalid_value).unwrap_err(),
                    ValueTooBigError{
                        actual: invalid_value,
                        max_allowed: 0b0001_1111_1111_1111,
                        value_type:  ValueType::IpFragmentOffset
                    }
                );
            }
        }
    }

    proptest! {
        #[test]
        fn new_unchecked(valid_value in 0..=0b0001_1111_1111_1111u16) {
            assert_eq!(
                valid_value,
                unsafe {
                    IpFragOffset::new_unchecked(valid_value).value()
                }
            );
        }
    }

    proptest! {
        #[test]
        fn fmt(valid_value in 0..=0b0001_1111_1111_1111u16) {
            assert_eq!(format!("{}", IpFragOffset(valid_value)), format!("{}", valid_value));
        }
    }

    proptest! {
        #[test]
        fn from(valid_value in 0..=0b0001_1111_1111_1111u16,) {
            let frag_offset = IpFragOffset::try_new(valid_value).unwrap();
            let actual: u16 = frag_offset.into();
            assert_eq!(actual, valid_value);
        }
    }
}
