//! Attribute-related types used by the proc macro

use crate::{Asn1Type, Tag, TagMode, TagNumber};
use proc_macro2::{Span, TokenStream};
use quote::quote;
use std::{fmt::Debug, str::FromStr};
use syn::punctuated::Punctuated;
use syn::{parse::Parse, parse::ParseStream, Attribute, Ident, LitStr, Path, Token};

/// Attribute name.
pub(crate) const ATTR_NAME: &str = "asn1";

/// Attributes on a `struct` or `enum` type.
#[derive(Clone, Debug, Default)]
pub(crate) struct TypeAttrs {
    /// Tagging mode for this type: `EXPLICIT` or `IMPLICIT`, supplied as
    /// `#[asn1(tag_mode = "...")]`.
    ///
    /// The default value is `EXPLICIT`.
    pub tag_mode: TagMode,
}

impl TypeAttrs {
    /// Parse attributes from a struct field or enum variant.
    pub fn parse(attrs: &[Attribute]) -> syn::Result<Self> {
        let mut tag_mode = None;

        let mut parsed_attrs = Vec::new();
        AttrNameValue::from_attributes(attrs, &mut parsed_attrs)?;

        for attr in parsed_attrs {
            // `tag_mode = "..."` attribute
            let mode = attr.parse_value("tag_mode")?.ok_or_else(|| {
                syn::Error::new_spanned(
                    &attr.name,
                    "invalid `asn1` attribute (valid options are `tag_mode`)",
                )
            })?;

            if tag_mode.is_some() {
                return Err(syn::Error::new_spanned(
                    &attr.name,
                    "duplicate ASN.1 `tag_mode` attribute",
                ));
            }

            tag_mode = Some(mode);
        }

        Ok(Self {
            tag_mode: tag_mode.unwrap_or_default(),
        })
    }
}

/// Field-level attributes.
#[derive(Clone, Debug, Default)]
pub(crate) struct FieldAttrs {
    /// Value of the `#[asn1(type = "...")]` attribute if provided.
    pub asn1_type: Option<Asn1Type>,

    /// Value of the `#[asn1(context_specific = "...")] attribute if provided.
    pub context_specific: Option<TagNumber>,

    /// Indicates name of function that supplies the default value, which will be used in cases
    /// where encoding is omitted per DER and to omit the encoding per DER
    pub default: Option<Path>,

    /// Is this field "extensible", i.e. preceded by the `...` extensibility marker?
    pub extensible: bool,

    /// Is this field `OPTIONAL`?
    pub optional: bool,

    /// Tagging mode for this type: `EXPLICIT` or `IMPLICIT`, supplied as
    /// `#[asn1(tag_mode = "...")]`.
    ///
    /// Inherits from the type-level tagging mode if specified, or otherwise
    /// defaults to `EXPLICIT`.
    pub tag_mode: TagMode,

    /// Is the inner type constructed?
    pub constructed: bool,
}

impl FieldAttrs {
    /// Return true when either an optional or default ASN.1 attribute is associated
    /// with a field. Default signifies optionality due to omission of default values in
    /// DER encodings.
    fn is_optional(&self) -> bool {
        self.optional || self.default.is_some()
    }

