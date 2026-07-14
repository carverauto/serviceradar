#![doc = include_str!("../README.md")]

//! ## About
//! Custom derive support for the [`der`] crate.
//!
//! This crate contains custom derive macros intended to be used in the
//! following way:
//!
//! - [`Choice`][`derive@Choice`]: map ASN.1 `CHOICE` to a Rust enum.
//! - [`Enumerated`][`derive@Enumerated`]: map ASN.1 `ENUMERATED` to a C-like Rust enum.
//! - [`Sequence`][`derive@Sequence`]: map ASN.1 `SEQUENCE` to a Rust struct.
//! - [`ValueOrd`][`derive@ValueOrd`]: determine DER ordering for ASN.1 `SET OF`.
//!
//! Note that this crate shouldn't be used directly, but instead accessed
//! by using the `derive` feature of the `der` crate, which re-exports the
//! above macros from the toplevel.
//!
//! ## Why not `serde`?
//! The `der` crate is designed to be easily usable in embedded environments,
//! including ones where code size comes at a premium.
//!
//! This crate (i.e. `der_derive`) is able to generate code which is
//! significantly smaller than `serde_derive`. This is because the `der`
//! crate has been designed with high-level abstractions which reduce
//! code size, including trait object-based encoders which allow encoding
//! logic which is duplicated in `serde` serializers to be implemented in
//! a single place in the `der` crate.
//!
//! This is a deliberate tradeoff in terms of performance, flexibility, and
//! code size. At least for now, the `der` crate is optimizing for leveraging
//! as many abstractions as it can to minimize code size.
//!
//! ## Toplevel attributes
//!
//! The following attributes can be added to an `enum` or `struct` when
//! deriving either [`Choice`] or [`Sequence`] respectively:
//!
//! ### `#[asn1(tag_mode = "...")]` attribute: `EXPLICIT` vs `IMPLICIT`
//!
//! This attribute can be used to declare the tagging mode used by a particular
//! ASN.1 module.
//!
//! It's used when parsing `CONTEXT-SENSITIVE` fields.
//!
//! The default is `EXPLICIT`, so the attribute only needs to be added when
//! a particular module is declared `IMPLICIT`.
//!
//! ## Field-level attributes
//!
//! The following attributes can be added to either the fields of a particular
//! `struct` or the variants of a particular `enum`:
//!
//! ### `#[asn1(context_specific = "...")]` attribute: `CONTEXT-SPECIFIC` support
//!
//! This attribute can be added to associate a particular `CONTEXT-SPECIFIC`
//! tag number with a given enum variant or struct field.
//!
//! The value must be quoted and contain a number, e.g. `#[asn1(context_specific = "29")]`.
//!
//! ### `#[asn1(default = "...")]` attribute: `DEFAULT` support
//!
//! This behaves like `serde_derive`'s `default` attribute, allowing you to
//! specify the path to a function which returns a default value.
//!
//! ### `#[asn1(extensible = "true")]` attribute: support for `...` extensibility operator
//!
//! This attribute can be applied to the fields of `struct` types, and will
//! skip over unrecognized lower-numbered `CONTEXT-SPECIFIC` fields when
//! looking for a particular field of a struct.
//!
//! ### `#[asn1(optional = "true")]` attribute: support for `OPTIONAL` fields
//!
//! This attribute explicitly annotates a field as `OPTIONAL`.
//!
//! ### `#[asn1(type = "...")]` attribute: ASN.1 type declaration
//!
//! This attribute can be used to specify the ASN.1 type for a particular
//! `enum` variant or `struct` field.
//!
//! It's presently mandatory for all `enum` variants, even when using one of
//! the ASN.1 types defined by this crate.
//!
//! For structs, placing this attribute on a field makes it possible to
//! decode/encode types which don't directly implement the `Decode`/`Encode`
//! traits but do impl `From` and `TryInto` and `From` for one of the ASN.1 types
//! listed below (use the ASN.1 type keywords as the `type`):
//!
//! - `BIT STRING`: performs an intermediate conversion to [`der::asn1::BitString`]
//! - `IA5String`: performs an intermediate conversion to [`der::asn1::IA5String`]
//! - `GeneralizedTime`: performs an intermediate conversion to [`der::asn1::GeneralizedTime`]
//! - `OCTET STRING`: performs an intermediate conversion to [`der::asn1::OctetString`]
//! - `PrintableString`: performs an intermediate conversion to [`der::asn1::PrintableString`]
//! - `UTCTime`: performs an intermediate conversion to [`der::asn1::UtcTime`]
//! - `UTF8String`: performs an intermediate conversion to [`der::asn1::Utf8String`]
//!
//! ### `#[asn1(constructed = "...")]` attribute: support for constructed inner types
//!
//! This attribute can be used to specify that an "inner" type is constructed. It is most
//! commonly used when a `CHOICE` has a constructed inner type.
//!
//! Note: please open a GitHub Issue if you would like to request support
//! for additional ASN.1 types.
//!
//! [`der`]: https://docs.rs/der/
//! [`Choice`]: derive@Choice
//! [`Sequence`]: derive@Sequence
//! [`der::asn1::BitString`]: https://docs.rs/der/latest/der/asn1/struct.BitString.html
//! [`der::asn1::Ia5String`]: https://docs.rs/der/latest/der/asn1/struct.Ia5String.html
//! [`der::asn1::GeneralizedTime`]: https://docs.rs/der/latest/der/asn1/struct.GeneralizedTime.html
//! [`der::asn1::OctetString`]: https://docs.rs/der/latest/der/asn1/struct.OctetString.html
//! [`der::asn1::PrintableString`]: https://docs.rs/der/latest/der/asn1/struct.PrintableString.html
//! [`der::asn1::UtcTime`]: https://docs.rs/der/latest/der/asn1/struct.UtcTime.html
//! [`der::asn1::Utf8String`]: https://docs.rs/der/latest/der/asn1/struct.Utf8String.html

