//! Support for deriving the `Decode` and `Encode` traits on enums for
//! the purposes of decoding/encoding ASN.1 `ENUMERATED` types as mapped to
//! enum variants.

use crate::attributes::AttrNameValue;
use crate::{default_lifetime, ATTR_NAME};
use proc_macro2::TokenStream;
use quote::quote;
use syn::{DeriveInput, Expr, ExprLit, Ident, Lit, LitInt, Variant};

/// Valid options for the `#[repr]` attribute on `Enumerated` types.
const REPR_TYPES: &[&str] = &["u8", "u16", "u32"];

/// Derive the `Enumerated` trait for an enum.
pub(crate) struct DeriveEnumerated {
    /// Name of the enum type.
    ident: Ident,

    /// Value of the `repr` attribute.
    repr: Ident,

    /// Whether or not to tag the enum as an integer
    integer: bool,

    /// Variants of this enum.
    variants: Vec<EnumeratedVariant>,
}

impl DeriveEnumerated {
    /// Parse [`DeriveInput`].
    pub fn new(input: DeriveInput) -> syn::Result<Self> {
        let data = match input.data {
            syn::Data::Enum(data) => data,
            _ => abort!(
                input.ident,
                "can't derive `Enumerated` on this type: only `enum` types are allowed",
            ),
        };

        // Reject `asn1` attributes, parse the `repr` attribute
        let mut repr: Option<Ident> = None;
        let mut integer = false;

        for attr in &input.attrs {
            if attr.path().is_ident(ATTR_NAME) {
                let kvs = match AttrNameValue::parse_attribute(attr) {
                    Ok(kvs) => kvs,
                    Err(e) => abort!(attr, e),
                };
                for anv in kvs {
                    if anv.name.is_ident("type") {
                        match anv.value.value().as_str() {
                            "ENUMERATED" => integer = false,
                            "INTEGER" => integer = true,
                            s => abort!(anv.value, format_args!("`type = \"{s}\"` is unsupported")),
                        }
                    }
                }
            } else if attr.path().is_ident("repr") {
                if repr.is_some() {
                    abort!(
                        attr,
                        "multiple `#[repr]` attributes encountered on `Enumerated`",
                    );
                }

                let r = attr.parse_args::<Ident>().map_err(|_| {
                    syn::Error::new_spanned(attr, "error parsing `#[repr]` attribute")
                })?;

                // Validate
                if !REPR_TYPES.contains(&r.to_string().as_str()) {
                    abort!(
                        attr,
                        format_args!("invalid `#[repr]` type: allowed types are {REPR_TYPES:?}"),
                    );
                }

                repr = Some(r);
            }
        }

        // Parse enum variants
        let variants = data
            .variants
            .iter()
            .map(EnumeratedVariant::new)
            .collect::<syn::Result<_>>()?;

        Ok(Self {
            ident: input.ident.clone(),
            repr: repr.ok_or_else(|| {
                syn::Error::new_spanned(
                    &input.ident,
                    format_args!("no `#[repr]` attribute on enum: must be one of {REPR_TYPES:?}"),
                )
            })?,
            variants,
            integer,
        })
    }

    /// Lower the derived output into a [`TokenStream`].
    pub fn to_tokens(&self) -> TokenStream {
        let default_lifetime = default_lifetime();
        let ident = &self.ident;
        let repr = &self.repr;
        let tag = match self.integer {
            false => quote! { ::der::Tag::Enumerated },
            true => quote! { ::der::Tag::Integer },
        };

        let mut try_from_body = Vec::new();
        for variant in &self.variants {
            try_from_body.push(variant.to_try_from_tokens());
        }

        quote! {
            impl<#default_lifetime> ::der::DecodeValue<#default_lifetime> for #ident {
                fn decode_value<R: ::der::Reader<#default_lifetime>>(
                    reader: &mut R,
                    header: ::der::Header
                ) -> ::der::Result<Self> {
                    <#repr as ::der::DecodeValue>::decode_value(reader, header)?.try_into()
                }
            }

            impl ::der::EncodeValue for #ident {
                fn value_len(&self) -> ::der::Result<::der::Length> {
                    ::der::EncodeValue::value_len(&(*self as #repr))
                }

                fn encode_value(&self, encoder: &mut impl ::der::Writer) -> ::der::Result<()> {
                    ::der::EncodeValue::encode_value(&(*self as #repr), encoder)
                }
            }

            impl ::der::FixedTag for #ident {
                const TAG: ::der::Tag = #tag;
            }

            impl TryFrom<#repr> for #ident {
                type Error = ::der::Error;

                fn try_from(n: #repr) -> ::der::Result<Self> {
                    match n {
                        #(#try_from_body)*
                        _ => Err(#tag.value_error())
                    }
                }
            }
        }
    }
}

/// "IR" for a variant of a derived `Enumerated`.
pub struct EnumeratedVariant {
    /// Variant name.
    ident: Ident,

    /// Integer value that this variant corresponds to.
    discriminant: LitInt,
}

impl EnumeratedVariant {
    /// Create a new [`ChoiceVariant`] from the input [`Variant`].
    fn new(input: &Variant) -> syn::Result<Self> {
        for attr in &input.attrs {
            if attr.path().is_ident(ATTR_NAME) {
                abort!(
                    attr,
                    "`asn1` attribute is not allowed on fields of `Enumerated` types"
                );
            }
        }

        match &input.discriminant {
            Some((
                _,
                Expr::Lit(ExprLit {
                    lit: Lit::Int(discriminant),
                    ..
                }),
            )) => Ok(Self {
                ident: input.ident.clone(),
                discriminant: discriminant.clone(),
            }),
            Some((_, other)) => abort!(other, "invalid discriminant for `Enumerated`"),
            None => abort!(input, "`Enumerated` variant has no discriminant"),
        }
    }

    /// Write the body for the derived [`TryFrom`] impl.
    pub fn to_try_from_tokens(&self) -> TokenStream {
        let ident = &self.ident;
        let discriminant = &self.discriminant;
        quote! {
            #discriminant => Ok(Self::#ident),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::DeriveEnumerated;
    use syn::parse_quote;

    /// X.509 `CRLReason`.
    #[test]
    fn crlreason_example() {
        let input = parse_quote! {
            #[repr(u32)]
            pub enum CrlReason {
                Unspecified = 0,
                KeyCompromise = 1,
                CaCompromise = 2,
                AffiliationChanged = 3,
                Superseded = 4,
                CessationOfOperation = 5,
                CertificateHold = 6,
                RemoveFromCrl = 8,
                PrivilegeWithdrawn = 9,
                AaCompromised = 10,
            }
        };

        let ir = DeriveEnumerated::new(input).unwrap();
        assert_eq!(ir.ident, "CrlReason");
        assert_eq!(ir.repr, "u32");
        assert_eq!(ir.variants.len(), 10);

        let unspecified = &ir.variants[0];
        assert_eq!(unspecified.ident, "Unspecified");
        assert_eq!(unspecified.discriminant.to_string(), "0");

        let key_compromise = &ir.variants[1];
        assert_eq!(key_compromise.ident, "KeyCompromise");
        assert_eq!(key_compromise.discriminant.to_string(), "1");

        let key_compromise = &ir.variants[2];
        assert_eq!(key_compromise.ident, "CaCompromise");
        assert_eq!(key_compromise.discriminant.to_string(), "2");
    }
}
