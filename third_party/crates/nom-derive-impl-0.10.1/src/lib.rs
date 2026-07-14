//! # nom-derive-impl
//!
//! ## Overview
//!
//! nom-derive is a custom derive attribute, to derive `nom` parsers automatically from the structure definition.
//!
//! This crate is not meant to be used directly.
//! See [`nom-derive`](https://docs.rs/nom-derive) crate for documentation.

extern crate proc_macro;
extern crate proc_macro2;
extern crate syn;
#[macro_use]
extern crate quote;

use proc_macro::TokenStream;
use syn::*;

mod config;
mod endian;
mod enums;
mod gen;
mod meta;
mod parsertree;
mod structs;

use crate::endian::*;
use crate::gen::*;

/// The `Nom` derive automatically generates a `parse` function for the structure
/// using [nom] parsers. It will try to infer parsers for primitive of known
/// types, but also allows you to specify parsers using custom attributes.
///
/// Deriving parsers supports `struct` and `enum` types.
///
/// The documentation of the `Nom` custom derive attribute and all possible options
/// can be found in the [nom-derive documentation](https://docs.rs/nom-derive).
///
/// Many examples are provided, and more can be found in the [project
/// tests](https://github.com/rust-bakery/nom-derive/tree/master/tests).
///
/// [nom]: https://github.com/Geal/nom
#[proc_macro_derive(Nom, attributes(nom))]
pub fn nom(input: TokenStream) -> TokenStream {
    // Parse the input tokens into a syntax tree
    let ast = parse_macro_input!(input as DeriveInput);

    // Build and return the generated impl
    match gen_impl(&ast, ParserEndianness::Unspecified) {
        Ok(ts) => ts.into(),
        Err(e) => e.to_compile_error().into(),
    }
}

/// The `NomBE` acts like the [`Nom`] attribute, but sets the endianness to big-endian for the
/// current object. This can be overriden locally at the field-level.
#[proc_macro_derive(NomBE, attributes(nom))]
pub fn nom_be(input: TokenStream) -> TokenStream {
    // Parse the input tokens into a syntax tree
    let ast = parse_macro_input!(input as DeriveInput);

    // Build and return the generated impl
    match gen_impl(&ast, ParserEndianness::BigEndian) {
        Ok(ts) => ts.into(),
        Err(e) => e.to_compile_error().into(),
    }
}

/// The `NomLE` acts like the [`Nom`] attribute, but sets the endianness to little-endian for the
/// current object. This can be overriden locally at the field-level.
#[proc_macro_derive(NomLE, attributes(nom))]
pub fn nom_le(input: TokenStream) -> TokenStream {
    // Parse the input tokens into a syntax tree
    let ast = parse_macro_input!(input as DeriveInput);

    // Build and return the generated impl
    match gen_impl(&ast, ParserEndianness::LittleEndian) {
        Ok(ts) => ts.into(),
        Err(e) => e.to_compile_error().into(),
    }
}
