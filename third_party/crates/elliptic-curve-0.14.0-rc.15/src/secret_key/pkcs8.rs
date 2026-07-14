//! PKCS#8 encoding/decoding support.

use super::SecretKey;
use crate::{
    ALGORITHM_OID, Curve, FieldBytesSize,
    pkcs8::{AssociatedOid, der::Decode},
    sec1::{ModulusSize, ValidatePublicKey},
};
use pkcs8::spki::{AlgorithmIdentifier, AssociatedAlgorithmIdentifier, ObjectIdentifier};
use sec1::EcPrivateKey;

// Imports for the `EncodePrivateKey` impl
#[cfg(all(feature = "alloc", feature = "arithmetic"))]
use {
    crate::{
        AffinePoint, CurveArithmetic,
        sec1::{FromEncodedPoint, ToEncodedPoint},
    },
    pkcs8::{
        EncodePrivateKey,
        der::{self, Encode, asn1::OctetStringRef},
    },
    zeroize::Zeroizing,
};

// Imports for actual PEM support
#[cfg(feature = "pem")]
use {
    crate::{Result, error::Error},
    core::str::FromStr,
    pkcs8::DecodePrivateKey,
};

impl<C> AssociatedAlgorithmIdentifier for SecretKey<C>
where
    C: AssociatedOid + Curve,
{
    type Params = ObjectIdentifier;

    const ALGORITHM_IDENTIFIER: AlgorithmIdentifier<ObjectIdentifier> = AlgorithmIdentifier {
        oid: ALGORITHM_OID,
        parameters: Some(C::OID),
    };
}

impl<C> TryFrom<pkcs8::PrivateKeyInfoRef<'_>> for SecretKey<C>
where
    C: AssociatedOid + Curve + ValidatePublicKey,
    FieldBytesSize<C>: ModulusSize,
{
    type Error = pkcs8::Error;

    fn try_from(private_key_info: pkcs8::PrivateKeyInfoRef<'_>) -> pkcs8::Result<Self> {
        private_key_info
            .algorithm
            .assert_oids(ALGORITHM_OID, C::OID)?;

        Ok(EcPrivateKey::from_der(private_key_info.private_key.as_bytes())?.try_into()?)
    }
}

#[cfg(all(feature = "alloc", feature = "arithmetic"))]
impl<C> EncodePrivateKey for SecretKey<C>
where
    C: AssociatedOid + CurveArithmetic,
    AffinePoint<C>: FromEncodedPoint<C> + ToEncodedPoint<C>,
    FieldBytesSize<C>: ModulusSize,
{
    fn to_pkcs8_der(&self) -> pkcs8::Result<der::SecretDocument> {
        let algorithm_identifier = pkcs8::AlgorithmIdentifierRef {
            oid: ALGORITHM_OID,
            parameters: Some((&C::OID).into()),
        };

        let private_key_bytes = Zeroizing::new(self.to_bytes());
        let public_key_bytes = self.public_key().to_encoded_point(false);

        let ec_private_key = Zeroizing::new(
            EcPrivateKey {
                private_key: &private_key_bytes,
                parameters: None,
                public_key: Some(public_key_bytes.as_bytes()),
            }
            .to_der()?,
        );

        let pkcs8_key = pkcs8::PrivateKeyInfoRef::new(
            algorithm_identifier,
            OctetStringRef::new(&ec_private_key)?,
        );
        Ok(der::SecretDocument::encode_msg(&pkcs8_key)?)
    }
}

#[cfg(feature = "pem")]
impl<C> FromStr for SecretKey<C>
where
    C: Curve + AssociatedOid + ValidatePublicKey,
    FieldBytesSize<C>: ModulusSize,
{
    type Err = Error;

    fn from_str(s: &str) -> Result<Self> {
        Self::from_pkcs8_pem(s).map_err(|_| Error)
    }
}
