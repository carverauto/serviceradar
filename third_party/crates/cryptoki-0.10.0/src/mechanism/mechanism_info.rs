// Copyright 2021 Contributors to the Parsec project.
// SPDX-License-Identifier: Apache-2.0
//! Mechanism info and associated flags

use bitflags::bitflags;
use cryptoki_sys::*;
use std::fmt::{Debug, Formatter};

bitflags! {
    struct MechanismInfoFlags: CK_FLAGS {
        const HW = CKF_HW;
        const ENCRYPT = CKF_ENCRYPT;
        const DECRYPT = CKF_DECRYPT;
        const DIGEST = CKF_DIGEST;
        const SIGN = CKF_SIGN;
        const SIGN_RECOVER = CKF_SIGN_RECOVER;
        const VERIFY = CKF_VERIFY;
        const VERIFY_RECOVER = CKF_VERIFY_RECOVER;
        const GENERATE = CKF_GENERATE;
        const GENERATE_KEY_PAIR = CKF_GENERATE_KEY_PAIR;
        const WRAP = CKF_WRAP;
        const UNWRAP = CKF_UNWRAP;
        const DERIVE = CKF_DERIVE;
        const EXTENSION = CKF_EXTENSION;
        const EC_F_P = CKF_EC_F_P;
        const EC_F_2M = CKF_EC_F_2M;
        const EC_ECPARAMETERS = CKF_EC_ECPARAMETERS;
        const EC_NAMEDCURVE = CKF_EC_NAMEDCURVE;
        const EC_OID = CKF_EC_OID;
        const EC_UNCOMPRESS = CKF_EC_UNCOMPRESS;
        const EC_COMPRESS = CKF_EC_COMPRESS;
        const MESSAGE_ENCRYPT = CKF_MESSAGE_ENCRYPT;
        const MESSAGE_DECRYPT = CKF_MESSAGE_DECRYPT;
        const MULTI_MESSAGE = CKF_MULTI_MESSAGE;
    }
}

/// Information about a particular mechanism
#[derive(Debug, Clone, Copy)]
pub struct MechanismInfo {
    min_key_size: usize,
    max_key_size: usize,
    flags: MechanismInfoFlags,
}

impl MechanismInfo {
    /// The minimum size of the key for the mechanism
    ///
    /// **[Conformance](crate#conformance-notes):**
    /// Whether this is measured in bits or in bytes is mechanism-dependent.
    /// For some mechanisms, this field may be meaningless and take any value.
    pub fn min_key_size(&self) -> usize {
        self.min_key_size
    }

    /// The maximum size of the key for the mechanism
    ///
    /// **[Conformance](crate#conformance-notes):**
    /// Whether this is measured in bits or in bytes is mechanism-dependent
    /// For some mechanisms, this field may be meaningless and take any value.
    pub fn max_key_size(&self) -> usize {
        self.max_key_size
    }

    /// True if the mechanism is performed by the device; false if the
    /// mechanism is performed in software
    pub fn hardware(&self) -> bool {
        self.flags.contains(MechanismInfoFlags::HW)
    }

    /// True if the mechanism can be used to encrypt data
    ///
    /// See [`Session::encrypt`](crate::session::Session::encrypt)
    pub fn encrypt(&self) -> bool {
        self.flags.contains(MechanismInfoFlags::ENCRYPT)
    }

    /// True if the mechanism can be used to decrypt encrypted data
    ///
    /// See [`Session::decrypt`](crate::session::Session::decrypt)
    pub fn decrypt(&self) -> bool {
        self.flags.contains(MechanismInfoFlags::DECRYPT)
    }

    /// True if the mechanism can be used to digest a message
    // TODO See [`Session::digest`](crate::session::Session::digest)
    pub fn digest(&self) -> bool {
        self.flags.contains(MechanismInfoFlags::DIGEST)
    }

    /// True if the mechanism can be used to digitally sign data
    ///
    /// See [`Session::sign`](crate::session::Session::sign)
    pub fn sign(&self) -> bool {
        self.flags.contains(MechanismInfoFlags::SIGN)
    }

    /// True if the mechanism can be used to digitally data which can be
    /// recovered from the signature
    ///
    // TODO See [`Session::sign_recover`](crate::session::Session::sign_recover)
    pub fn sign_recover(&self) -> bool {
        self.flags.contains(MechanismInfoFlags::SIGN_RECOVER)
    }

