//! `RSASSA-PSS` signatures.

use alloc::boxed::Box;
use core::fmt::{Debug, Display, Formatter, LowerHex, UpperHex};
use crypto_bigint::BoxedUint;
use signature::SignatureEncoding;

#[cfg(feature = "serde")]
use serdect::serde::{de, Deserialize, Serialize};
#[cfg(feature = "encoding")]
use spki::{
    der::{asn1::BitString, Result as DerResult},
    SignatureBitStringEncoding,
};

/// `RSASSA-PSS` signatures as described in [RFC8017 § 8.1].
///
/// [RFC8017 § 8.1]: https://datatracker.ietf.org/doc/html/rfc8017#section-8.1
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Signature {
    pub(super) inner: BoxedUint,
}

impl SignatureEncoding for Signature {
    type Repr = Box<[u8]>;
}

#[cfg(feature = "encoding")]
impl SignatureBitStringEncoding for Signature {
    fn to_bitstring(&self) -> DerResult<BitString> {
        BitString::new(0, self.to_vec())
    }
}

impl TryFrom<&[u8]> for Signature {
    type Error = signature::Error;

    fn try_from(bytes: &[u8]) -> signature::Result<Self> {
        // TODO(tarcieri): max length restriction? (#350)
        let inner = BoxedUint::from_be_slice_vartime(bytes);
        Ok(Self { inner })
    }
}

impl From<Signature> for Box<[u8]> {
    fn from(signature: Signature) -> Box<[u8]> {
        signature.inner.to_be_bytes()
    }
}

impl LowerHex for Signature {
    fn fmt(&self, f: &mut Formatter<'_>) -> core::fmt::Result {
        write!(f, "{:x}", &self.inner)
    }
}

impl UpperHex for Signature {
    fn fmt(&self, f: &mut Formatter<'_>) -> core::fmt::Result {
        write!(f, "{:X}", &self.inner)
    }
}

impl Display for Signature {
    fn fmt(&self, f: &mut Formatter<'_>) -> core::fmt::Result {
        write!(f, "{:X}", self)
    }
}

#[cfg(feature = "serde")]
impl Serialize for Signature {
    fn serialize<S>(&self, serializer: S) -> core::result::Result<S::Ok, S::Error>
    where
        S: serdect::serde::Serializer,
    {
        serdect::slice::serialize_hex_lower_or_bin(&self.to_bytes(), serializer)
    }
}

#[cfg(feature = "serde")]
impl<'de> Deserialize<'de> for Signature {
    fn deserialize<D>(deserializer: D) -> core::result::Result<Self, D::Error>
    where
        D: serdect::serde::Deserializer<'de>,
    {
        serdect::slice::deserialize_hex_or_bin_vec(deserializer)?
            .as_slice()
            .try_into()
            .map_err(de::Error::custom)
    }
}

#[cfg(test)]
mod tests {
    #[test]
    #[cfg(feature = "serde")]
    fn test_serde() {
        use super::*;
        use serde_test::{assert_tokens, Configure, Token};
        let signature = Signature {
            inner: BoxedUint::from(42u32),
        };

        let tokens = [Token::Str("000000000000002a")];
        assert_tokens(&signature.readable(), &tokens);
    }
}
