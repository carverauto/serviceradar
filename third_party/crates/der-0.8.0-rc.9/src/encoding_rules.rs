use crate::{Error, ErrorKind};
use core::{fmt, str::FromStr};

/// ASN.1 encoding rules.
///
/// This enum identifies the specific encoding rules which are applied at the time a given document
/// is decoded from a byte/octet serialization.
///
/// In addition to the Distinguished Encoding Rules (DER), this crate also supports a strict subset
/// of the Basic Encoding Rules (BER) which supports the minimum amount of additional productions
/// beyond DER needed to interoperate with other implementations of cryptography-oriented formats
/// which utilize BER, e.g. CMS, PKCS#8.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, PartialOrd, Ord)]
pub enum EncodingRules {
    /// Basic Encoding Rules.
    #[cfg(feature = "ber")]
    Ber,

    /// Distinguished Encoding Rules.
    #[default]
    Der,
}

impl EncodingRules {
    /// Are we using Basic Encoding Rules?
    #[cfg(feature = "ber")]
    pub const fn is_ber(self) -> bool {
        matches!(self, EncodingRules::Ber)
    }

    /// Are we using Distinguished Encoding Rules?
    pub const fn is_der(self) -> bool {
        matches!(self, EncodingRules::Der)
    }
}

impl FromStr for EncodingRules {
    type Err = Error;

    fn from_str(s: &str) -> Result<Self, Error> {
        match s {
            #[cfg(feature = "ber")]
            "ber" | "BER" => Ok(EncodingRules::Ber),
            "der" | "DER" => Ok(EncodingRules::Der),
            _ => Err(ErrorKind::EncodingRules.into()),
        }
    }
}

impl fmt::Display for EncodingRules {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            #[cfg(feature = "ber")]
            Self::Ber => "BER",
            Self::Der => "DER",
        })
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::EncodingRules;

    #[cfg(feature = "alloc")]
    #[test]
    fn display() {
        use alloc::string::ToString;
        #[cfg(feature = "ber")]
        assert_eq!(EncodingRules::Ber.to_string(), "BER");
        assert_eq!(EncodingRules::Der.to_string(), "DER");
    }

    #[test]
    fn parse() {
        #[cfg(feature = "ber")]
        assert_eq!(EncodingRules::Ber, "ber".parse().unwrap());
        #[cfg(feature = "ber")]
        assert_eq!(EncodingRules::Ber, "BER".parse().unwrap());
        assert_eq!(EncodingRules::Der, "der".parse().unwrap());
        assert_eq!(EncodingRules::Der, "DER".parse().unwrap());

        assert!("CER".parse::<EncodingRules>().is_err());
    }
}