#![crate_type = "proc-macro"]
#![forbid(unsafe_code)]
#![warn(
    clippy::unwrap_used,
    rust_2018_idioms,
    trivial_casts,
    unused_qualifications
)]

macro_rules! abort {
    ( $tokens:expr, $message:expr $(,)? ) => {
        return Err(syn::Error::new_spanned($tokens, $message))
    };
}

mod asn1_type;
mod attributes;
mod choice;
mod enumerated;
mod sequence;
mod tag;
mod value_ord;

use crate::{
    asn1_type::Asn1Type,
    attributes::{FieldAttrs, TypeAttrs, ATTR_NAME},
    choice::DeriveChoice,
    enumerated::DeriveEnumerated,
    sequence::DeriveSequence,
    tag::{Tag, TagMode, TagNumber},
    value_ord::DeriveValueOrd,
};
use proc_macro::TokenStream;
use proc_macro2::Span;
use syn::{parse_macro_input, DeriveInput, Lifetime};

/// Get the default lifetime.
fn default_lifetime() -> Lifetime {
    Lifetime::new("'__der_lifetime", Span::call_site())
}

/// Derive the [`Choice`][1] trait on an `enum`.
///
/// This custom derive macro can be used to automatically impl the
/// [`Decode`][2] and [`Encode`][3] traits along with the
/// [`Choice`][1] supertrait for any enum representing an ASN.1 `CHOICE`.
///
/// The enum must consist entirely of 1-tuple variants wrapping inner
/// types which must also impl the [`Decode`][2] and [`Encode`][3]
/// traits. It will will also generate [`From`] impls for each of the
/// inner types of the variants into the enum that wraps them.
///
/// # Usage
///
/// ```ignore
/// // NOTE: requires the `derive` feature of `der`
/// use der::Choice;
///
/// /// `Time` as defined in RFC 5280
/// #[derive(Choice)]
/// pub enum Time {
///     #[asn1(type = "UTCTime")]
///     UtcTime(UtcTime),
///
///     #[asn1(type = "GeneralizedTime")]
///     GeneralTime(GeneralizedTime),
/// }
/// ```
///
/// # `#[asn1(type = "...")]` attribute
///
/// See [toplevel documentation for the `der_derive` crate][4] for more
/// information about the `#[asn1]` attribute.
///
/// [1]: https://docs.rs/der/latest/der/trait.Choice.html
/// [2]: https://docs.rs/der/latest/der/trait.Decode.html
/// [3]: https://docs.rs/der/latest/der/trait.Encode.html
/// [4]: https://docs.rs/der_derive/
#[proc_macro_derive(Choice, attributes(asn1))]
pub fn derive_choice(input: TokenStream) -> TokenStream {
    let input = parse_macro_input!(input as DeriveInput);
    match DeriveChoice::new(input) {
        Ok(t) => t.to_tokens().into(),
        Err(e) => e.to_compile_error().into(),
    }
}

