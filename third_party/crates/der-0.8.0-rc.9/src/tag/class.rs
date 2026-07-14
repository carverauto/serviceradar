//! Class of an ASN.1 tag.

use core::fmt;

/// `UNIVERSAL`: built-in types whose meaning is the same in all
/// applications.
pub const CLASS_UNIVERSAL: u8 = 0b00000000;
/// `APPLICATION`: types whose meaning is specific to an application.
pub const CLASS_APPLICATION: u8 = 0b01000000;
/// `CONTEXT-SPECIFIC`: types whose meaning is specific to a given
/// structured type.
pub const CLASS_CONTEXT_SPECIFIC: u8 = 0b10000000;
/// `PRIVATE`: types whose meaning is specific to a given enterprise.
pub const CLASS_PRIVATE: u8 = 0b11000000;

/// Class of an ASN.1 tag.
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
#[repr(u8)]
pub enum Class {
    /// `UNIVERSAL`: built-in types whose meaning is the same in all
    /// applications.
    Universal = CLASS_UNIVERSAL,

    /// `APPLICATION`: types whose meaning is specific to an application,
    ///
    /// Types in two different applications may have the same
    /// application-specific tag and different meanings.
    Application = CLASS_APPLICATION,

    /// `CONTEXT-SPECIFIC`: types whose meaning is specific to a given
    /// structured type.
    ///
    /// Context-specific tags are used to distinguish between component types
    /// with the same underlying tag within the context of a given structured
    /// type, and component types in two different structured types may have
    /// the same tag and different meanings.
    ContextSpecific = CLASS_CONTEXT_SPECIFIC,

    /// `PRIVATE`: types whose meaning is specific to a given enterprise.
    Private = CLASS_PRIVATE,
}

impl fmt::Display for Class {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Class::Universal => "UNIVERSAL",
            Class::Application => "APPLICATION",
            Class::ContextSpecific => "CONTEXT-SPECIFIC",
            Class::Private => "PRIVATE",
        })
    }
}

impl Class {
    /// Returns class as 2 most-significant bits (mask 0b11000000)
    pub const fn bits(&self) -> u8 {
        *self as u8
    }

    /// Returns class extracted from 2 most-significant bits (mask 0b11000000)
    pub const fn from_bits(bits: u8) -> Self {
        match (bits >> 6) & 0b11 {
            0b00 => Class::Universal,
            0b01 => Class::Application,
            0b10 => Class::ContextSpecific,
            0b11 => Class::Private,
            _ => unreachable!(),
        }
    }
}
impl From<u8> for Class {
    fn from(value: u8) -> Self {
        Class::from_bits(value)
    }
}
