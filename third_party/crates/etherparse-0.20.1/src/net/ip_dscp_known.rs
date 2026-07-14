use crate::err::ip::IpDscpUnknownValueError;

use super::IpDscp;

/// Known "Differentiated Services Field Codepoints" (DSCP) values according to
/// the [IANA registry](https://www.iana.org/assignments/dscp-registry/dscp-registry.xhtml)
/// (exported on 2025-04-24).
///
/// DSCP was established in
/// [RFC-2472](https://datatracker.ietf.org/doc/html/rfc2474) and defined/maintained in the
/// [IANA dscp-registry](https://www.iana.org/assignments/dscp-registry/dscp-registry.xhtml)
#[derive(Copy, Debug, Clone, Eq, PartialEq, PartialOrd, Ord, Hash)]
pub enum IpDscpKnown {
    /// Class Selector 0 (Pool 1) [RFC-2474](https://datatracker.ietf.org/doc/html/rfc2474)
    ClassSelector0 = 0b0000_0000,

    /// Class Selector 1 (Pool 1) [RFC-2474](https://datatracker.ietf.org/doc/html/rfc2474)
    ClassSelector1 = 0b0000_1000,

    /// Class Selector 2 (Pool 1) [RFC-2474](https://datatracker.ietf.org/doc/html/rfc2474)
    ClassSelector2 = 0b0001_0000,

    /// Class Selector 3 (Pool 1) [RFC-2474](https://datatracker.ietf.org/doc/html/rfc2474)
    ClassSelector3 = 0b0001_1000,

    /// Class Selector 4 (Pool 1) [RFC-2474](https://datatracker.ietf.org/doc/html/rfc2474)
    ClassSelector4 = 0b0010_0000,

    /// Class Selector 5 (Pool 1) [RFC-2474](https://datatracker.ietf.org/doc/html/rfc2474)
    ClassSelector5 = 0b0010_1000,

    /// Class Selector 6 (Pool 1) [RFC-2474](https://datatracker.ietf.org/doc/html/rfc2474)
    ClassSelector6 = 0b0011_0000,

    /// Class Selector 7 (Pool 1) [RFC-2474](https://datatracker.ietf.org/doc/html/rfc2474)
    ClassSelector7 = 0b0011_1000,

    /// Assured Forwarding PHB Group 11 (Pool 1) [RFC-2597](https://datatracker.ietf.org/doc/html/rfc2597)
    AfGroup11 = 0b0000_1010,

    /// Assured Forwarding PHB Group 12 (Pool 1) [RFC-2597](https://datatracker.ietf.org/doc/html/rfc2597)
    AfGroup12 = 0b0000_1100,

    /// Assured Forwarding PHB Group 13 (Pool 1) [RFC-2597](https://datatracker.ietf.org/doc/html/rfc2597)
    AfGroup13 = 0b0000_1110,

    /// Assured Forwarding PHB Group 21 (Pool 1) [RFC-2597](https://datatracker.ietf.org/doc/html/rfc2597)
    AfGroup21 = 0b0001_0010,

    /// Assured Forwarding PHB Group 22 (Pool 1) [RFC-2597](https://datatracker.ietf.org/doc/html/rfc2597)
    AfGroup22 = 0b0001_0100,

    /// Assured Forwarding PHB Group 23 (Pool 1) [RFC-2597](https://datatracker.ietf.org/doc/html/rfc2597)
    AfGroup23 = 0b0001_0110,

    /// Assured Forwarding PHB Group 31 (Pool 1) [RFC-2597](https://datatracker.ietf.org/doc/html/rfc2597)
    AfGroup31 = 0b0001_1010,

    /// Assured Forwarding PHB Group 32 (Pool 1) [RFC-2597](https://datatracker.ietf.org/doc/html/rfc2597)
    AfGroup32 = 0b0001_1100,

    /// Assured Forwarding PHB Group 33 (Pool 1) [RFC-2597](https://datatracker.ietf.org/doc/html/rfc2597)
    AfGroup33 = 0b0001_1110,

    /// Assured Forwarding PHB Group 41 (Pool 1) [RFC-2597](https://datatracker.ietf.org/doc/html/rfc2597)
    AfGroup41 = 0b0010_0010,

