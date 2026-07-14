// Copyright 2021 Contributors to the Parsec project.
// SPDX-License-Identifier: Apache-2.0
//! Data types for mechanisms

pub mod aead;
pub mod eddsa;
pub mod ekdf;
pub mod elliptic_curve;
pub mod hkdf;
pub mod kbkdf;
mod mechanism_info;
pub mod rsa;
pub mod vendor_defined;

use cryptoki_sys::*;
use log::error;
use std::convert::{TryFrom, TryInto};
use std::ffi::c_void;
use std::fmt::Formatter;
use std::mem::size_of;
use std::ops::Deref;
use std::ptr::null_mut;
use vendor_defined::VendorDefinedMechanism;

use crate::error::Error;
use crate::mechanism::rsa::PkcsOaepParams;
pub use mechanism_info::MechanismInfo;

#[derive(Copy, Debug, Clone, PartialEq, Eq)]
// transparent so that a vector of MechanismType should have the same layout than a vector of
// CK_MECHANISM_TYPE.
/// Type of a mechanism
#[repr(transparent)]
pub struct MechanismType {
    val: CK_MECHANISM_TYPE,
}

impl MechanismType {
    // AES
    /// AES key generation mechanism
    pub const AES_KEY_GEN: MechanismType = MechanismType {
        val: CKM_AES_KEY_GEN,
    };
    /// AES-CBC mechanism
    ///
    /// For encryption, the message length must be a multiple of the block
    /// size.  For wrapping, the mechanism encrypts the value of the key,
    /// padded on the trailing end with up to block size minus one null bytes.
    /// For unwrapping, the result is truncated according to the key type and
    /// the length provided by the template.
    pub const AES_CBC: MechanismType = MechanismType { val: CKM_AES_CBC };
    /// AES-CBC with PKCS#7 padding mechanism
    ///
    /// The plaintext may be any size.  The PKCS#7 padding allows the length of
    /// the plaintext to be recovered from the ciphertext.  Therefore no length
    /// should be provided when unwrapping keys with this mechanism.
    pub const AES_CBC_PAD: MechanismType = MechanismType {
        val: CKM_AES_CBC_PAD,
    };
    /// AES-ECB mechanism
    pub const AES_ECB: MechanismType = MechanismType { val: CKM_AES_ECB };
    /// AES key wrap mechanism.  This mechanism can only wrap a key or encrypt a block of data
    /// whose length is a multiple of the AES Key Wrap algorithm block size.
    pub const AES_KEY_WRAP: MechanismType = MechanismType {
        val: CKM_AES_KEY_WRAP,
    };
    /// AES key wrap mechanism.  This mechanism can wrap a key or encrypt a block of data of any
    /// length.  It does the padding detailed in PKCS#7 of inputs.
    pub const AES_KEY_WRAP_PAD: MechanismType = MechanismType {
        val: CKM_AES_KEY_WRAP_PAD,
    };
    /// AES-CTR mechanism
    pub const AES_CTR: MechanismType = MechanismType { val: CKM_AES_CTR };
    /// AES-GCM mechanism
    pub const AES_GCM: MechanismType = MechanismType { val: CKM_AES_GCM };

    /// Derivation via encryption
    pub const AES_CBC_ENCRYPT_DATA: MechanismType = MechanismType {
        val: CKM_AES_CBC_ENCRYPT_DATA,
    };

    /// AES-CMAC mechanism (See RFC 4493)
    pub const AES_CMAC: MechanismType = MechanismType { val: CKM_AES_CMAC };

    /// AES-CFB128 mechanism
    pub const AES_CFB128: MechanismType = MechanismType {
        val: CKM_AES_CFB128,
    };

    // RSA
    /// PKCS #1 RSA key pair generation mechanism
    pub const RSA_PKCS_KEY_PAIR_GEN: MechanismType = MechanismType {
        val: CKM_RSA_PKCS_KEY_PAIR_GEN,
    };
    /// Multi-purpose mechanism based on the RSA public-key cryptosystem and the block formats
    /// initially defined in PKCS #1 v1.5
    pub const RSA_PKCS: MechanismType = MechanismType { val: CKM_RSA_PKCS };
    /// Mechanism based on the RSA public-key cryptosystem and the PSS block format defined in PKCS
    /// #1
    pub const RSA_PKCS_PSS: MechanismType = MechanismType {
        val: CKM_RSA_PKCS_PSS,
    };

    /// Multi-purpose mechanism based on the RSA public-key cryptosystem and the OAEP block format
    /// defined in PKCS #1
    pub const RSA_PKCS_OAEP: MechanismType = MechanismType {
        val: CKM_RSA_PKCS_OAEP,
    };
    /// Multi-purpose mechanism based on the RSA public-key cryptosystem.  This is so-called "raw"
    /// RSA, as assumed in X.509.
    pub const RSA_X_509: MechanismType = MechanismType { val: CKM_RSA_X_509 };

    // DES
    /// DES
    /// Note that DES is deprecated. See <https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-131Ar2.pdf> section 2, p. 6.
    pub const DES_KEY_GEN: MechanismType = MechanismType {
        val: CKM_DES_KEY_GEN,
    };
    /// DES2
    /// Note that DES2 is deprecated. See <https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-131Ar2.pdf> section 2, p. 6.
    pub const DES2_KEY_GEN: MechanismType = MechanismType {
        val: CKM_DES2_KEY_GEN,
    };
    /// DES3
    /// Note that DES3 is deprecated. See <https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-131Ar2.pdf> section 2, p. 6.
    pub const DES3_KEY_GEN: MechanismType = MechanismType {
        val: CKM_DES3_KEY_GEN,
    };
    /// DES-CBC mechanism.
    ///
    /// For encryption, the message length must be a multiple of the block
    /// size.  For wrapping, the mechanism encrypts the value of the key,
    /// padded on the trailing end with up to block size minus one null bytes.
    /// For unwrapping, the result is truncated according to the key type and
    /// the length provided by the template.
    pub const DES_CBC: MechanismType = MechanismType { val: CKM_DES_CBC };
    /// DES3-CBC mechanism.
    ///
    /// For encryption, the message length must be a multiple of the block
    /// size.  For wrapping, the mechanism encrypts the value of the key,
    /// padded on the trailing end with up to block size minus one null bytes.
    /// For unwrapping, the result is truncated according to the key type and
    /// the length provided by the template.
    pub const DES3_CBC: MechanismType = MechanismType { val: CKM_DES3_CBC };
    /// DES-CBC with PKCS#7 padding mechanism
    ///
    /// The plaintext may be any size.  The PKCS#7 padding allows the length of
    /// the plaintext to be recovered from the ciphertext.  Therefore no length
    /// should be provided when unwrapping keys with this mechanism.
    pub const DES_CBC_PAD: MechanismType = MechanismType {
        val: CKM_DES_CBC_PAD,
    };
    /// DES3-CBC with PKCS#7 padding mechanism
    ///
    /// The plaintext may be any size.  The PKCS#7 padding allows the length of
    /// the plaintext to be recovered from the ciphertext.  Therefore no length
    /// should be provided when unwrapping keys with this mechanism.
    pub const DES3_CBC_PAD: MechanismType = MechanismType {
        val: CKM_DES3_CBC_PAD,
    };
    /// DES ECB
    /// Note that DES is deprecated. See <https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-131Ar2.pdf> section 2, p. 6.
    pub const DES_ECB: MechanismType = MechanismType { val: CKM_DES_ECB };
    /// DES3 ECB
    /// Note that DES3 is deprecated. See <https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-131Ar2.pdf> section 2, p. 6.
    pub const DES3_ECB: MechanismType = MechanismType { val: CKM_DES3_ECB };

    // ECC
    /// EC key pair generation mechanism
    pub const ECC_KEY_PAIR_GEN: MechanismType = MechanismType {
        val: CKM_EC_KEY_PAIR_GEN,
    };
    /// EC edwards key pair generation mechanism
    pub const ECC_EDWARDS_KEY_PAIR_GEN: MechanismType = MechanismType {
        val: CKM_EC_EDWARDS_KEY_PAIR_GEN,
    };
    /// EC montgomery key pair generation mechanism
    pub const ECC_MONTGOMERY_KEY_PAIR_GEN: MechanismType = MechanismType {
        val: CKM_EC_MONTGOMERY_KEY_PAIR_GEN,
    };

    /// EDDSA mechanism
    ///
    /// Note: EdDSA is not part of the PKCS#11 v2.40 standard and as
    /// such may not be understood by the backend. It is included here
    /// because some vendor implementations support it through the
    /// v2.40 interface.
    pub const EDDSA: MechanismType = MechanismType { val: CKM_EDDSA };
    /// ECDH key derivation mechanism
    pub const ECDH1_DERIVE: MechanismType = MechanismType {
        val: CKM_ECDH1_DERIVE,
    };

    /// ECDSA mechanism
    pub const ECDSA: MechanismType = MechanismType { val: CKM_ECDSA };
    /// ECDSA with SHA-1 mechanism
    pub const ECDSA_SHA1: MechanismType = MechanismType {
        val: CKM_ECDSA_SHA1,
    };
    /// ECDSA with SHA-224 mechanism
    pub const ECDSA_SHA224: MechanismType = MechanismType {
        val: CKM_ECDSA_SHA224,
    };
    /// ECDSA with SHA-256 mechanism
    pub const ECDSA_SHA256: MechanismType = MechanismType {
        val: CKM_ECDSA_SHA256,
    };
    /// ECDSA with SHA-384 mechanism
    pub const ECDSA_SHA384: MechanismType = MechanismType {
        val: CKM_ECDSA_SHA384,
    };
    /// ECDSA with SHA-512 mechanism
    pub const ECDSA_SHA512: MechanismType = MechanismType {
        val: CKM_ECDSA_SHA512,
    };

    // SHA-n
    /// SHA-1 mechanism
    pub const SHA1: MechanismType = MechanismType { val: CKM_SHA_1 };
    /// SHA-224 mechanism
    pub const SHA224: MechanismType = MechanismType { val: CKM_SHA224 };
    /// SHA-256 mechanism
    pub const SHA256: MechanismType = MechanismType { val: CKM_SHA256 };
    /// SHA-384 mechanism
    pub const SHA384: MechanismType = MechanismType { val: CKM_SHA384 };
    /// SHA-512 mechanism
    pub const SHA512: MechanismType = MechanismType { val: CKM_SHA512 };

