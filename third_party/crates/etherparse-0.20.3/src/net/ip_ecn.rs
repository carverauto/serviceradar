#[deprecated(since = "0.18.0", note = "Please use `IpEcn` instead.")]
pub type Ipv4Ecn = IpEcn;

use crate::err::ValueTooBigError;

/// Code points for "Explicit Congestion Notification" (ECN) present in the
/// [`crate::Ipv4Header`] and [`crate::Ipv6Header`].
///
/// Code points are defined in [RFC-3168](https://datatracker.ietf.org/doc/html/rfc3168)
///
/// For reasoning to why there are two code points with the exact same meaning,
/// see [RFC-3168 Section 20.2](https://datatracker.ietf.org/doc/html/rfc3168#section-20.2)
#[repr(u8)]
#[derive(Copy, Debug, Clone, Eq, PartialEq, PartialOrd, Ord, Hash)]
pub enum IpEcn {
    /// End node is not an ECN capable transport.
    NotEct = 0b00,
    /// End node is an ECN capable transport (experimental).
    Ect1 = 0b01,
    /// End node is an ECN capable transport.
    Ect0 = 0b10,
    /// Congestion is experienced by the router.
    CongestionExperienced = 0b11,
}

impl IpEcn {
    /// IpEcn with value 0.
    pub const ZERO: IpEcn = IpEcn::NotEct;

    /// IpEcn with value 1.
    pub const ONE: IpEcn = IpEcn::Ect1;

    /// IpEcn with value 2.
    pub const TWO: IpEcn = IpEcn::Ect0;

    /// IpEcn with value 3.
    pub const THREE: IpEcn = IpEcn::CongestionExperienced;

    /// Maximum value of an IPv4 or IPv6 header ECN.
    pub const MAX_U8: u8 = 0b0000_0011;

    #[deprecated(since = "0.18.0", note = "Please use IpEcn::THREE instead.")]
    /// Deprecated, use [`crate::IpEcn::THREE`] instead.
    pub const TRHEE: IpEcn = IpEcn::THREE;

    /// Tries to create an [`IpEcn`] and checks that the passed value
    /// is smaller or equal than [`IpEcn::MAX_U8`] (2 bit unsigned integer).
    ///
    /// In case the passed value is bigger then what can be represented in an 2 bit
    /// integer an error is returned. Otherwise an `Ok` containing the [`IpEcn`].
    ///
    /// ```
    /// use etherparse::IpEcn;
    ///
    /// let ecn = IpEcn::try_new(2).unwrap();
    /// assert_eq!(ecn.value(), 2);
    ///
    /// // if a number that can not be represented in an 2 bit integer
    /// // gets passed in an error is returned
    /// use etherparse::err::{ValueTooBigError, ValueType};
    /// assert_eq!(
    ///     IpEcn::try_new(IpEcn::MAX_U8 + 1),
    ///     Err(ValueTooBigError{
    ///         actual: IpEcn::MAX_U8 + 1,
    ///         max_allowed: IpEcn::MAX_U8,
    ///         value_type: ValueType::IpEcn,
    ///     })
    /// );
    /// ```
    #[inline]
    pub const fn try_new(value: u8) -> Result<IpEcn, ValueTooBigError<u8>> {
        use crate::err::ValueType;
        if value <= IpEcn::MAX_U8 {
            // SAFETY: Safe as value has been verified to be
            //         <= IpEcn::MAX_U8.
            unsafe { Ok(Self::new_unchecked(value)) }
        } else {
            Err(ValueTooBigError {
                actual: value,
                max_allowed: IpEcn::MAX_U8,
                value_type: ValueType::IpEcn,
            })
        }
    }

