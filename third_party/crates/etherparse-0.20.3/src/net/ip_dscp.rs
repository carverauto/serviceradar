use crate::err::ValueTooBigError;

/// Deprecated, use [`IpDscp`] instead.
#[deprecated(since = "0.18.0", note = "Use `IpDscp` instead of `Ipv4Dscp`")]
pub type Ipv4Dscp = IpDscp;

/// 6 bit unsigned integer containing the "Differentiated Services
/// Code Point" (present in the [`crate::Ipv4Header`] and in the
/// in [`crate::Ipv6Header`] as part of `traffic_class`).
///
/// Established in
/// [RFC-2472](https://datatracker.ietf.org/doc/html/rfc2474) and defined/maintained in the
/// [IANA dscp-registry](https://www.iana.org/assignments/dscp-registry/dscp-registry.xhtml)
#[derive(Copy, Clone, Default, Debug, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub struct IpDscp(u8);

impl IpDscp {
    /// IpDscp with value 0.
    pub const ZERO: IpDscp = IpDscp(0);

    /// Maximum value of an IPv4 header DSCP.
    pub const MAX_U8: u8 = 0b0011_1111;

    /// Maximum value of DSCP field (6 bits).
    pub const MAX: IpDscp = IpDscp(Self::MAX_U8);

    /// Class Selector 0 (Pool 1) [RFC-2474](https://datatracker.ietf.org/doc/html/rfc2474)
    pub const CS0: IpDscp = IpDscp(0b00_0000);

    /// Class Selector 1 (Pool 1) [RFC-2474](https://datatracker.ietf.org/doc/html/rfc2474)
    pub const CS1: IpDscp = IpDscp(0b00_1000);

    /// Class Selector 2 (Pool 1) [RFC-2474](https://datatracker.ietf.org/doc/html/rfc2474)
    pub const CS2: IpDscp = IpDscp(0b01_0000);

    /// Class Selector 3 (Pool 1) [RFC-2474](https://datatracker.ietf.org/doc/html/rfc2474)
    pub const CS3: IpDscp = IpDscp(0b01_1000);

    /// Class Selector 4 (Pool 1) [RFC-2474](https://datatracker.ietf.org/doc/html/rfc2474)
    pub const CS4: IpDscp = IpDscp(0b10_0000);

    /// Class Selector 5 (Pool 1) [RFC-2474](https://datatracker.ietf.org/doc/html/rfc2474)
    pub const CS5: IpDscp = IpDscp(0b10_1000);

    /// Class Selector 6 (Pool 1) [RFC-2474](https://datatracker.ietf.org/doc/html/rfc2474)
    pub const CS6: IpDscp = IpDscp(0b11_0000);

    /// Class Selector 7 (Pool 1) [RFC-2474](https://datatracker.ietf.org/doc/html/rfc2474)
    pub const CS7: IpDscp = IpDscp(0b11_1000);

    /// Assured Forwarding PHB Group 11 (Pool 1) [RFC-2597](https://datatracker.ietf.org/doc/html/rfc2597)
    pub const AF11: IpDscp = IpDscp(0b00_1010);

    /// Assured Forwarding PHB Group 12 (Pool 1) [RFC-2597](https://datatracker.ietf.org/doc/html/rfc2597)
    pub const AF12: IpDscp = IpDscp(0b00_1100);

    /// Assured Forwarding PHB Group 13 (Pool 1) [RFC-2597](https://datatracker.ietf.org/doc/html/rfc2597)
    pub const AF13: IpDscp = IpDscp(0b00_1110);

    /// Assured Forwarding PHB Group 21 (Pool 1) [RFC-2597](https://datatracker.ietf.org/doc/html/rfc2597)
    pub const AF21: IpDscp = IpDscp(0b01_0010);

    /// Assured Forwarding PHB Group 22 (Pool 1) [RFC-2597](https://datatracker.ietf.org/doc/html/rfc2597)
    pub const AF22: IpDscp = IpDscp(0b01_0100);

    /// Assured Forwarding PHB Group 23 (Pool 1) [RFC-2597](https://datatracker.ietf.org/doc/html/rfc2597)
    pub const AF23: IpDscp = IpDscp(0b01_0110);

