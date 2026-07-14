//! Choice variant IR and lowerings

use crate::{FieldAttrs, Tag, TypeAttrs};
use proc_macro2::TokenStream;
use quote::quote;
use syn::{Fields, Ident, Path, Type, Variant};

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum TagOrPath {
    Tag(Tag),
    Path(Path),
}

impl PartialEq<Tag> for TagOrPath {
    fn eq(&self, rhs: &Tag) -> bool {
        match self {
            Self::Tag(lhs) => lhs == rhs,
            _ => false,
        }
    }
}

impl From<Tag> for TagOrPath {
    fn from(tag: Tag) -> Self {
        Self::Tag(tag)
    }
}

impl From<Path> for TagOrPath {
    fn from(path: Path) -> Self {
        Self::Path(path)
    }
}

impl TryFrom<&Variant> for TagOrPath {
    type Error = syn::Error;

    fn try_from(input: &Variant) -> syn::Result<Self> {
        if let Fields::Unnamed(fields) = &input.fields {
            if fields.unnamed.len() == 1 {
                if let Type::Path(path) = &fields.unnamed[0].ty {
                    return Ok(path.path.clone().into());
                }
            }
        }

        Err(syn::Error::new_spanned(
            &input.ident,
            "no #[asn1(type=...)] specified for enum variant",
        ))
    }
}

impl TagOrPath {
    pub fn to_tokens(&self) -> TokenStream {
        match self {
            Self::Tag(tag) => tag.to_tokens(),
            Self::Path(path) => quote! { <#path as ::der::FixedTag>::TAG },
        }
    }
}

/// "IR" for a variant of a derived `Choice`.
pub(super) struct ChoiceVariant {
    /// Variant name.
    pub(super) ident: Ident,

    /// "Field" (in this case variant)-level attributes.
    pub(super) attrs: FieldAttrs,

    /// Tag for the ASN.1 type.
    pub(super) tag: TagOrPath,
}

impl ChoiceVariant {
    /// Create a new [`ChoiceVariant`] from the input [`Variant`].
    pub(super) fn new(input: &Variant, type_attrs: &TypeAttrs) -> syn::Result<Self> {
        let ident = input.ident.clone();
        let attrs = FieldAttrs::parse(&input.attrs, type_attrs)?;

        if attrs.extensible {
            abort!(&ident, "`extensible` is not allowed on CHOICE");
        }

        // Validate that variant is a 1-element tuple struct
        match &input.fields {
            // TODO(tarcieri): handle 0 bindings for ASN.1 NULL
            Fields::Unnamed(fields) if fields.unnamed.len() == 1 => (),
            _ => abort!(&ident, "enum variant must be a 1-element tuple struct"),
        }

        let tag = match attrs.tag()? {
            Some(x) => x.into(),
            None => input.try_into()?,
        };

        Ok(Self { ident, attrs, tag })
    }

