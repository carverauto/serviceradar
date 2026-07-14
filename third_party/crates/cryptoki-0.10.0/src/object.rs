// Copyright 2021 Contributors to the Parsec project.
// SPDX-License-Identifier: Apache-2.0
//! Object types (including Attributes)

use crate::error::{Error, Result};
use crate::mechanism::MechanismType;
use crate::types::{Date, Ulong};
use cryptoki_sys::*;
use log::error;
use std::convert::TryFrom;
use std::convert::TryInto;
use std::ffi::c_void;
use std::fmt::Formatter;
use std::mem::size_of;
use std::ops::Deref;

const MAX_CU_ULONG: CK_ULONG = !0;

#[derive(Debug, Copy, Clone, Ord, PartialOrd, Eq, PartialEq, Hash)]
#[non_exhaustive]
/// Type of an attribute
pub enum AttributeType {
    /// DER-encoding of the attribute certificate's issuer
    AcIssuer,
    /// List of mechanisms allowed to be used with the key
    AllowedMechanisms,
    /// Indicates that the user has to supply the PIN for each use with the key
    AlwaysAuthenticate,
    /// Indicates if the key has always had the Sensitive attribute set to true
    AlwaysSensitive,
    /// Description of the application that manages the object
    Application,
    /// BER-encoding of a sequence of object identifier values
    AttrTypes,
    /// Base number value of a key
    Base,
    /// Type of certificate
    CertificateType,
    /// Checksum
    CheckValue,
    /// Type of an object
    Class,
    /// The CRT coefficient `iqmp` of an RSA private key
    Coefficient,
    /// Determines if an object can be copied
    Copyable,
    /// Determines if a key supports decryption
    Decrypt,
    /// Determines if it is possible to derive other keys from the key
    Derive,
    /// Determines if it is possible to destroy an object
    Destroyable,
    /// Parameters defining an elliptic curve
    EcParams,
    /// DER-encoded Elliptic Curve point
    EcPoint,
    /// Determines if a key supports encryption
    Encrypt,
    /// The end date for the object
    EndDate,
    /// The private exponent `dmp1` of an RSA private key
    Exponent1,
    /// The private exponent `dmq1` of an RSA private key
    Exponent2,
    /// Determines if a key is extractable and can be wrapped
    Extractable,
    /// Hash of issuer public key
    HashOfIssuerPublicKey,
    /// Hash of subject public key
    HashOfSubjectPublicKey,
    /// Key identifier for key
    Id,
    /// DER-encoding of the certificate issuer name
    Issuer,
    /// Identifier of the mechanism used to generate the key material
    KeyGenMechanism,
    /// Type of a key
    KeyType,
    /// Description of the object
    Label,
    /// Indicates if the key was generated locally or copied from a locally created object
    Local,
    /// Determines if the object can be modified
    Modifiable,
    /// Modulus value of a key
    Modulus,
    /// Length in bits of the modulus of a key
    ModulusBits,
    /// Indicates if the key has never had the Extractable attribute set to true
    NeverExtractable,
    /// Object ID
    ObjectId,
    /// DER encoding of the attribute certificate's subject field
    Owner,
    /// Prime number value of a key
    Prime,
    /// The prime `p` of an RSA private key
    Prime1,
    /// The prime `q` of an RSA private key
    Prime2,
    /// Determines if the object is private
    Private,
    /// Private exponent `d`
    PrivateExponent,
    /// Public exponent value of a key
    PublicExponent,
    /// DER-encoding of the SubjectPublicKeyInfo
    PublicKeyInfo,
    /// Determines if the key is sensitive
    Sensitive,
    /// DER encoding of the certificate serial number
    SerialNumber,
    /// Determines if a key supports signing
    Sign,
    /// Determines if a key supports signing where the data can be recovered from the signature
    SignRecover,
    /// The start date of the object
    StartDate,
    /// DER-encoding of certificate subject name
    Subject,
    /// Determines if the object is a token object
    Token,
    /// Determines if the object is trusted
    Trusted,
    /// Unique Object Id
    UniqueId,
    /// Determines if a key supports unwrapping
    Unwrap,
    /// Gives the URL where the complete certificate can be obtained
    Url,
    /// Value of the object
    Value,
    /// Length in bytes of the value
    ValueLen,
    /// Vendor defined attribute
    VendorDefined(CK_ATTRIBUTE_TYPE),
    /// Determines if a key supports verifying
    Verify,
    /// Determines if a key supports verifying where the data can be recovered from the signature
    VerifyRecover,
    /// Determines if a key supports wrapping
    Wrap,
    /// Indicates that the key can only be wrapped with a wrapping key that has the Trusted attribute
    WrapWithTrusted,
}