    // SHAn-RSA-PKCS
    /// SHA1-RSA-PKCS mechanism
    pub const SHA1_RSA_PKCS: MechanismType = MechanismType {
        val: CKM_SHA1_RSA_PKCS,
    };
    /// SHA224-RSA-PKCS mechanism
    pub const SHA224_RSA_PKCS: MechanismType = MechanismType {
        val: CKM_SHA224_RSA_PKCS,
    };
    /// SHA256-RSA-PKCS mechanism
    pub const SHA256_RSA_PKCS: MechanismType = MechanismType {
        val: CKM_SHA256_RSA_PKCS,
    };
    /// SHA384-RSA-PKCS mechanism
    pub const SHA384_RSA_PKCS: MechanismType = MechanismType {
        val: CKM_SHA384_RSA_PKCS,
    };
    /// SHA512-RSA-PKCS mechanism
    pub const SHA512_RSA_PKCS: MechanismType = MechanismType {
        val: CKM_SHA512_RSA_PKCS,
    };

    // SHAn-RSA-PKCS-PSS
    /// SHA1-RSA-PKCS-PSS mechanism
    pub const SHA1_RSA_PKCS_PSS: MechanismType = MechanismType {
        val: CKM_SHA1_RSA_PKCS_PSS,
    };
    /// SHA256-RSA-PKCS-PSS mechanism
    pub const SHA256_RSA_PKCS_PSS: MechanismType = MechanismType {
        val: CKM_SHA256_RSA_PKCS_PSS,
    };
    /// SHA384-RSA-PKCS-PSS mechanism
    pub const SHA384_RSA_PKCS_PSS: MechanismType = MechanismType {
        val: CKM_SHA384_RSA_PKCS_PSS,
    };
    /// SHA512-RSA-PKCS-PSS mechanism
    pub const SHA512_RSA_PKCS_PSS: MechanismType = MechanismType {
        val: CKM_SHA512_RSA_PKCS_PSS,
    };

    // SHAn-HMAC
    /// SHA1-HMAC mechanism
    pub const SHA1_HMAC: MechanismType = MechanismType {
        val: CKM_SHA_1_HMAC,
    };
    /// SHA224-HMAC mechanism
    pub const SHA224_HMAC: MechanismType = MechanismType {
        val: CKM_SHA224_HMAC,
    };
    /// SHA256-HMAC mechanism
    pub const SHA256_HMAC: MechanismType = MechanismType {
        val: CKM_SHA256_HMAC,
    };
    /// SHA384-HMAC mechanism
    pub const SHA384_HMAC: MechanismType = MechanismType {
        val: CKM_SHA384_HMAC,
    };
    /// SHA512-HMAC mechanism
    pub const SHA512_HMAC: MechanismType = MechanismType {
        val: CKM_SHA512_HMAC,
    };

    // SHA-n key generation (for use with the corresponding HMAC mechanism)
    /// SHA-1 key generation mechanism
    pub const SHA1_KEY_GEN: MechanismType = MechanismType {
        val: CKM_SHA_1_KEY_GEN,
    };
    /// SHA-224 key generation mechanism
    pub const SHA224_KEY_GEN: MechanismType = MechanismType {
        val: CKM_SHA224_KEY_GEN,
    };
    /// SHA-256 key generation mechanism
    pub const SHA256_KEY_GEN: MechanismType = MechanismType {
        val: CKM_SHA256_KEY_GEN,
    };
    /// SHA-384 key generation mechanism
    pub const SHA384_KEY_GEN: MechanismType = MechanismType {
        val: CKM_SHA384_KEY_GEN,
    };
    /// SHA-512 key generation mechanism
    pub const SHA512_KEY_GEN: MechanismType = MechanismType {
        val: CKM_SHA512_KEY_GEN,
    };

    /// GENERIC-SECRET-KEY-GEN mechanism
    pub const GENERIC_SECRET_KEY_GEN: MechanismType = MechanismType {
        val: CKM_GENERIC_SECRET_KEY_GEN,
    };

    // HKDF
    /// HKDF key generation mechanism
    pub const HKDF_KEY_GEN: MechanismType = MechanismType {
        val: CKM_HKDF_KEY_GEN,
    };
    /// HKDF-DERIVE mechanism
    pub const HKDF_DERIVE: MechanismType = MechanismType {
        val: CKM_HKDF_DERIVE,
    };
    /// HKDF-DATA mechanism
    pub const HKDF_DATA: MechanismType = MechanismType { val: CKM_HKDF_DATA };

    // NIST SP 800-108 KDF (aka KBKDF)
    /// NIST SP 800-108 KDF (aka KBKDF) mechanism in counter-mode
    pub const SP800_108_COUNTER_KDF: MechanismType = MechanismType {
        val: CKM_SP800_108_COUNTER_KDF,
    };
    /// NIST SP 800-108 KDF (aka KBKDF) mechanism in feedback-mode
    pub const SP800_108_FEEDBACK_KDF: MechanismType = MechanismType {
        val: CKM_SP800_108_FEEDBACK_KDF,
    };
    /// NIST SP 800-108 KDF (aka KBKDF) mechanism in double pipeline-mode
    pub const SP800_108_DOUBLE_PIPELINE_KDF: MechanismType = MechanismType {
        val: CKM_SP800_108_DOUBLE_PIPELINE_KDF,
    };

    /// Create vendor defined mechanism
    ///
    /// # Arguments
    ///
    /// * `val` - The value of vendor defined mechanism
    ///
    /// # Errors
    ///
    /// If `val` is less then `CKM_VENDOR_DEFINED`, a `Error::InvalidValue` will be returned
    ///
    /// # Examples
    /// ```rust
    /// use cryptoki::mechanism::{vendor_defined::CKM_VENDOR_DEFINED, MechanismType};
    ///
    /// let some_custom_mech: MechanismType =
    ///     MechanismType::new_vendor_defined(CKM_VENDOR_DEFINED | 0x00000001).unwrap();
    /// ```
    pub fn new_vendor_defined(val: CK_MECHANISM_TYPE) -> crate::error::Result<MechanismType> {
        if val < CKM_VENDOR_DEFINED {
            Err(Error::InvalidValue)
        } else {
            Ok(MechanismType { val })
        }
    }

