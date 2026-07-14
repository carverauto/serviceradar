use super::Tlv;
use crate::error::TlvError;
use crate::Result;

use alloc::vec::Vec;

/// Value definition of BER-TLV data
#[derive(PartialEq, Debug, Clone)]
pub enum Value {
    /// constructed data object, i.e., the value is encoded in BER-TLV
    Constructed(Vec<Tlv>),
    /// primitive data object, i.e., the value is not encoded in BER-TLV
    /// (may be empty)
    Primitive(Vec<u8>),
}

impl Value {
    /// Wether the value is constructed or not
    #[must_use]
    pub fn is_constructed(&self) -> bool {
        matches!(self, Self::Constructed(_))
    }

    /// Get value length once serialized into BER-TLV data
    #[must_use]
    pub fn len_as_bytes(&self) -> usize {
        match &self {
            Self::Primitive(v) => v.len(),
            Self::Constructed(tlv) => tlv.iter().fold(0, |sum, x| sum + x.len()),
        }
    }

    /// Append a BER-TLV data object.
    /// # Errors
    /// Fails with `TlvError::Inconsistant` on primitive or empty values.
    pub fn push(&mut self, tlv: Tlv) -> Result<()> {
        match self {
            Self::Constructed(t) => {
                t.push(tlv);
                Ok(())
            }
            Self::Primitive(_) => Err(TlvError::Inconsistant),
        }
    }
}