impl AttributeType {
    pub(crate) fn stringify(val: CK_ATTRIBUTE_TYPE) -> String {
        match val {
            CKA_CLASS => String::from(stringify!(CKA_CLASS)),
            CKA_TOKEN => String::from(stringify!(CKA_TOKEN)),
            CKA_PRIVATE => String::from(stringify!(CKA_PRIVATE)),
            CKA_LABEL => String::from(stringify!(CKA_LABEL)),
            CKA_APPLICATION => String::from(stringify!(CKA_APPLICATION)),
            CKA_VALUE => String::from(stringify!(CKA_VALUE)),
            CKA_OBJECT_ID => String::from(stringify!(CKA_OBJECT_ID)),
            CKA_CERTIFICATE_TYPE => String::from(stringify!(CKA_CERTIFICATE_TYPE)),
            CKA_ISSUER => String::from(stringify!(CKA_ISSUER)),
            CKA_SERIAL_NUMBER => String::from(stringify!(CKA_SERIAL_NUMBER)),
            CKA_AC_ISSUER => String::from(stringify!(CKA_AC_ISSUER)),
            CKA_OWNER => String::from(stringify!(CKA_OWNER)),
            CKA_ATTR_TYPES => String::from(stringify!(CKA_ATTR_TYPES)),
            CKA_TRUSTED => String::from(stringify!(CKA_TRUSTED)),
            CKA_CERTIFICATE_CATEGORY => String::from(stringify!(CKA_CERTIFICATE_CATEGORY)),
            CKA_JAVA_MIDP_SECURITY_DOMAIN => {
                String::from(stringify!(CKA_JAVA_MIDP_SECURITY_DOMAIN))
            }
            CKA_URL => String::from(stringify!(CKA_URL)),
            CKA_HASH_OF_SUBJECT_PUBLIC_KEY => {
                String::from(stringify!(CKA_HASH_OF_SUBJECT_PUBLIC_KEY))
            }
            CKA_HASH_OF_ISSUER_PUBLIC_KEY => {
                String::from(stringify!(CKA_HASH_OF_ISSUER_PUBLIC_KEY))
            }
            CKA_NAME_HASH_ALGORITHM => String::from(stringify!(CKA_NAME_HASH_ALGORITHM)),
            CKA_CHECK_VALUE => String::from(stringify!(CKA_CHECK_VALUE)),
            CKA_KEY_TYPE => String::from(stringify!(CKA_KEY_TYPE)),
            CKA_SUBJECT => String::from(stringify!(CKA_SUBJECT)),
            CKA_ID => String::from(stringify!(CKA_ID)),
            CKA_SENSITIVE => String::from(stringify!(CKA_SENSITIVE)),
            CKA_ENCRYPT => String::from(stringify!(CKA_ENCRYPT)),
            CKA_DECRYPT => String::from(stringify!(CKA_DECRYPT)),
            CKA_WRAP => String::from(stringify!(CKA_WRAP)),
            CKA_UNWRAP => String::from(stringify!(CKA_UNWRAP)),
            CKA_SIGN => String::from(stringify!(CKA_SIGN)),
            CKA_SIGN_RECOVER => String::from(stringify!(CKA_SIGN_RECOVER)),
            CKA_VERIFY => String::from(stringify!(CKA_VERIFY)),
            CKA_VERIFY_RECOVER => String::from(stringify!(CKA_VERIFY_RECOVER)),
            CKA_DERIVE => String::from(stringify!(CKA_DERIVE)),
            CKA_START_DATE => String::from(stringify!(CKA_START_DATE)),
            CKA_END_DATE => String::from(stringify!(CKA_END_DATE)),
            CKA_MODULUS => String::from(stringify!(CKA_MODULUS)),
            CKA_MODULUS_BITS => String::from(stringify!(CKA_MODULUS_BITS)),
            CKA_PUBLIC_EXPONENT => String::from(stringify!(CKA_PUBLIC_EXPONENT)),
            CKA_PRIVATE_EXPONENT => String::from(stringify!(CKA_PRIVATE_EXPONENT)),
            CKA_PRIME_1 => String::from(stringify!(CKA_PRIME_1)),
            CKA_PRIME_2 => String::from(stringify!(CKA_PRIME_2)),
            CKA_EXPONENT_1 => String::from(stringify!(CKA_EXPONENT_1)),
            CKA_EXPONENT_2 => String::from(stringify!(CKA_EXPONENT_2)),
            CKA_COEFFICIENT => String::from(stringify!(CKA_COEFFICIENT)),
            CKA_PUBLIC_KEY_INFO => String::from(stringify!(CKA_PUBLIC_KEY_INFO)),
            CKA_PRIME => String::from(stringify!(CKA_PRIME)),
            CKA_SUBPRIME => String::from(stringify!(CKA_SUBPRIME)),
            CKA_BASE => String::from(stringify!(CKA_BASE)),
            CKA_PRIME_BITS => String::from(stringify!(CKA_PRIME_BITS)),
            CKA_SUB_PRIME_BITS => String::from(stringify!(CKA_SUB_PRIME_BITS)),
            CKA_VALUE_BITS => String::from(stringify!(CKA_VALUE_BITS)),
            CKA_VALUE_LEN => String::from(stringify!(CKA_VALUE_LEN)),
            CKA_EXTRACTABLE => String::from(stringify!(CKA_EXTRACTABLE)),
            CKA_LOCAL => String::from(stringify!(CKA_LOCAL)),
            CKA_NEVER_EXTRACTABLE => String::from(stringify!(CKA_NEVER_EXTRACTABLE)),
            CKA_ALWAYS_SENSITIVE => String::from(stringify!(CKA_ALWAYS_SENSITIVE)),
            CKA_KEY_GEN_MECHANISM => String::from(stringify!(CKA_KEY_GEN_MECHANISM)),
            CKA_MODIFIABLE => String::from(stringify!(CKA_MODIFIABLE)),
            CKA_COPYABLE => String::from(stringify!(CKA_COPYABLE)),
            CKA_DESTROYABLE => String::from(stringify!(CKA_DESTROYABLE)),
            CKA_EC_PARAMS => String::from(stringify!(CKA_EC_PARAMS)),
            CKA_EC_POINT => String::from(stringify!(CKA_EC_POINT)),
            CKA_SECONDARY_AUTH => String::from(stringify!(CKA_SECONDARY_AUTH)),
            CKA_AUTH_PIN_FLAGS => String::from(stringify!(CKA_AUTH_PIN_FLAGS)),
            CKA_ALWAYS_AUTHENTICATE => String::from(stringify!(CKA_ALWAYS_AUTHENTICATE)),
            CKA_WRAP_WITH_TRUSTED => String::from(stringify!(CKA_WRAP_WITH_TRUSTED)),
            CKA_OTP_FORMAT => String::from(stringify!(CKA_OTP_FORMAT)),
            CKA_OTP_LENGTH => String::from(stringify!(CKA_OTP_LENGTH)),
            CKA_OTP_TIME_INTERVAL => String::from(stringify!(CKA_OTP_TIME_INTERVAL)),
            CKA_OTP_USER_FRIENDLY_MODE => String::from(stringify!(CKA_OTP_USER_FRIENDLY_MODE)),
            CKA_OTP_CHALLENGE_REQUIREMENT => {
                String::from(stringify!(CKA_OTP_CHALLENGE_REQUIREMENT))
            }
            CKA_OTP_TIME_REQUIREMENT => String::from(stringify!(CKA_OTP_TIME_REQUIREMENT)),
            CKA_OTP_COUNTER_REQUIREMENT => String::from(stringify!(CKA_OTP_COUNTER_REQUIREMENT)),
            CKA_OTP_PIN_REQUIREMENT => String::from(stringify!(CKA_OTP_PIN_REQUIREMENT)),
            CKA_OTP_USER_IDENTIFIER => String::from(stringify!(CKA_OTP_USER_IDENTIFIER)),
            CKA_OTP_SERVICE_IDENTIFIER => String::from(stringify!(CKA_OTP_SERVICE_IDENTIFIER)),
            CKA_OTP_SERVICE_LOGO => String::from(stringify!(CKA_OTP_SERVICE_LOGO)),
            CKA_OTP_SERVICE_LOGO_TYPE => String::from(stringify!(CKA_OTP_SERVICE_LOGO_TYPE)),
            CKA_OTP_COUNTER => String::from(stringify!(CKA_OTP_COUNTER)),
            CKA_OTP_TIME => String::from(stringify!(CKA_OTP_TIME)),
            CKA_GOSTR3410_PARAMS => String::from(stringify!(CKA_GOSTR3410_PARAMS)),
            CKA_GOSTR3411_PARAMS => String::from(stringify!(CKA_GOSTR3411_PARAMS)),
            CKA_GOST28147_PARAMS => String::from(stringify!(CKA_GOST28147_PARAMS)),
            CKA_HW_FEATURE_TYPE => String::from(stringify!(CKA_HW_FEATURE_TYPE)),
            CKA_RESET_ON_INIT => String::from(stringify!(CKA_RESET_ON_INIT)),
            CKA_HAS_RESET => String::from(stringify!(CKA_HAS_RESET)),
            CKA_PIXEL_X => String::from(stringify!(CKA_PIXEL_X)),
            CKA_PIXEL_Y => String::from(stringify!(CKA_PIXEL_Y)),
            CKA_RESOLUTION => String::from(stringify!(CKA_RESOLUTION)),
            CKA_CHAR_ROWS => String::from(stringify!(CKA_CHAR_ROWS)),
            CKA_CHAR_COLUMNS => String::from(stringify!(CKA_CHAR_COLUMNS)),
            CKA_COLOR => String::from(stringify!(CKA_COLOR)),
            CKA_BITS_PER_PIXEL => String::from(stringify!(CKA_BITS_PER_PIXEL)),
            CKA_CHAR_SETS => String::from(stringify!(CKA_CHAR_SETS)),
            CKA_ENCODING_METHODS => String::from(stringify!(CKA_ENCODING_METHODS)),
            CKA_MIME_TYPES => String::from(stringify!(CKA_MIME_TYPES)),
            CKA_MECHANISM_TYPE => String::from(stringify!(CKA_MECHANISM_TYPE)),
            CKA_REQUIRED_CMS_ATTRIBUTES => String::from(stringify!(CKA_REQUIRED_CMS_ATTRIBUTES)),
            CKA_DEFAULT_CMS_ATTRIBUTES => String::from(stringify!(CKA_DEFAULT_CMS_ATTRIBUTES)),
            CKA_SUPPORTED_CMS_ATTRIBUTES => String::from(stringify!(CKA_SUPPORTED_CMS_ATTRIBUTES)),
            CKA_WRAP_TEMPLATE => String::from(stringify!(CKA_WRAP_TEMPLATE)),
            CKA_UNWRAP_TEMPLATE => String::from(stringify!(CKA_UNWRAP_TEMPLATE)),
            CKA_DERIVE_TEMPLATE => String::from(stringify!(CKA_DERIVE_TEMPLATE)),
            CKA_ALLOWED_MECHANISMS => String::from(stringify!(CKA_ALLOWED_MECHANISMS)),
            CKA_UNIQUE_ID => String::from(stringify!(CKA_UNIQUE_ID)),
            CKA_VENDOR_DEFINED..=MAX_CU_ULONG => {
                format!("{}_{}", stringify!(CKA_VENDOR_DEFINED), val)
            }
            _ => format!("unknown ({val:08x})"),
        }
    }
}

impl std::fmt::Display for AttributeType {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        let attrib: CK_ATTRIBUTE_TYPE = (*self).into();
        write!(f, "{}", AttributeType::stringify(attrib))
    }
}