    /// Parse attributes from a struct field or enum variant.
    pub fn parse(attrs: &[Attribute], type_attrs: &TypeAttrs) -> syn::Result<Self> {
        let mut asn1_type = None;
        let mut context_specific = None;
        let mut default = None;
        let mut extensible = None;
        let mut optional = None;
        let mut tag_mode = None;
        let mut constructed = None;

        let mut parsed_attrs = Vec::new();
        AttrNameValue::from_attributes(attrs, &mut parsed_attrs)?;

        for attr in parsed_attrs {
            // `context_specific = "..."` attribute
            if let Some(tag_number) = attr.parse_value("context_specific")? {
                if context_specific.is_some() {
                    abort!(attr.name, "duplicate ASN.1 `context_specific` attribute");
                }

                context_specific = Some(tag_number);
            // `default` attribute
            } else if attr.parse_value::<String>("default")?.is_some() {
                if default.is_some() {
                    abort!(attr.name, "duplicate ASN.1 `default` attribute");
                }

                default = Some(attr.value.parse().map_err(|e| {
                    syn::Error::new_spanned(
                        attr.value,
                        format_args!("error parsing ASN.1 `default` attribute: {e}"),
                    )
                })?);
            // `extensible` attribute
            } else if let Some(ext) = attr.parse_value("extensible")? {
                if extensible.is_some() {
                    abort!(attr.name, "duplicate ASN.1 `extensible` attribute");
                }

                extensible = Some(ext);
            // `optional` attribute
            } else if let Some(opt) = attr.parse_value("optional")? {
                if optional.is_some() {
                    abort!(attr.name, "duplicate ASN.1 `optional` attribute");
                }

                optional = Some(opt);
            // `tag_mode` attribute
            } else if let Some(mode) = attr.parse_value("tag_mode")? {
                if tag_mode.is_some() {
                    abort!(attr.name, "duplicate ASN.1 `tag_mode` attribute");
                }

                tag_mode = Some(mode);
            // `type = "..."` attribute
            } else if let Some(ty) = attr.parse_value("type")? {
                if asn1_type.is_some() {
                    abort!(attr.name, "duplicate ASN.1 `type` attribute");
                }

                asn1_type = Some(ty);
            // `constructed = "..."` attribute
            } else if let Some(ty) = attr.parse_value("constructed")? {
                if constructed.is_some() {
                    abort!(attr.name, "duplicate ASN.1 `constructed` attribute");
                }

                constructed = Some(ty);
            } else {
                abort!(
                    attr.name,
                    "unknown field-level `asn1` attribute \
                    (valid options are `context_specific`, `type`)",
                );
            }
        }

        Ok(Self {
            asn1_type,
            context_specific,
            default,
            extensible: extensible.unwrap_or_default(),
            optional: optional.unwrap_or_default(),
            tag_mode: tag_mode.unwrap_or(type_attrs.tag_mode),
            constructed: constructed.unwrap_or_default(),
        })
    }

    /// Get the expected [`Tag`] for this field.
    pub fn tag(&self) -> syn::Result<Option<Tag>> {
        match self.context_specific {
            Some(tag_number) => Ok(Some(Tag::ContextSpecific {
                constructed: self.constructed,
                number: tag_number,
            })),

            None => match self.tag_mode {
                TagMode::Explicit => Ok(self.asn1_type.map(Tag::Universal)),
                TagMode::Implicit => Err(syn::Error::new(
                    Span::call_site(),
                    "implicit tagging requires a `tag_number`",
                )),
            },
        }
    }

