//! ASN.1 tag numbers

use super::Tag;
use core::fmt;

/// ASN.1 tag numbers (i.e. lower 5 bits of a [`Tag`]).
///
/// From X.690 Section 8.1.2.2:
///
/// > bits 5 to 1 shall encode the number of the tag as a binary integer with
/// > bit 5 as the most significant bit.
///
/// This library supports tag numbers ranging from zero to 30 (inclusive) for
/// universal tags and arbitrary 32-bit tag numbers for application, private
/// and context-specific tags.
///
/// Section 8.1.2.4 describes how to support multi-byte tag numbers, which are
/// encoded by using a leading tag number of 31 (`0b11111`).
#[derive(Copy, Clone, Debug, Eq, Hash, PartialEq, PartialOrd, Ord)]
pub struct TagNumber(pub u32);

impl TagNumber {
    /// Mask value used to obtain the tag number from a tag octet.
    pub(super) const MASK: u8 = 0b11111;

    /// Create a new tag number.
    #[deprecated(
        since = "0.8.0",
        note = "use TagNumber(value) directly as inner field is now pub"
    )]
    pub const fn new(value: u32) -> Self {
        Self(value)
    }

    /// Create an `APPLICATION` tag with this tag number.
    pub fn application(self, constructed: bool) -> Tag {
        Tag::Application {
            constructed,
            number: self,
        }
    }

    /// Create a `CONTEXT-SPECIFIC` tag with this tag number.
    pub fn context_specific(self, constructed: bool) -> Tag {
        Tag::ContextSpecific {
            constructed,
            number: self,
        }
    }

    /// Create a `PRIVATE` tag with this tag number.
    pub fn private(self, constructed: bool) -> Tag {
        Tag::Private {
            constructed,
            number: self,
        }
    }

    /// Get the inner value.
    pub fn value(self) -> u32 {
        self.0
    }
}

impl From<u32> for TagNumber {
    fn from(value: u32) -> TagNumber {
        TagNumber(value)
    }
}

impl From<TagNumber> for u32 {
    fn from(number: TagNumber) -> u32 {
        number.0
    }
}

impl fmt::Display for TagNumber {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

// Implement by hand because the derive would create invalid values.
// Use the constructor to create a valid value.
#[cfg(feature = "arbitrary")]
impl<'a> arbitrary::Arbitrary<'a> for TagNumber {
    fn arbitrary(u: &mut arbitrary::Unstructured<'a>) -> arbitrary::Result<Self> {
        Ok(Self(u.int_in_range(0..=30)?))
    }

    fn size_hint(depth: usize) -> (usize, Option<usize>) {
        u8::size_hint(depth)
    }
}