impl From<AttributeType> for CK_ATTRIBUTE_TYPE {
    fn from(attribute_type: AttributeType) -> Self {
        match attribute_type {
            AttributeType::AcIssuer => CKA_AC_ISSUER,
            AttributeType::AllowedMechanisms => CKA_ALLOWED_MECHANISMS,
            AttributeType::AlwaysAuthenticate => CKA_ALWAYS_AUTHENTICATE,
            AttributeType::AlwaysSensitive => CKA_ALWAYS_SENSITIVE,
            AttributeType::Application => CKA_APPLICATION,
            AttributeType::AttrTypes => CKA_ATTR_TYPES,
            AttributeType::Base => CKA_BASE,
            AttributeType::CertificateType => CKA_CERTIFICATE_TYPE,
            AttributeType::CheckValue => CKA_CHECK_VALUE,
            AttributeType::Class => CKA_CLASS,
            AttributeType::Coefficient => CKA_COEFFICIENT,
            AttributeType::Copyable => CKA_COPYABLE,
            AttributeType::Decrypt => CKA_DECRYPT,
            AttributeType::Derive => CKA_DERIVE,
            AttributeType::Destroyable => CKA_DESTROYABLE,
            AttributeType::EcParams => CKA_EC_PARAMS,
            AttributeType::EcPoint => CKA_EC_POINT,
            AttributeType::Encrypt => CKA_ENCRYPT,
            AttributeType::EndDate => CKA_END_DATE,
            AttributeType::Exponent1 => CKA_EXPONENT_1,
            AttributeType::Exponent2 => CKA_EXPONENT_2,
            AttributeType::Extractable => CKA_EXTRACTABLE,
            AttributeType::HashOfIssuerPublicKey => CKA_HASH_OF_ISSUER_PUBLIC_KEY,
            AttributeType::HashOfSubjectPublicKey => CKA_HASH_OF_SUBJECT_PUBLIC_KEY,
            AttributeType::Id => CKA_ID,
            AttributeType::Issuer => CKA_ISSUER,
            AttributeType::KeyGenMechanism => CKA_KEY_GEN_MECHANISM,
            AttributeType::KeyType => CKA_KEY_TYPE,
            AttributeType::Label => CKA_LABEL,
            AttributeType::Local => CKA_LOCAL,
            AttributeType::Modifiable => CKA_MODIFIABLE,
            AttributeType::Modulus => CKA_MODULUS,
            AttributeType::ModulusBits => CKA_MODULUS_BITS,
            AttributeType::NeverExtractable => CKA_NEVER_EXTRACTABLE,
            AttributeType::ObjectId => CKA_OBJECT_ID,
            AttributeType::Owner => CKA_OWNER,
            AttributeType::Prime => CKA_PRIME,
            AttributeType::Prime1 => CKA_PRIME_1,
            AttributeType::Prime2 => CKA_PRIME_2,
            AttributeType::Private => CKA_PRIVATE,
            AttributeType::PrivateExponent => CKA_PRIVATE_EXPONENT,
            AttributeType::PublicExponent => CKA_PUBLIC_EXPONENT,
            AttributeType::PublicKeyInfo => CKA_PUBLIC_KEY_INFO,
            AttributeType::Sensitive => CKA_SENSITIVE,
            AttributeType::SerialNumber => CKA_SERIAL_NUMBER,
            AttributeType::Sign => CKA_SIGN,
            AttributeType::SignRecover => CKA_SIGN_RECOVER,
            AttributeType::StartDate => CKA_START_DATE,
            AttributeType::Subject => CKA_SUBJECT,
            AttributeType::Token => CKA_TOKEN,
            AttributeType::Trusted => CKA_TRUSTED,
            AttributeType::UniqueId => CKA_UNIQUE_ID,
            AttributeType::Unwrap => CKA_UNWRAP,
            AttributeType::Url => CKA_URL,
            AttributeType::Value => CKA_VALUE,
            AttributeType::ValueLen => CKA_VALUE_LEN,
            AttributeType::VendorDefined(val) => val,
            AttributeType::Verify => CKA_VERIFY,
            AttributeType::VerifyRecover => CKA_VERIFY_RECOVER,
            AttributeType::Wrap => CKA_WRAP,
            AttributeType::WrapWithTrusted => CKA_WRAP_WITH_TRUSTED,
        }
    }
}

impl TryFrom<CK_ATTRIBUTE_TYPE> for AttributeType {
    type Error = Error;