    /// Assured Forwarding PHB Group 31 (Pool 1) [RFC-2597](https://datatracker.ietf.org/doc/html/rfc2597)
    pub const AF31: IpDscp = IpDscp(0b01_1010);

    /// Assured Forwarding PHB Group 32 (Pool 1) [RFC-2597](https://datatracker.ietf.org/doc/html/rfc2597)
    pub const AF32: IpDscp = IpDscp(0b01_1100);

    /// Assured Forwarding PHB Group 11 (Pool 1) [RFC-2597](https://datatracker.ietf.org/doc/html/rfc2597)
    pub const AF33: IpDscp = IpDscp(0b01_1110);

    /// Assured Forwarding PHB Group 11 (Pool 1) [RFC-2597](https://datatracker.ietf.org/doc/html/rfc2597)
    pub const AF41: IpDscp = IpDscp(0b10_0010);

    /// Assured Forwarding PHB Group 11 (Pool 1) [RFC-2597](https://datatracker.ietf.org/doc/html/rfc2597)
    pub const AF42: IpDscp = IpDscp(0b10_0100);

    /// Assured Forwarding PHB Group 11 (Pool 1) [RFC-2597](https://datatracker.ietf.org/doc/html/rfc2597)
    pub const AF43: IpDscp = IpDscp(0b10_0110);

    /// Expedited Forwarding (Pool 1) [RFC-3246](https://datatracker.ietf.org/doc/html/rfc3246)
    pub const EF: IpDscp = IpDscp(0b10_1110);

    /// Voice admit (Pool 1) [RFC-5865](https://datatracker.ietf.org/doc/html/rfc5865)
    pub const VOICE_ADMIT: IpDscp = IpDscp(0b10_1100);

    /// Lower Effort PHB (Pool 3) [RFC-8622](https://datatracker.ietf.org/doc/html/rfc8622)
    pub const LOWER_EFFORT: IpDscp = IpDscp(0b00_0001);

    /// Tries to create an [`IpDscp`] and checks that the passed value
    /// is smaller or equal than [`IpDscp::MAX_U8`] (6 bit unsigned integer).
    ///
    /// In case the passed value is bigger then what can be represented in an 6 bit
    /// integer an error is returned. Otherwise an `Ok` containing the [`IpDscp`].
    ///
    /// ```
    /// use etherparse::IpDscp;
    ///
    /// let dscp = IpDscp::try_new(32).unwrap();
    /// assert_eq!(dscp.value(), 32);
    ///
    /// // if a number that can not be represented in an 6 bit integer
    /// // gets passed in an error is returned
    /// use etherparse::err::{ValueTooBigError, ValueType};
    /// assert_eq!(
    ///     IpDscp::try_new(IpDscp::MAX_U8 + 1),
    ///     Err(ValueTooBigError{
    ///         actual: IpDscp::MAX_U8 + 1,
    ///         max_allowed: IpDscp::MAX_U8,
    ///         value_type: ValueType::IpDscp,
    ///     })
    /// );
    /// ```
    #[inline]
    pub const fn try_new(value: u8) -> Result<IpDscp, ValueTooBigError<u8>> {
        use crate::err::ValueType;
        if value <= IpDscp::MAX_U8 {
            Ok(IpDscp(value))
        } else {
            Err(ValueTooBigError {
                actual: value,
                max_allowed: IpDscp::MAX_U8,
                value_type: ValueType::IpDscp,
            })
        }
    }

    /// Creates an [`IpDscp`] without checking that the value
    /// is smaller or equal than [`IpDscp::MAX_U8`] (6 bit unsigned integer).
    /// The caller must guarantee that `value <= IpDscp::MAX_U8`.
    ///
    /// # Safety
    ///
    /// `value` must be smaller or equal than [`IpDscp::MAX_U8`]
    /// otherwise the behavior of functions or data structures relying
    /// on this pre-requirement is undefined.
    #[inline]
    pub const unsafe fn new_unchecked(value: u8) -> IpDscp {
        debug_assert!(value <= IpDscp::MAX_U8);
        IpDscp(value)
    }

