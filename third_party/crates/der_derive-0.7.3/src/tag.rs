//! Tag-related functionality.

use crate::Asn1Type;
use proc_macro2::TokenStream;
use quote::quote;
use std::{
    fmt::{self, Display},
    str::FromStr,
};

/// Tag "IR" type.
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
pub(crate) enum Tag {
    /// Universal tags with an associated [`Asn1Type`].
    Universal(Asn1Type),

    /// Context-specific tags with an associated [`TagNumber`].
    ContextSpecific {
        /// Is the inner ASN.1 type constructed?
        constructed: bool,

        /// Context-specific tag number
        number: TagNumber,
    },
}

impl Tag {
    /// Lower this [`Tag`] to a [`TokenStream`].
    pub fn to_tokens(self) -> TokenStream {
        match self {
            Tag::Universal(ty) => ty.tag(),
            Tag::ContextSpecific {
                constructed,
                number,
            } => {
                let constructed = if constructed {
                    quote!(true)
                } else {
                    quote!(false)
                };

                let number = number.to_tokens();

                quote! {
                    ::der::Tag::ContextSpecific {
                        constructed: #constructed,
                        number: #number,
                    }
                }
            }
        }
    }
}

/// Tagging modes: `EXPLICIT` versus `IMPLICIT`.
#[derive(Copy, Clone, Debug, Default, Eq, PartialEq, PartialOrd, Ord)]
pub(crate) enum TagMode {
    /// `EXPLICIT` tagging.
    ///
    /// Tag is added in addition to the inner tag of the type.
    #[default]
    Explicit,

    /// `IMPLICIT` tagging.
    ///
    /// Tag replaces the existing tag of the inner type.
    Implicit,
}

impl TagMode {
    /// Lower this [`TagMode`] to a [`TokenStream`] with the `der`
    /// crate's corresponding enum variant for this tag mode.
    pub fn to_tokens(self) -> TokenStream {
        match self {
            TagMode::Explicit => quote!(::der::TagMode::Explicit),
            TagMode::Implicit => quote!(::der::TagMode::Implicit),
        }
    }
}

impl FromStr for TagMode {
    type Err = ParseError;

    fn from_str(s: &str) -> Result<Self, ParseError> {
        match s {
            "EXPLICIT" | "explicit" => Ok(TagMode::Explicit),
            "IMPLICIT" | "implicit" => Ok(TagMode::Implicit),
            _ => Err(ParseError),
        }
    }
}

impl Display for TagMode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            TagMode::Explicit => f.write_str("EXPLICIT"),
            TagMode::Implicit => f.write_str("IMPLICIT"),
        }
    }
}

/// ASN.1 tag numbers (i.e. lower 5 bits of a [`Tag`]).
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
pub(crate) struct TagNumber(pub u8);

impl TagNumber {
    /// Maximum tag number supported (inclusive).
    pub const MAX: u8 = 30;

    /// Get tokens describing this tag.
    pub fn to_tokens(self) -> TokenStream {
        match self.0 {
            0 => quote!(::der::TagNumber::N0),
            1 => quote!(::der::TagNumber::N1),
            2 => quote!(::der::TagNumber::N2),
            3 => quote!(::der::TagNumber::N3),
            4 => quote!(::der::TagNumber::N4),
            5 => quote!(::der::TagNumber::N5),
            6 => quote!(::der::TagNumber::N6),
            7 => quote!(::der::TagNumber::N7),
            8 => quote!(::der::TagNumber::N8),
            9 => quote!(::der::TagNumber::N9),
            10 => quote!(::der::TagNumber::N10),
            11 => quote!(::der::TagNumber::N11),
            12 => quote!(::der::TagNumber::N12),
            13 => quote!(::der::TagNumber::N13),
            14 => quote!(::der::TagNumber::N14),
            15 => quote!(::der::TagNumber::N15),
            16 => quote!(::der::TagNumber::N16),
            17 => quote!(::der::TagNumber::N17),
            18 => quote!(::der::TagNumber::N18),
            19 => quote!(::der::TagNumber::N19),
            20 => quote!(::der::TagNumber::N20),
            21 => quote!(::der::TagNumber::N21),
            22 => quote!(::der::TagNumber::N22),
            23 => quote!(::der::TagNumber::N23),
            24 => quote!(::der::TagNumber::N24),
            25 => quote!(::der::TagNumber::N25),
            26 => quote!(::der::TagNumber::N26),
            27 => quote!(::der::TagNumber::N27),
            28 => quote!(::der::TagNumber::N28),
            29 => quote!(::der::TagNumber::N29),
            30 => quote!(::der::TagNumber::N30),
            _ => unreachable!("tag number out of range: {}", self),
        }
    }
}

impl FromStr for TagNumber {
    type Err = ParseError;

    fn from_str(s: &str) -> Result<Self, ParseError> {
        let n = s.parse::<u8>().map_err(|_| ParseError)?;

        if n <= Self::MAX {
            Ok(Self(n))
        } else {
            Err(ParseError)
        }
    }
}

impl Display for TagNumber {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

/// Error type
#[derive(Debug)]
pub(crate) struct ParseError;