    fn try_from(attribute_type: CK_ATTRIBUTE_TYPE) -> Result<Self> {
        match attribute_type {
            CKA_AC_ISSUER => Ok(AttributeType::AcIssuer),
            CKA_ALLOWED_MECHANISMS => Ok(AttributeType::AllowedMechanisms),
            CKA_ALWAYS_AUTHENTICATE => Ok(AttributeType::AlwaysAuthenticate),
            CKA_ALWAYS_SENSITIVE => Ok(AttributeType::AlwaysSensitive),
            CKA_APPLICATION => Ok(AttributeType::Application),
            CKA_ATTR_TYPES => Ok(AttributeType::AttrTypes),
            CKA_BASE => Ok(AttributeType::Base),
            CKA_CERTIFICATE_TYPE => Ok(AttributeType::CertificateType),
            CKA_CHECK_VALUE => Ok(AttributeType::CheckValue),
            CKA_CLASS => Ok(AttributeType::Class),
            CKA_COEFFICIENT => Ok(AttributeType::Coefficient),
            CKA_COPYABLE => Ok(AttributeType::Copyable),
            CKA_DECRYPT => Ok(AttributeType::Decrypt),
            CKA_DERIVE => Ok(AttributeType::Derive),
            CKA_DESTROYABLE => Ok(AttributeType::Destroyable),
            CKA_EC_PARAMS => Ok(AttributeType::EcParams),
            CKA_EC_POINT => Ok(AttributeType::EcPoint),
            CKA_ENCRYPT => Ok(AttributeType::Encrypt),
            CKA_END_DATE => Ok(AttributeType::EndDate),
            CKA_EXPONENT_1 => Ok(AttributeType::Exponent1),
            CKA_EXPONENT_2 => Ok(AttributeType::Exponent2),
            CKA_EXTRACTABLE => Ok(AttributeType::Extractable),
            CKA_HASH_OF_ISSUER_PUBLIC_KEY => Ok(AttributeType::HashOfIssuerPublicKey),
            CKA_HASH_OF_SUBJECT_PUBLIC_KEY => Ok(AttributeType::HashOfSubjectPublicKey),
            CKA_ID => Ok(AttributeType::Id),
            CKA_ISSUER => Ok(AttributeType::Issuer),
            CKA_KEY_GEN_MECHANISM => Ok(AttributeType::KeyGenMechanism),
            CKA_KEY_TYPE => Ok(AttributeType::KeyType),
            CKA_LABEL => Ok(AttributeType::Label),
            CKA_LOCAL => Ok(AttributeType::Local),
            CKA_MODIFIABLE => Ok(AttributeType::Modifiable),
            CKA_MODULUS => Ok(AttributeType::Modulus),
            CKA_MODULUS_BITS => Ok(AttributeType::ModulusBits),
            CKA_NEVER_EXTRACTABLE => Ok(AttributeType::NeverExtractable),
            CKA_OBJECT_ID => Ok(AttributeType::ObjectId),
            CKA_OWNER => Ok(AttributeType::Owner),
            CKA_PRIME => Ok(AttributeType::Prime),
            CKA_PRIME_1 => Ok(AttributeType::Prime1),
            CKA_PRIME_2 => Ok(AttributeType::Prime2),
            CKA_PRIVATE => Ok(AttributeType::Private),
            CKA_PRIVATE_EXPONENT => Ok(AttributeType::PrivateExponent),
            CKA_PUBLIC_EXPONENT => Ok(AttributeType::PublicExponent),
            CKA_PUBLIC_KEY_INFO => Ok(AttributeType::PublicKeyInfo),
            CKA_SENSITIVE => Ok(AttributeType::Sensitive),
            CKA_SERIAL_NUMBER => Ok(AttributeType::SerialNumber),
            CKA_SIGN => Ok(AttributeType::Sign),
            CKA_SIGN_RECOVER => Ok(AttributeType::SignRecover),
            CKA_START_DATE => Ok(AttributeType::StartDate),
            CKA_SUBJECT => Ok(AttributeType::Subject),
            CKA_TOKEN => Ok(AttributeType::Token),
            CKA_TRUSTED => Ok(AttributeType::Trusted),
            CKA_UNIQUE_ID => Ok(AttributeType::UniqueId),
            CKA_UNWRAP => Ok(AttributeType::Unwrap),
            CKA_URL => Ok(AttributeType::Url),
            CKA_VALUE => Ok(AttributeType::Value),
            CKA_VALUE_LEN => Ok(AttributeType::ValueLen),
            CKA_VERIFY => Ok(AttributeType::Verify),
            CKA_VERIFY_RECOVER => Ok(AttributeType::VerifyRecover),
            CKA_WRAP => Ok(AttributeType::Wrap),
            CKA_WRAP_WITH_TRUSTED => Ok(AttributeType::WrapWithTrusted),
            CKA_VENDOR_DEFINED..=MAX_CU_ULONG => Ok(AttributeType::VendorDefined(attribute_type)),
            attr_type => {
                error!("Attribute type {} not supported.", attr_type);
                Err(Error::NotSupported)
            }
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
/// Attribute value
pub enum Attribute {
    /// DER-encoding of the attribute certificate's issuer
    AcIssuer(Vec<u8>),
    /// List of mechanisms allowed to be used with the key
    AllowedMechanisms(Vec<MechanismType>),
    /// Indicates that the user has to supply the PIN for each use with the key
    AlwaysAuthenticate(bool),
    /// Indicates if the key has always had the Sensitive attribute set to true
    AlwaysSensitive(bool),
    /// Description of the application that manages the object
    Application(Vec<u8>),
    /// BER-encoding of a sequence of object identifier values
    AttrTypes(Vec<u8>),
    /// Base number value of a key
    Base(Vec<u8>),
    /// Type of certificate
    CertificateType(CertificateType),
    /// Checksum
    CheckValue(Vec<u8>),
    /// Type of an object
    Class(ObjectClass),
    /// The CRT coefficient `iqmp` of an RSA private key
    Coefficient(Vec<u8>),
    /// Determines if an object can be copied
    Copyable(bool),
    /// Determines if a key supports decryption
    Decrypt(bool),
    /// Determines if it is possible to derive other keys from the key
    Derive(bool),
    /// Determines if it is possible to destroy an object
    Destroyable(bool),
    /// Parameters describing an elliptic curve
    EcParams(Vec<u8>),
    /// Elliptic Curve point
    EcPoint(Vec<u8>),
    /// Determines if a key supports encryption
    Encrypt(bool),
    /// The end date of the object
    EndDate(Date),
    /// The private exponent `dmp1` of an RSA private key
    Exponent1(Vec<u8>),
    /// The private exponent `dmq1` of an RSA private key
    Exponent2(Vec<u8>),
    /// Determines if a key is extractable and can be wrapped
    Extractable(bool),
    /// Hash of issuer public key
    HashOfIssuerPublicKey(Vec<u8>),
    /// Hash of subject public key
    HashOfSubjectPublicKey(Vec<u8>),
    /// Key identifier for key
    Id(Vec<u8>),
    /// DER-encoding of the certificate issuer name
    Issuer(Vec<u8>),
    /// Identifier of the mechanism used to generate the key material
    KeyGenMechanism(MechanismType),
    /// Type of a key
    KeyType(KeyType),
    /// Description of the object
    Label(Vec<u8>),
    /// Indicates if the key was generated locally or copied from a locally created object
    Local(bool),
    /// Determines if the object can be modified
    Modifiable(bool),
    /// Modulus value of a key
    Modulus(Vec<u8>),
    /// Length in bits of the modulus of a key
    ModulusBits(Ulong),
    /// Indicates if the key has never had the Extractable attribute set to true
    NeverExtractable(bool),
    /// Object ID
    ObjectId(Vec<u8>),
    /// DER encoding of the attribute certificate's subject field
    Owner(Vec<u8>),
    /// Prime number value of a key
    Prime(Vec<u8>),
    /// The prime `p` of an RSA private key
    Prime1(Vec<u8>),
    /// The prime `q` of an RSA private key
    Prime2(Vec<u8>),
    /// Determines if the object is private
    Private(bool),
    /// The private exponent `d`
    PrivateExponent(Vec<u8>),
    /// Public exponent value of a key
    PublicExponent(Vec<u8>),
    /// DER-encoding of the SubjectPublicKeyInfo
    PublicKeyInfo(Vec<u8>),
    /// Determines if the key is sensitive
    Sensitive(bool),
    /// DER encoding of the certificate serial number
    SerialNumber(Vec<u8>),
    /// Determines if a key supports signing
    Sign(bool),
    /// Determines if a key supports signing where the data can be recovered from the signature
    SignRecover(bool),
    /// The start date of the object
    StartDate(Date),
    /// DER-encoding of certificate subject name
    Subject(Vec<u8>),
    /// Determines if the object is a token object
    Token(bool),
    /// Determines if an object is trusted
    Trusted(bool),
    /// Unique Object Id
    UniqueId(Vec<u8>),
    /// Determines if a key supports unwrapping
    Unwrap(bool),
    /// Gives the URL where the complete certificate can ber obtained
    Url(Vec<u8>),
    /// Value of the object
    Value(Vec<u8>),
    /// Length in bytes of the value
    ValueLen(Ulong),
    /// Vendor defined value
    VendorDefined((AttributeType, Vec<u8>)),
    /// Determines if a key supports verifying
    Verify(bool),
    /// Determines if a key supports verifying where the data can be recovered from the signature
    VerifyRecover(bool),
    /// Determines if a key supports wrapping
    Wrap(bool),
    /// Indicates that the key can only be wrapped with a wrapping key that has the Trusted attribute
    WrapWithTrusted(bool),
}

impl Attribute {
    /// Get the type of an attribute
    pub fn attribute_type(&self) -> AttributeType {
        match self {
            Attribute::AcIssuer(_) => AttributeType::AcIssuer,
            Attribute::AllowedMechanisms(_) => AttributeType::AllowedMechanisms,
            Attribute::AlwaysAuthenticate(_) => AttributeType::AlwaysAuthenticate,
            Attribute::AlwaysSensitive(_) => AttributeType::AlwaysSensitive,
            Attribute::Application(_) => AttributeType::Application,
            Attribute::AttrTypes(_) => AttributeType::AttrTypes,
            Attribute::Base(_) => AttributeType::Base,
            Attribute::CertificateType(_) => AttributeType::CertificateType,
            Attribute::CheckValue(_) => AttributeType::CheckValue,
            Attribute::Class(_) => AttributeType::Class,
            Attribute::Coefficient(_) => AttributeType::Coefficient,
            Attribute::Copyable(_) => AttributeType::Copyable,
            Attribute::Decrypt(_) => AttributeType::Decrypt,
            Attribute::Derive(_) => AttributeType::Derive,
            Attribute::Destroyable(_) => AttributeType::Destroyable,
            Attribute::EcParams(_) => AttributeType::EcParams,
            Attribute::EcPoint(_) => AttributeType::EcPoint,
            Attribute::Encrypt(_) => AttributeType::Encrypt,
            Attribute::EndDate(_) => AttributeType::EndDate,
            Attribute::Exponent1(_) => AttributeType::Exponent1,
            Attribute::Exponent2(_) => AttributeType::Exponent2,
            Attribute::Extractable(_) => AttributeType::Extractable,
            Attribute::HashOfIssuerPublicKey(_) => AttributeType::HashOfIssuerPublicKey,
            Attribute::HashOfSubjectPublicKey(_) => AttributeType::HashOfSubjectPublicKey,
            Attribute::Id(_) => AttributeType::Id,
            Attribute::Issuer(_) => AttributeType::Issuer,
            Attribute::KeyGenMechanism(_) => AttributeType::KeyGenMechanism,
            Attribute::KeyType(_) => AttributeType::KeyType,
            Attribute::Label(_) => AttributeType::Label,
            Attribute::Local(_) => AttributeType::Local,
            Attribute::Modifiable(_) => AttributeType::Modifiable,
            Attribute::Modulus(_) => AttributeType::Modulus,
            Attribute::ModulusBits(_) => AttributeType::ModulusBits,
            Attribute::NeverExtractable(_) => AttributeType::NeverExtractable,
            Attribute::ObjectId(_) => AttributeType::ObjectId,
            Attribute::Owner(_) => AttributeType::Owner,
            Attribute::Prime(_) => AttributeType::Prime,
            Attribute::Prime1(_) => AttributeType::Prime1,
            Attribute::Prime2(_) => AttributeType::Prime2,
            Attribute::Private(_) => AttributeType::Private,
            Attribute::PrivateExponent(_) => AttributeType::PrivateExponent,
            Attribute::PublicExponent(_) => AttributeType::PublicExponent,
            Attribute::PublicKeyInfo(_) => AttributeType::PublicKeyInfo,
            Attribute::Sensitive(_) => AttributeType::Sensitive,
            Attribute::SerialNumber(_) => AttributeType::SerialNumber,
            Attribute::Sign(_) => AttributeType::Sign,
            Attribute::SignRecover(_) => AttributeType::SignRecover,
            Attribute::StartDate(_) => AttributeType::StartDate,
            Attribute::Subject(_) => AttributeType::Subject,
            Attribute::Token(_) => AttributeType::Token,
            Attribute::Trusted(_) => AttributeType::Trusted,
            Attribute::UniqueId(_) => AttributeType::UniqueId,
            Attribute::Unwrap(_) => AttributeType::Unwrap,
            Attribute::Url(_) => AttributeType::Url,
            Attribute::Value(_) => AttributeType::Value,
            Attribute::ValueLen(_) => AttributeType::ValueLen,
            Attribute::VendorDefined((num, _)) => *num,
            Attribute::Verify(_) => AttributeType::Verify,
            Attribute::VerifyRecover(_) => AttributeType::VerifyRecover,
            Attribute::Wrap(_) => AttributeType::Wrap,
            Attribute::WrapWithTrusted(_) => AttributeType::WrapWithTrusted,
        }
    }

    /// Returns the length in bytes of the objects contained by this CkAttribute.
    fn len(&self) -> usize {
        match self {
            Attribute::AlwaysAuthenticate(_)
            | Attribute::AlwaysSensitive(_)
            | Attribute::Copyable(_)
            | Attribute::Decrypt(_)
            | Attribute::Derive(_)
            | Attribute::Destroyable(_)
            | Attribute::Encrypt(_)
            | Attribute::Extractable(_)
            | Attribute::Local(_)
            | Attribute::Modifiable(_)
            | Attribute::NeverExtractable(_)
            | Attribute::Private(_)
            | Attribute::Sensitive(_)
            | Attribute::Sign(_)
            | Attribute::SignRecover(_)
            | Attribute::Token(_)
            | Attribute::Trusted(_)
            | Attribute::Unwrap(_)
            | Attribute::Verify(_)
            | Attribute::VerifyRecover(_)
            | Attribute::Wrap(_)
            | Attribute::WrapWithTrusted(_) => size_of::<bool>(),
            Attribute::Base(_) => 1,
            Attribute::Application(bytes) | Attribute::Label(bytes) | Attribute::Url(bytes) => {
                size_of::<CK_UTF8CHAR>() * bytes.len()
            }
            Attribute::AcIssuer(bytes) => bytes.len(),
            Attribute::AttrTypes(bytes) => bytes.len(),
            Attribute::CertificateType(_) => size_of::<CK_CERTIFICATE_TYPE>(),
            Attribute::CheckValue(bytes) => bytes.len(),
            Attribute::Class(_) => size_of::<CK_OBJECT_CLASS>(),
            Attribute::Coefficient(bytes) => bytes.len(),
            Attribute::EcParams(bytes) => bytes.len(),
            Attribute::EcPoint(bytes) => bytes.len(),
            Attribute::Exponent1(bytes) => bytes.len(),
            Attribute::Exponent2(bytes) => bytes.len(),
            Attribute::HashOfIssuerPublicKey(bytes) => bytes.len(),
            Attribute::HashOfSubjectPublicKey(bytes) => bytes.len(),
            Attribute::Id(bytes) => bytes.len(),
            Attribute::Issuer(bytes) => bytes.len(),
            Attribute::KeyGenMechanism(_) => size_of::<CK_MECHANISM_TYPE>(),
            Attribute::KeyType(_) => size_of::<CK_KEY_TYPE>(),
            Attribute::Modulus(bytes) => bytes.len(),
            Attribute::ModulusBits(_) => size_of::<CK_ULONG>(),
            Attribute::ObjectId(bytes) => bytes.len(),
            Attribute::Owner(bytes) => bytes.len(),
            Attribute::Prime(bytes) => bytes.len(),
            Attribute::Prime1(bytes) => bytes.len(),
            Attribute::Prime2(bytes) => bytes.len(),
            Attribute::PrivateExponent(bytes) => bytes.len(),
            Attribute::PublicExponent(bytes) => bytes.len(),
            Attribute::PublicKeyInfo(bytes) => bytes.len(),
            Attribute::SerialNumber(bytes) => bytes.len(),
            Attribute::Subject(bytes) => bytes.len(),
            Attribute::UniqueId(bytes) => bytes.len(),
            Attribute::Value(bytes) => bytes.len(),
            Attribute::ValueLen(_) => size_of::<CK_ULONG>(),
            Attribute::EndDate(_) | Attribute::StartDate(_) => size_of::<CK_DATE>(),

            Attribute::AllowedMechanisms(mechanisms) => {
                size_of::<CK_MECHANISM_TYPE>() * mechanisms.len()
            }
            Attribute::VendorDefined((_, bytes)) => bytes.len(),
        }
    }

    /// Returns a CK_VOID_PTR pointing to the object contained by this CkAttribute.
    ///
    /// Casting from an immutable reference to a mutable pointer is kind of unsafe but the
    /// Attribute structure will only be used with PKCS11 functions that do not modify the template
    /// given.
    /// The C_GetAttributeValue function, which is the only one that modifies the template given,
    /// will not use Attribute parameters but return them
    /// directly to the caller.
    fn ptr(&self) -> *mut c_void {
        // Note: bools in Rust are guaranteed to occupy a byte, so
        // &mut bool as a raw pointer will provide the same space
        // needed for CK_BBOOL types. See also:
        // https://doc.rust-lang.org/reference/type-layout.html#primitive-data-layout
        match self {
            // CK_BBOOL
            Attribute::AlwaysAuthenticate(b)
            | Attribute::AlwaysSensitive(b)
            | Attribute::Copyable(b)
            | Attribute::Decrypt(b)
            | Attribute::Derive(b)
            | Attribute::Destroyable(b)
            | Attribute::Encrypt(b)
            | Attribute::Extractable(b)
            | Attribute::Local(b)
            | Attribute::Modifiable(b)
            | Attribute::NeverExtractable(b)
            | Attribute::Private(b)
            | Attribute::Sensitive(b)
            | Attribute::Sign(b)
            | Attribute::SignRecover(b)
            | Attribute::Token(b)
            | Attribute::Trusted(b)
            | Attribute::Unwrap(b)
            | Attribute::Verify(b)
            | Attribute::VerifyRecover(b)
            | Attribute::Wrap(b)
            | Attribute::WrapWithTrusted(b) => b as *const _ as *mut c_void,
            // CK_ULONG
            Attribute::ModulusBits(val) | Attribute::ValueLen(val) => {
                val as *const _ as *mut c_void
            }
            // Vec<u8>
            Attribute::AcIssuer(bytes)
            | Attribute::Application(bytes)
            | Attribute::AttrTypes(bytes)
            | Attribute::Base(bytes)
            | Attribute::CheckValue(bytes)
            | Attribute::Coefficient(bytes)
            | Attribute::EcParams(bytes)
            | Attribute::EcPoint(bytes)
            | Attribute::Exponent1(bytes)
            | Attribute::Exponent2(bytes)
            | Attribute::HashOfIssuerPublicKey(bytes)
            | Attribute::HashOfSubjectPublicKey(bytes)
            | Attribute::Issuer(bytes)
            | Attribute::Label(bytes)
            | Attribute::ObjectId(bytes)
            | Attribute::Prime(bytes)
            | Attribute::Prime1(bytes)
            | Attribute::Prime2(bytes)
            | Attribute::PrivateExponent(bytes)
            | Attribute::PublicExponent(bytes)
            | Attribute::PublicKeyInfo(bytes)
            | Attribute::Modulus(bytes)
            | Attribute::Owner(bytes)
            | Attribute::SerialNumber(bytes)
            | Attribute::Subject(bytes)
            | Attribute::UniqueId(bytes)
            | Attribute::Url(bytes)
            | Attribute::Value(bytes)
            | Attribute::VendorDefined((_, bytes))
            | Attribute::Id(bytes) => bytes.as_ptr() as *mut c_void,
            // Unique types
            Attribute::CertificateType(certificate_type) => {
                certificate_type as *const _ as *mut c_void
            }
            Attribute::Class(object_class) => object_class as *const _ as *mut c_void,
            Attribute::KeyGenMechanism(mech) => mech as *const _ as *mut c_void,
            Attribute::KeyType(key_type) => key_type as *const _ as *mut c_void,
            Attribute::AllowedMechanisms(mechanisms) => mechanisms.as_ptr() as *mut c_void,
            Attribute::EndDate(date) | Attribute::StartDate(date) => {
                date as *const _ as *mut c_void
            }
        }
    }
}

impl From<&Attribute> for CK_ATTRIBUTE {
    fn from(attribute: &Attribute) -> Self {
        Self {
            type_: attribute.attribute_type().into(),
            pValue: attribute.ptr(),
            // The panic should only happen if there is a bug.
            ulValueLen: attribute
                .len()
                .try_into()
                .expect("Can not convert the attribute length value (usize) to a CK_ULONG."),
        }
    }
}

/// Private function standing in for `TryInto<bool>` for `&[u8]`
/// which can't be implemented through the actual trait because
/// it and both types are external to this crate.
/// NB from the specification: "In Cryptoki, the CK_BBOOL data type
/// is a Boolean type that can be true or false. A zero value means
/// false, and a nonzero value means true." so there is no invalid
/// byte value.
fn try_u8_into_bool(slice: &[u8]) -> Result<bool> {
    let as_array: [u8; size_of::<CK_BBOOL>()] = slice.try_into()?;
    let as_byte = CK_BBOOL::from_ne_bytes(as_array);
    Ok(!matches!(as_byte, 0u8))
}

impl TryFrom<CK_ATTRIBUTE> for Attribute {
    type Error = Error;

    fn try_from(attribute: CK_ATTRIBUTE) -> Result<Self> {
        let attr_type = AttributeType::try_from(attribute.type_)?;
        // Cast from c_void to u8
        let val = unsafe {
            std::slice::from_raw_parts(
                attribute.pValue as *const u8,
                attribute.ulValueLen.try_into()?,
            )
        };
        match attr_type {
            // CK_BBOOL
            AttributeType::AlwaysAuthenticate => {
                Ok(Attribute::AlwaysAuthenticate(try_u8_into_bool(val)?))
            }
            AttributeType::AlwaysSensitive => {
                Ok(Attribute::AlwaysSensitive(try_u8_into_bool(val)?))
            }
            AttributeType::Copyable => Ok(Attribute::Copyable(try_u8_into_bool(val)?)),
            AttributeType::Decrypt => Ok(Attribute::Decrypt(try_u8_into_bool(val)?)),
            AttributeType::Derive => Ok(Attribute::Derive(try_u8_into_bool(val)?)),
            AttributeType::Destroyable => Ok(Attribute::Destroyable(try_u8_into_bool(val)?)),
            AttributeType::Encrypt => Ok(Attribute::Encrypt(try_u8_into_bool(val)?)),
            AttributeType::Extractable => Ok(Attribute::Extractable(try_u8_into_bool(val)?)),
            AttributeType::Local => Ok(Attribute::Local(try_u8_into_bool(val)?)),
            AttributeType::Modifiable => Ok(Attribute::Modifiable(try_u8_into_bool(val)?)),
            AttributeType::NeverExtractable => {
                Ok(Attribute::NeverExtractable(try_u8_into_bool(val)?))
            }
            AttributeType::Private => Ok(Attribute::Private(try_u8_into_bool(val)?)),
            AttributeType::Sensitive => Ok(Attribute::Sensitive(try_u8_into_bool(val)?)),
            AttributeType::Sign => Ok(Attribute::Sign(try_u8_into_bool(val)?)),
            AttributeType::SignRecover => Ok(Attribute::SignRecover(try_u8_into_bool(val)?)),
            AttributeType::Token => Ok(Attribute::Token(try_u8_into_bool(val)?)),
            AttributeType::Trusted => Ok(Attribute::Trusted(try_u8_into_bool(val)?)),
            AttributeType::Unwrap => Ok(Attribute::Unwrap(try_u8_into_bool(val)?)),
            AttributeType::Verify => Ok(Attribute::Verify(try_u8_into_bool(val)?)),
            AttributeType::VerifyRecover => Ok(Attribute::VerifyRecover(try_u8_into_bool(val)?)),
            AttributeType::Wrap => Ok(Attribute::Wrap(try_u8_into_bool(val)?)),
            AttributeType::WrapWithTrusted => {
                Ok(Attribute::WrapWithTrusted(try_u8_into_bool(val)?))
            }
            // CK_ULONG
            AttributeType::ModulusBits => Ok(Attribute::ModulusBits(
                CK_ULONG::from_ne_bytes(val.try_into()?).into(),
            )),
            AttributeType::ValueLen => Ok(Attribute::ValueLen(
                CK_ULONG::from_ne_bytes(val.try_into()?).into(),
            )),
            // Vec<u8>
            AttributeType::AcIssuer => Ok(Attribute::AcIssuer(val.to_vec())),
            AttributeType::Application => Ok(Attribute::Application(val.to_vec())),
            AttributeType::AttrTypes => Ok(Attribute::AttrTypes(val.to_vec())),
            AttributeType::Base => Ok(Attribute::Base(val.to_vec())),
            AttributeType::CheckValue => Ok(Attribute::CheckValue(val.to_vec())),
            AttributeType::Coefficient => Ok(Attribute::Coefficient(val.to_vec())),
            AttributeType::EcParams => Ok(Attribute::EcParams(val.to_vec())),
            AttributeType::EcPoint => Ok(Attribute::EcPoint(val.to_vec())),
            AttributeType::Exponent1 => Ok(Attribute::Exponent1(val.to_vec())),
            AttributeType::Exponent2 => Ok(Attribute::Exponent2(val.to_vec())),
            AttributeType::HashOfIssuerPublicKey => {
                Ok(Attribute::HashOfIssuerPublicKey(val.to_vec()))
            }
            AttributeType::HashOfSubjectPublicKey => {
                Ok(Attribute::HashOfSubjectPublicKey(val.to_vec()))
            }
            AttributeType::Issuer => Ok(Attribute::Issuer(val.to_vec())),
            AttributeType::Label => Ok(Attribute::Label(val.to_vec())),
            AttributeType::Prime => Ok(Attribute::Prime(val.to_vec())),
            AttributeType::Prime1 => Ok(Attribute::Prime1(val.to_vec())),
            AttributeType::Prime2 => Ok(Attribute::Prime2(val.to_vec())),
            AttributeType::PrivateExponent => Ok(Attribute::PrivateExponent(val.to_vec())),
            AttributeType::PublicExponent => Ok(Attribute::PublicExponent(val.to_vec())),
            AttributeType::PublicKeyInfo => Ok(Attribute::PublicKeyInfo(val.to_vec())),
            AttributeType::Modulus => Ok(Attribute::Modulus(val.to_vec())),
            AttributeType::ObjectId => Ok(Attribute::ObjectId(val.to_vec())),
            AttributeType::Owner => Ok(Attribute::Owner(val.to_vec())),
            AttributeType::SerialNumber => Ok(Attribute::SerialNumber(val.to_vec())),
            AttributeType::Subject => Ok(Attribute::Subject(val.to_vec())),
            AttributeType::UniqueId => Ok(Attribute::UniqueId(val.to_vec())),
            AttributeType::Url => Ok(Attribute::Url(val.to_vec())),
            AttributeType::Value => Ok(Attribute::Value(val.to_vec())),
            AttributeType::Id => Ok(Attribute::Id(val.to_vec())),
            // Unique types
            AttributeType::CertificateType => Ok(Attribute::CertificateType(
                CK_CERTIFICATE_TYPE::from_ne_bytes(val.try_into()?).try_into()?,
            )),
            AttributeType::Class => Ok(Attribute::Class(
                CK_OBJECT_CLASS::from_ne_bytes(val.try_into()?).try_into()?,
            )),
            AttributeType::KeyGenMechanism => Ok(Attribute::KeyGenMechanism(
                CK_MECHANISM_TYPE::from_ne_bytes(val.try_into()?).try_into()?,
            )),
            AttributeType::KeyType => Ok(Attribute::KeyType(
                CK_KEY_TYPE::from_ne_bytes(val.try_into()?).try_into()?,
            )),
            AttributeType::AllowedMechanisms => {
                let val = unsafe {
                    std::slice::from_raw_parts(
                        attribute.pValue as *const CK_MECHANISM_TYPE,
                        attribute.ulValueLen.try_into()?,
                    )
                };
                let types: Vec<MechanismType> = val
                    .iter()
                    .copied()
                    .map(|t| t.try_into())
                    .collect::<Result<Vec<MechanismType>>>()?;
                Ok(Attribute::AllowedMechanisms(types))
            }
            AttributeType::EndDate => {
                if val.is_empty() {
                    Ok(Attribute::EndDate(Date::new_empty()))
                } else {
                    let date = val.as_ptr() as *const CK_DATE;
                    unsafe {
                        let year = String::from_utf8_lossy(Vec::from((*date).year).as_slice())
                            .trim_end()
                            .to_string();
                        let month = String::from_utf8_lossy(Vec::from((*date).month).as_slice())
                            .trim_end()
                            .to_string();
                        let day = String::from_utf8_lossy(Vec::from((*date).day).as_slice())
                            .trim_end()
                            .to_string();
                        Ok(Attribute::EndDate(Date::new_from_str_slice(
                            year.as_str(),
                            month.as_str(),
                            day.as_str(),
                        )?))
                    }
                }
            }
            AttributeType::StartDate => {
                if val.is_empty() {
                    Ok(Attribute::StartDate(Date::new_empty()))
                } else {
                    let date = val.as_ptr() as *const CK_DATE;
                    unsafe {
                        let year = String::from_utf8_lossy(Vec::from((*date).year).as_slice())
                            .trim_end()
                            .to_string();
                        let month = String::from_utf8_lossy(Vec::from((*date).month).as_slice())
                            .trim_end()
                            .to_string();
                        let day = String::from_utf8_lossy(Vec::from((*date).day).as_slice())
                            .trim_end()
                            .to_string();
                        Ok(Attribute::StartDate(Date::new_from_str_slice(
                            year.as_str(),
                            month.as_str(),
                            day.as_str(),
                        )?))
                    }
                }
            }
            AttributeType::VendorDefined(t) => Ok(Attribute::VendorDefined((
                AttributeType::VendorDefined(t),
                val.to_vec(),
            ))),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
/// Token specific identifier for an object
pub struct ObjectHandle {
    handle: CK_OBJECT_HANDLE,
}

impl ObjectHandle {
    pub(crate) fn new(handle: CK_OBJECT_HANDLE) -> Self {
        ObjectHandle { handle }
    }

    pub(crate) fn handle(&self) -> CK_OBJECT_HANDLE {
        self.handle
    }
}

impl std::fmt::Display for ObjectHandle {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.handle)
    }
}

impl std::fmt::LowerHex for ObjectHandle {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:08x}", self.handle)
    }
}

impl std::fmt::UpperHex for ObjectHandle {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:08X}", self.handle)
    }
}