/// Derive decoders and encoders for ASN.1 [`Enumerated`] types on a
/// C-like `enum` type.
///
/// # Usage
///
/// The `Enumerated` proc macro requires a C-like enum which impls `Copy`
/// and has a `#[repr]` of `u8`, `u16`, or `u32`:
///
/// ```ignore
/// use der::Enumerated;
///
/// #[derive(Enumerated, Copy, Clone, Debug, Eq, PartialEq)]
/// #[repr(u32)]
/// pub enum CrlReason {
///     Unspecified = 0,
///     KeyCompromise = 1,
///     CaCompromise = 2,
///     AffiliationChanged = 3,
///     Superseded = 4,
///     CessationOfOperation = 5,
///     CertificateHold = 6,
///     RemoveFromCrl = 8,
///     PrivilegeWithdrawn = 9,
///     AaCompromised = 10
/// }
/// ```
///
/// Note that the derive macro will write a `TryFrom<...>` impl for the
/// provided `#[repr]`, which is used by the decoder.
#[proc_macro_derive(Enumerated, attributes(asn1))]
pub fn derive_enumerated(input: TokenStream) -> TokenStream {
    let input = parse_macro_input!(input as DeriveInput);
    match DeriveEnumerated::new(input) {
        Ok(t) => t.to_tokens().into(),
        Err(e) => e.to_compile_error().into(),
    }
}

/// Derive the [`Sequence`][1] trait on a `struct`.
///
/// This custom derive macro can be used to automatically impl the
/// `Sequence` trait for any struct which can be decoded/encoded as an
/// ASN.1 `SEQUENCE`.
///
/// # Usage
///
/// ```ignore
/// use der::{
///     asn1::{Any, ObjectIdentifier},
///     Sequence
/// };
///
/// /// X.509 `AlgorithmIdentifier`
/// #[derive(Sequence)]
/// pub struct AlgorithmIdentifier<'a> {
///     /// This field contains an ASN.1 `OBJECT IDENTIFIER`, a.k.a. OID.
///     pub algorithm: ObjectIdentifier,
///
///     /// This field is `OPTIONAL` and contains the ASN.1 `ANY` type, which
///     /// in this example allows arbitrary algorithm-defined parameters.
///     pub parameters: Option<Any<'a>>
/// }
/// ```
///
/// # `#[asn1(type = "...")]` attribute
///
/// See [toplevel documentation for the `der_derive` crate][2] for more
/// information about the `#[asn1]` attribute.
///
/// [1]: https://docs.rs/der/latest/der/trait.Sequence.html
/// [2]: https://docs.rs/der_derive/
#[proc_macro_derive(Sequence, attributes(asn1))]
pub fn derive_sequence(input: TokenStream) -> TokenStream {
    let input = parse_macro_input!(input as DeriveInput);
    match DeriveSequence::new(input) {
        Ok(t) => t.to_tokens().into(),
        Err(e) => e.to_compile_error().into(),
    }
}

/// Derive the [`ValueOrd`][1] trait on a `struct`.
///
/// This trait is used in conjunction with ASN.1 `SET OF` types to determine
/// the lexicographical order of their DER encodings.
///
/// [1]: https://docs.rs/der/latest/der/trait.ValueOrd.html
#[proc_macro_derive(ValueOrd, attributes(asn1))]
pub fn derive_value_ord(input: TokenStream) -> TokenStream {
    let input = parse_macro_input!(input as DeriveInput);
    match DeriveValueOrd::new(input) {
        Ok(t) => t.to_tokens().into(),
        Err(e) => e.to_compile_error().into(),
    }
}