    /// Assured Forwarding PHB Group 42 (Pool 1) [RFC-2597](https://datatracker.ietf.org/doc/html/rfc2597)
    AfGroup42 = 0b0010_0100,

    /// Assured Forwarding PHB Group 43 (Pool 1) [RFC-2597](https://datatracker.ietf.org/doc/html/rfc2597)
    AfGroup43 = 0b0010_0110,

    /// Expedited Forwarding (Pool 1) [RFC-3246](https://datatracker.ietf.org/doc/html/rfc3246)
    ExpeditedForwarding = 0b_0010_1110,

    /// Voice admit (Pool 1) [RFC-5865](https://datatracker.ietf.org/doc/html/rfc5865)
    VoiceAdmit = 0b0010_1100,

    /// Lower Effort PHB (Pool 3) [RFC-8622](https://datatracker.ietf.org/doc/html/rfc8622)
    LowerEffort = 0b0000_0001,
    // NOTE: NQB was omitted here because it has an expiration in the IANA registry.
}

impl IpDscpKnown {
    /// Try converting an [`IpDscp`] into a [`IpDscpKnown`] value.
    ///
    /// Returns an error if the value is not a known DSCP value.
    pub const fn try_from_ip_dscp(value: IpDscp) -> Result<IpDscpKnown, IpDscpUnknownValueError> {
        match value {
            IpDscp::CS0 => Ok(IpDscpKnown::ClassSelector0),
            IpDscp::CS1 => Ok(IpDscpKnown::ClassSelector1),
            IpDscp::CS2 => Ok(IpDscpKnown::ClassSelector2),
            IpDscp::CS3 => Ok(IpDscpKnown::ClassSelector3),
            IpDscp::CS4 => Ok(IpDscpKnown::ClassSelector4),
            IpDscp::CS5 => Ok(IpDscpKnown::ClassSelector5),
            IpDscp::CS6 => Ok(IpDscpKnown::ClassSelector6),
            IpDscp::CS7 => Ok(IpDscpKnown::ClassSelector7),
            IpDscp::AF11 => Ok(IpDscpKnown::AfGroup11),
            IpDscp::AF12 => Ok(IpDscpKnown::AfGroup12),
            IpDscp::AF13 => Ok(IpDscpKnown::AfGroup13),
            IpDscp::AF21 => Ok(IpDscpKnown::AfGroup21),
            IpDscp::AF22 => Ok(IpDscpKnown::AfGroup22),
            IpDscp::AF23 => Ok(IpDscpKnown::AfGroup23),
            IpDscp::AF31 => Ok(IpDscpKnown::AfGroup31),
            IpDscp::AF32 => Ok(IpDscpKnown::AfGroup32),
            IpDscp::AF33 => Ok(IpDscpKnown::AfGroup33),
            IpDscp::AF41 => Ok(IpDscpKnown::AfGroup41),
            IpDscp::AF42 => Ok(IpDscpKnown::AfGroup42),
            IpDscp::AF43 => Ok(IpDscpKnown::AfGroup43),
            IpDscp::EF => Ok(IpDscpKnown::ExpeditedForwarding),
            IpDscp::VOICE_ADMIT => Ok(IpDscpKnown::VoiceAdmit),
            IpDscp::LOWER_EFFORT => Ok(IpDscpKnown::LowerEffort),
            value => Err(IpDscpUnknownValueError {
                value: value.value(),
            }),
        }
    }
}

impl TryFrom<IpDscp> for IpDscpKnown {
    type Error = crate::err::ip::IpDscpUnknownValueError;

    fn try_from(value: IpDscp) -> Result<Self, Self::Error> {
        Self::try_from_ip_dscp(value)
    }
}

impl From<IpDscpKnown> for u8 {
    fn from(value: IpDscpKnown) -> Self {
        value as u8
    }
}

