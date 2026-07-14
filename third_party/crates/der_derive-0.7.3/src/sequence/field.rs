//! Sequence field IR and lowerings

use crate::{Asn1Type, FieldAttrs, TagMode, TagNumber, TypeAttrs};
use proc_macro2::TokenStream;
use quote::quote;
use syn::{Field, Ident, Path, Type};

/// "IR" for a field of a derived `Sequence`.
pub(super) struct SequenceField {
    /// Variant name.
    pub(super) ident: Ident,

    /// Field-level attributes.
    pub(super) attrs: FieldAttrs,

    /// Field type
    pub(super) field_type: Type,
}

impl SequenceField {
    /// Create a new [`SequenceField`] from the input [`Field`].
    pub(super) fn new(field: &Field, type_attrs: &TypeAttrs) -> syn::Result<Self> {
        let ident = field.ident.as_ref().cloned().ok_or_else(|| {
            syn::Error::new_spanned(
                field,
                "no name on struct field i.e. tuple structs unsupported",
            )
        })?;

        let attrs = FieldAttrs::parse(&field.attrs, type_attrs)?;

        if attrs.asn1_type.is_some() && attrs.default.is_some() {
            return Err(syn::Error::new_spanned(
                ident,
                "ASN.1 `type` and `default` options cannot be combined",
            ));
        }

        if attrs.default.is_some() && attrs.optional {
            return Err(syn::Error::new_spanned(
                ident,
                "`optional` and `default` field qualifiers are mutually exclusive",
            ));
        }

        Ok(Self {
            ident,
            attrs,
            field_type: field.ty.clone(),
        })
    }

    /// Derive code for decoding a field of a sequence.
    pub(super) fn to_decode_tokens(&self) -> TokenStream {
        let mut lowerer = LowerFieldDecoder::new(&self.attrs);

        if self.attrs.asn1_type.is_some() {
            lowerer.apply_asn1_type(self.attrs.optional);
        }

        if let Some(default) = &self.attrs.default {
            // TODO(tarcieri): default in conjunction with ASN.1 types?
            debug_assert!(
                self.attrs.asn1_type.is_none(),
                "`type` and `default` are mutually exclusive"
            );

            // TODO(tarcieri): support for context-specific fields with defaults?
            if self.attrs.context_specific.is_none() {
                lowerer.apply_default(default, &self.field_type);
            }
        }

        lowerer.into_tokens(&self.ident)
    }

    /// Derive code for encoding a field of a sequence.
    pub(super) fn to_encode_tokens(&self) -> TokenStream {
        let mut lowerer = LowerFieldEncoder::new(&self.ident);
        let attrs = &self.attrs;

        if let Some(ty) = &attrs.asn1_type {
            // TODO(tarcieri): default in conjunction with ASN.1 types?
            debug_assert!(
                attrs.default.is_none(),
                "`type` and `default` are mutually exclusive"
            );
            lowerer.apply_asn1_type(ty, attrs.optional);
        }

        if let Some(tag_number) = &attrs.context_specific {
            lowerer.apply_context_specific(tag_number, &attrs.tag_mode, attrs.optional);
        }

        if let Some(default) = &attrs.default {
            debug_assert!(
                !attrs.optional,
                "`default`, and `optional` are mutually exclusive"
            );
            lowerer.apply_default(&self.ident, default, &self.field_type);
        }

        lowerer.into_tokens()
    }
}

/// AST lowerer for field decoders.
struct LowerFieldDecoder {
    /// Decoder-in-progress.
    decoder: TokenStream,
}

impl LowerFieldDecoder {
    /// Create a new field decoder lowerer.
    fn new(attrs: &FieldAttrs) -> Self {
        Self {
            decoder: attrs.decoder(),
        }
    }

    ///  the field decoder to tokens.
    fn into_tokens(self, ident: &Ident) -> TokenStream {
        let decoder = self.decoder;

        quote! {
            let #ident = #decoder;
        }
    }

    /// Apply the ASN.1 type (if defined).
    fn apply_asn1_type(&mut self, optional: bool) {
        let decoder = &self.decoder;

        self.decoder = if optional {
            quote! {
                #decoder.map(TryInto::try_into).transpose()?
            }
        } else {
            quote! {
                #decoder.try_into()?
            }
        }
    }

    /// Handle default value for a type.
    fn apply_default(&mut self, default: &Path, field_type: &Type) {
        self.decoder = quote! {
            Option::<#field_type>::decode(reader)?.unwrap_or_else(#default);
        };
    }
}

/// AST lowerer for field encoders.
struct LowerFieldEncoder {
    /// Encoder-in-progress.
    encoder: TokenStream,
}