    /// Returns the underlying unsigned 6 bit value as an `u8` value.
    #[inline]
    pub const fn value(self) -> u8 {
        self.0
    }
}

impl core::fmt::Display for IpDscp {
    #[inline]
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        self.0.fmt(f)
    }
}

impl From<IpDscp> for u8 {
    #[inline]
    fn from(value: IpDscp) -> Self {
        value.0
    }
}

impl TryFrom<u8> for IpDscp {
    type Error = ValueTooBigError<u8>;

    #[inline]
    fn try_from(value: u8) -> Result<Self, Self::Error> {
        use crate::err::ValueType;
        if value <= IpDscp::MAX_U8 {
            Ok(IpDscp(value))
        } else {
            Err(Self::Error {
                actual: value,
                max_allowed: IpDscp::MAX_U8,
                value_type: ValueType::IpDscp,
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
            let a = IpDscp(32);
            let b = a;
            assert_eq!(a, b);
            assert_eq!(a.clone(), a);
        }

        // default
        {
            let actual: IpDscp = Default::default();
            assert_eq!(actual.value(), 0);
        }

        // debug
        {
            let a = IpDscp(32);
            assert_eq!(format!("{:?}", a), format!("IpDscp(32)"));
        }

        // ord & partial ord
        {
            use core::cmp::Ordering;
            let a = IpDscp(32);
            let b = a;
            assert_eq!(a.cmp(&b), Ordering::Equal);
            assert_eq!(a.partial_cmp(&b), Some(Ordering::Equal));
        }

        // hash
        {
            use std::collections::hash_map::DefaultHasher;
            let a = {
                let mut hasher = DefaultHasher::new();
                IpDscp(64).hash(&mut hasher);
                hasher.finish()
            };
            let b = {
                let mut hasher = DefaultHasher::new();
                IpDscp(64).hash(&mut hasher);
                hasher.finish()
            };
            assert_eq!(a, b);
        }
    }

    proptest! {
        #[test]
        fn try_new(
            valid_value in 0..=0b0011_1111u8,
            invalid_value in 0b0100_0000u8..=u8::MAX
        ) {
            use crate::err::{ValueType, ValueTooBigError};
            assert_eq!(
                valid_value,
                IpDscp::try_new(valid_value).unwrap().value()
            );
            assert_eq!(
                IpDscp::try_new(invalid_value).unwrap_err(),
                ValueTooBigError{
                    actual: invalid_value,
                    max_allowed: 0b0011_1111,
                    value_type:  ValueType::IpDscp
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
                let actual: IpDscp = valid_value.try_into().unwrap();
                assert_eq!(actual.value(), valid_value);

                let err: Result<IpDscp, ValueTooBigError<u8>> = invalid_value.try_into();
                assert_eq!(
                    err.unwrap_err(),
                    ValueTooBigError{
                        actual: invalid_value,
                        max_allowed: 0b0011_1111,
                        value_type:  ValueType::IpDscp
                    }
                );
            }
            // try_from
            {
                assert_eq!(
                    IpDscp::try_from(valid_value).unwrap().value(),
                    valid_value
                );

                assert_eq!(
                    IpDscp::try_from(invalid_value).unwrap_err(),
                    ValueTooBigError{
                        actual: invalid_value,
                        max_allowed: 0b0011_1111,
                        value_type:  ValueType::IpDscp
                    }
                );
            }
        }
    }

    proptest! {
        #[test]
        fn new_unchecked(valid_value in 0..=0b0011_1111u8) {
            assert_eq!(
                valid_value,
                unsafe {
                    IpDscp::new_unchecked(valid_value).value()
                }
            );
        }
    }

    proptest! {
        #[test]
        fn fmt(valid_value in 0..=0b0011_1111u8) {
            assert_eq!(format!("{}", IpDscp(valid_value)), format!("{}", valid_value));
        }
    }

    proptest! {
        #[test]
        fn from(valid_value in 0..=0b0011_1111u8,) {
            let dscp = IpDscp::try_new(valid_value).unwrap();
            let actual: u8 = dscp.into();
            assert_eq!(actual, valid_value);
        }
    }
}
