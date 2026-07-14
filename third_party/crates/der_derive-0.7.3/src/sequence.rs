//! Support for deriving the `Sequence` trait on structs for the purposes of
//! decoding/encoding ASN.1 `SEQUENCE` types as mapped to struct fields.

mod field;

use crate::{default_lifetime, TypeAttrs};
use field::SequenceField;
use proc_macro2::TokenStream;
use quote::quote;
use syn::{DeriveInput, GenericParam, Generics, Ident, LifetimeParam};

/// Derive the `Sequence` trait for a struct
pub(crate) struct DeriveSequence {
    /// Name of the sequence struct.
    ident: Ident,

    /// Generics of the struct.
    generics: Generics,

    /// Fields of the struct.
    fields: Vec<SequenceField>,
}

impl DeriveSequence {
    /// Parse [`DeriveInput`].
    pub fn new(input: DeriveInput) -> syn::Result<Self> {
        let data = match input.data {
            syn::Data::Struct(data) => data,
            _ => abort!(
                input.ident,
                "can't derive `Sequence` on this type: only `struct` types are allowed",
            ),
        };

        let type_attrs = TypeAttrs::parse(&input.attrs)?;

        let fields = data
            .fields
            .iter()
            .map(|field| SequenceField::new(field, &type_attrs))
            .collect::<syn::Result<_>>()?;

        Ok(Self {
            ident: input.ident,
            generics: input.generics.clone(),
            fields,
        })
    }