impl From<IpDscpKnown> for IpDscp {
    fn from(value: IpDscpKnown) -> Self {
        // SAFE: As all IpDscpKnown values are bellow the maximum
        //       value of IpDscp::MAX_U8.
        unsafe { IpDscp::new_unchecked(value as u8) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{err::ip::IpDscpUnknownValueError, IpDscp};

    #[test]
    fn try_from_ip_dscp() {
        // ok value conversions
        {
            use IpDscpKnown::*;
            let tests = [
                (ClassSelector0, 0b0000_0000u8),
                (ClassSelector1, 0b0000_1000u8),
                (ClassSelector2, 0b0001_0000u8),
                (ClassSelector3, 0b0001_1000u8),
                (ClassSelector4, 0b0010_0000u8),
                (ClassSelector5, 0b0010_1000u8),
                (ClassSelector6, 0b0011_0000u8),
                (ClassSelector7, 0b0011_1000u8),
                (AfGroup11, 0b0000_1010u8),
                (AfGroup12, 0b0000_1100u8),
                (AfGroup13, 0b0000_1110u8),
                (AfGroup21, 0b0001_0010u8),
                (AfGroup22, 0b0001_0100u8),
                (AfGroup23, 0b0001_0110u8),
                (AfGroup31, 0b0001_1010u8),
                (AfGroup32, 0b0001_1100u8),
                (AfGroup33, 0b0001_1110u8),
                (AfGroup41, 0b0010_0010u8),
                (AfGroup42, 0b0010_0100u8),
                (AfGroup43, 0b0010_0110u8),
                (ExpeditedForwarding, 0b_0010_1110u8),
                (VoiceAdmit, 0b0010_1100u8),
                (LowerEffort, 0b0000_0001u8),
            ];
            for (expected, value) in tests {
                let ip_dscp = IpDscp::try_new(value).unwrap();
                assert_eq!(Ok(expected), IpDscpKnown::try_from_ip_dscp(ip_dscp));
                assert_eq!(Ok(expected), IpDscpKnown::try_from(ip_dscp));
            }
        }

        // unknown conversions (experimental range)
        {
            // defined based on IANA registry
            let unknown_ranges = [
                2..=7u8,
                9..=9u8,
                11..=11u8,
                13..=13u8,
                15..=15u8,
                17..=17u8,
                19..=19u8,
                21..=21u8,
                23..=23u8,
                25..=25u8,
                27..=27u8,
                29..=29u8,
                31..=31u8,
                33..=33u8,
                35..=35u8,
                37..=37u8,
                39..=39u8,
                41..=43u8,
                45..=45u8,
                47..=47u8,
                49..=55u8,
                57..=0b0011_1111u8,
            ];
            for range in unknown_ranges {
                for value in range {
                    let ip_dscp = IpDscp::try_new(value).unwrap();
                    assert_eq!(
                        Err(IpDscpUnknownValueError { value }),
                        IpDscpKnown::try_from_ip_dscp(ip_dscp)
                    );
                    assert_eq!(
                        Err(IpDscpUnknownValueError { value }),
                        IpDscpKnown::try_from(ip_dscp)
                    );
                }
            }
        }
    }

    #[test]
    fn into_u8_and_ip_dscp() {
        use IpDscpKnown::*;
        let tests = [
            (ClassSelector0, 0b0000_0000u8),
            (ClassSelector1, 0b0000_1000u8),
            (ClassSelector2, 0b0001_0000u8),
            (ClassSelector3, 0b0001_1000u8),
            (ClassSelector4, 0b0010_0000u8),
            (ClassSelector5, 0b0010_1000u8),
            (ClassSelector6, 0b0011_0000u8),
            (ClassSelector7, 0b0011_1000u8),
            (AfGroup11, 0b0000_1010u8),
            (AfGroup12, 0b0000_1100u8),
            (AfGroup13, 0b0000_1110u8),
            (AfGroup21, 0b0001_0010u8),
            (AfGroup22, 0b0001_0100u8),
            (AfGroup23, 0b0001_0110u8),
            (AfGroup31, 0b0001_1010u8),
            (AfGroup32, 0b0001_1100u8),
            (AfGroup33, 0b0001_1110u8),
            (AfGroup41, 0b0010_0010u8),
            (AfGroup42, 0b0010_0100u8),
            (AfGroup43, 0b0010_0110u8),
            (ExpeditedForwarding, 0b_0010_1110u8),
            (VoiceAdmit, 0b0010_1100u8),
            (LowerEffort, 0b0000_0001u8),
        ];
        for (input, expected) in tests {
            assert_eq!(expected, u8::from(input));
            assert_eq!(IpDscp::try_new(expected).unwrap(), IpDscp::from(input));
        }
    }
}