    pub(crate) fn stringify(mech: CK_MECHANISM_TYPE) -> String {
        match mech {
            CKM_RSA_PKCS_KEY_PAIR_GEN => String::from(stringify!(CKM_RSA_PKCS_KEY_PAIR_GEN)),
            CKM_RSA_PKCS => String::from(stringify!(CKM_RSA_PKCS)),
            CKM_RSA_9796 => String::from(stringify!(CKM_RSA_9796)),
            CKM_RSA_X_509 => String::from(stringify!(CKM_RSA_X_509)),
            CKM_MD2_RSA_PKCS => String::from(stringify!(CKM_MD2_RSA_PKCS)),
            CKM_MD5_RSA_PKCS => String::from(stringify!(CKM_MD5_RSA_PKCS)),
            CKM_SHA1_RSA_PKCS => String::from(stringify!(CKM_SHA1_RSA_PKCS)),
            CKM_RIPEMD128_RSA_PKCS => String::from(stringify!(CKM_RIPEMD128_RSA_PKCS)),
            CKM_RIPEMD160_RSA_PKCS => String::from(stringify!(CKM_RIPEMD160_RSA_PKCS)),
            CKM_RSA_PKCS_OAEP => String::from(stringify!(CKM_RSA_PKCS_OAEP)),
            CKM_RSA_X9_31_KEY_PAIR_GEN => String::from(stringify!(CKM_RSA_X9_31_KEY_PAIR_GEN)),
            CKM_RSA_X9_31 => String::from(stringify!(CKM_RSA_X9_31)),
            CKM_SHA1_RSA_X9_31 => String::from(stringify!(CKM_SHA1_RSA_X9_31)),
            CKM_RSA_PKCS_PSS => String::from(stringify!(CKM_RSA_PKCS_PSS)),
            CKM_SHA1_RSA_PKCS_PSS => String::from(stringify!(CKM_SHA1_RSA_PKCS_PSS)),
            CKM_DSA_KEY_PAIR_GEN => String::from(stringify!(CKM_DSA_KEY_PAIR_GEN)),
            CKM_DSA => String::from(stringify!(CKM_DSA)),
            CKM_DSA_SHA1 => String::from(stringify!(CKM_DSA_SHA1)),
            CKM_DSA_SHA224 => String::from(stringify!(CKM_DSA_SHA224)),
            CKM_DSA_SHA256 => String::from(stringify!(CKM_DSA_SHA256)),
            CKM_DSA_SHA384 => String::from(stringify!(CKM_DSA_SHA384)),
            CKM_DSA_SHA512 => String::from(stringify!(CKM_DSA_SHA512)),
            CKM_DH_PKCS_KEY_PAIR_GEN => String::from(stringify!(CKM_DH_PKCS_KEY_PAIR_GEN)),
            CKM_DH_PKCS_DERIVE => String::from(stringify!(CKM_DH_PKCS_DERIVE)),
            CKM_X9_42_DH_KEY_PAIR_GEN => String::from(stringify!(CKM_X9_42_DH_KEY_PAIR_GEN)),
            CKM_X9_42_DH_DERIVE => String::from(stringify!(CKM_X9_42_DH_DERIVE)),
            CKM_X9_42_DH_HYBRID_DERIVE => String::from(stringify!(CKM_X9_42_DH_HYBRID_DERIVE)),
            CKM_X9_42_MQV_DERIVE => String::from(stringify!(CKM_X9_42_MQV_DERIVE)),
            CKM_SHA256_RSA_PKCS => String::from(stringify!(CKM_SHA256_RSA_PKCS)),
            CKM_SHA384_RSA_PKCS => String::from(stringify!(CKM_SHA384_RSA_PKCS)),
            CKM_SHA512_RSA_PKCS => String::from(stringify!(CKM_SHA512_RSA_PKCS)),
            CKM_SHA256_RSA_PKCS_PSS => String::from(stringify!(CKM_SHA256_RSA_PKCS_PSS)),
            CKM_SHA384_RSA_PKCS_PSS => String::from(stringify!(CKM_SHA384_RSA_PKCS_PSS)),
            CKM_SHA512_RSA_PKCS_PSS => String::from(stringify!(CKM_SHA512_RSA_PKCS_PSS)),
            CKM_SHA512_224 => String::from(stringify!(CKM_SHA512_224)),
            CKM_SHA512_224_HMAC => String::from(stringify!(CKM_SHA512_224_HMAC)),
            CKM_SHA512_224_HMAC_GENERAL => String::from(stringify!(CKM_SHA512_224_HMAC_GENERAL)),
            CKM_SHA512_224_KEY_DERIVATION => {
                String::from(stringify!(CKM_SHA512_224_KEY_DERIVATION))
            }
            CKM_SHA512_256 => String::from(stringify!(CKM_SHA512_256)),
            CKM_SHA512_256_HMAC => String::from(stringify!(CKM_SHA512_256_HMAC)),
            CKM_SHA512_256_HMAC_GENERAL => String::from(stringify!(CKM_SHA512_256_HMAC_GENERAL)),
            CKM_SHA512_256_KEY_DERIVATION => {
                String::from(stringify!(CKM_SHA512_256_KEY_DERIVATION))
            }
            CKM_SHA512_T => String::from(stringify!(CKM_SHA512_T)),
            CKM_SHA512_T_HMAC => String::from(stringify!(CKM_SHA512_T_HMAC)),
            CKM_SHA512_T_HMAC_GENERAL => String::from(stringify!(CKM_SHA512_T_HMAC_GENERAL)),
            CKM_SHA512_T_KEY_DERIVATION => String::from(stringify!(CKM_SHA512_T_KEY_DERIVATION)),
            CKM_RC2_KEY_GEN => String::from(stringify!(CKM_RC2_KEY_GEN)),
            CKM_RC2_ECB => String::from(stringify!(CKM_RC2_ECB)),
            CKM_RC2_CBC => String::from(stringify!(CKM_RC2_CBC)),
            CKM_RC2_MAC => String::from(stringify!(CKM_RC2_MAC)),
            CKM_RC2_MAC_GENERAL => String::from(stringify!(CKM_RC2_MAC_GENERAL)),
            CKM_RC2_CBC_PAD => String::from(stringify!(CKM_RC2_CBC_PAD)),
            CKM_RC4_KEY_GEN => String::from(stringify!(CKM_RC4_KEY_GEN)),
            CKM_RC4 => String::from(stringify!(CKM_RC4)),
            CKM_DES_KEY_GEN => String::from(stringify!(CKM_DES_KEY_GEN)),
            CKM_DES_ECB => String::from(stringify!(CKM_DES_ECB)),
            CKM_DES_CBC => String::from(stringify!(CKM_DES_CBC)),
            CKM_DES_MAC => String::from(stringify!(CKM_DES_MAC)),
            CKM_DES_MAC_GENERAL => String::from(stringify!(CKM_DES_MAC_GENERAL)),
            CKM_DES_CBC_PAD => String::from(stringify!(CKM_DES_CBC_PAD)),
            CKM_DES2_KEY_GEN => String::from(stringify!(CKM_DES2_KEY_GEN)),
            CKM_DES3_KEY_GEN => String::from(stringify!(CKM_DES3_KEY_GEN)),
            CKM_DES3_ECB => String::from(stringify!(CKM_DES3_ECB)),
            CKM_DES3_CBC => String::from(stringify!(CKM_DES3_CBC)),
            CKM_DES3_MAC => String::from(stringify!(CKM_DES3_MAC)),
            CKM_DES3_MAC_GENERAL => String::from(stringify!(CKM_DES3_MAC_GENERAL)),
            CKM_DES3_CBC_PAD => String::from(stringify!(CKM_DES3_CBC_PAD)),
            CKM_DES3_CMAC_GENERAL => String::from(stringify!(CKM_DES3_CMAC_GENERAL)),
            CKM_DES3_CMAC => String::from(stringify!(CKM_DES3_CMAC)),
            CKM_CDMF_KEY_GEN => String::from(stringify!(CKM_CDMF_KEY_GEN)),
            CKM_CDMF_ECB => String::from(stringify!(CKM_CDMF_ECB)),
            CKM_CDMF_CBC => String::from(stringify!(CKM_CDMF_CBC)),
            CKM_CDMF_MAC => String::from(stringify!(CKM_CDMF_MAC)),
            CKM_CDMF_MAC_GENERAL => String::from(stringify!(CKM_CDMF_MAC_GENERAL)),
            CKM_CDMF_CBC_PAD => String::from(stringify!(CKM_CDMF_CBC_PAD)),
            CKM_DES_OFB64 => String::from(stringify!(CKM_DES_OFB64)),
            CKM_DES_OFB8 => String::from(stringify!(CKM_DES_OFB8)),
            CKM_DES_CFB64 => String::from(stringify!(CKM_DES_CFB64)),
            CKM_DES_CFB8 => String::from(stringify!(CKM_DES_CFB8)),
            CKM_MD2 => String::from(stringify!(CKM_MD2)),
            CKM_MD2_HMAC => String::from(stringify!(CKM_MD2_HMAC)),
            CKM_MD2_HMAC_GENERAL => String::from(stringify!(CKM_MD2_HMAC_GENERAL)),
            CKM_MD5 => String::from(stringify!(CKM_MD5)),
            CKM_MD5_HMAC => String::from(stringify!(CKM_MD5_HMAC)),
            CKM_MD5_HMAC_GENERAL => String::from(stringify!(CKM_MD5_HMAC_GENERAL)),
            CKM_SHA_1 => String::from(stringify!(CKM_SHA_1)),
            CKM_SHA_1_HMAC => String::from(stringify!(CKM_SHA_1_HMAC)),
            CKM_SHA_1_HMAC_GENERAL => String::from(stringify!(CKM_SHA_1_HMAC_GENERAL)),
            CKM_SHA_1_KEY_GEN => String::from(stringify!(CKM_SHA_1_KEY_GEN)),
            CKM_RIPEMD128 => String::from(stringify!(CKM_RIPEMD128)),
            CKM_RIPEMD128_HMAC => String::from(stringify!(CKM_RIPEMD128_HMAC)),
            CKM_RIPEMD128_HMAC_GENERAL => String::from(stringify!(CKM_RIPEMD128_HMAC_GENERAL)),
            CKM_RIPEMD160 => String::from(stringify!(CKM_RIPEMD160)),
            CKM_RIPEMD160_HMAC => String::from(stringify!(CKM_RIPEMD160_HMAC)),
            CKM_RIPEMD160_HMAC_GENERAL => String::from(stringify!(CKM_RIPEMD160_HMAC_GENERAL)),
            CKM_SHA256 => String::from(stringify!(CKM_SHA256)),
            CKM_SHA256_HMAC => String::from(stringify!(CKM_SHA256_HMAC)),
            CKM_SHA256_HMAC_GENERAL => String::from(stringify!(CKM_SHA256_HMAC_GENERAL)),
            CKM_SHA256_KEY_GEN => String::from(stringify!(CKM_SHA256_KEY_GEN)),
            CKM_SHA384 => String::from(stringify!(CKM_SHA384)),
            CKM_SHA384_HMAC => String::from(stringify!(CKM_SHA384_HMAC)),
            CKM_SHA384_HMAC_GENERAL => String::from(stringify!(CKM_SHA384_HMAC_GENERAL)),
            CKM_SHA384_KEY_GEN => String::from(stringify!(CKM_SHA384_KEY_GEN)),
            CKM_SHA512 => String::from(stringify!(CKM_SHA512)),
            CKM_SHA512_HMAC => String::from(stringify!(CKM_SHA512_HMAC)),
            CKM_SHA512_HMAC_GENERAL => String::from(stringify!(CKM_SHA512_HMAC_GENERAL)),
            CKM_SHA512_KEY_GEN => String::from(stringify!(CKM_SHA512_KEY_GEN)),
            CKM_SECURID_KEY_GEN => String::from(stringify!(CKM_SECURID_KEY_GEN)),
            CKM_SECURID => String::from(stringify!(CKM_SECURID)),
            CKM_HOTP_KEY_GEN => String::from(stringify!(CKM_HOTP_KEY_GEN)),
            CKM_HOTP => String::from(stringify!(CKM_HOTP)),
            CKM_ACTI => String::from(stringify!(CKM_ACTI)),
            CKM_ACTI_KEY_GEN => String::from(stringify!(CKM_ACTI_KEY_GEN)),
            CKM_CAST_KEY_GEN => String::from(stringify!(CKM_CAST_KEY_GEN)),
            CKM_CAST_ECB => String::from(stringify!(CKM_CAST_ECB)),
            CKM_CAST_CBC => String::from(stringify!(CKM_CAST_CBC)),
            CKM_CAST_MAC => String::from(stringify!(CKM_CAST_MAC)),
            CKM_CAST_MAC_GENERAL => String::from(stringify!(CKM_CAST_MAC_GENERAL)),
            CKM_CAST_CBC_PAD => String::from(stringify!(CKM_CAST_CBC_PAD)),
            CKM_CAST3_KEY_GEN => String::from(stringify!(CKM_CAST3_KEY_GEN)),
            CKM_CAST3_ECB => String::from(stringify!(CKM_CAST3_ECB)),
            CKM_CAST3_CBC => String::from(stringify!(CKM_CAST3_CBC)),
            CKM_CAST3_MAC => String::from(stringify!(CKM_CAST3_MAC)),
            CKM_CAST3_MAC_GENERAL => String::from(stringify!(CKM_CAST3_MAC_GENERAL)),
            CKM_CAST3_CBC_PAD => String::from(stringify!(CKM_CAST3_CBC_PAD)),
            CKM_CAST128_KEY_GEN => String::from(stringify!(CKM_CAST128_KEY_GEN)),
            CKM_CAST128_ECB => String::from(stringify!(CKM_CAST128_ECB)),
            CKM_CAST128_CBC => String::from(stringify!(CKM_CAST128_CBC)),
            CKM_CAST128_MAC => String::from(stringify!(CKM_CAST128_MAC)),
            CKM_CAST128_MAC_GENERAL => String::from(stringify!(CKM_CAST128_MAC_GENERAL)),
            CKM_CAST128_CBC_PAD => String::from(stringify!(CKM_CAST128_CBC_PAD)),
            CKM_RC5_KEY_GEN => String::from(stringify!(CKM_RC5_KEY_GEN)),
            CKM_RC5_ECB => String::from(stringify!(CKM_RC5_ECB)),
            CKM_RC5_CBC => String::from(stringify!(CKM_RC5_CBC)),
            CKM_RC5_MAC => String::from(stringify!(CKM_RC5_MAC)),
            CKM_RC5_MAC_GENERAL => String::from(stringify!(CKM_RC5_MAC_GENERAL)),
            CKM_RC5_CBC_PAD => String::from(stringify!(CKM_RC5_CBC_PAD)),
            CKM_IDEA_KEY_GEN => String::from(stringify!(CKM_IDEA_KEY_GEN)),
            CKM_IDEA_ECB => String::from(stringify!(CKM_IDEA_ECB)),
            CKM_IDEA_CBC => String::from(stringify!(CKM_IDEA_CBC)),
            CKM_IDEA_MAC => String::from(stringify!(CKM_IDEA_MAC)),
            CKM_IDEA_MAC_GENERAL => String::from(stringify!(CKM_IDEA_MAC_GENERAL)),
            CKM_IDEA_CBC_PAD => String::from(stringify!(CKM_IDEA_CBC_PAD)),
            CKM_GENERIC_SECRET_KEY_GEN => String::from(stringify!(CKM_GENERIC_SECRET_KEY_GEN)),
            CKM_CONCATENATE_BASE_AND_KEY => String::from(stringify!(CKM_CONCATENATE_BASE_AND_KEY)),
            CKM_CONCATENATE_BASE_AND_DATA => {
                String::from(stringify!(CKM_CONCATENATE_BASE_AND_DATA))
            }
            CKM_CONCATENATE_DATA_AND_BASE => {
                String::from(stringify!(CKM_CONCATENATE_DATA_AND_BASE))
            }
            CKM_XOR_BASE_AND_DATA => String::from(stringify!(CKM_XOR_BASE_AND_DATA)),
            CKM_EXTRACT_KEY_FROM_KEY => String::from(stringify!(CKM_EXTRACT_KEY_FROM_KEY)),
            CKM_SSL3_PRE_MASTER_KEY_GEN => String::from(stringify!(CKM_SSL3_PRE_MASTER_KEY_GEN)),
            CKM_SSL3_MASTER_KEY_DERIVE => String::from(stringify!(CKM_SSL3_MASTER_KEY_DERIVE)),
            CKM_SSL3_KEY_AND_MAC_DERIVE => String::from(stringify!(CKM_SSL3_KEY_AND_MAC_DERIVE)),
            CKM_SSL3_MASTER_KEY_DERIVE_DH => {
                String::from(stringify!(CKM_SSL3_MASTER_KEY_DERIVE_DH))
            }
            CKM_TLS_PRE_MASTER_KEY_GEN => String::from(stringify!(CKM_TLS_PRE_MASTER_KEY_GEN)),
            CKM_TLS_MASTER_KEY_DERIVE => String::from(stringify!(CKM_TLS_MASTER_KEY_DERIVE)),
            CKM_TLS_KEY_AND_MAC_DERIVE => String::from(stringify!(CKM_TLS_KEY_AND_MAC_DERIVE)),
            CKM_TLS_MASTER_KEY_DERIVE_DH => String::from(stringify!(CKM_TLS_MASTER_KEY_DERIVE_DH)),
            CKM_TLS_PRF => String::from(stringify!(CKM_TLS_PRF)),
            CKM_SSL3_MD5_MAC => String::from(stringify!(CKM_SSL3_MD5_MAC)),
            CKM_SSL3_SHA1_MAC => String::from(stringify!(CKM_SSL3_SHA1_MAC)),
            CKM_MD5_KEY_DERIVATION => String::from(stringify!(CKM_MD5_KEY_DERIVATION)),
            CKM_MD2_KEY_DERIVATION => String::from(stringify!(CKM_MD2_KEY_DERIVATION)),
            CKM_SHA1_KEY_DERIVATION => String::from(stringify!(CKM_SHA1_KEY_DERIVATION)),
            CKM_SHA256_KEY_DERIVATION => String::from(stringify!(CKM_SHA256_KEY_DERIVATION)),
            CKM_SHA384_KEY_DERIVATION => String::from(stringify!(CKM_SHA384_KEY_DERIVATION)),
            CKM_SHA512_KEY_DERIVATION => String::from(stringify!(CKM_SHA512_KEY_DERIVATION)),
            CKM_PBE_MD2_DES_CBC => String::from(stringify!(CKM_PBE_MD2_DES_CBC)),
            CKM_PBE_MD5_DES_CBC => String::from(stringify!(CKM_PBE_MD5_DES_CBC)),
            CKM_PBE_MD5_CAST_CBC => String::from(stringify!(CKM_PBE_MD5_CAST_CBC)),
            CKM_PBE_MD5_CAST3_CBC => String::from(stringify!(CKM_PBE_MD5_CAST3_CBC)),
            CKM_PBE_MD5_CAST128_CBC => String::from(stringify!(CKM_PBE_MD5_CAST128_CBC)),
            CKM_PBE_SHA1_CAST128_CBC => String::from(stringify!(CKM_PBE_SHA1_CAST128_CBC)),
            CKM_PBE_SHA1_RC4_128 => String::from(stringify!(CKM_PBE_SHA1_RC4_128)),
            CKM_PBE_SHA1_RC4_40 => String::from(stringify!(CKM_PBE_SHA1_RC4_40)),
            CKM_PBE_SHA1_DES3_EDE_CBC => String::from(stringify!(CKM_PBE_SHA1_DES3_EDE_CBC)),
            CKM_PBE_SHA1_DES2_EDE_CBC => String::from(stringify!(CKM_PBE_SHA1_DES2_EDE_CBC)),
            CKM_PBE_SHA1_RC2_128_CBC => String::from(stringify!(CKM_PBE_SHA1_RC2_128_CBC)),
            CKM_PBE_SHA1_RC2_40_CBC => String::from(stringify!(CKM_PBE_SHA1_RC2_40_CBC)),
            CKM_PKCS5_PBKD2 => String::from(stringify!(CKM_PKCS5_PBKD2)),
            CKM_PBA_SHA1_WITH_SHA1_HMAC => String::from(stringify!(CKM_PBA_SHA1_WITH_SHA1_HMAC)),
            CKM_WTLS_PRE_MASTER_KEY_GEN => String::from(stringify!(CKM_WTLS_PRE_MASTER_KEY_GEN)),
            CKM_WTLS_MASTER_KEY_DERIVE => String::from(stringify!(CKM_WTLS_MASTER_KEY_DERIVE)),
            CKM_WTLS_MASTER_KEY_DERIVE_DH_ECC => {
                String::from(stringify!(CKM_WTLS_MASTER_KEY_DERIVE_DH_ECC))
            }
            CKM_WTLS_PRF => String::from(stringify!(CKM_WTLS_PRF)),
            CKM_WTLS_SERVER_KEY_AND_MAC_DERIVE => {
                String::from(stringify!(CKM_WTLS_SERVER_KEY_AND_MAC_DERIVE))
            }
            CKM_WTLS_CLIENT_KEY_AND_MAC_DERIVE => {
                String::from(stringify!(CKM_WTLS_CLIENT_KEY_AND_MAC_DERIVE))
            }
            CKM_TLS10_MAC_SERVER => String::from(stringify!(CKM_TLS10_MAC_SERVER)),
            CKM_TLS10_MAC_CLIENT => String::from(stringify!(CKM_TLS10_MAC_CLIENT)),
            CKM_TLS12_MAC => String::from(stringify!(CKM_TLS12_MAC)),
            CKM_TLS12_KDF => String::from(stringify!(CKM_TLS12_KDF)),
            CKM_TLS12_MASTER_KEY_DERIVE => String::from(stringify!(CKM_TLS12_MASTER_KEY_DERIVE)),
            CKM_TLS12_KEY_AND_MAC_DERIVE => String::from(stringify!(CKM_TLS12_KEY_AND_MAC_DERIVE)),
            CKM_TLS12_MASTER_KEY_DERIVE_DH => {
                String::from(stringify!(CKM_TLS12_MASTER_KEY_DERIVE_DH))
            }
            CKM_TLS12_KEY_SAFE_DERIVE => String::from(stringify!(CKM_TLS12_KEY_SAFE_DERIVE)),
            CKM_TLS_MAC => String::from(stringify!(CKM_TLS_MAC)),
            CKM_TLS_KDF => String::from(stringify!(CKM_TLS_KDF)),
            CKM_KEY_WRAP_LYNKS => String::from(stringify!(CKM_KEY_WRAP_LYNKS)),
            CKM_KEY_WRAP_SET_OAEP => String::from(stringify!(CKM_KEY_WRAP_SET_OAEP)),
            CKM_CMS_SIG => String::from(stringify!(CKM_CMS_SIG)),
            CKM_KIP_DERIVE => String::from(stringify!(CKM_KIP_DERIVE)),
            CKM_KIP_WRAP => String::from(stringify!(CKM_KIP_WRAP)),
            CKM_KIP_MAC => String::from(stringify!(CKM_KIP_MAC)),
            CKM_CAMELLIA_KEY_GEN => String::from(stringify!(CKM_CAMELLIA_KEY_GEN)),
            CKM_CAMELLIA_CTR => String::from(stringify!(CKM_CAMELLIA_CTR)),
            CKM_ARIA_KEY_GEN => String::from(stringify!(CKM_ARIA_KEY_GEN)),
            CKM_ARIA_ECB => String::from(stringify!(CKM_ARIA_ECB)),
            CKM_ARIA_CBC => String::from(stringify!(CKM_ARIA_CBC)),
            CKM_ARIA_MAC => String::from(stringify!(CKM_ARIA_MAC)),
            CKM_ARIA_MAC_GENERAL => String::from(stringify!(CKM_ARIA_MAC_GENERAL)),
            CKM_ARIA_CBC_PAD => String::from(stringify!(CKM_ARIA_CBC_PAD)),
            CKM_ARIA_ECB_ENCRYPT_DATA => String::from(stringify!(CKM_ARIA_ECB_ENCRYPT_DATA)),
            CKM_ARIA_CBC_ENCRYPT_DATA => String::from(stringify!(CKM_ARIA_CBC_ENCRYPT_DATA)),
            CKM_SEED_KEY_GEN => String::from(stringify!(CKM_SEED_KEY_GEN)),
            CKM_SEED_ECB => String::from(stringify!(CKM_SEED_ECB)),
            CKM_SEED_CBC => String::from(stringify!(CKM_SEED_CBC)),
            CKM_SEED_MAC => String::from(stringify!(CKM_SEED_MAC)),
            CKM_SEED_MAC_GENERAL => String::from(stringify!(CKM_SEED_MAC_GENERAL)),
            CKM_SEED_CBC_PAD => String::from(stringify!(CKM_SEED_CBC_PAD)),
            CKM_SEED_ECB_ENCRYPT_DATA => String::from(stringify!(CKM_SEED_ECB_ENCRYPT_DATA)),
            CKM_SEED_CBC_ENCRYPT_DATA => String::from(stringify!(CKM_SEED_CBC_ENCRYPT_DATA)),
            CKM_SKIPJACK_KEY_GEN => String::from(stringify!(CKM_SKIPJACK_KEY_GEN)),
            CKM_SKIPJACK_ECB64 => String::from(stringify!(CKM_SKIPJACK_ECB64)),
            CKM_SKIPJACK_CBC64 => String::from(stringify!(CKM_SKIPJACK_CBC64)),
            CKM_SKIPJACK_OFB64 => String::from(stringify!(CKM_SKIPJACK_OFB64)),
            CKM_SKIPJACK_CFB64 => String::from(stringify!(CKM_SKIPJACK_CFB64)),
            CKM_SKIPJACK_CFB32 => String::from(stringify!(CKM_SKIPJACK_CFB32)),
            CKM_SKIPJACK_CFB16 => String::from(stringify!(CKM_SKIPJACK_CFB16)),
            CKM_SKIPJACK_CFB8 => String::from(stringify!(CKM_SKIPJACK_CFB8)),
            CKM_SKIPJACK_WRAP => String::from(stringify!(CKM_SKIPJACK_WRAP)),
            CKM_SKIPJACK_PRIVATE_WRAP => String::from(stringify!(CKM_SKIPJACK_PRIVATE_WRAP)),
            CKM_SKIPJACK_RELAYX => String::from(stringify!(CKM_SKIPJACK_RELAYX)),
            CKM_KEA_KEY_PAIR_GEN => String::from(stringify!(CKM_KEA_KEY_PAIR_GEN)),
            CKM_KEA_KEY_DERIVE => String::from(stringify!(CKM_KEA_KEY_DERIVE)),
            CKM_FORTEZZA_TIMESTAMP => String::from(stringify!(CKM_FORTEZZA_TIMESTAMP)),
            CKM_BATON_KEY_GEN => String::from(stringify!(CKM_BATON_KEY_GEN)),
            CKM_BATON_ECB128 => String::from(stringify!(CKM_BATON_ECB128)),
            CKM_BATON_ECB96 => String::from(stringify!(CKM_BATON_ECB96)),
            CKM_BATON_CBC128 => String::from(stringify!(CKM_BATON_CBC128)),
            CKM_BATON_COUNTER => String::from(stringify!(CKM_BATON_COUNTER)),
            CKM_BATON_SHUFFLE => String::from(stringify!(CKM_BATON_SHUFFLE)),
            CKM_BATON_WRAP => String::from(stringify!(CKM_BATON_WRAP)),
            CKM_EC_KEY_PAIR_GEN => String::from(stringify!(CKM_EC_KEY_PAIR_GEN)),
            CKM_ECDSA => String::from(stringify!(CKM_ECDSA)),
            CKM_ECDSA_SHA1 => String::from(stringify!(CKM_ECDSA_SHA1)),
            CKM_ECDSA_SHA224 => String::from(stringify!(CKM_ECDSA_SHA224)),
            CKM_ECDSA_SHA256 => String::from(stringify!(CKM_ECDSA_SHA256)),
            CKM_ECDSA_SHA384 => String::from(stringify!(CKM_ECDSA_SHA384)),
            CKM_ECDSA_SHA512 => String::from(stringify!(CKM_ECDSA_SHA512)),
            CKM_ECDH1_DERIVE => String::from(stringify!(CKM_ECDH1_DERIVE)),
            CKM_ECDH1_COFACTOR_DERIVE => String::from(stringify!(CKM_ECDH1_COFACTOR_DERIVE)),
            CKM_ECMQV_DERIVE => String::from(stringify!(CKM_ECMQV_DERIVE)),
            CKM_ECDH_AES_KEY_WRAP => String::from(stringify!(CKM_ECDH_AES_KEY_WRAP)),
            CKM_RSA_AES_KEY_WRAP => String::from(stringify!(CKM_RSA_AES_KEY_WRAP)),
            CKM_JUNIPER_KEY_GEN => String::from(stringify!(CKM_JUNIPER_KEY_GEN)),
            CKM_JUNIPER_ECB128 => String::from(stringify!(CKM_JUNIPER_ECB128)),
            CKM_JUNIPER_CBC128 => String::from(stringify!(CKM_JUNIPER_CBC128)),
            CKM_JUNIPER_COUNTER => String::from(stringify!(CKM_JUNIPER_COUNTER)),
            CKM_JUNIPER_SHUFFLE => String::from(stringify!(CKM_JUNIPER_SHUFFLE)),
            CKM_JUNIPER_WRAP => String::from(stringify!(CKM_JUNIPER_WRAP)),
            CKM_FASTHASH => String::from(stringify!(CKM_FASTHASH)),
            CKM_AES_KEY_GEN => String::from(stringify!(CKM_AES_KEY_GEN)),
            CKM_AES_ECB => String::from(stringify!(CKM_AES_ECB)),
            CKM_AES_CBC => String::from(stringify!(CKM_AES_CBC)),
            CKM_AES_MAC => String::from(stringify!(CKM_AES_MAC)),
            CKM_AES_MAC_GENERAL => String::from(stringify!(CKM_AES_MAC_GENERAL)),
            CKM_AES_CBC_PAD => String::from(stringify!(CKM_AES_CBC_PAD)),
            CKM_AES_CTR => String::from(stringify!(CKM_AES_CTR)),
            CKM_AES_GCM => String::from(stringify!(CKM_AES_GCM)),
            CKM_AES_CCM => String::from(stringify!(CKM_AES_CCM)),
            CKM_AES_CTS => String::from(stringify!(CKM_AES_CTS)),
            CKM_AES_CMAC => String::from(stringify!(CKM_AES_CMAC)),
            CKM_AES_CMAC_GENERAL => String::from(stringify!(CKM_AES_CMAC_GENERAL)),
            CKM_AES_XCBC_MAC => String::from(stringify!(CKM_AES_XCBC_MAC)),
            CKM_AES_XCBC_MAC_96 => String::from(stringify!(CKM_AES_XCBC_MAC_96)),
            CKM_AES_GMAC => String::from(stringify!(CKM_AES_GMAC)),
            CKM_BLOWFISH_KEY_GEN => String::from(stringify!(CKM_BLOWFISH_KEY_GEN)),
            CKM_BLOWFISH_CBC => String::from(stringify!(CKM_BLOWFISH_CBC)),
            CKM_TWOFISH_KEY_GEN => String::from(stringify!(CKM_TWOFISH_KEY_GEN)),
            CKM_TWOFISH_CBC => String::from(stringify!(CKM_TWOFISH_CBC)),
            CKM_BLOWFISH_CBC_PAD => String::from(stringify!(CKM_BLOWFISH_CBC_PAD)),
            CKM_TWOFISH_CBC_PAD => String::from(stringify!(CKM_TWOFISH_CBC_PAD)),
            CKM_DES_ECB_ENCRYPT_DATA => String::from(stringify!(CKM_DES_ECB_ENCRYPT_DATA)),
            CKM_DES_CBC_ENCRYPT_DATA => String::from(stringify!(CKM_DES_CBC_ENCRYPT_DATA)),
            CKM_DES3_ECB_ENCRYPT_DATA => String::from(stringify!(CKM_DES3_ECB_ENCRYPT_DATA)),
            CKM_DES3_CBC_ENCRYPT_DATA => String::from(stringify!(CKM_DES3_CBC_ENCRYPT_DATA)),
            CKM_AES_ECB_ENCRYPT_DATA => String::from(stringify!(CKM_AES_ECB_ENCRYPT_DATA)),
            CKM_AES_CBC_ENCRYPT_DATA => String::from(stringify!(CKM_AES_CBC_ENCRYPT_DATA)),
            CKM_GOSTR3410_KEY_PAIR_GEN => String::from(stringify!(CKM_GOSTR3410_KEY_PAIR_GEN)),
            CKM_GOSTR3410 => String::from(stringify!(CKM_GOSTR3410)),
            CKM_GOSTR3410_WITH_GOSTR3411 => String::from(stringify!(CKM_GOSTR3410_WITH_GOSTR3411)),
            CKM_GOSTR3410_KEY_WRAP => String::from(stringify!(CKM_GOSTR3410_KEY_WRAP)),
            CKM_GOSTR3410_DERIVE => String::from(stringify!(CKM_GOSTR3410_DERIVE)),
            CKM_GOSTR3411 => String::from(stringify!(CKM_GOSTR3411)),
            CKM_GOSTR3411_HMAC => String::from(stringify!(CKM_GOSTR3411_HMAC)),
            CKM_GOST28147_KEY_GEN => String::from(stringify!(CKM_GOST28147_KEY_GEN)),
            CKM_GOST28147_ECB => String::from(stringify!(CKM_GOST28147_ECB)),
            CKM_GOST28147 => String::from(stringify!(CKM_GOST28147)),
            CKM_GOST28147_MAC => String::from(stringify!(CKM_GOST28147_MAC)),
            CKM_GOST28147_KEY_WRAP => String::from(stringify!(CKM_GOST28147_KEY_WRAP)),
            CKM_DSA_PARAMETER_GEN => String::from(stringify!(CKM_DSA_PARAMETER_GEN)),
            CKM_DH_PKCS_PARAMETER_GEN => String::from(stringify!(CKM_DH_PKCS_PARAMETER_GEN)),
            CKM_X9_42_DH_PARAMETER_GEN => String::from(stringify!(CKM_X9_42_DH_PARAMETER_GEN)),
            CKM_DSA_PROBABLISTIC_PARAMETER_GEN => {
                String::from(stringify!(CKM_DSA_PROBABLISTIC_PARAMETER_GEN))
            }
            CKM_DSA_SHAWE_TAYLOR_PARAMETER_GEN => {
                String::from(stringify!(CKM_DSA_SHAWE_TAYLOR_PARAMETER_GEN))
            }
            CKM_AES_OFB => String::from(stringify!(CKM_AES_OFB)),
            CKM_AES_CFB64 => String::from(stringify!(CKM_AES_CFB64)),
            CKM_AES_CFB8 => String::from(stringify!(CKM_AES_CFB8)),
            CKM_AES_CFB128 => String::from(stringify!(CKM_AES_CFB128)),
            CKM_AES_CFB1 => String::from(stringify!(CKM_AES_CFB1)),
            CKM_VENDOR_DEFINED => String::from(stringify!(CKM_VENDOR_DEFINED)),
            CKM_SHA224 => String::from(stringify!(CKM_SHA224)),
            CKM_SHA224_HMAC => String::from(stringify!(CKM_SHA224_HMAC)),
            CKM_SHA224_HMAC_GENERAL => String::from(stringify!(CKM_SHA224_HMAC_GENERAL)),
            CKM_SHA224_RSA_PKCS => String::from(stringify!(CKM_SHA224_RSA_PKCS)),
            CKM_SHA224_RSA_PKCS_PSS => String::from(stringify!(CKM_SHA224_RSA_PKCS_PSS)),
            CKM_SHA224_KEY_GEN => String::from(stringify!(CKM_SHA224_KEY_GEN)),
            CKM_SHA224_KEY_DERIVATION => String::from(stringify!(CKM_SHA224_KEY_DERIVATION)),
            CKM_CAMELLIA_ECB => String::from(stringify!(CKM_CAMELLIA_ECB)),
            CKM_CAMELLIA_CBC => String::from(stringify!(CKM_CAMELLIA_CBC)),
            CKM_CAMELLIA_MAC => String::from(stringify!(CKM_CAMELLIA_MAC)),
            CKM_CAMELLIA_MAC_GENERAL => String::from(stringify!(CKM_CAMELLIA_MAC_GENERAL)),
            CKM_CAMELLIA_CBC_PAD => String::from(stringify!(CKM_CAMELLIA_CBC_PAD)),
            CKM_CAMELLIA_ECB_ENCRYPT_DATA => {
                String::from(stringify!(CKM_CAMELLIA_ECB_ENCRYPT_DATA))
            }
            CKM_CAMELLIA_CBC_ENCRYPT_DATA => {
                String::from(stringify!(CKM_CAMELLIA_CBC_ENCRYPT_DATA))
            }
            CKM_AES_KEY_WRAP => String::from(stringify!(CKM_AES_KEY_WRAP)),
            CKM_AES_KEY_WRAP_PAD => String::from(stringify!(CKM_AES_KEY_WRAP_PAD)),
            CKM_RSA_PKCS_TPM_1_1 => String::from(stringify!(CKM_RSA_PKCS_TPM_1_1)),
            CKM_RSA_PKCS_OAEP_TPM_1_1 => String::from(stringify!(CKM_RSA_PKCS_OAEP_TPM_1_1)),
            CKM_EC_EDWARDS_KEY_PAIR_GEN => String::from(stringify!(CKM_EC_EDWARDS_KEY_PAIR_GEN)),
            CKM_EC_MONTGOMERY_KEY_PAIR_GEN => {
                String::from(stringify!(CKM_EC_MONTGOMERY_KEY_PAIR_GEN))
            }
            CKM_EDDSA => String::from(stringify!(CKM_EDDSA)),
            CKM_HKDF_KEY_GEN => String::from(stringify!(CKM_HKDF_KEY_GEN)),
            CKM_HKDF_DERIVE => String::from(stringify!(CKM_HKDF_DERIVE)),
            CKM_HKDF_DATA => String::from(stringify!(CKM_HKDF_DATA)),
            CKM_SP800_108_COUNTER_KDF => String::from(stringify!(CKM_SP800_108_COUNTER_KDF)),
            CKM_SP800_108_FEEDBACK_KDF => String::from(stringify!(CKM_SP800_108_FEEDBACK_KDF)),
            CKM_SP800_108_DOUBLE_PIPELINE_KDF => {
                String::from(stringify!(CKM_SP800_108_DOUBLE_PIPELINE_KDF))
            }
            _ => format!("unknown {mech:08x}"),
        }
    }
}