    /// Lower the derived output into a [`TokenStream`].
    pub fn to_tokens(&self) -> TokenStream {
        let ident = &self.ident;
        let mut generics = self.generics.clone();

        // Use the first lifetime parameter as lifetime for Decode/Encode lifetime
        // if none found, add one.
        let lifetime = generics
            .lifetimes()
            .next()
            .map(|lt| lt.lifetime.clone())
            .unwrap_or_else(|| {
                let lt = default_lifetime();
                generics
                    .params
                    .insert(0, GenericParam::Lifetime(LifetimeParam::new(lt.clone())));
                lt
            });

        // We may or may not have inserted a lifetime.
        let (_, ty_generics, where_clause) = self.generics.split_for_impl();
        let (impl_generics, _, _) = generics.split_for_impl();

        let mut decode_body = Vec::new();
        let mut decode_result = Vec::new();
        let mut encoded_lengths = Vec::new();
        let mut encode_fields = Vec::new();

        for field in &self.fields {
            decode_body.push(field.to_decode_tokens());
            decode_result.push(&field.ident);

            let field = field.to_encode_tokens();
            encoded_lengths.push(quote!(#field.encoded_len()?));
            encode_fields.push(quote!(#field.encode(writer)?;));
        }

        quote! {
            impl #impl_generics ::der::DecodeValue<#lifetime> for #ident #ty_generics #where_clause {
                fn decode_value<R: ::der::Reader<#lifetime>>(
                    reader: &mut R,
                    header: ::der::Header,
                ) -> ::der::Result<Self> {
                    use ::der::{Decode as _, DecodeValue as _, Reader as _};

                    reader.read_nested(header.length, |reader| {
                        #(#decode_body)*

                        Ok(Self {
                            #(#decode_result),*
                        })
                    })
                }
            }

            impl #impl_generics ::der::EncodeValue for #ident #ty_generics #where_clause {
                fn value_len(&self) -> ::der::Result<::der::Length> {
                    use ::der::Encode as _;

                    [
                        #(#encoded_lengths),*
                    ]
                        .into_iter()
                        .try_fold(::der::Length::ZERO, |acc, len| acc + len)
                }

                fn encode_value(&self, writer: &mut impl ::der::Writer) -> ::der::Result<()> {
                    use ::der::Encode as _;
                    #(#encode_fields)*
                    Ok(())
                }
            }

            impl #impl_generics ::der::Sequence<#lifetime> for #ident #ty_generics #where_clause {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::DeriveSequence;
    use crate::{Asn1Type, TagMode};
    use syn::parse_quote;

    /// X.509 SPKI `AlgorithmIdentifier`.
    #[test]
    fn algorithm_identifier_example() {
        let input = parse_quote! {
            #[derive(Sequence)]
            pub struct AlgorithmIdentifier<'a> {
                pub algorithm: ObjectIdentifier,
                pub parameters: Option<Any<'a>>,
            }
        };

        let ir = DeriveSequence::new(input).unwrap();
        assert_eq!(ir.ident, "AlgorithmIdentifier");
        assert_eq!(
            ir.generics.lifetimes().next().unwrap().lifetime.to_string(),
            "'a"
        );
        assert_eq!(ir.fields.len(), 2);

        let algorithm_field = &ir.fields[0];
        assert_eq!(algorithm_field.ident, "algorithm");
        assert_eq!(algorithm_field.attrs.asn1_type, None);
        assert_eq!(algorithm_field.attrs.context_specific, None);
        assert_eq!(algorithm_field.attrs.tag_mode, TagMode::Explicit);

        let parameters_field = &ir.fields[1];
        assert_eq!(parameters_field.ident, "parameters");
        assert_eq!(parameters_field.attrs.asn1_type, None);
        assert_eq!(parameters_field.attrs.context_specific, None);
        assert_eq!(parameters_field.attrs.tag_mode, TagMode::Explicit);
    }

    /// X.509 `SubjectPublicKeyInfo`.
    #[test]
    fn spki_example() {
        let input = parse_quote! {
            #[derive(Sequence)]
            pub struct SubjectPublicKeyInfo<'a> {
                pub algorithm: AlgorithmIdentifier<'a>,

                #[asn1(type = "BIT STRING")]
                pub subject_public_key: &'a [u8],
            }
        };

        let ir = DeriveSequence::new(input).unwrap();
        assert_eq!(ir.ident, "SubjectPublicKeyInfo");
        assert_eq!(
            ir.generics.lifetimes().next().unwrap().lifetime.to_string(),
            "'a"
        );
        assert_eq!(ir.fields.len(), 2);

        let algorithm_field = &ir.fields[0];
        assert_eq!(algorithm_field.ident, "algorithm");
        assert_eq!(algorithm_field.attrs.asn1_type, None);
        assert_eq!(algorithm_field.attrs.context_specific, None);
        assert_eq!(algorithm_field.attrs.tag_mode, TagMode::Explicit);

        let subject_public_key_field = &ir.fields[1];
        assert_eq!(subject_public_key_field.ident, "subject_public_key");
        assert_eq!(
            subject_public_key_field.attrs.asn1_type,
            Some(Asn1Type::BitString)
        );
        assert_eq!(subject_public_key_field.attrs.context_specific, None);
        assert_eq!(subject_public_key_field.attrs.tag_mode, TagMode::Explicit);
    }

    /// PKCS#8v2 `OneAsymmetricKey`.
    ///
    /// ```text
    /// OneAsymmetricKey ::= SEQUENCE {
    ///     version                   Version,
    ///     privateKeyAlgorithm       PrivateKeyAlgorithmIdentifier,
    ///     privateKey                PrivateKey,
    ///     attributes            [0] Attributes OPTIONAL,
    ///     ...,
    ///     [[2: publicKey        [1] PublicKey OPTIONAL ]],
    ///     ...
    ///   }
    ///
    /// Version ::= INTEGER { v1(0), v2(1) } (v1, ..., v2)
    ///
    /// PrivateKeyAlgorithmIdentifier ::= AlgorithmIdentifier
    ///
    /// PrivateKey ::= OCTET STRING
    ///
    /// Attributes ::= SET OF Attribute
    ///
    /// PublicKey ::= BIT STRING
    /// ```
    #[test]
    fn pkcs8_example() {
        let input = parse_quote! {
            #[derive(Sequence)]
            pub struct OneAsymmetricKey<'a> {
                pub version: u8,
                pub private_key_algorithm: AlgorithmIdentifier<'a>,
                #[asn1(type = "OCTET STRING")]
                pub private_key: &'a [u8],
                #[asn1(context_specific = "0", extensible = "true", optional = "true")]
                pub attributes: Option<SetOf<Any<'a>, 1>>,
                #[asn1(
                    context_specific = "1",
                    extensible = "true",
                    optional = "true",
                    type = "BIT STRING"
                )]
                pub public_key: Option<&'a [u8]>,
            }
        };

        let ir = DeriveSequence::new(input).unwrap();
        assert_eq!(ir.ident, "OneAsymmetricKey");
        assert_eq!(
            ir.generics.lifetimes().next().unwrap().lifetime.to_string(),
            "'a"
        );
        assert_eq!(ir.fields.len(), 5);

        let version_field = &ir.fields[0];
        assert_eq!(version_field.ident, "version");
        assert_eq!(version_field.attrs.asn1_type, None);
        assert_eq!(version_field.attrs.context_specific, None);
        assert_eq!(version_field.attrs.extensible, false);
        assert_eq!(version_field.attrs.optional, false);
        assert_eq!(version_field.attrs.tag_mode, TagMode::Explicit);

        let algorithm_field = &ir.fields[1];
        assert_eq!(algorithm_field.ident, "private_key_algorithm");
        assert_eq!(algorithm_field.attrs.asn1_type, None);
        assert_eq!(algorithm_field.attrs.context_specific, None);
        assert_eq!(algorithm_field.attrs.extensible, false);
        assert_eq!(algorithm_field.attrs.optional, false);
        assert_eq!(algorithm_field.attrs.tag_mode, TagMode::Explicit);

        let private_key_field = &ir.fields[2];
        assert_eq!(private_key_field.ident, "private_key");
        assert_eq!(
            private_key_field.attrs.asn1_type,
            Some(Asn1Type::OctetString)
        );
        assert_eq!(private_key_field.attrs.context_specific, None);
        assert_eq!(private_key_field.attrs.extensible, false);
        assert_eq!(private_key_field.attrs.optional, false);
        assert_eq!(private_key_field.attrs.tag_mode, TagMode::Explicit);

        let attributes_field = &ir.fields[3];
        assert_eq!(attributes_field.ident, "attributes");
        assert_eq!(attributes_field.attrs.asn1_type, None);
        assert_eq!(
            attributes_field.attrs.context_specific,
            Some("0".parse().unwrap())
        );
        assert_eq!(attributes_field.attrs.extensible, true);
        assert_eq!(attributes_field.attrs.optional, true);
        assert_eq!(attributes_field.attrs.tag_mode, TagMode::Explicit);

        let public_key_field = &ir.fields[4];
        assert_eq!(public_key_field.ident, "public_key");
        assert_eq!(public_key_field.attrs.asn1_type, Some(Asn1Type::BitString));
        assert_eq!(
            public_key_field.attrs.context_specific,
            Some("1".parse().unwrap())
        );
        assert_eq!(public_key_field.attrs.extensible, true);
        assert_eq!(public_key_field.attrs.optional, true);
        assert_eq!(public_key_field.attrs.tag_mode, TagMode::Explicit);
    }

    /// `IMPLICIT` tagged example
    #[test]
    fn implicit_example() {
        let input = parse_quote! {
            #[asn1(tag_mode = "IMPLICIT")]
            pub struct ImplicitSequence<'a> {
                #[asn1(context_specific = "0", type = "BIT STRING")]
                bit_string: BitString<'a>,

                #[asn1(context_specific = "1", type = "GeneralizedTime")]
                time: GeneralizedTime,

                #[asn1(context_specific = "2", type = "UTF8String")]
                utf8_string: String,
            }
        };

        let ir = DeriveSequence::new(input).unwrap();
        assert_eq!(ir.ident, "ImplicitSequence");
        assert_eq!(
            ir.generics.lifetimes().next().unwrap().lifetime.to_string(),
            "'a"
        );
        assert_eq!(ir.fields.len(), 3);

        let bit_string = &ir.fields[0];
        assert_eq!(bit_string.ident, "bit_string");
        assert_eq!(bit_string.attrs.asn1_type, Some(Asn1Type::BitString));
        assert_eq!(
            bit_string.attrs.context_specific,
            Some("0".parse().unwrap())
        );
        assert_eq!(bit_string.attrs.tag_mode, TagMode::Implicit);

        let time = &ir.fields[1];
        assert_eq!(time.ident, "time");
        assert_eq!(time.attrs.asn1_type, Some(Asn1Type::GeneralizedTime));
        assert_eq!(time.attrs.context_specific, Some("1".parse().unwrap()));
        assert_eq!(time.attrs.tag_mode, TagMode::Implicit);

        let utf8_string = &ir.fields[2];
        assert_eq!(utf8_string.ident, "utf8_string");
        assert_eq!(utf8_string.attrs.asn1_type, Some(Asn1Type::Utf8String));
        assert_eq!(
            utf8_string.attrs.context_specific,
            Some("2".parse().unwrap())
        );
        assert_eq!(utf8_string.attrs.tag_mode, TagMode::Implicit);
    }
}
