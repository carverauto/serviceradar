//! MPLS Label Exp field decoding (IPFIX fields 203 and 237).
//!
//! The 3-bit Experimental/Traffic Class field from the MPLS header.
//! Used for both `mplsTopLabelExp` (203) and `postMplsTopLabelExp` (237).

use nom::IResult;
use nom_derive::Parse;
use serde::Serialize;

/// Decoded MPLS Experimental/Traffic Class value (3 bits, range 0-7).
///
/// Shared type for IPFIX fields 203 (`mplsTopLabelExp`) and
/// 237 (`postMplsTopLabelExp`).
#[derive(Debug, PartialEq, Eq, Clone, Copy, Serialize, PartialOrd, Ord)]
pub struct MplsLabelExp(pub u8);

impl MplsLabelExp {
    /// Parse an `MplsLabelExp` from a byte slice by reading a single `u8`.
    pub fn parse(input: &[u8]) -> IResult<&[u8], Self> {
        let (remaining, value) = u8::parse(input)?;
        Ok((remaining, Self::from(value)))
    }

    /// Returns the 3-bit experimental value (0-7).
    pub fn value(&self) -> u8 {
        self.0
    }
}

impl std::fmt::Display for MplsLabelExp {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl From<u8> for MplsLabelExp {
    fn from(value: u8) -> Self {
        Self(value & 0x07)
    }
}

impl From<MplsLabelExp> for u8 {
    fn from(exp: MplsLabelExp) -> Self {
        exp.0
    }
}

#[cfg(test)]
mod mpls_label_exp_tests {
    use super::MplsLabelExp;

    #[test]
    fn test_display() {
        assert_eq!(MplsLabelExp::from(0).to_string(), "0");
        assert_eq!(MplsLabelExp::from(7).to_string(), "7");
    }

    #[test]
    fn test_round_trip() {
        for value in 0..=7u8 {
            let exp = MplsLabelExp::from(value);
            assert_eq!(u8::from(exp), value);
        }
    }

    #[test]
    fn test_masks_to_3_bits() {
        assert_eq!(MplsLabelExp::from(0xFF).value(), 7);
        assert_eq!(MplsLabelExp::from(0x08).value(), 0);
    }
}
