use crate::err::ValueTooBigError;

/// 12 bit unsigned integer containing the "VLAN identifier" (present
/// in the [`crate::SingleVlanHeader`]).
#[derive(Copy, Clone, Default, Debug, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub struct VlanId(u16);

impl VlanId {
    /// VlanId with value 0.
    pub const ZERO: VlanId = VlanId(0);

    /// Maximum value of an VLAN id.
    pub const MAX_U16: u16 = 0b0000_1111_1111_1111;

    /// Tries to create an [`VlanId`] and checks that the passed value
    /// is smaller or equal than [`VlanId::MAX_U16`] (12 bit unsigned integer).
    ///
    /// In case the passed value is bigger then what can be represented in an 12 bit
    /// integer an error is returned. Otherwise an `Ok` containing the [`VlanId`].
    ///
    /// ```
    /// use etherparse::VlanId;
    ///
    /// let vlanid = VlanId::try_new(2).unwrap();
    /// assert_eq!(vlanid.value(), 2);
    ///
    /// // if a number that can not be represented in an 12 bit integer
    /// // gets passed in an error is returned
    /// use etherparse::err::{ValueTooBigError, ValueType};
    /// assert_eq!(
    ///     VlanId::try_new(VlanId::MAX_U16 + 1),
    ///     Err(ValueTooBigError{
    ///         actual: VlanId::MAX_U16 + 1,
    ///         max_allowed: VlanId::MAX_U16,
    ///         value_type: ValueType::VlanId,
    ///     })
    /// );
    /// ```
    #[inline]
    pub const fn try_new(value: u16) -> Result<VlanId, ValueTooBigError<u16>> {
        use crate::err::ValueType;
        if value <= VlanId::MAX_U16 {
            Ok(VlanId(value))
        } else {
            Err(ValueTooBigError {
                actual: value,
                max_allowed: VlanId::MAX_U16,
                value_type: ValueType::VlanId,
            })
        }
    }

    /// Creates an [`VlanId`] WITHOUT checking that the value
    /// is smaller or equal than [`VlanId::MAX_U16`] (12 bit unsigned integer).
    /// The caller must guarantee that `value <= VlanId::MAX_U16`.
    ///
    /// # Safety
    ///
    /// `value` must be smaller or equal than [`VlanId::MAX_U16`]
    /// otherwise the behavior of functions or data structures relying
    /// on this pre-requirement is undefined.
    #[inline]
    pub const unsafe fn new_unchecked(value: u16) -> VlanId {
        debug_assert!(value <= VlanId::MAX_U16);
        VlanId(value)
    }

    /// Returns the underlying unsigned 12 bit value as an `u16` value.
    #[inline]
    pub const fn value(self) -> u16 {
        self.0
    }
}

impl core::fmt::Display for VlanId {
    #[inline]
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        self.0.fmt(f)
    }
}

impl From<VlanId> for u16 {
    #[inline]
    fn from(value: VlanId) -> Self {
        value.0
    }
}

impl TryFrom<u16> for VlanId {
    type Error = ValueTooBigError<u16>;

    #[inline]
    fn try_from(value: u16) -> Result<Self, Self::Error> {
        use crate::err::ValueType;
        if value <= VlanId::MAX_U16 {
            Ok(VlanId(value))
        } else {
            Err(Self::Error {
                actual: value,
                max_allowed: VlanId::MAX_U16,
                value_type: ValueType::VlanId,
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
            let a = VlanId(2);
            let b = a;
            assert_eq!(a, b);
            assert_eq!(a.clone(), a);
        }

        // default
        {
            let actual: VlanId = Default::default();
            assert_eq!(actual.value(), 0);
        }

        // debug
        {
            let a = VlanId(2);
            assert_eq!(format!("{:?}", a), format!("VlanId(2)"));
        }

        // ord & partial ord
        {
            use core::cmp::Ordering;
            let a = VlanId(2);
            let b = a;
            assert_eq!(a.cmp(&b), Ordering::Equal);
            assert_eq!(a.partial_cmp(&b), Some(Ordering::Equal));
        }

        // hash
        {
            use std::collections::hash_map::DefaultHasher;
            let a = {
                let mut hasher = DefaultHasher::new();
                VlanId(2).hash(&mut hasher);
                hasher.finish()
            };
            let b = {
                let mut hasher = DefaultHasher::new();
                VlanId(2).hash(&mut hasher);
                hasher.finish()
            };
            assert_eq!(a, b);
        }
    }

    proptest! {
        #[test]
        fn try_new(
            valid_value in 0..=0b0000_1111_1111_1111u16,
            invalid_value in 0b0001_0000_0000_0000u16..=u16::MAX
        ) {
            use crate::err::{ValueType, ValueTooBigError};
            assert_eq!(
                valid_value,
                VlanId::try_new(valid_value).unwrap().value()
            );
            assert_eq!(
                VlanId::try_new(invalid_value).unwrap_err(),
                ValueTooBigError{
                    actual: invalid_value,
                    max_allowed: 0b0000_1111_1111_1111,
                    value_type:  ValueType::VlanId
                }
            );
        }
    }

    proptest! {
        #[test]
        fn try_from(
            valid_value in 0..=0b0000_1111_1111_1111u16,
            invalid_value in 0b0001_0000_0000_0000u16..=u16::MAX
        ) {
            use crate::err::{ValueType, ValueTooBigError};
            // try_into
            {
                let actual: VlanId = valid_value.try_into().unwrap();
                assert_eq!(actual.value(), valid_value);

                let err: Result<VlanId, ValueTooBigError<u16>> = invalid_value.try_into();
                assert_eq!(
                    err.unwrap_err(),
                    ValueTooBigError{
                        actual: invalid_value,
                        max_allowed: 0b0000_1111_1111_1111,
                        value_type:  ValueType::VlanId
                    }
                );
            }
            // try_from
            {
                assert_eq!(
                    VlanId::try_from(valid_value).unwrap().value(),
                    valid_value
                );

                assert_eq!(
                    VlanId::try_from(invalid_value).unwrap_err(),
                    ValueTooBigError{
                        actual: invalid_value,
                        max_allowed: 0b0000_1111_1111_1111,
                        value_type:  ValueType::VlanId
                    }
                );
            }
        }
    }

    proptest! {
        #[test]
        fn new_unchecked(valid_value in 0..=0b0000_1111_1111_1111u16) {
            assert_eq!(
                valid_value,
                unsafe {
                    VlanId::new_unchecked(valid_value).value()
                }
            );
        }
    }

    proptest! {
        #[test]
        fn fmt(valid_value in 0..=0b0000_1111_1111_1111u16) {
            assert_eq!(format!("{}", VlanId(valid_value)), format!("{}", valid_value));
        }
    }

    proptest! {
        #[test]
        fn from(valid_value in 0..=0b0000_1111_1111_1111u16,) {
            let vlanid = VlanId::try_new(valid_value).unwrap();
            let actual: u16 = vlanid.into();
            assert_eq!(actual, valid_value);
        }
    }
}