#[derive(Copy, Debug, Clone, PartialEq, Eq)]
#[repr(transparent)]
/// Identifier of the class of an object
pub struct ObjectClass {
    val: CK_OBJECT_CLASS,
}

impl ObjectClass {
    /// Data objects
    pub const DATA: ObjectClass = ObjectClass { val: CKO_DATA };
    /// Certificate objects
    pub const CERTIFICATE: ObjectClass = ObjectClass {
        val: CKO_CERTIFICATE,
    };
    /// Public key object
    pub const PUBLIC_KEY: ObjectClass = ObjectClass {
        val: CKO_PUBLIC_KEY,
    };
    /// Private key object
    pub const PRIVATE_KEY: ObjectClass = ObjectClass {
        val: CKO_PRIVATE_KEY,
    };
    /// Secret key object
    pub const SECRET_KEY: ObjectClass = ObjectClass {
        val: CKO_SECRET_KEY,
    };
    /// A hardware feature object
    pub const HARDWARE_FEATURE: ObjectClass = ObjectClass {
        val: CKO_HW_FEATURE,
    };
    /// A domain parameters object
    pub const DOMAIN_PARAMETERS: ObjectClass = ObjectClass {
        val: CKO_DOMAIN_PARAMETERS,
    };
    /// A mechanism object
    pub const MECHANISM: ObjectClass = ObjectClass { val: CKO_MECHANISM };
    /// An OTP key object
    pub const OTP_KEY: ObjectClass = ObjectClass { val: CKO_OTP_KEY };