    /// True if the mechanism can be used to verify a digital signature
    ///
    /// See [`Session::verify`](crate::session::Session::verify)
    pub fn verify(&self) -> bool {
        self.flags.contains(MechanismInfoFlags::VERIFY)
    }

    /// True if the mechanism can be used to verify a digital signature and
    /// recover the signed data
    ///
    // TODO See [`Session::verify_recover`](crate::session::Session::verify_recover)
    pub fn verify_recover(&self) -> bool {
        self.flags.contains(MechanismInfoFlags::VERIFY_RECOVER)
    }

    /// True if the mechanism can be used to generate a secret key
    ///
    // TODO See [`Session::generate`](crate::session::Session::generate)
    pub fn generate(&self) -> bool {
        self.flags.contains(MechanismInfoFlags::GENERATE)
    }

    /// True if the mechanism can be used to generate a public/private key pair
    ///
    /// See [`Session::generate_key_pair`](crate::session::Session::generate_key_pair))
    pub fn generate_key_pair(&self) -> bool {
        self.flags.contains(MechanismInfoFlags::GENERATE_KEY_PAIR)
    }

    /// True if the mechanism can be used to wrap (encrypt) a key
    ///
    // TODO See [`Session::wrap`](crate::session::Session::wrap))
    pub fn wrap(&self) -> bool {
        self.flags.contains(MechanismInfoFlags::WRAP)
    }

    /// True if the mechanism can be used to unwrap (decrypt) a key
    ///
    // TODO See [`Session::unwrap`](crate::session::Session::unwrap))
    pub fn unwrap(&self) -> bool {
        self.flags.contains(MechanismInfoFlags::UNWRAP)
    }

    /// True if the mechanism can be used to derive a key from a base key
    ///
    // TODO See [`Session::derive`](crate::session::Session::derive))
    pub fn derive(&self) -> bool {
        self.flags.contains(MechanismInfoFlags::DERIVE)
    }

    /// True if there is an extension to the flags; false if no extensions
    ///
    /// **[Conformance](crate#conformance-notes):**
    /// This *must* be false for PKCS#11 v2.40
    pub fn extension(&self) -> bool {
        self.flags.contains(MechanismInfoFlags::EXTENSION)
    }

    /// True if the mechanism can be used to  with elliptic curve domain
    /// parameters over ***F<sub>p</sub>***
    ///
    /// **[Conformance](crate#conformance-notes):**
    /// *At least* one of [`ec_f_p`](Self::ec_f_p) and
    /// [`ec_f_2m`](Self::ec_f_2m) must be `true`
    pub fn ec_f_p(&self) -> bool {
        self.flags.contains(MechanismInfoFlags::EC_F_P)
    }

    /// True if the mechanism can be used with elliptic curve domain parameters
    /// over ***F<sub>2<sup>m</sup></sub>***
    ///
    /// **[Conformance](crate#conformance-notes):**
    /// *At least* one of [`ec_f_p`](Self::ec_f_p) and
    /// [`ec_f_2m`](Self::ec_f_2m) must be `true`
    pub fn ec_f_2m(&self) -> bool {
        self.flags.contains(MechanismInfoFlags::EC_F_2M)
    }

    /// True if the mechanism supports specifying elliptic curve domain
    /// parameters explicitly
    ///
    /// **[Conformance](crate#conformance-notes):**
    /// *At least* one of [`ec_from_parameters`](Self::ec_from_parameters) and
    /// [`ec_from_oid`](Self::ec_from_oid) must be `true`
    pub fn ec_from_parameters(&self) -> bool {
        self.flags.contains(MechanismInfoFlags::EC_ECPARAMETERS)
    }

    /// True if the mechanism supports specifying elliptic curve domain
    /// parameters with a named curve
    ///
    /// **[Conformance](crate#conformance-notes):**
    /// *At least* one of [`ec_from_parameters`](Self::ec_from_parameters) and
    /// [`ec_from_named_curve`](Self::ec_from_named_curve) must be `true`
    #[deprecated = "use `ec_from_oid` instead"]
    pub fn ec_from_named_curve(&self) -> bool {
        self.flags.contains(MechanismInfoFlags::EC_NAMEDCURVE)
    }