impl std::fmt::Display for MechanismType {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", MechanismType::stringify(self.val))
    }
}

impl Deref for MechanismType {
    type Target = CK_MECHANISM_TYPE;

    fn deref(&self) -> &Self::Target {
        &self.val
    }
}

impl From<MechanismType> for CK_MECHANISM_TYPE {
    fn from(mechanism_type: MechanismType) -> Self {
        *mechanism_type
    }
}

impl TryFrom<CK_MECHANISM_TYPE> for MechanismType {
    type Error = Error;

    fn try_from(mechanism_type: CK_MECHANISM_TYPE) -> Result<Self, Self::Error> {
        match mechanism_type {
            CKM_AES_KEY_GEN => Ok(MechanismType::AES_KEY_GEN),
            CKM_AES_CBC => Ok(MechanismType::AES_CBC),
            CKM_AES_CBC_PAD => Ok(MechanismType::AES_CBC_PAD),
            CKM_AES_ECB => Ok(MechanismType::AES_ECB),
            CKM_AES_KEY_WRAP => Ok(MechanismType::AES_KEY_WRAP),
            CKM_AES_KEY_WRAP_PAD => Ok(MechanismType::AES_KEY_WRAP_PAD),
            CKM_AES_CTR => Ok(MechanismType::AES_CTR),
            CKM_AES_GCM => Ok(MechanismType::AES_GCM),
            CKM_AES_CBC_ENCRYPT_DATA => Ok(MechanismType::AES_CBC_ENCRYPT_DATA),
            CKM_AES_CMAC => Ok(MechanismType::AES_CMAC),
            CKM_AES_CFB128 => Ok(MechanismType::AES_CFB128),
            CKM_RSA_PKCS_KEY_PAIR_GEN => Ok(MechanismType::RSA_PKCS_KEY_PAIR_GEN),
            CKM_RSA_PKCS => Ok(MechanismType::RSA_PKCS),
            CKM_RSA_PKCS_PSS => Ok(MechanismType::RSA_PKCS_PSS),
            CKM_SHA1_RSA_PKCS_PSS => Ok(MechanismType::SHA1_RSA_PKCS_PSS),
            CKM_SHA256_RSA_PKCS_PSS => Ok(MechanismType::SHA256_RSA_PKCS_PSS),
            CKM_SHA384_RSA_PKCS_PSS => Ok(MechanismType::SHA384_RSA_PKCS_PSS),
            CKM_SHA512_RSA_PKCS_PSS => Ok(MechanismType::SHA512_RSA_PKCS_PSS),
            CKM_RSA_PKCS_OAEP => Ok(MechanismType::RSA_PKCS_OAEP),
            CKM_RSA_X_509 => Ok(MechanismType::RSA_X_509),
            CKM_DES3_KEY_GEN => Ok(MechanismType::DES3_KEY_GEN),
            CKM_DES3_ECB => Ok(MechanismType::DES3_ECB),
            CKM_EC_KEY_PAIR_GEN => Ok(MechanismType::ECC_KEY_PAIR_GEN),
            CKM_EC_EDWARDS_KEY_PAIR_GEN => Ok(MechanismType::ECC_EDWARDS_KEY_PAIR_GEN),
            CKM_EC_MONTGOMERY_KEY_PAIR_GEN => Ok(MechanismType::ECC_MONTGOMERY_KEY_PAIR_GEN),
            CKM_EDDSA => Ok(MechanismType::EDDSA),
            CKM_ECDH1_DERIVE => Ok(MechanismType::ECDH1_DERIVE),
            CKM_ECDSA => Ok(MechanismType::ECDSA),
            CKM_ECDSA_SHA1 => Ok(MechanismType::ECDSA_SHA1),
            CKM_ECDSA_SHA256 => Ok(MechanismType::ECDSA_SHA256),
            CKM_ECDSA_SHA384 => Ok(MechanismType::ECDSA_SHA384),
            CKM_ECDSA_SHA512 => Ok(MechanismType::ECDSA_SHA512),
            CKM_SHA_1 => Ok(MechanismType::SHA1),
            CKM_SHA256 => Ok(MechanismType::SHA256),
            CKM_SHA384 => Ok(MechanismType::SHA384),
            CKM_SHA512 => Ok(MechanismType::SHA512),
            CKM_SHA1_RSA_PKCS => Ok(MechanismType::SHA1_RSA_PKCS),
            CKM_SHA256_RSA_PKCS => Ok(MechanismType::SHA256_RSA_PKCS),
            CKM_SHA384_RSA_PKCS => Ok(MechanismType::SHA384_RSA_PKCS),
            CKM_SHA512_RSA_PKCS => Ok(MechanismType::SHA512_RSA_PKCS),
            CKM_SHA_1_HMAC => Ok(MechanismType::SHA1_HMAC),
            CKM_SHA224_HMAC => Ok(MechanismType::SHA224_HMAC),
            CKM_SHA256_HMAC => Ok(MechanismType::SHA256_HMAC),
            CKM_SHA384_HMAC => Ok(MechanismType::SHA384_HMAC),
            CKM_SHA512_HMAC => Ok(MechanismType::SHA512_HMAC),
            CKM_SHA_1_KEY_GEN => Ok(MechanismType::SHA1_KEY_GEN),
            CKM_SHA224_KEY_GEN => Ok(MechanismType::SHA224_KEY_GEN),
            CKM_SHA256_KEY_GEN => Ok(MechanismType::SHA256_KEY_GEN),
            CKM_SHA384_KEY_GEN => Ok(MechanismType::SHA384_KEY_GEN),
            CKM_SHA512_KEY_GEN => Ok(MechanismType::SHA512_KEY_GEN),
            CKM_GENERIC_SECRET_KEY_GEN => Ok(MechanismType::GENERIC_SECRET_KEY_GEN),
            CKM_HKDF_KEY_GEN => Ok(MechanismType::HKDF_KEY_GEN),
            CKM_HKDF_DERIVE => Ok(MechanismType::HKDF_DERIVE),
            CKM_HKDF_DATA => Ok(MechanismType::HKDF_DATA),
            CKM_SP800_108_COUNTER_KDF => Ok(MechanismType::SP800_108_COUNTER_KDF),
            CKM_SP800_108_FEEDBACK_KDF => Ok(MechanismType::SP800_108_FEEDBACK_KDF),
            CKM_SP800_108_DOUBLE_PIPELINE_KDF => Ok(MechanismType::SP800_108_DOUBLE_PIPELINE_KDF),
            other => {
                error!("Mechanism type {} is not supported.", other);
                Err(Error::NotSupported)
            }
        }
    }
}