    pub(crate) fn stringify(class: CK_OBJECT_CLASS) -> String {
        match class {
            CKO_DATA => String::from(stringify!(CKO_DATA)),
            CKO_CERTIFICATE => String::from(stringify!(CKO_CERTIFICATE)),
            CKO_PUBLIC_KEY => String::from(stringify!(CKO_PUBLIC_KEY)),
            CKO_PRIVATE_KEY => String::from(stringify!(CKO_PRIVATE_KEY)),
            CKO_SECRET_KEY => String::from(stringify!(CKO_SECRET_KEY)),
            CKO_HW_FEATURE => String::from(stringify!(CKO_HW_FEATURE)),
            CKO_DOMAIN_PARAMETERS => String::from(stringify!(CKO_DOMAIN_PARAMETERS)),
            CKO_MECHANISM => String::from(stringify!(CKO_MECHANISM)),
            CKO_OTP_KEY => String::from(stringify!(CKO_OTP_KEY)),
            _ => format!("unknown ({class:08x})"),
        }
    }
}

impl std::fmt::Display for ObjectClass {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", ObjectClass::stringify(self.val))
    }
}

impl Deref for ObjectClass {
    type Target = CK_OBJECT_CLASS;

    fn deref(&self) -> &Self::Target {
        &self.val
    }
}

