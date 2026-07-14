//! Macros used by this crate

/// Implements the following traits for a newtype of a `der` decodable/encodable type:
///
/// - `From` conversions to/from the inner type
/// - `AsRef` and `AsMut`
/// - `DecodeValue` and `EncodeValue`
/// - `FixedTag` mapping to the inner value's `FixedTag::TAG`
///
/// The main case is simplifying newtypes which need an `AssociatedOid`
#[macro_export]
macro_rules! impl_newtype {
    ($newtype:ty, $inner:ty) => {
        #[allow(unused_lifetimes)]
        impl<'a> From<$inner> for $newtype {
            #[inline]
            fn from(value: $inner) -> Self {
                Self(value)
            }
        }

        #[allow(unused_lifetimes)]
        impl<'a> From<$newtype> for $inner {
            #[inline]
            fn from(value: $newtype) -> Self {
                value.0
            }
        }

        #[allow(unused_lifetimes)]
        impl<'a> AsRef<$inner> for $newtype {
            #[inline]
            fn as_ref(&self) -> &$inner {
                &self.0
            }
        }

        #[allow(unused_lifetimes)]
        impl<'a> AsMut<$inner> for $newtype {
            #[inline]
            fn as_mut(&mut self) -> &mut $inner {
                &mut self.0
            }
        }

        #[allow(unused_lifetimes)]
        impl<'a> ::der::FixedTag for $newtype {
            const TAG: ::der::Tag = <$inner as ::der::FixedTag>::TAG;
        }

        impl<'a> ::der::DecodeValue<'a> for $newtype {
            fn decode_value<R: ::der::Reader<'a>>(
                decoder: &mut R,
                header: ::der::Header,
            ) -> ::der::Result<Self> {
                Ok(Self(<$inner as ::der::DecodeValue>::decode_value(
                    decoder, header,
                )?))
            }
        }

        #[allow(unused_lifetimes)]
        impl<'a> ::der::EncodeValue for $newtype {
            fn encode_value(&self, encoder: &mut impl ::der::Writer) -> ::der::Result<()> {
                self.0.encode_value(encoder)
            }

            fn value_len(&self) -> ::der::Result<::der::Length> {
                self.0.value_len()
            }
        }

        #[allow(unused_lifetimes)]
        impl<'a> ::der::ValueOrd for $newtype {
            fn value_cmp(&self, other: &Self) -> ::der::Result<::core::cmp::Ordering> {
                self.0.value_cmp(&other.0)
            }
        }
    };
}

/// Implements the AsExtension traits for every defined Extension paylooad
macro_rules! impl_extension {
    ($newtype:ty) => {
        impl_extension!($newtype, critical = false);
    };
    ($newtype:ty, critical = $critical:expr) => {
        impl crate::ext::AsExtension for $newtype {
            fn critical(
                &self,
                _subject: &crate::name::Name,
                _extensions: &[crate::ext::Extension],
            ) -> bool {
                $critical
            }
        }
    };
}

/// Implements conversions between [`spki::SubjectPublicKeyInfo`] and [`SubjectKeyIdentifier`] or [`AuthorityKeyIdentifier`]
macro_rules! impl_key_identifier {
    ($newtype:ty, $out:expr) => {
        #[cfg(feature = "builder")]
        mod builder_key_identifier {
            use super::*;
            use der::asn1::OctetString;
            use sha1::{Digest, Sha1};
            use spki::SubjectPublicKeyInfoRef;

            impl<'a> TryFrom<SubjectPublicKeyInfoRef<'a>> for $newtype {
                type Error = der::Error;

                fn try_from(issuer: SubjectPublicKeyInfoRef<'a>) -> Result<Self, Self::Error> {
                    // https://datatracker.ietf.org/doc/html/rfc5280#section-4.2.1.2
                    //
                    //  For CA certificates, subject key identifiers SHOULD be derived from
                    //  the public key or a method that generates unique values.  Two common
                    //  methods for generating key identifiers from the public key are:

                    //     (1) The keyIdentifier is composed of the 160-bit SHA-1 hash of the
                    //          value of the BIT STRING subjectPublicKey (excluding the tag,
                    //          length, and number of unused bits).

                    //     (2) The keyIdentifier is composed of a four-bit type field with
                    //          the value 0100 followed by the least significant 60 bits of
                    //          the SHA-1 hash of the value of the BIT STRING
                    //          subjectPublicKey (excluding the tag, length, and number of
                    //          unused bits).

                    // Here we're using the first method

                    let result = Sha1::digest(issuer.subject_public_key.raw_bytes());
                    $out(result.as_slice())
                }
            }
        }
    };
}