    /// True if the mechanism supports specifying elliptic curve domain
    /// parameters with an oid
    ///
    /// **[Conformance](crate#conformance-notes):**
    /// *At least* one of [`ec_from_parameters`](Self::ec_from_parameters) and
    /// [`ec_from_oid`](Self::ec_from_oid) must be `true`
    pub fn ec_from_oid(&self) -> bool {
        self.flags.contains(MechanismInfoFlags::EC_OID)
    }

    /// True if the mechanism can be used with elliptic curve points in
    /// uncompressed form
    ///
    /// **[Conformance](crate#conformance-notes):**
    /// *At least* one of [`ec_uncompressed`](Self::ec_uncompressed) and
    /// [`ec_compressed`](Self::ec_compressed) must be `true`
    pub fn ec_uncompressed(&self) -> bool {
        self.flags.contains(MechanismInfoFlags::EC_UNCOMPRESS)
    }

    /// True if the mechanism can be used with elliptic curve points in
    /// compressed form
    ///
    /// **[Conformance](crate#conformance-notes):**
    /// *At least* one of [`ec_uncompressed`](Self::ec_uncompressed) and
    /// [`ec_compressed`](Self::ec_compressed) must be `true`
    pub fn ec_compressed(&self) -> bool {
        self.flags.contains(MechanismInfoFlags::EC_COMPRESS)
    }

    /// True if the mechanism can be used to encrypt messages
    ///
    /// See [`Session::encrypt_message`](crate::session::Session::encrypt_message)
    pub fn message_encrypt(&self) -> bool {
        self.flags.contains(MechanismInfoFlags::MESSAGE_ENCRYPT)
    }

    /// True if the mechanism can be used to decrypt encrypted messages
    ///
    /// See [`Session::decrypt`](crate::session::Session::decrypt_message)
    pub fn message_decrypt(&self) -> bool {
        self.flags.contains(MechanismInfoFlags::MESSAGE_DECRYPT)
    }

    /// True if the mechanism can be used with encrypt/decrypt_message_begin API.
    /// One of message_* flag must also be set.
    ///
    pub fn multi_message(&self) -> bool {
        self.flags.contains(MechanismInfoFlags::MULTI_MESSAGE)
    }
}

impl std::fmt::Display for MechanismInfo {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:#?}", self.flags)?;

        if self.min_key_size == 0 && self.max_key_size == 0 {
            return Ok(());
        }

        write!(f, ", min_key_size={}", self.min_key_size)?;

        if self.max_key_size != 0 {
            write!(f, ", max_key_size={}", self.max_key_size)?;
        }

        Ok(())
    }
}

#[doc(hidden)]
impl From<CK_MECHANISM_INFO> for MechanismInfo {
    fn from(val: CK_MECHANISM_INFO) -> Self {
        Self {
            min_key_size: val.ulMinKeySize as usize,
            max_key_size: val.ulMaxKeySize as usize,
            flags: MechanismInfoFlags::from_bits_truncate(val.flags),
        }
    }
}

#[cfg(test)]
mod test {
    use super::{MechanismInfo, MechanismInfoFlags};

    #[test]
    fn debug_flags_all() {
        let expected = "\
HW | ENCRYPT | DECRYPT | DIGEST | SIGN | SIGN_RECOVER | VERIFY | \
VERIFY_RECOVER | GENERATE | GENERATE_KEY_PAIR | WRAP | UNWRAP | DERIVE | \
EXTENSION | EC_F_P | EC_F_2M | EC_ECPARAMETERS | EC_NAMEDCURVE | \
EC_OID | EC_UNCOMPRESS | EC_COMPRESS | MESSAGE_ENCRYPT | MESSAGE_DECRYPT | \
MULTI_MESSAGE";
        let all = MechanismInfoFlags::all();
        let observed = format!("{all:#?}");
        println!("{observed}");
        assert_eq!(observed, expected);
    }

    #[test]
    fn debug_info() {
        let info = MechanismInfo {
            min_key_size: 16,
            max_key_size: 4096,
            flags: MechanismInfoFlags::empty(),
        };
        let expected = r#"MechanismInfo {
    min_key_size: 16,
    max_key_size: 4096,
    flags: (empty),
}"#;
        let observed = format!("{info:#?}");
        assert_eq!(observed, expected);
    }
}
