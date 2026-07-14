use crate::err::ValueTooBigError;

/// 3 bit unsigned integer containing the "Priority Code Point"
/// (present in the [`crate::SingleVlanHeader`]).
///
/// Refers to the IEEE 802.1p class of service and maps to the
/// frame priority level.
#[derive(Copy, Clone, Default, Debug, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub struct VlanPcp(u8);

impl VlanPcp {
    /// VlanPcp with value 0.
    pub const ZERO: VlanPcp = VlanPcp(0);

    /// Maximum value of an vlan header PCP.
    pub const MAX_U8: u8 = 0b0000_0111;

    /// Tries to create an [`VlanPcp`] and checks that the passed value
    /// is smaller or equal than [`VlanPcp::MAX_U8`] (3 bit unsigned integer).
    ///
    /// In case the passed value is bigger then what can be represented in an 3 bit
    /// integer an error is returned. Otherwise an `Ok` containing the [`VlanPcp`].
    ///
    /// ```
    /// use etherparse::VlanPcp;
    ///
    /// let pcp = VlanPcp::try_new(2).unwrap();
    /// assert_eq!(pcp.value(), 2);
    ///
    /// // if a number that can not be represented in an 3 bit integer
    /// // gets passed in an error is returned
    /// use etherparse::err::{ValueTooBigError, ValueType};
    /// assert_eq!(
    ///     VlanPcp::try_new(VlanPcp::MAX_U8 + 1),
    ///     Err(ValueTooBigError{
    ///         actual: VlanPcp::MAX_U8 + 1,
    ///         max_allowed: VlanPcp::MAX_U8,
    ///         value_type: ValueType::VlanPcp,
    ///     })
    /// );
    /// ```
    #[inline]
    pub const fn try_new(value: u8) -> Result<VlanPcp, ValueTooBigError<u8>> {
        use crate::err::ValueType;
        if value <= VlanPcp::MAX_U8 {
            Ok(VlanPcp(value))
        } else {
            Err(ValueTooBigError {
                actual: value,
                max_allowed: VlanPcp::MAX_U8,
                value_type: ValueType::VlanPcp,
            })
        }
    }

    /// Creates an [`VlanPcp`] without checking that the value
    /// is smaller or equal than [`VlanPcp::MAX_U8`] (3 bit unsigned integer).
    /// The caller must guarantee that `value <= VlanPcp::MAX_U8`.
    ///
    /// # Safety
    ///
    /// `value` must be smaller or equal than [`VlanPcp::MAX_U8`]
    /// otherwise the behavior of functions or data structures relying
    /// on this pre-requirement is undefined.
    #[inline]
    pub const unsafe fn new_unchecked(value: u8) -> VlanPcp {
        debug_assert!(value <= VlanPcp::MAX_U8);
        VlanPcp(value)
    }

    /// Returns the underlying unsigned 3 bit value as an `u8` value.
    #[inline]
    pub const fn value(self) -> u8 {
        self.0
    }
}

impl core::fmt::Display for VlanPcp {
    #[inline]
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        self.0.fmt(f)
    }
}

impl From<VlanPcp> for u8 {
    #[inline]
    fn from(value: VlanPcp) -> Self {
        value.0
    }
}

impl TryFrom<u8> for VlanPcp {
    type Error = ValueTooBigError<u8>;

    #[inline]
    fn try_from(value: u8) -> Result<Self, Self::Error> {
        use crate::err::ValueType;
        if value <= VlanPcp::MAX_U8 {
            Ok(VlanPcp(value))
        } else {
            Err(Self::Error {
                actual: value,
                max_allowed: VlanPcp::MAX_U8,
                value_type: ValueType::VlanPcp,
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
            let a = VlanPcp(2);
            let b = a;
            assert_eq!(a, b);
            assert_eq!(a.clone(), a);
        }

        // default
        {
            let actual: VlanPcp = Default::default();
            assert_eq!(actual.value(), 0);
        }

        // debug
        {
            let a = VlanPcp(2);
            assert_eq!(format!("{:?}", a), format!("VlanPcp(2)"));
        }

        // ord & partial ord
        {
            use core::cmp::Ordering;
            let a = VlanPcp(2);
            let b = a;
            assert_eq!(a.cmp(&b), Ordering::Equal);
            assert_eq!(a.partial_cmp(&b), Some(Ordering::Equal));
        }

        // hash
        {
            use std::collections::hash_map::DefaultHasher;
            let a = {
                let mut hasher = DefaultHasher::new();
                VlanPcp(2).hash(&mut hasher);
                hasher.finish()
            };
            let b = {
                let mut hasher = DefaultHasher::new();
                VlanPcp(2).hash(&mut hasher);
                hasher.finish()
            };
            assert_eq!(a, b);
        }
    }

    proptest! {
        #[test]
        fn try_new(
            valid_value in 0..=0b0000_0111u8,
            invalid_value in 0b0000_1000u8..=u8::MAX
        ) {
            use crate::err::{ValueType, ValueTooBigError};
            assert_eq!(
                valid_value,
                VlanPcp::try_new(valid_value).unwrap().value()
            );
            assert_eq!(
                VlanPcp::try_new(invalid_value).unwrap_err(),
                ValueTooBigError{
                    actual: invalid_value,
                    max_allowed: 0b0000_0111,
                    value_type:  ValueType::VlanPcp
                }
            );
        }
    }

    proptest! {
        #[test]
        fn try_from(
            valid_value in 0..=0b0000_0111u8,
            invalid_value in 0b0000_1000u8..=u8::MAX
        ) {
            use crate::err::{ValueType, ValueTooBigError};
            // try_into
            {
                let actual: VlanPcp = valid_value.try_into().unwrap();
                assert_eq!(actual.value(), valid_value);

                let err: Result<VlanPcp, ValueTooBigError<u8>> = invalid_value.try_into();
                assert_eq!(
                    err.unwrap_err(),
                    ValueTooBigError{
                        actual: invalid_value,
                        max_allowed: 0b0000_0111,
                        value_type:  ValueType::VlanPcp
                    }
                );
            }
            // try_from
            {
                assert_eq!(
                    VlanPcp::try_from(valid_value).unwrap().value(),
                    valid_value
                );

                assert_eq!(
                    VlanPcp::try_from(invalid_value).unwrap_err(),
                    ValueTooBigError{
                        actual: invalid_value,
                        max_allowed: 0b0000_0111,
                        value_type:  ValueType::VlanPcp
                    }
                );
            }
        }
    }

    proptest! {
        #[test]
        fn new_unchecked(valid_value in 0..=0b0000_0111u8) {
            assert_eq!(
                valid_value,
                unsafe {
                    VlanPcp::new_unchecked(valid_value).value()
                }
            );
        }
    }

    proptest! {
        #[test]
        fn fmt(valid_value in 0..=0b0000_0111u8) {
            assert_eq!(format!("{}", VlanPcp(valid_value)), format!("{}", valid_value));
        }
    }

    proptest! {
        #[test]
        fn from(valid_value in 0..=0b0000_0111u8,) {
            let pcp = VlanPcp::try_new(valid_value).unwrap();
            let actual: u8 = pcp.into();
            assert_eq!(actual, valid_value);
        }
    }
}