    /// Derive a match arm of the impl body for `TryFrom<der::asn1::Any<'_>>`.
    pub(super) fn to_decode_tokens(&self) -> TokenStream {
        let tag = self.tag.to_tokens();
        let ident = &self.ident;
        let decoder = self.attrs.decoder();

        match self.attrs.asn1_type {
            Some(..) => quote! { #tag => Ok(Self::#ident(#decoder.try_into()?)), },
            None => quote! { #tag => Ok(Self::#ident(#decoder)), },
        }
    }

    /// Derive a match arm for the impl body for `der::EncodeValue::encode_value`.
    pub(super) fn to_encode_value_tokens(&self) -> TokenStream {
        let ident = &self.ident;
        let binding = quote!(variant);
        let encoder = self.attrs.value_encode(&binding);
        quote! {
            Self::#ident(#binding) => #encoder,
        }
    }

    /// Derive a match arm for the impl body for `der::EncodeValue::value_len`.
    pub(super) fn to_value_len_tokens(&self) -> TokenStream {
        let ident = &self.ident;

        match self.attrs.context_specific {
            Some(tag_number) => {
                let tag_number = tag_number.to_tokens();
                let tag_mode = self.attrs.tag_mode.to_tokens();

                quote! {
                    Self::#ident(variant) => ::der::asn1::ContextSpecificRef {
                        tag_number: #tag_number,
                        tag_mode: #tag_mode,
                        value: variant,
                    }.value_len(),
                }
            }

            _ => quote! { Self::#ident(variant) => variant.value_len(), },
        }
    }

    /// Derive a match arm for the impl body for `der::Tagged::tag`.
    pub(super) fn to_tagged_tokens(&self) -> TokenStream {
        let ident = &self.ident;
        let tag = self.tag.to_tokens();
        quote! {
            Self::#ident(_) => #tag,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::ChoiceVariant;
    use crate::{choice::variant::TagOrPath, Asn1Type, FieldAttrs, Tag, TagMode, TagNumber};
    use proc_macro2::Span;
    use quote::quote;
    use syn::Ident;

    #[test]
    fn simple() {
        let ident = Ident::new("ExampleVariant", Span::call_site());
        let attrs = FieldAttrs::default();
        let tag = Tag::Universal(Asn1Type::Utf8String).into();
        let variant = ChoiceVariant { ident, attrs, tag };

        assert_eq!(
            variant.to_decode_tokens().to_string(),
            quote! {
                ::der::Tag::Utf8String => Ok(Self::ExampleVariant(
                    reader.decode()?
                )),
            }
            .to_string()
        );

        assert_eq!(
            variant.to_encode_value_tokens().to_string(),
            quote! {
                Self::ExampleVariant(variant) => variant.encode_value(encoder),
            }
            .to_string()
        );

        assert_eq!(
            variant.to_value_len_tokens().to_string(),
            quote! {
                Self::ExampleVariant(variant) => variant.value_len(),
            }
            .to_string()
        );

        assert_eq!(
            variant.to_tagged_tokens().to_string(),
            quote! {
                Self::ExampleVariant(_) => ::der::Tag::Utf8String,
            }
            .to_string()
        )
    }

    #[test]
    fn utf8string() {
        let ident = Ident::new("ExampleVariant", Span::call_site());
        let attrs = FieldAttrs {
            asn1_type: Some(Asn1Type::Utf8String),
            ..Default::default()
        };
        let tag = Tag::Universal(Asn1Type::Utf8String).into();
        let variant = ChoiceVariant { ident, attrs, tag };

        assert_eq!(
            variant.to_decode_tokens().to_string(),
            quote! {
                ::der::Tag::Utf8String => Ok(Self::ExampleVariant(
                    ::der::asn1::Utf8StringRef::decode(reader)?
                    .try_into()?
                )),
            }
            .to_string()
        );

        assert_eq!(
            variant.to_encode_value_tokens().to_string(),
            quote! {
                Self::ExampleVariant(variant) => ::der::asn1::Utf8StringRef::new(variant)?.encode_value(encoder),
            }
            .to_string()
        );

        assert_eq!(
            variant.to_value_len_tokens().to_string(),
            quote! {
                Self::ExampleVariant(variant) => variant.value_len(),
            }
            .to_string()
        );

        assert_eq!(
            variant.to_tagged_tokens().to_string(),
            quote! {
                Self::ExampleVariant(_) => ::der::Tag::Utf8String,
            }
            .to_string()
        )
    }

    #[test]
    fn explicit() {
        for tag_number in [0, 1, 2, 3] {
            for constructed in [false, true] {
                let ident = Ident::new("ExplicitVariant", Span::call_site());
                let attrs = FieldAttrs {
                    constructed,
                    context_specific: Some(TagNumber(tag_number)),
                    ..Default::default()
                };
                assert_eq!(attrs.tag_mode, TagMode::Explicit);

                let tag = TagOrPath::Tag(Tag::ContextSpecific {
                    constructed,
                    number: TagNumber(tag_number),
                });

                let variant = ChoiceVariant { ident, attrs, tag };
                let tag_number = TagNumber(tag_number).to_tokens();

                assert_eq!(
                    variant.to_decode_tokens().to_string(),
                    quote! {
                        ::der::Tag::ContextSpecific {
                            constructed: #constructed,
                            number: #tag_number,
                        } => Ok(Self::ExplicitVariant(
                            match ::der::asn1::ContextSpecific::<>::decode(reader)? {
                                field if field.tag_number == #tag_number => Some(field),
                                _ => None
                            }
                            .ok_or_else(|| {
                                der::Tag::ContextSpecific {
                                    number: #tag_number,
                                    constructed: #constructed
                                }
                                .value_error()
                            })?
                            .value
                        )),
                    }
                    .to_string()
                );

                assert_eq!(
                    variant.to_encode_value_tokens().to_string(),
                    quote! {
                        Self::ExplicitVariant(variant) => ::der::asn1::ContextSpecificRef {
                            tag_number: #tag_number,
                            tag_mode: ::der::TagMode::Explicit,
                            value: variant,
                        }
                        .encode_value(encoder),
                    }
                    .to_string()
                );

                assert_eq!(
                    variant.to_value_len_tokens().to_string(),
                    quote! {
                        Self::ExplicitVariant(variant) => ::der::asn1::ContextSpecificRef {
                            tag_number: #tag_number,
                            tag_mode: ::der::TagMode::Explicit,
                            value: variant,
                        }
                        .value_len(),
                    }
                    .to_string()
                );

                assert_eq!(
                    variant.to_tagged_tokens().to_string(),
                    quote! {
                        Self::ExplicitVariant(_) => ::der::Tag::ContextSpecific {
                            constructed: #constructed,
                            number: #tag_number,
                        },
                    }
                    .to_string()
                )
            }
        }
    }

    #[test]
    fn implicit() {
        for tag_number in [0, 1, 2, 3] {
            for constructed in [false, true] {
                let ident = Ident::new("ImplicitVariant", Span::call_site());

                let attrs = FieldAttrs {
                    constructed,
                    context_specific: Some(TagNumber(tag_number)),
                    tag_mode: TagMode::Implicit,
                    ..Default::default()
                };

                let tag = TagOrPath::Tag(Tag::ContextSpecific {
                    constructed,
                    number: TagNumber(tag_number),
                });

                let variant = ChoiceVariant { ident, attrs, tag };
                let tag_number = TagNumber(tag_number).to_tokens();

                assert_eq!(
                    variant.to_decode_tokens().to_string(),
                    quote! {
                        ::der::Tag::ContextSpecific {
                            constructed: #constructed,
                            number: #tag_number,
                        } => Ok(Self::ImplicitVariant(
                            ::der::asn1::ContextSpecific::<>::decode_implicit(
                                reader,
                                #tag_number
                            )?
                            .ok_or_else(|| {
                                der::Tag::ContextSpecific {
                                  number: #tag_number,
                                  constructed: #constructed
                                }
                                .value_error()
                            })?
                            .value
                        )),
                    }
                    .to_string()
                );

                assert_eq!(
                    variant.to_encode_value_tokens().to_string(),
                    quote! {
                        Self::ImplicitVariant(variant) => ::der::asn1::ContextSpecificRef {
                            tag_number: #tag_number,
                            tag_mode: ::der::TagMode::Implicit,
                            value: variant,
                        }
                        .encode_value(encoder),
                    }
                    .to_string()
                );

                assert_eq!(
                    variant.to_value_len_tokens().to_string(),
                    quote! {
                        Self::ImplicitVariant(variant) => ::der::asn1::ContextSpecificRef {
                            tag_number: #tag_number,
                            tag_mode: ::der::TagMode::Implicit,
                            value: variant,
                        }
                        .value_len(),
                    }
                    .to_string()
                );

                assert_eq!(
                    variant.to_tagged_tokens().to_string(),
                    quote! {
                        Self::ImplicitVariant(_) => ::der::Tag::ContextSpecific {
                            constructed: #constructed,
                            number: #tag_number,
                        },
                    }
                    .to_string()
                )
            }
        }
    }
}