#[derive(Debug)]
#[non_exhaustive]
/// Type defining a specific mechanism and its parameters
pub enum Mechanism<'a> {
    // AES
    /// AES key gen mechanism
    AesKeyGen,
    /// AES-CBC mechanism
    ///
    /// The parameter to this mechanism is the initialization vector.
    ///
    /// For encryption, the message length must be a multiple of the block
    /// size.  For wrapping, the mechanism encrypts the value of the key,
    /// padded on the trailing end with up to block size minus one null bytes.
    /// For unwrapping, the result is truncated according to the key type and
    /// the length provided by the template.
    AesCbc([u8; 16]),
    /// AES-CBC with PKCS#7 padding mechanism
    ///
    /// The parameter to this mechanism is the initialization vector.
    ///
    /// The plaintext may be any size.  The PKCS#7 padding allows the length of
    /// the plaintext to be recovered from the ciphertext.  Therefore no length
    /// should be provided when unwrapping keys with this mechanism.
    AesCbcPad([u8; 16]),
    /// AES in ECB mode
    AesEcb,
    /// AES key wrap
    AesKeyWrap,
    /// AES key wrap with padding block
    AesKeyWrapPad,
    /// AES-GCM mechanism
    AesGcm(aead::GcmParams<'a>),
    /// AES-GCM mechanism with message based API and parameters
    // TODO Should we reuse the AesGcm and use Option<> to select parameter?
    AesGcmMessage(aead::GcmMessageParams<'a>),
    /// AES-CBC-ENCRYPT-DATA mechanism
    ///
    /// The parameter to this mechanism is the initialization vector and the message to encrypt. These mechanisms allow
    /// derivation of keys using the result of an encryption operation as the key value.
    ///
    /// For derivation, the message length must be a multiple of the block
    /// size. See <https://www.cryptsoft.com/pkcs11doc/v220/>.
    AesCbcEncryptData(ekdf::AesCbcDeriveParams<'a>),
    /// AES CMAC (RFC 4493)
    AesCMac,

    // RSA
    /// PKCS #1 RSA key pair generation mechanism
    RsaPkcsKeyPairGen,
    /// Multi-purpose mechanism based on the RSA public-key cryptosystem and the block formats
    /// initially defined in PKCS #1 v1.5
    RsaPkcs,
    /// Mechanism based on the RSA public-key cryptosystem and the PSS block format defined in PKCS
    /// #1
    RsaPkcsPss(rsa::PkcsPssParams),
    /// Multi-purpose mechanism based on the RSA public-key cryptosystem and the OAEP block format
    /// defined in PKCS #1
    RsaPkcsOaep(PkcsOaepParams<'a>),
    /// Multi-purpose mechanism based on the RSA public-key cryptosystem.  This is so-called "raw"
    /// RSA, as assumed in X.509.
    RsaX509,

    // DES
    /// DES
    DesKeyGen,
    /// DES2
    Des2KeyGen,
    /// DES3
    Des3KeyGen,
    /// DES-CBC mechanism
    ///
    /// The parameter to this mechanism is the initialization vector.
    ///
    /// For encryption, the message length must be a multiple of the block
    /// size.  For wrapping, the mechanism encrypts the value of the key,
    /// padded on the trailing end with up to block size minus one null bytes.
    /// For unwrapping, the result is truncated according to the key type and
    /// the length provided by the template.
    DesCbc([u8; 8]),
    /// DES3-CBC mechanism
    ///
    /// The parameter to this mechanism is the initialization vector.
    ///
    /// For encryption, the message length must be a multiple of the block
    /// size.  For wrapping, the mechanism encrypts the value of the key,
    /// padded on the trailing end with up to block size minus one null bytes.
    /// For unwrapping, the result is truncated according to the key type and
    /// the length provided by the template.
    Des3Cbc([u8; 8]),
    /// DES-CBC with PKCS#7 padding mechanism
    ///
    /// The parameter to this mechanism is the initialization vector.
    ///
    /// The plaintext may be any size.  The PKCS#7 padding allows the length of
    /// the plaintext to be recovered from the ciphertext.  Therefore no length
    /// should be provided when unwrapping keys with this mechanism.
    DesCbcPad([u8; 8]),
    /// DES3-CBC with PKCS#7 padding mechanism
    ///
    /// The parameter to this mechanism is the initialization vector.
    ///
    /// The plaintext may be any size.  The PKCS#7 padding allows the length of
    /// the plaintext to be recovered from the ciphertext.  Therefore no length
    /// should be provided when unwrapping keys with this mechanism.
    Des3CbcPad([u8; 8]),
    /// DES ECB
    DesEcb,
    /// DES3 ECB
    Des3Ecb,

    // ECC
    /// EC key pair generation
    EccKeyPairGen,
    /// EC edwards key pair generation
    EccEdwardsKeyPairGen,
    /// EC montgomery key pair generation
    EccMontgomeryKeyPairGen,
    /// ECDH
    Ecdh1Derive(elliptic_curve::Ecdh1DeriveParams<'a>),
    /// ECDSA mechanism
    Ecdsa,
    /// ECDSA with SHA-1 mechanism
    EcdsaSha1,
    /// ECDSA with SHA-224 mechanism
    EcdsaSha224,
    /// ECDSA with SHA-256 mechanism
    EcdsaSha256,
    /// ECDSA with SHA-384 mechanism
    EcdsaSha384,
    /// ECDSA with SHA-512 mechanism
    EcdsaSha512,
    /// EDDSA mechanism
    ///
    /// This mechanism has an optional parameter, a CK_EDDSA_PARAMS
    /// structure. The absence or presence of the parameter as well
    /// as its content is used to identify which signature scheme
    /// is to be used.
    ///
    /// Note: EdDSA is not part of the PKCS#11 v2.40 standard and as
    /// such may not be understood by some backends. It is included
    /// here because some vendor implementations support it through
    /// the v2.40 interface.
    Eddsa(eddsa::EddsaParams<'a>),

    // SHA-n
    /// SHA-1 mechanism
    Sha1,
    /// SHA-224 mechanism
    Sha224,
    /// SHA-256 mechanism
    Sha256,
    /// SHA-384 mechanism
    Sha384,
    /// SHA-512 mechanism
    Sha512,

    // SHAn-RSA-PKCS
    /// SHA1-RSA-PKCS mechanism
    Sha1RsaPkcs,
    /// SHA224-RSA-PKCS mechanism
    Sha224RsaPkcs,
    /// SHA256-RSA-PKCS mechanism
    Sha256RsaPkcs,
    /// SHA384-RSA-PKCS mechanism
    Sha384RsaPkcs,
    /// SHA512-RSA-PKCS mechanism
    Sha512RsaPkcs,

    // SHAn-RSA-PKCS-PSS
    /// SHA1-RSA-PKCS-PSS mechanism
    Sha1RsaPkcsPss(rsa::PkcsPssParams),
    /// SHA256-RSA-PKCS-PSS mechanism
    Sha256RsaPkcsPss(rsa::PkcsPssParams),
    /// SHA256-RSA-PKCS-PSS mechanism
    Sha384RsaPkcsPss(rsa::PkcsPssParams),
    /// SHA256-RSA-PKCS-PSS mechanism
    Sha512RsaPkcsPss(rsa::PkcsPssParams),

    // SHAn-HMAC
    /// SHA1-HMAC mechanism
    Sha1Hmac,
    /// SHA224-HMAC mechanism
    Sha224Hmac,
    /// SHA256-HMAC mechanism
    Sha256Hmac,
    /// SHA384-HMAC mechanism
    Sha384Hmac,
    /// SHA512-HMAC mechanism
    Sha512Hmac,

    // SHA-n key generation (for use with the corresponding HMAC mechanism)
    /// SHA-1 key generation mechanism
    Sha1KeyGen,
    /// SHA-224 key generation mechanism
    Sha224KeyGen,
    /// SHA-256 key generation mechanism
    Sha256KeyGen,
    /// SHA-384 key generation mechanism
    Sha384KeyGen,
    /// SHA-512 key generation mechanism
    Sha512KeyGen,

    /// GENERIC-SECRET-KEY-GEN mechanism
    GenericSecretKeyGen,

    // HKDF
    /// HKDF key gen mechanism
    HkdfKeyGen,
    /// HKDF-DERIVE mechanism
    HkdfDerive(hkdf::HkdfParams<'a>),
    /// HKDF-DATA mechanism
    HkdfData(hkdf::HkdfParams<'a>),

    // NIST SP 800-108 KDF (aka KBKDF)
    /// NIST SP 800-108 KDF (aka KBKDF) mechanism in counter-mode
    KbkdfCounter(kbkdf::KbkdfParams<'a>),
    /// NIST SP 800-108 KDF (aka KBKDF) mechanism in feedback-mode
    KbkdfFeedback(kbkdf::KbkdfFeedbackParams<'a>),
    /// NIST SP 800-108 KDF (aka KBKDF) mechanism in double pipeline-mode
    KbkdfDoublePipeline(kbkdf::KbkdfParams<'a>),

    /// Vendor defined mechanism
    VendorDefined(VendorDefinedMechanism<'a>),
}

impl Mechanism<'_> {
    /// Get the type of a mechanism
    pub fn mechanism_type(&self) -> MechanismType {
        match self {
            Mechanism::AesKeyGen => MechanismType::AES_KEY_GEN,
            Mechanism::AesEcb => MechanismType::AES_ECB,
            Mechanism::AesCbc(_) => MechanismType::AES_CBC,
            Mechanism::AesCbcPad(_) => MechanismType::AES_CBC_PAD,
            Mechanism::AesKeyWrap => MechanismType::AES_KEY_WRAP,
            Mechanism::AesKeyWrapPad => MechanismType::AES_KEY_WRAP_PAD,
            Mechanism::AesGcm(_) => MechanismType::AES_GCM,
            Mechanism::AesGcmMessage(_) => MechanismType::AES_GCM,
            Mechanism::AesCbcEncryptData(_) => MechanismType::AES_CBC_ENCRYPT_DATA,
            Mechanism::AesCMac => MechanismType::AES_CMAC,
            Mechanism::RsaPkcsKeyPairGen => MechanismType::RSA_PKCS_KEY_PAIR_GEN,
            Mechanism::RsaPkcs => MechanismType::RSA_PKCS,
            Mechanism::RsaPkcsPss(_) => MechanismType::RSA_PKCS_PSS,
            Mechanism::RsaPkcsOaep(_) => MechanismType::RSA_PKCS_OAEP,
            Mechanism::RsaX509 => MechanismType::RSA_X_509,

            Mechanism::DesKeyGen => MechanismType::DES_KEY_GEN,
            Mechanism::Des2KeyGen => MechanismType::DES2_KEY_GEN,
            Mechanism::Des3KeyGen => MechanismType::DES3_KEY_GEN,
            Mechanism::DesCbc(_) => MechanismType::DES_CBC,
            Mechanism::Des3Cbc(_) => MechanismType::DES3_CBC,
            Mechanism::DesCbcPad(_) => MechanismType::DES_CBC_PAD,
            Mechanism::Des3CbcPad(_) => MechanismType::DES3_CBC_PAD,
            Mechanism::DesEcb => MechanismType::DES_ECB,
            Mechanism::Des3Ecb => MechanismType::DES3_ECB,

            Mechanism::EccKeyPairGen => MechanismType::ECC_KEY_PAIR_GEN,
            Mechanism::EccEdwardsKeyPairGen => MechanismType::ECC_EDWARDS_KEY_PAIR_GEN,
            Mechanism::EccMontgomeryKeyPairGen => MechanismType::ECC_MONTGOMERY_KEY_PAIR_GEN,
            Mechanism::Eddsa(_) => MechanismType::EDDSA,
            Mechanism::Ecdh1Derive(_) => MechanismType::ECDH1_DERIVE,
            Mechanism::Ecdsa => MechanismType::ECDSA,
            Mechanism::EcdsaSha1 => MechanismType::ECDSA_SHA1,
            Mechanism::EcdsaSha224 => MechanismType::ECDSA_SHA224,
            Mechanism::EcdsaSha256 => MechanismType::ECDSA_SHA256,
            Mechanism::EcdsaSha384 => MechanismType::ECDSA_SHA384,
            Mechanism::EcdsaSha512 => MechanismType::ECDSA_SHA512,

            Mechanism::Sha1 => MechanismType::SHA1,
            Mechanism::Sha224 => MechanismType::SHA224,
            Mechanism::Sha256 => MechanismType::SHA256,
            Mechanism::Sha384 => MechanismType::SHA384,
            Mechanism::Sha512 => MechanismType::SHA512,

            Mechanism::Sha1RsaPkcs => MechanismType::SHA1_RSA_PKCS,
            Mechanism::Sha224RsaPkcs => MechanismType::SHA224_RSA_PKCS,
            Mechanism::Sha256RsaPkcs => MechanismType::SHA256_RSA_PKCS,
            Mechanism::Sha384RsaPkcs => MechanismType::SHA384_RSA_PKCS,
            Mechanism::Sha512RsaPkcs => MechanismType::SHA512_RSA_PKCS,

            Mechanism::Sha1RsaPkcsPss(_) => MechanismType::SHA1_RSA_PKCS_PSS,
            Mechanism::Sha256RsaPkcsPss(_) => MechanismType::SHA256_RSA_PKCS_PSS,
            Mechanism::Sha384RsaPkcsPss(_) => MechanismType::SHA384_RSA_PKCS_PSS,
            Mechanism::Sha512RsaPkcsPss(_) => MechanismType::SHA512_RSA_PKCS_PSS,

            Mechanism::Sha1Hmac => MechanismType::SHA1_HMAC,
            Mechanism::Sha224Hmac => MechanismType::SHA224_HMAC,
            Mechanism::Sha256Hmac => MechanismType::SHA256_HMAC,
            Mechanism::Sha384Hmac => MechanismType::SHA384_HMAC,
            Mechanism::Sha512Hmac => MechanismType::SHA512_HMAC,

            Mechanism::Sha1KeyGen => MechanismType::SHA1_KEY_GEN,
            Mechanism::Sha224KeyGen => MechanismType::SHA224_KEY_GEN,
            Mechanism::Sha256KeyGen => MechanismType::SHA256_KEY_GEN,
            Mechanism::Sha384KeyGen => MechanismType::SHA384_KEY_GEN,
            Mechanism::Sha512KeyGen => MechanismType::SHA512_KEY_GEN,

            Mechanism::GenericSecretKeyGen => MechanismType::GENERIC_SECRET_KEY_GEN,

            Mechanism::HkdfKeyGen => MechanismType::HKDF_KEY_GEN,
            Mechanism::HkdfDerive(_) => MechanismType::HKDF_DERIVE,
            Mechanism::HkdfData(_) => MechanismType::HKDF_DATA,

            Mechanism::KbkdfCounter(_) => MechanismType::SP800_108_COUNTER_KDF,
            Mechanism::KbkdfFeedback(_) => MechanismType::SP800_108_FEEDBACK_KDF,
            Mechanism::KbkdfDoublePipeline(_) => MechanismType::SP800_108_DOUBLE_PIPELINE_KDF,

            Mechanism::VendorDefined(vm) => MechanismType {
                val: vm.inner.mechanism,
            },
        }
    }
}

impl From<&Mechanism<'_>> for CK_MECHANISM {
    fn from(mech: &Mechanism) -> Self {
        let mechanism = mech.mechanism_type().into();
        match mech {
            // Mechanisms with parameters
            Mechanism::AesCbc(params) | Mechanism::AesCbcPad(params) => {
                make_mechanism(mechanism, params)
            }
            Mechanism::AesCbcEncryptData(params) => make_mechanism(mechanism, params),
            Mechanism::DesCbc(params)
            | Mechanism::Des3Cbc(params)
            | Mechanism::DesCbcPad(params)
            | Mechanism::Des3CbcPad(params) => make_mechanism(mechanism, params),
            Mechanism::AesGcm(params) => CK_MECHANISM {
                mechanism,
                pParameter: params as *const _ as *mut c_void,
                ulParameterLen: size_of::<CK_GCM_PARAMS>()
                    .try_into()
                    .expect("usize can not fit in CK_ULONG"),
            },
            Mechanism::AesGcmMessage(params) => CK_MECHANISM {
                mechanism,
                pParameter: params as *const _ as *mut c_void,
                ulParameterLen: size_of::<CK_GCM_MESSAGE_PARAMS>()
                    .try_into()
                    .expect("usize can not fit in CK_ULONG"),
            },
            Mechanism::RsaPkcsPss(params)
            | Mechanism::Sha1RsaPkcsPss(params)
            | Mechanism::Sha256RsaPkcsPss(params)
            | Mechanism::Sha384RsaPkcsPss(params)
            | Mechanism::Sha512RsaPkcsPss(params) => make_mechanism(mechanism, params),
            Mechanism::RsaPkcsOaep(params) => make_mechanism(mechanism, params),
            Mechanism::Ecdh1Derive(params) => make_mechanism(mechanism, params),
            Mechanism::Eddsa(params) => match params.inner() {
                None => CK_MECHANISM {
                    mechanism,
                    pParameter: null_mut(),
                    ulParameterLen: 0,
                },
                Some(params) => make_mechanism(mechanism, params),
            },
            Mechanism::HkdfDerive(params) | Mechanism::HkdfData(params) => {
                make_mechanism(mechanism, params)
            }
            Mechanism::KbkdfCounter(params) | Mechanism::KbkdfDoublePipeline(params) => {
                make_mechanism(mechanism, params.inner())
            }
            Mechanism::KbkdfFeedback(params) => make_mechanism(mechanism, params.inner()),
            // Mechanisms without parameters
            Mechanism::AesKeyGen
            | Mechanism::AesEcb
            | Mechanism::AesKeyWrap
            | Mechanism::AesKeyWrapPad
            | Mechanism::AesCMac
            | Mechanism::RsaPkcsKeyPairGen
            | Mechanism::RsaPkcs
            | Mechanism::RsaX509
            | Mechanism::Sha1
            | Mechanism::Sha224
            | Mechanism::Sha256
            | Mechanism::Sha384
            | Mechanism::Sha512
            | Mechanism::DesKeyGen
            | Mechanism::Des2KeyGen
            | Mechanism::Des3KeyGen
            | Mechanism::DesEcb
            | Mechanism::Des3Ecb
            | Mechanism::EccKeyPairGen
            | Mechanism::EccEdwardsKeyPairGen
            | Mechanism::EccMontgomeryKeyPairGen
            | Mechanism::Ecdsa
            | Mechanism::EcdsaSha1
            | Mechanism::EcdsaSha224
            | Mechanism::EcdsaSha256
            | Mechanism::EcdsaSha384
            | Mechanism::EcdsaSha512
            | Mechanism::Sha1RsaPkcs
            | Mechanism::Sha224RsaPkcs
            | Mechanism::Sha256RsaPkcs
            | Mechanism::Sha384RsaPkcs
            | Mechanism::Sha512RsaPkcs
            | Mechanism::Sha1Hmac
            | Mechanism::Sha224Hmac
            | Mechanism::Sha256Hmac
            | Mechanism::Sha384Hmac
            | Mechanism::Sha512Hmac
            | Mechanism::Sha1KeyGen
            | Mechanism::Sha224KeyGen
            | Mechanism::Sha256KeyGen
            | Mechanism::Sha384KeyGen
            | Mechanism::Sha512KeyGen
            | Mechanism::GenericSecretKeyGen
            | Mechanism::HkdfKeyGen => CK_MECHANISM {
                mechanism,
                pParameter: null_mut(),
                ulParameterLen: 0,
            },
            // Vendor defined mechanisms
            Mechanism::VendorDefined(vm) => vm.inner,
        }
    }
}

// Make a CK_MECHANISM from mechanism type and parameter
fn make_mechanism<T>(mechanism: CK_MECHANISM_TYPE, param: &T) -> CK_MECHANISM {
    CK_MECHANISM {
        mechanism,
        /*
         * SAFETY: Parameters that expect to have some part of themselves
         * mutated should indicate this to the end user by marking both the
         * relevant constructor parameters and the type's PhantomData as mut.
         * Otherwise, we should generally not expect the backend to mutate the
         * parameters, so this cast is fine.
         * The list of such mutable parameter types so far:
         * - aead::GcmParams
         * - aead::GcmMessageParams
         * - kbkdf::KbkdfParams
         * - kbkdf::KbkdfFeedbackParams
         */
        pParameter: param as *const T as *mut c_void,
        ulParameterLen: size_of::<T>()
            .try_into()
            .expect("usize can not fit in CK_ULONG"),
    }
}

/// Type defining a specific mechanism parameters used for message based operations
#[derive(Debug)]
pub enum MessageParam<'a> {
    /// AES-GCM mechanism with message based API and parameters
    AesGcmMessage(aead::GcmMessageParams<'a>),
}

impl MessageParam<'_> {
    pub(crate) fn as_ptr(&self) -> *mut ::std::os::raw::c_void {
        match self {
            MessageParam::AesGcmMessage(param) => param as *const _ as *mut c_void,
        }
    }

    pub(crate) fn len(&self) -> CK_ULONG {
        match self {
            MessageParam::AesGcmMessage(_) => size_of::<CK_GCM_MESSAGE_PARAMS>()
                .try_into()
                .expect("usize can not fit in CK_ULONG"),
        }
    }
}
