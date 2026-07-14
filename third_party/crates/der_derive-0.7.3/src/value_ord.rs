//! Support for deriving the `ValueOrd` trait on enums and structs.
//!
//! This trait is used in conjunction with ASN.1 `SET OF` types to determine
//! the lexicographical order of their DER encodings.

// TODO(tarcieri): enum support

use crate::{FieldAttrs, TypeAttrs};
use proc_macro2::TokenStream;
use quote::quote;
use syn::{DeriveInput, Field, Ident, Lifetime, Variant};

/// Derive the `Enumerated` trait for an enum.
pub(crate) struct DeriveValueOrd {
    /// Name of the enum.
    ident: Ident,

    /// Lifetime of the struct.
    lifetime: Option<Lifetime>,

    /// Fields of structs or enum variants.
    fields: Vec<ValueField>,

    /// Type of input provided (`enum` or `struct`).
    input_type: InputType,
}

impl DeriveValueOrd {
    /// Parse [`DeriveInput`].
    pub fn new(input: DeriveInput) -> syn::Result<Self> {
        let ident = input.ident;
        let type_attrs = TypeAttrs::parse(&input.attrs)?;

        // TODO(tarcieri): properly handle multiple lifetimes
        let lifetime = input
            .generics
            .lifetimes()
            .next()
            .map(|lt| lt.lifetime.clone());

        let (fields, input_type) = match input.data {
            syn::Data::Enum(data) => (
                data.variants
                    .into_iter()
                    .map(|variant| ValueField::new_enum(variant, &type_attrs))
                    .collect::<syn::Result<_>>()?,
                InputType::Enum,
            ),
            syn::Data::Struct(data) => (
                data.fields
                    .into_iter()
                    .map(|field| ValueField::new_struct(field, &type_attrs))
                    .collect::<syn::Result<_>>()?,
                InputType::Struct,
            ),
            _ => abort!(
                ident,
                "can't derive `ValueOrd` on this type: \
                 only `enum` and `struct` types are allowed",
            ),
        };

        Ok(Self {
            ident,
            lifetime,
            fields,
            input_type,
        })
    }

    /// Lower the derived output into a [`TokenStream`].
    pub fn to_tokens(&self) -> TokenStream {
        let ident = &self.ident;

        // Lifetime parameters
        // TODO(tarcieri): support multiple lifetimes
        let lt_params = self
            .lifetime
            .as_ref()
            .map(|lt| vec![lt.clone()])
            .unwrap_or_default();

        let mut body = Vec::new();

        for field in &self.fields {
            body.push(field.to_tokens());
        }

        let body = match self.input_type {
            InputType::Enum => {
                quote! {
                    #[allow(unused_imports)]
                    use ::der::ValueOrd;
                    match (self, other) {
                        #(#body)*
                        _ => unreachable!(),
                    }
                }
            }
            InputType::Struct => {
                quote! {
                    #[allow(unused_imports)]
                    use ::der::{DerOrd, ValueOrd};

                    #(#body)*

                    Ok(::core::cmp::Ordering::Equal)
                }
            }
        };

        quote! {
            impl<#(#lt_params)*> ::der::ValueOrd for #ident<#(#lt_params)*> {
                fn value_cmp(&self, other: &Self) -> ::der::Result<::core::cmp::Ordering> {
                    #body
                }
            }
        }
    }
}

/// What kind of input was provided (i.e. `enum` or `struct`).
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum InputType {
    /// Input is an `enum`.
    Enum,

    /// Input is a `struct`.
    Struct,
}

struct ValueField {
    /// Name of the field
    ident: Ident,

    /// Field-level attributes.
    attrs: FieldAttrs,

    is_enum: bool,
}

impl ValueField {
    /// Create from an `enum` variant.
    fn new_enum(variant: Variant, type_attrs: &TypeAttrs) -> syn::Result<Self> {
        let ident = variant.ident;

        let attrs = FieldAttrs::parse(&variant.attrs, type_attrs)?;
        Ok(Self {
            ident,
            attrs,
            is_enum: true,
        })
    }

    /// Create from a `struct` field.
    fn new_struct(field: Field, type_attrs: &TypeAttrs) -> syn::Result<Self> {
        let ident =
            field.ident.as_ref().cloned().ok_or_else(|| {
                syn::Error::new_spanned(&field, "tuple structs are not supported")
            })?;

        let attrs = FieldAttrs::parse(&field.attrs, type_attrs)?;
        Ok(Self {
            ident,
            attrs,
            is_enum: false,
        })
    }

    /// Lower to [`TokenStream`].
    fn to_tokens(&self) -> TokenStream {
        let ident = &self.ident;

        if self.is_enum {
            let binding1 = quote!(Self::#ident(this));
            let binding2 = quote!(Self::#ident(other));
            quote! {
                (#binding1, #binding2) => this.value_cmp(other),
            }
        } else {
            let mut binding1 = quote!(self.#ident);
            let mut binding2 = quote!(other.#ident);

            if let Some(ty) = &self.attrs.asn1_type {
                binding1 = ty.encoder(&binding1);
                binding2 = ty.encoder(&binding2);
            }

            quote! {
                match #binding1.der_cmp(&#binding2)? {
                    ::core::cmp::Ordering::Equal => (),
                    other => return Ok(other),
                }
            }
        }
    }
}