    /// Get a `der::Decoder` object which respects these field attributes.
    pub fn decoder(&self) -> TokenStream {
        if let Some(tag_number) = self.context_specific {
            let type_params = self.asn1_type.map(|ty| ty.type_path()).unwrap_or_default();
            let tag_number = tag_number.to_tokens();

            let context_specific = match self.tag_mode {
                TagMode::Explicit => {
                    if self.extensible || self.is_optional() {
                        quote! {
                            ::der::asn1::ContextSpecific::<#type_params>::decode_explicit(
                                reader,
                                #tag_number
                            )?
                        }
                    } else {
                        quote! {
                            match ::der::asn1::ContextSpecific::<#type_params>::decode(reader)? {
                                field if field.tag_number == #tag_number => Some(field),
                                _ => None
                            }
                        }
                    }
                }
                TagMode::Implicit => {
                    quote! {
                        ::der::asn1::ContextSpecific::<#type_params>::decode_implicit(
                            reader,
                            #tag_number
                        )?
                    }
                }
            };

            if self.is_optional() {
                if let Some(default) = &self.default {
                    quote!(#context_specific.map(|cs| cs.value).unwrap_or_else(#default))
                } else {
                    quote!(#context_specific.map(|cs| cs.value))
                }
            } else {
                // TODO(tarcieri): better error handling?
                let constructed = self.constructed;
                quote! {
                    #context_specific.ok_or_else(|| {
                        der::Tag::ContextSpecific {
                            number: #tag_number,
                            constructed: #constructed
                        }.value_error()
                    })?.value
                }
            }
        } else if let Some(default) = &self.default {
            let type_params = self.asn1_type.map(|ty| ty.type_path()).unwrap_or_default();
            self.asn1_type.map(|ty| ty.decoder()).unwrap_or_else(|| {
                quote! {
                    Option::<#type_params>::decode(reader)?.unwrap_or_else(#default),
                }
            })
        } else {
            self.asn1_type
                .map(|ty| ty.decoder())
                .unwrap_or_else(|| quote!(reader.decode()?))
        }
    }

    /// Get tokens to encode the binding using `::der::EncodeValue`.
    pub fn value_encode(&self, binding: &TokenStream) -> TokenStream {
        match self.context_specific {
            Some(tag_number) => {
                let tag_number = tag_number.to_tokens();
                let tag_mode = self.tag_mode.to_tokens();
                quote! {
                    ::der::asn1::ContextSpecificRef {
                        tag_number: #tag_number,
                        tag_mode: #tag_mode,
                        value: #binding,
                    }.encode_value(encoder)
                }
            }

            None => self
                .asn1_type
                .map(|ty| {
                    let encoder_obj = ty.encoder(binding);
                    quote!(#encoder_obj.encode_value(encoder))
                })
                .unwrap_or_else(|| quote!(#binding.encode_value(encoder))),
        }
    }
}

/// Name/value pair attribute.
pub(crate) struct AttrNameValue {
    /// Attribute name.
    pub name: Path,

    /// Attribute value.
    pub value: LitStr,
}

impl Parse for AttrNameValue {
    fn parse(input: ParseStream<'_>) -> syn::Result<Self> {
        let name = match input.parse() {
            Ok(name) => name,
            // If it doesn't parse as a path, check if it's the keyword `type`
            // The asn1 macro uses this even though Path cannot technically contain
            // non-identifiers, so it needs to be forced in.
            Err(e) => {
                if let Ok(tok) = input.parse::<Token![type]>() {
                    Path::from(Ident::new("type", tok.span))
                } else {
                    // If it still doesn't parse, report the original error rather than the
                    // one produced by the workaround.
                    return Err(e);
                }
            }
        };
        input.parse::<Token![=]>()?;
        let value = input.parse()?;
        Ok(Self { name, value })
    }
}

impl AttrNameValue {
    pub fn parse_attribute(attr: &Attribute) -> syn::Result<impl IntoIterator<Item = Self>> {
        attr.parse_args_with(Punctuated::<Self, Token![,]>::parse_terminated)
    }

    /// Parse a slice of attributes.
    pub fn from_attributes(attrs: &[Attribute], out: &mut Vec<Self>) -> syn::Result<()> {
        for attr in attrs {
            if !attr.path().is_ident(ATTR_NAME) {
                continue;
            }

            match Self::parse_attribute(attr) {
                Ok(parsed) => out.extend(parsed),
                Err(e) => abort!(attr, e),
            }
        }

        Ok(())
    }

    /// Parse an attribute value if the name matches the specified one.
    pub fn parse_value<T>(&self, name: &str) -> syn::Result<Option<T>>
    where
        T: FromStr + Debug,
        T::Err: Debug,
    {
        Ok(if self.name.is_ident(name) {
            Some(
                self.value
                    .value()
                    .parse()
                    .map_err(|_| syn::Error::new_spanned(&self.name, "error parsing attribute"))?,
            )
        } else {
            None
        })
    }
}