impl From<ObjectClass> for CK_OBJECT_CLASS {
    fn from(object_class: ObjectClass) -> Self {
        *object_class
    }
}

impl TryFrom<CK_OBJECT_CLASS> for ObjectClass {
    type Error = Error;

    fn try_from(object_class: CK_OBJECT_CLASS) -> Result<Self> {
        match object_class {
            CKO_DATA => Ok(ObjectClass::DATA),
            CKO_CERTIFICATE => Ok(ObjectClass::CERTIFICATE),
            CKO_PUBLIC_KEY => Ok(ObjectClass::PUBLIC_KEY),
            CKO_PRIVATE_KEY => Ok(ObjectClass::PRIVATE_KEY),
            CKO_SECRET_KEY => Ok(ObjectClass::SECRET_KEY),
            CKO_HW_FEATURE => Ok(ObjectClass::HARDWARE_FEATURE),
            CKO_DOMAIN_PARAMETERS => Ok(ObjectClass::DOMAIN_PARAMETERS),
            CKO_MECHANISM => Ok(ObjectClass::MECHANISM),
            CKO_OTP_KEY => Ok(ObjectClass::OTP_KEY),

            _ => {
                error!("Object class {} is not supported.", object_class);
                Err(Error::NotSupported)
            }
        }
    }
}

#[derive(Debug, Copy, Clone, PartialEq, Eq)]
#[repr(transparent)]
/// Key type
pub struct KeyType {
    val: CK_KEY_TYPE,
}

impl KeyType {
    /// RSA key
    pub const RSA: KeyType = KeyType { val: CKK_RSA };
    /// DSA key
    pub const DSA: KeyType = KeyType { val: CKK_DSA };
    /// DH key
    pub const DH: KeyType = KeyType { val: CKK_DH };
    /// EC key
    pub const EC: KeyType = KeyType { val: CKK_EC };
    /// X9_42_DH key
    pub const X9_42_DH: KeyType = KeyType { val: CKK_X9_42_DH };
    /// KEA key
    pub const KEA: KeyType = KeyType { val: CKK_KEA };
    /// Generic Secret (hmac) key
    pub const GENERIC_SECRET: KeyType = KeyType {
        val: CKK_GENERIC_SECRET,
    };
    /// RC2 key
    pub const RC2: KeyType = KeyType { val: CKK_RC2 };
    /// RC4 key
    pub const RC4: KeyType = KeyType { val: CKK_RC4 };
    /// DES key
    pub const DES: KeyType = KeyType { val: CKK_DES };
    /// DES2 key
    pub const DES2: KeyType = KeyType { val: CKK_DES2 };
    /// DES3 secret
    /// Note that DES3 is deprecated. See <https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-131Ar2.pdf> section 2, p. 6.
    pub const DES3: KeyType = KeyType { val: CKK_DES3 };
    /// CAST key
    pub const CAST: KeyType = KeyType { val: CKK_CAST };
    /// CAST3 key
    pub const CAST3: KeyType = KeyType { val: CKK_CAST3 };
    /// CAST128 key
    pub const CAST128: KeyType = KeyType { val: CKK_CAST128 };
    /// RC5 key
    pub const RC5: KeyType = KeyType { val: CKK_RC5 };
    /// IDEA key
    pub const IDEA: KeyType = KeyType { val: CKK_IDEA };
    /// SKIPJACK key
    pub const SKIPJACK: KeyType = KeyType { val: CKK_SKIPJACK };
    /// BATON key
    pub const BATON: KeyType = KeyType { val: CKK_BATON };
    /// JUNIPER key
    pub const JUNIPER: KeyType = KeyType { val: CKK_JUNIPER };
    /// CDMF key
    pub const CDMF: KeyType = KeyType { val: CKK_CDMF };
    /// AES key
    pub const AES: KeyType = KeyType { val: CKK_AES };
    /// BLOWFISH key
    pub const BLOWFISH: KeyType = KeyType { val: CKK_BLOWFISH };
    /// TWOFISH key
    pub const TWOFISH: KeyType = KeyType { val: CKK_TWOFISH };
    /// SECURID key
    pub const SECURID: KeyType = KeyType { val: CKK_SECURID };
    /// HOTP key
    pub const HOTP: KeyType = KeyType { val: CKK_HOTP };
    /// ACTI key
    pub const ACTI: KeyType = KeyType { val: CKK_ACTI };
    /// CAMELLIA key
    pub const CAMELLIA: KeyType = KeyType { val: CKK_CAMELLIA };
    /// ARIA key
    pub const ARIA: KeyType = KeyType { val: CKK_ARIA };
    /// MD5 HMAC key
    pub const MD5_HMAC: KeyType = KeyType { val: CKK_MD5_HMAC };
    /// SHA1 HMAC key
    pub const SHA_1_HMAC: KeyType = KeyType {
        val: CKK_SHA_1_HMAC,
    };
    /// RIPEMD128 HMAC key
    pub const RIPEMD128_HMAC: KeyType = KeyType {
        val: CKK_RIPEMD128_HMAC,
    };

    /// RIPEMD160 HMAC key
    pub const RIPEMD160_HMAC: KeyType = KeyType {
        val: CKK_RIPEMD160_HMAC,
    };

    /// SHA256 HMAC key
    pub const SHA256_HMAC: KeyType = KeyType {
        val: CKK_SHA256_HMAC,
    };

    /// SHA384 HMAC key
    pub const SHA384_HMAC: KeyType = KeyType {
        val: CKK_SHA256_HMAC,
    };

    /// SHA512 HMAC key
    pub const SHA512_HMAC: KeyType = KeyType {
        val: CKK_SHA256_HMAC,
    };

    /// SHA224 HMAC key
    pub const SHA224_HMAC: KeyType = KeyType {
        val: CKK_SHA256_HMAC,
    };

    /// SEED key
    pub const SEED: KeyType = KeyType { val: CKK_SEED };

    /// GOSTR3410 key
    pub const GOSTR3410: KeyType = KeyType { val: CKK_GOSTR3410 };

    /// GOSTR3411 key
    pub const GOSTR3411: KeyType = KeyType { val: CKK_GOSTR3411 };

    /// GOST28147 key
    pub const GOST28147: KeyType = KeyType { val: CKK_GOST28147 };

    /// EC edwards key
    pub const EC_EDWARDS: KeyType = KeyType {
        val: CKK_EC_EDWARDS,
    };
    /// EC montgomery key
    pub const EC_MONTGOMERY: KeyType = KeyType {
        val: CKK_EC_MONTGOMERY,
    };

    /// HKDF key
    pub const HKDF: KeyType = KeyType { val: CKK_HKDF };

    /// Create vendor defined key type
    ///
    /// # Arguments
    ///
    /// * `val` - The value of vendor defined key type
    ///
    /// # Errors
    ///
    /// If `val` is less then `CKK_VENDOR_DEFINED`, a `Error::InvalidValue` will be returned
    ///
    /// # Examples
    /// ```rust
    /// use cryptoki::object::KeyType;
    /// use cryptoki_sys::CKK_VENDOR_DEFINED;
    ///
    /// let some_key_type: KeyType =
    ///     KeyType::new_vendor_defined(CKK_VENDOR_DEFINED | 0x14).unwrap();
    /// ```
    pub fn new_vendor_defined(val: CK_KEY_TYPE) -> Result<KeyType> {
        if val < CKK_VENDOR_DEFINED {
            Err(Error::InvalidValue)
        } else {
            Ok(KeyType { val })
        }
    }