impl LowerFieldEncoder {
    /// Create a new field encoder lowerer.
    fn new(ident: &Ident) -> Self {
        Self {
            encoder: quote!(self.#ident),
        }
    }

    ///  the field encoder to tokens.
    fn into_tokens(self) -> TokenStream {
        self.encoder
    }

    /// Apply the ASN.1 type (if defined).
    fn apply_asn1_type(&mut self, asn1_type: &Asn1Type, optional: bool) {
        let binding = &self.encoder;

        self.encoder = if optional {
            let map_arg = quote!(field);
            let encoder = asn1_type.encoder(&map_arg);

            quote! {
                #binding.as_ref().map(|#map_arg| {
                    der::Result::Ok(#encoder)
                }).transpose()?
            }
        } else {
            let encoder = asn1_type.encoder(binding);
            quote!(#encoder)
        };
    }

    /// Handle default value for a type.
    fn apply_default(&mut self, ident: &Ident, default: &Path, field_type: &Type) {
        let encoder = &self.encoder;

        self.encoder = quote! {
            {
                let default_value: #field_type = #default();
                if &self.#ident == &default_value {
                    None
                } else {
                    Some(#encoder)
                }
            }
        };
    }

    /// Make this field context-specific.
    fn apply_context_specific(
        &mut self,
        tag_number: &TagNumber,
        tag_mode: &TagMode,
        optional: bool,
    ) {
        let encoder = &self.encoder;
        let number_tokens = tag_number.to_tokens();
        let mode_tokens = tag_mode.to_tokens();

        if optional {
            self.encoder = quote! {
                #encoder.as_ref().map(|field| {
                    ::der::asn1::ContextSpecificRef {
                        tag_number: #number_tokens,
                        tag_mode: #mode_tokens,
                        value: field,
                    }
                })
            };
        } else {
            self.encoder = quote! {
                ::der::asn1::ContextSpecificRef {
                    tag_number: #number_tokens,
                    tag_mode: #mode_tokens,
                    value: &#encoder,
                }
            };
        }
    }
}

#[cfg(test)]
mod tests {
    use super::SequenceField;
    use crate::{FieldAttrs, TagMode, TagNumber};
    use proc_macro2::Span;
    use quote::quote;
    use syn::{punctuated::Punctuated, Ident, Path, PathSegment, Type, TypePath};

    /// Create a [`Type::Path`].
    pub fn type_path(ident: Ident) -> Type {
        let mut segments = Punctuated::new();
        segments.push_value(PathSegment {
            ident,
            arguments: Default::default(),
        });

        Type::Path(TypePath {
            qself: None,
            path: Path {
                leading_colon: None,
                segments,
            },
        })
    }

    #[test]
    fn simple() {
        let span = Span::call_site();
        let ident = Ident::new("example_field", span);

        let attrs = FieldAttrs {
            asn1_type: None,
            context_specific: None,
            default: None,
            extensible: false,
            optional: false,
            tag_mode: TagMode::Explicit,
            constructed: false,
        };

        let field_type = Ident::new("String", span);

        let field = SequenceField {
            ident,
            attrs,
            field_type: type_path(field_type),
        };

        assert_eq!(
            field.to_decode_tokens().to_string(),
            quote! {
                let example_field = reader.decode()?;
            }
            .to_string()
        );

        assert_eq!(
            field.to_encode_tokens().to_string(),
            quote! {
                self.example_field
            }
            .to_string()
        );
    }

    #[test]
    fn implicit() {
        let span = Span::call_site();
        let ident = Ident::new("implicit_field", span);

        let attrs = FieldAttrs {
            asn1_type: None,
            context_specific: Some(TagNumber(0)),
            default: None,
            extensible: false,
            optional: false,
            tag_mode: TagMode::Implicit,
            constructed: false,
        };

        let field_type = Ident::new("String", span);

        let field = SequenceField {
            ident,
            attrs,
            field_type: type_path(field_type),
        };

        assert_eq!(
            field.to_decode_tokens().to_string(),
            quote! {
                let implicit_field = ::der::asn1::ContextSpecific::<>::decode_implicit(
                        reader,
                        ::der::TagNumber::N0
                    )?
                    .ok_or_else(|| {
                        der::Tag::ContextSpecific {
                            number: ::der::TagNumber::N0,
                            constructed: false
                        }
                        .value_error()
                    })?
                    .value;
            }
            .to_string()
        );

        assert_eq!(
            field.to_encode_tokens().to_string(),
            quote! {
                ::der::asn1::ContextSpecificRef {
                    tag_number: ::der::TagNumber::N0,
                    tag_mode: ::der::TagMode::Implicit,
                    value: &self.implicit_field,
                }
            }
            .to_string()
        );
    }
}