    /// Creates an [`IpEcn`] without checking that the value
    /// is smaller or equal than [`IpEcn::MAX_U8`] (2 bit unsigned integer).
    /// The caller must guarantee that `value <= IpEcn::MAX_U8`.
    ///
    /// # Safety
    ///
    /// `value` must be smaller or equal than [`IpEcn::MAX_U8`]
    /// otherwise the behavior of functions or data structures relying
    /// on this pre-requirement is undefined.
    #[inline]
    pub const unsafe fn new_unchecked(value: u8) -> IpEcn {
        debug_assert!(value <= IpEcn::MAX_U8);
        core::mem::transmute::<u8, IpEcn>(value)
    }

    /// Returns the underlying unsigned 2 bit value as an `u8` value.
    #[inline]
    pub const fn value(self) -> u8 {
        self as u8
    }
}

impl core::default::Default for IpEcn {
    fn default() -> Self {
        IpEcn::ZERO
    }
}

impl core::fmt::Display for IpEcn {
    #[inline]
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        self.value().fmt(f)
    }
}

impl From<IpEcn> for u8 {
    #[inline]
    fn from(value: IpEcn) -> Self {
        value as u8
    }
}

impl TryFrom<u8> for IpEcn {
    type Error = ValueTooBigError<u8>;

    #[inline]
    fn try_from(value: u8) -> Result<Self, Self::Error> {
        Self::try_new(value)
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
            let a = IpEcn::TWO;
            let b = a;
            assert_eq!(a, b);
            assert_eq!(a.clone(), a);
        }

        // default
        {
            let actual: IpEcn = Default::default();
            assert_eq!(actual.value(), 0);
        }

        // debug
        {
            let a = IpEcn::Ect0;
            assert_eq!(format!("{:?}", a), format!("Ect0"));
        }

        // ord & partial ord
        {
            use core::cmp::Ordering;
            let a = IpEcn::TWO;
            let b = a;
            assert_eq!(a.cmp(&b), Ordering::Equal);
            assert_eq!(a.partial_cmp(&b), Some(Ordering::Equal));
        }

        // hash
        {
            use std::collections::hash_map::DefaultHasher;
            let a = {
                let mut hasher = DefaultHasher::new();
                IpEcn::TWO.hash(&mut hasher);
                hasher.finish()
            };
            let b = {
                let mut hasher = DefaultHasher::new();
                IpEcn::TWO.hash(&mut hasher);
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
                IpEcn::try_new(valid_value).unwrap().value()
            );
            assert_eq!(
                IpEcn::try_new(invalid_value).unwrap_err(),
                ValueTooBigError{
                    actual: invalid_value,
                    max_allowed: 0b0000_0011,
                    value_type:  ValueType::IpEcn
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
                let actual: IpEcn = valid_value.try_into().unwrap();
                assert_eq!(actual.value(), valid_value);

                let err: Result<IpEcn, ValueTooBigError<u8>> = invalid_value.try_into();
                assert_eq!(
                    err.unwrap_err(),
                    ValueTooBigError{
                        actual: invalid_value,
                        max_allowed: 0b0000_0011,
                        value_type:  ValueType::IpEcn
                    }
                );
            }
            // try_from
            {
                assert_eq!(
                    IpEcn::try_from(valid_value).unwrap().value(),
                    valid_value
                );

                assert_eq!(
                    IpEcn::try_from(invalid_value).unwrap_err(),
                    ValueTooBigError{
                        actual: invalid_value,
                        max_allowed: 0b0000_0011,
                        value_type:  ValueType::IpEcn
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
                    IpEcn::new_unchecked(valid_value).value()
                }
            );
        }
    }

    proptest! {
        #[test]
        fn fmt(valid_value in 0..=0b0000_0011u8) {
            assert_eq!(format!("{}", IpEcn::try_new(valid_value).unwrap()), format!("{}", valid_value));
        }
    }

    proptest! {
        #[test]
        fn from(valid_value in 0..=0b0000_0011u8,) {
            let ecn = IpEcn::try_new(valid_value).unwrap();
            let actual: u8 = ecn.into();
            assert_eq!(actual, valid_value);
        }
    }
}