    fn stringify(key_type: CK_KEY_TYPE) -> String {
        match key_type {
            CKK_RSA => String::from(stringify!(CKK_RSA)),
            CKK_DSA => String::from(stringify!(CKK_DSA)),
            CKK_DH => String::from(stringify!(CKK_DH)),
            CKK_EC => String::from(stringify!(CKK_EC)),
            CKK_X9_42_DH => String::from(stringify!(CKK_X9_42_DH)),
            CKK_KEA => String::from(stringify!(CKK_KEA)),
            CKK_GENERIC_SECRET => String::from(stringify!(CKK_GENERIC_SECRET)),
            CKK_RC2 => String::from(stringify!(CKK_RC2)),
            CKK_RC4 => String::from(stringify!(CKK_RC4)),
            CKK_DES => String::from(stringify!(CKK_DES)),
            CKK_DES2 => String::from(stringify!(CKK_DES2)),
            CKK_DES3 => String::from(stringify!(CKK_DES3)),
            CKK_CAST => String::from(stringify!(CKK_CAST)),
            CKK_CAST3 => String::from(stringify!(CKK_CAST3)),
            CKK_CAST128 => String::from(stringify!(CKK_CAST128)),
            CKK_RC5 => String::from(stringify!(CKK_RC5)),
            CKK_IDEA => String::from(stringify!(CKK_IDEA)),
            CKK_SKIPJACK => String::from(stringify!(CKK_SKIPJACK)),
            CKK_BATON => String::from(stringify!(CKK_BATON)),
            CKK_JUNIPER => String::from(stringify!(CKK_JUNIPER)),
            CKK_CDMF => String::from(stringify!(CKK_CDMF)),
            CKK_AES => String::from(stringify!(CKK_AES)),
            CKK_BLOWFISH => String::from(stringify!(CKK_BLOWFISH)),
            CKK_TWOFISH => String::from(stringify!(CKK_TWOFISH)),
            CKK_SECURID => String::from(stringify!(CKK_SECURID)),
            CKK_HOTP => String::from(stringify!(CKK_HOTP)),
            CKK_ACTI => String::from(stringify!(CKK_ACTI)),
            CKK_CAMELLIA => String::from(stringify!(CKK_CAMELLIA)),
            CKK_ARIA => String::from(stringify!(CKK_ARIA)),
            CKK_MD5_HMAC => String::from(stringify!(CKK_MD5_HMAC)),
            CKK_SHA_1_HMAC => String::from(stringify!(CKK_SHA_1_HMAC)),
            CKK_RIPEMD128_HMAC => String::from(stringify!(CKK_RIPEMD128_HMAC)),
            CKK_RIPEMD160_HMAC => String::from(stringify!(CKK_RIPEMD160_HMAC)),
            CKK_SHA256_HMAC => String::from(stringify!(CKK_SHA256_HMAC)),
            CKK_SHA384_HMAC => String::from(stringify!(CKK_SHA384_HMAC)),
            CKK_SHA512_HMAC => String::from(stringify!(CKK_SHA512_HMAC)),
            CKK_SHA224_HMAC => String::from(stringify!(CKK_SHA224_HMAC)),
            CKK_SEED => String::from(stringify!(CKK_SEED)),
            CKK_GOSTR3410 => String::from(stringify!(CKK_GOSTR3410)),
            CKK_GOSTR3411 => String::from(stringify!(CKK_GOSTR3411)),
            CKK_GOST28147 => String::from(stringify!(CKK_GOST28147)),
            CKK_EC_EDWARDS => String::from(stringify!(CKK_EC_EDWARDS)),
            CKK_EC_MONTGOMERY => String::from(stringify!(CKK_EC_MONTGOMERY)),
            CKK_HKDF => String::from(stringify!(CKK_HKDF)),
            CKK_VENDOR_DEFINED..=MAX_CU_ULONG => String::from(stringify!(key_type)),
            _ => format!("unknown ({key_type:08x})"),
        }
    }
}

impl std::fmt::Display for KeyType {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", KeyType::stringify(self.val))
    }
}

impl Deref for KeyType {
    type Target = CK_KEY_TYPE;

    fn deref(&self) -> &Self::Target {
        &self.val
    }
}

impl From<KeyType> for CK_KEY_TYPE {
    fn from(key_type: KeyType) -> Self {
        *key_type
    }
}

impl TryFrom<CK_KEY_TYPE> for KeyType {
    type Error = Error;

    fn try_from(key_type: CK_KEY_TYPE) -> Result<Self> {
        match key_type {
            CKK_RSA => Ok(KeyType::RSA),
            CKK_DSA => Ok(KeyType::DSA),
            CKK_DH => Ok(KeyType::DH),
            CKK_EC => Ok(KeyType::EC),
            CKK_X9_42_DH => Ok(KeyType::X9_42_DH),
            CKK_KEA => Ok(KeyType::KEA),
            CKK_GENERIC_SECRET => Ok(KeyType::GENERIC_SECRET),
            CKK_RC2 => Ok(KeyType::RC2),
            CKK_RC4 => Ok(KeyType::RC4),
            CKK_DES => Ok(KeyType::DES),
            CKK_DES2 => Ok(KeyType::DES2),
            CKK_DES3 => Ok(KeyType::DES3),
            CKK_CAST => Ok(KeyType::CAST),
            CKK_CAST3 => Ok(KeyType::CAST3),
            CKK_CAST128 => Ok(KeyType::CAST128),
            CKK_RC5 => Ok(KeyType::RC5),
            CKK_IDEA => Ok(KeyType::IDEA),
            CKK_SKIPJACK => Ok(KeyType::SKIPJACK),
            CKK_BATON => Ok(KeyType::BATON),
            CKK_JUNIPER => Ok(KeyType::JUNIPER),
            CKK_CDMF => Ok(KeyType::CDMF),
            CKK_AES => Ok(KeyType::AES),
            CKK_BLOWFISH => Ok(KeyType::BLOWFISH),
            CKK_TWOFISH => Ok(KeyType::TWOFISH),
            CKK_SECURID => Ok(KeyType::SECURID),
            CKK_HOTP => Ok(KeyType::HOTP),
            CKK_ACTI => Ok(KeyType::ACTI),
            CKK_CAMELLIA => Ok(KeyType::CAMELLIA),
            CKK_ARIA => Ok(KeyType::ARIA),
            CKK_MD5_HMAC => Ok(KeyType::MD5_HMAC),
            CKK_SHA_1_HMAC => Ok(KeyType::SHA_1_HMAC),
            CKK_RIPEMD128_HMAC => Ok(KeyType::RIPEMD128_HMAC),
            CKK_RIPEMD160_HMAC => Ok(KeyType::RIPEMD160_HMAC),
            CKK_SHA256_HMAC => Ok(KeyType::SHA256_HMAC),
            CKK_SHA384_HMAC => Ok(KeyType::SHA384_HMAC),
            CKK_SHA512_HMAC => Ok(KeyType::SHA512_HMAC),
            CKK_SHA224_HMAC => Ok(KeyType::SHA224_HMAC),
            CKK_SEED => Ok(KeyType::SEED),
            CKK_GOSTR3410 => Ok(KeyType::GOSTR3410),
            CKK_GOSTR3411 => Ok(KeyType::GOSTR3411),
            CKK_GOST28147 => Ok(KeyType::GOST28147),
            CKK_EC_EDWARDS => Ok(KeyType::EC_EDWARDS),
            CKK_EC_MONTGOMERY => Ok(KeyType::EC_MONTGOMERY),
            CKK_HKDF => Ok(KeyType::HKDF),
            CKK_VENDOR_DEFINED..=MAX_CU_ULONG => KeyType::new_vendor_defined(key_type),
            _ => {
                error!("Key type {} is not supported.", key_type);
                Err(Error::NotSupported)
            }
        }
    }
}

#[derive(Debug, Copy, Clone)]
/// Information about the attribute of an object
pub enum AttributeInfo {
    /// The requested attribute is not a valid attribute for the object
    TypeInvalid,
    /// The value of the attribute is sensitive and will not be returned
    Sensitive,
    /// The attribute is available to get from the object and has the specified size in bytes.
    Available(usize),
    /// The attribute is not available.
    Unavailable,
}

#[derive(Debug, Copy, Clone, PartialEq, Eq)]
#[repr(transparent)]
/// The certificate type
pub struct CertificateType {
    val: CK_CERTIFICATE_TYPE,
}

impl CertificateType {
    /// An X.509 certificate
    pub const X_509: CertificateType = CertificateType { val: CKC_X_509 };
    /// An X.509 attribute certificate
    pub const X_509_ATTR: CertificateType = CertificateType {
        val: CKC_X_509_ATTR_CERT,
    };
    /// A WTLS certificate
    pub const WTLS: CertificateType = CertificateType { val: CKC_WTLS };

    pub(crate) fn stringify(cert_type: CK_CERTIFICATE_TYPE) -> String {
        match cert_type {
            CKC_X_509 => String::from(stringify!(CKC_X_509)),
            CKC_X_509_ATTR_CERT => String::from(stringify!(CKC_X_509_ATTR_CERT)),
            CKC_WTLS => String::from(stringify!(CKC_WTLS)),
            _ => format!("unknown ({cert_type:08x})"),
        }
    }
}

impl std::fmt::Display for CertificateType {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", CertificateType::stringify(self.val))
    }
}

impl Deref for CertificateType {
    type Target = CK_CERTIFICATE_TYPE;

    fn deref(&self) -> &Self::Target {
        &self.val
    }
}

impl From<CertificateType> for CK_CERTIFICATE_TYPE {
    fn from(certificate_type: CertificateType) -> Self {
        *certificate_type
    }
}

impl TryFrom<CK_CERTIFICATE_TYPE> for CertificateType {
    type Error = Error;

    fn try_from(certificate_type: CK_CERTIFICATE_TYPE) -> Result<Self> {
        match certificate_type {
            CKC_X_509 => Ok(CertificateType::X_509),
            CKC_X_509_ATTR_CERT => Ok(CertificateType::X_509_ATTR),
            CKC_WTLS => Ok(CertificateType::WTLS),
            _ => {
                error!("Certificate type {} is not supported.", certificate_type);
                Err(Error::NotSupported)
            }
        }
    }
}
