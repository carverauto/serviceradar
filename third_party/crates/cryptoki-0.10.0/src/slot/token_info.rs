// Copyright 2021 Contributors to the Parsec project.
// SPDX-License-Identifier: Apache-2.0
//! PKCS11 Token info and associated flags

use crate::error::{Error, Result};
use crate::string_from_blank_padded;
use crate::types::convert_utc_time;
use crate::types::{UtcTime, Version};
use bitflags::bitflags;
use cryptoki_sys::*;
use std::convert::TryFrom;
use std::fmt::Debug;

bitflags! {
    /// Collection of flags defined for [`CK_TOKEN_INFO`]
    struct TokenInfoFlags: CK_FLAGS {
        const RNG = CKF_RNG;
        const WRITE_PROTECTED = CKF_WRITE_PROTECTED;
        const LOGIN_REQUIRED = CKF_LOGIN_REQUIRED;
        const USER_PIN_INITIALIZED = CKF_USER_PIN_INITIALIZED;
        const RESTORE_KEY_NOT_NEEDED = CKF_RESTORE_KEY_NOT_NEEDED;
        const CLOCK_ON_TOKEN = CKF_CLOCK_ON_TOKEN;
        const PROTECTED_AUTHENTICATION_PATH = CKF_PROTECTED_AUTHENTICATION_PATH;
        const DUAL_CRYPTO_OPERATIONS = CKF_DUAL_CRYPTO_OPERATIONS;
        const TOKEN_INITIALIZED = CKF_TOKEN_INITIALIZED;
        const SECONDARY_AUTHENTICATION = CKF_SECONDARY_AUTHENTICATION;
        const USER_PIN_COUNT_LOW = CKF_USER_PIN_COUNT_LOW;
        const USER_PIN_FINAL_TRY = CKF_USER_PIN_FINAL_TRY;
        const USER_PIN_LOCKED = CKF_USER_PIN_LOCKED;
        const USER_PIN_TO_BE_CHANGED = CKF_USER_PIN_TO_BE_CHANGED;
        const SO_PIN_COUNT_LOW = CKF_SO_PIN_COUNT_LOW;
        const SO_PIN_FINAL_TRY = CKF_SO_PIN_FINAL_TRY;
        const SO_PIN_LOCKED = CKF_SO_PIN_LOCKED;
        const SO_PIN_TO_BE_CHANGED = CKF_SO_PIN_TO_BE_CHANGED;
        const ERROR_STATE = CKF_ERROR_STATE;
    }
}

#[derive(Debug, Clone, Copy)]
/// A limiting value for the token that may or may not take an explicit value
pub enum Limit {
    /// There is an explicit value for this limit
    Max(u64),
    /// The token does not provide information about this limit
    Unavailable,
    /// The limit is "effectively infinite" and may be treated as such
    Infinite,
}

/// Information about a token
#[derive(Debug, Clone)]
pub struct TokenInfo {
    // The following four strings are limited in size based on
    // the originating struct definition. Sizes are in *bytes*
    // but UTF-8 data may represent fewer characters.
    // Original buffers were space (0x20) padded.
    label: String,           // len <= 32 bytes
    manufacturer_id: String, // len <= 32 bytes
    model: String,           // len <= 16 bytes
    serial_number: String,   // len <= 16 bytes
    flags: TokenInfoFlags,
    max_session_count: Limit,
    session_count: Option<u64>,
    max_rw_session_count: Limit,
    rw_session_count: Option<u64>,
    max_pin_len: usize,
    min_pin_len: usize,
    total_public_memory: Option<usize>,
    free_public_memory: Option<usize>,
    total_private_memory: Option<usize>,
    free_private_memory: Option<usize>,
    hardware_version: Version,
    firmware_version: Version,
    utc_time: Option<UtcTime>,
}
trait MaybeUnavailable: Sized {
    fn maybe_unavailable(value: CK_ULONG) -> Option<Self>;
}

impl MaybeUnavailable for usize {
    fn maybe_unavailable(value: CK_ULONG) -> Option<usize> {
        if value == CK_UNAVAILABLE_INFORMATION {
            None
        } else {
            Some(value as usize)
        }
    }
}

impl MaybeUnavailable for u64 {
    fn maybe_unavailable(value: CK_ULONG) -> Option<u64> {
        if value == CK_UNAVAILABLE_INFORMATION {
            None
        } else {
            // Must have cast for when ulong is 32 bits
            Some(value.into())
        }
    }
}

/// Flattens both `Infinite` and `Unavailable` to `None`,
impl From<Limit> for Option<u64> {
    fn from(limit: Limit) -> Self {
        match limit {
            Limit::Unavailable | Limit::Infinite => None,
            Limit::Max(n) => Some(n),
        }
    }
}

fn maybe_unlimited(value: CK_ULONG) -> Limit {
    match value {
        CK_UNAVAILABLE_INFORMATION => Limit::Unavailable,
        CK_EFFECTIVELY_INFINITE => Limit::Infinite,
        // Must have cast for when ulong is 32 bits
        _ => Limit::Max(value.into()),
    }
}

impl TokenInfo {
    /// An application-defined label, assigned during token initialization
    ///
    /// **[Conformance](crate#conformance-notes):**
    /// This string is maximally 32 bytes (*not* chars) as UTF-8
    pub fn label(&self) -> &str {
        &self.label
    }

    /// The ID of the device manufacturer
    ///
    /// **[Conformance](crate#conformance-notes):**
    /// This string is maximally 32 bytes (*not* chars) as UTF-8
    pub fn manufacturer_id(&self) -> &str {
        &self.manufacturer_id
    }

    /// The model of the device
    ///
    /// **[Conformance](crate#conformance-notes):**
    /// This string is maximally 16 bytes (*not* chars) as UTF-8
    pub fn model(&self) -> &str {
        &self.model
    }

    /// The character-string serial number of the device
    ///
    /// **[Conformance](crate#conformance-notes):**
    /// This string is maximally 16 bytes (*not* chars) as UTF-8
    pub fn serial_number(&self) -> &str {
        &self.serial_number
    }

    /// True if the token has its own random number generator
    pub fn rng(&self) -> bool {
        self.flags.contains(TokenInfoFlags::RNG)
    }

    /// True if the token is write-protected
    ///
    /// **[Conformance](crate#conformance-notes):**
    /// Exactly what this value means is determined by the application. An
    /// application may be unable to perform certain actions on a write-
    /// protected token. These actions can include any of the following (non-
    /// exhaustive):
    /// * Creating/modifying/deleting any object on the token
    /// * Creating/modifying/deleting a token object on the token
    /// * Changing the Security Officer's PIN
    /// * Changing the normal user's PIN
    ///
    /// The token may change its write-protected status depending on the
    /// session state to implement its object management policy. For instance,
    /// the token may report write-protection unless the session state is R/W
    /// SO or R/W User to implement a policy that does not allow any objects,
    /// public or private, to be created, modified, or deleted unless the user
    /// has successfully called [`Session::login`](crate::session::Session::login).
    pub fn write_protected(&self) -> bool {
        self.flags.contains(TokenInfoFlags::WRITE_PROTECTED)
    }

    /// True if there are some cryptographic functions that a user *must* be
    /// logged in to perform
    pub fn login_required(&self) -> bool {
        self.flags.contains(TokenInfoFlags::LOGIN_REQUIRED)
    }

    /// True of the normal user's PIN has been initialized
    pub fn user_pin_initialized(&self) -> bool {
        self.flags.contains(TokenInfoFlags::USER_PIN_INITIALIZED)
    }

    /// True if a successful save of a session's cryptographic operations state
    /// *always* contains all keys needed to restore the state of the session.
    pub fn restore_key_not_needed(&self) -> bool {
        self.flags.contains(TokenInfoFlags::RESTORE_KEY_NOT_NEEDED)
    }

    /// True if the token has its own hardware clock
    pub fn clock_on_token(&self) -> bool {
        self.flags.contains(TokenInfoFlags::CLOCK_ON_TOKEN)
    }

    /// True if the token has a "protected authentication path" whereby a user
    /// can log into the token without passing a PIN
    pub fn protected_authentication_path(&self) -> bool {
        self.flags
            .contains(TokenInfoFlags::PROTECTED_AUTHENTICATION_PATH)
    }

    /// True if a single session with the token can perform dual cryptographic
    /// operations
    // TODO: Requires Session callbacks to access
    // * digest_encrypt_update
    // * decrypt_digest_update
    // * sign_encrypt_update
    // * decrypt_verify_update
    pub fn dual_crypto_operations(&self) -> bool {
        self.flags.contains(TokenInfoFlags::DUAL_CRYPTO_OPERATIONS)
    }

    /// True if the token has been initialized with
    /// [`Pkcs11::init_token](crate::context::Pkcs11::init_token) or an
    /// equivalent mechanism outside the scope of the PKCS#11 standard
    ///
    /// **[Conformance](crate#conformance-notes):**
    /// Calling [`Pkcs11::init_token`](crate::context::Pkcs11::init_token) when
    /// this flag is set will cause the token to be reinitialized.
    pub fn token_initialized(&self) -> bool {
        self.flags.contains(TokenInfoFlags::TOKEN_INITIALIZED)
    }

    /// True if the token supports secondary authentication for private key
    /// objects
    /// **[Conformance](crate#conformance-notes):**
    /// This field is deprecated and new providers *must not* set it. I.e., this function must always return `false`.
    pub fn secondary_authentication(&self) -> bool {
        self.flags
            .contains(TokenInfoFlags::SECONDARY_AUTHENTICATION)
    }

    /// True if an incorrect user login PIN has been entered at least once
    /// since the last successful authentication
    ///
    /// **[Conformance](crate#conformance-notes):**
    /// This value may be set to always be false if the token either does not
    /// support the functionality or will not reveal the information because of
    /// its security policy.
    pub fn user_pin_count_low(&self) -> bool {
        self.flags.contains(TokenInfoFlags::USER_PIN_COUNT_LOW)
    }

    /// True if supplying an incorrect user PIN will cause it to become locked
    ///
    /// **[Conformance](crate#conformance-notes):**
    /// This value may be set to always be false if the token either does not
    /// support the functionality or will not reveal the information because of
    /// its security policy.
    pub fn user_pin_final_try(&self) -> bool {
        self.flags.contains(TokenInfoFlags::USER_PIN_FINAL_TRY)
    }

    /// True if the user PIN has been locked; user login to the token is not
    /// possible
    pub fn user_pin_locked(&self) -> bool {
        self.flags.contains(TokenInfoFlags::USER_PIN_LOCKED)
    }

    /// True if the user PIN value is the default value set by the token
    /// initialization or manufacturing, or the PIN has been expired by the
    /// card
    ///
    /// **[Conformance](crate#conformance-notes):**
    /// This may be always false if the token either does not support the
    /// functionality or will not reveal the information because of its
    /// security policy.
    ///
    /// If a PIN is set to the default value or has expired, this function
    /// returns `true`. When true, logging in with a PIN will succeed, but only
    /// the [`Session::set_pin`][crate::session::Session::set_pin] function can
    /// be called. Calling any other function that required the user to be
    /// logged in will cause [`PinExpired`][crate::error::RvError::PinExpired]
    /// to be returned until
    /// [`Session::set_pin`][crate::session::Session::set_pin] is called
    /// successfully.
    pub fn user_pin_to_be_changed(&self) -> bool {
        self.flags.contains(TokenInfoFlags::USER_PIN_TO_BE_CHANGED)
    }

    /// True if an incorrect Security Officer login PIN has been entered at least once since
    /// the last successful authentication
    ///
    /// **[Conformance](crate#conformance-notes):**
    /// This value may be set to always be false if the token either does not
    /// support the functionality or will not reveal the information because of
    /// its security policy.
    pub fn so_pin_count_low(&self) -> bool {
        self.flags.contains(TokenInfoFlags::SO_PIN_COUNT_LOW)
    }

    /// True if supplying an incorrect Security Officer PIN will cause it to become locked
    ///
    /// **[Conformance](crate#conformance-notes):**
    /// This value may be set to always be false if the token either does not
    /// support the functionality or will not reveal the information because of
    /// its security policy.
    pub fn so_pin_final_try(&self) -> bool {
        self.flags.contains(TokenInfoFlags::SO_PIN_FINAL_TRY)
    }

    /// True if the Security Officer PIN has been locked; Security Officer login to the token is not
    /// possible
    pub fn so_pin_locked(&self) -> bool {
        self.flags.contains(TokenInfoFlags::SO_PIN_LOCKED)
    }

    /// True if the Security Officer PIN value is the default value set by the token
    /// initialization or manufacturing, or the PIN has been expired by the card
    ///
    /// **[Conformance](crate#conformance-notes):**
    /// This may be always false if the token either does not support the
    /// functionality or will not reveal the information because of its security
    /// policy.
    ///
    /// If a PIN is set to the default value or has expired, this function
    /// returns `true`. When true, logging in with a PIN will succeed, but only
    /// the [`Session::set_pin`][crate::session::Session::set_pin] function can
    /// be called. Calling any other function that required the user to be
    /// logged in will cause [`PinExpired`][crate::error::RvError::PinExpired]
    /// to be returned until
    /// [`Session::set_pin`][crate::session::Session::set_pin] is called
    /// successfully.
    pub fn so_pin_to_be_changed(&self) -> bool {
        self.flags.contains(TokenInfoFlags::SO_PIN_TO_BE_CHANGED)
    }

    /// True if the token failed a FIPS 140-2 self-test and entered an error state
    pub fn error_state(&self) -> bool {
        self.flags.contains(TokenInfoFlags::ERROR_STATE)
    }

    /// The maximum number of sessions that can be opened with the token at one
    /// time by a single application.
    pub fn max_session_count(&self) -> Limit {
        self.max_session_count
    }

    /// The number of sessions this application currently has open with the
    /// token
    pub fn session_count(&self) -> Option<u64> {
        self.session_count
    }

    /// The maximum number of read/write sessions that can be opened with the
    /// token at one time by a single application.
    pub fn max_rw_session_count(&self) -> Limit {
        self.max_rw_session_count
    }

    /// The number of read/write sessions this application currently has open
    /// with the token
    pub fn rw_session_count(&self) -> Option<u64> {
        self.rw_session_count
    }

    /// The maximum length in bytes of the PIN
    pub fn max_pin_length(&self) -> usize {
        self.max_pin_len
    }

    /// The minimum length in bytes of the PIN
    pub fn min_pin_length(&self) -> usize {
        self.min_pin_len
    }

    /// The total amount of memory on the token (in bytes) in which public
    /// objects may be stored
    /// Returns `None` if this information is unavailable
    pub fn total_public_memory(&self) -> Option<usize> {
        self.total_public_memory
    }

    /// The amount of free (unused) emmeory on the token (in bytes) for public
    /// objects
    /// Returns `None` if this information is unavailable
    pub fn free_public_memory(&self) -> Option<usize> {
        self.free_public_memory
    }

    /// The total amount of memory on the token (in bytes) in which private
    /// objects may be stored
    /// Returns `None` if this information is unavailable
    pub fn total_private_memory(&self) -> Option<usize> {
        self.total_private_memory
    }

    /// The amount of free (unused) emmeory on the token (in bytes) for private
    /// objects
    /// Returns `None` if this information is unavailable
    pub fn free_private_memory(&self) -> Option<usize> {
        self.free_private_memory
    }

    /// The version number of the hardware
    pub fn hardware_version(&self) -> Version {
        self.hardware_version
    }

    /// The version number of the firmware
    pub fn firmware_version(&self) -> Version {
        self.firmware_version
    }

    /// The current UTC datetime reported by the token
    ///
    /// Returns `None` if the token is not equipped with a clock (i.e.,
    /// `self.clock_on_token() == false`)
    ///
    /// **[Conformance](crate#conformance-notes):**
    /// The string representation of the datetime from the token is only
    /// required to be parsable as a string of ASCII digits. No additional
    /// structure (e.g., months numbered from 0 or from 1) is defined.
    pub fn utc_time(&self) -> Option<UtcTime> {
        self.utc_time
    }
}

#[doc(hidden)]
impl TryFrom<CK_TOKEN_INFO> for TokenInfo {
    type Error = Error;
    fn try_from(val: CK_TOKEN_INFO) -> Result<Self> {
        let flags = TokenInfoFlags::from_bits_truncate(val.flags);
        let utc_time = if flags.contains(TokenInfoFlags::CLOCK_ON_TOKEN) {
            Some(convert_utc_time(val.utcTime)?)
        } else {
            None
        };
        Ok(Self {
            label: string_from_blank_padded(&val.label),
            manufacturer_id: string_from_blank_padded(&val.manufacturerID),
            model: string_from_blank_padded(&val.model),
            serial_number: string_from_blank_padded(&val.serialNumber),
            flags,
            max_session_count: maybe_unlimited(val.ulMaxSessionCount),
            session_count: u64::maybe_unavailable(val.ulSessionCount),
            max_rw_session_count: maybe_unlimited(val.ulMaxRwSessionCount),
            rw_session_count: u64::maybe_unavailable(val.ulRwSessionCount),
            max_pin_len: val.ulMaxPinLen as usize,
            min_pin_len: val.ulMinPinLen as usize,
            total_public_memory: usize::maybe_unavailable(val.ulTotalPublicMemory),
            free_public_memory: usize::maybe_unavailable(val.ulFreePublicMemory),
            total_private_memory: usize::maybe_unavailable(val.ulTotalPrivateMemory),
            free_private_memory: usize::maybe_unavailable(val.ulFreePrivateMemory),
            hardware_version: val.hardwareVersion.into(),
            firmware_version: val.firmwareVersion.into(),
            utc_time,
        })
    }
}

#[cfg(test)]
mod test {
    use super::{Limit, TokenInfo, TokenInfoFlags};
    use crate::types::{UtcTime, Version};

    #[test]
    fn debug_flags_all() {
        let expected = "\
RNG | WRITE_PROTECTED | LOGIN_REQUIRED | USER_PIN_INITIALIZED | \
RESTORE_KEY_NOT_NEEDED | CLOCK_ON_TOKEN | PROTECTED_AUTHENTICATION_PATH | \
DUAL_CRYPTO_OPERATIONS | TOKEN_INITIALIZED | SECONDARY_AUTHENTICATION | \
USER_PIN_COUNT_LOW | USER_PIN_FINAL_TRY | USER_PIN_LOCKED | \
USER_PIN_TO_BE_CHANGED | SO_PIN_COUNT_LOW | SO_PIN_FINAL_TRY | SO_PIN_LOCKED | \
SO_PIN_TO_BE_CHANGED | ERROR_STATE";
        let all = TokenInfoFlags::all();
        let observed = format!("{all:#?}");
        assert_eq!(observed, expected);
    }

    #[test]
    fn debug_info() {
        let info = TokenInfo {
            label: String::from("Token Label"),
            manufacturer_id: String::from("Manufacturer ID"),
            model: String::from("Token Model"),
            serial_number: String::from("Serial Number"),
            flags: TokenInfoFlags::empty(),
            max_session_count: Limit::Max(100),    // max == 100
            session_count: None,                   // unavailable
            max_rw_session_count: Limit::Infinite, // max == infinite
            rw_session_count: Some(1),
            max_pin_len: 16,
            min_pin_len: 4,
            total_public_memory: Some(1073741824), // 1GiB
            free_public_memory: Some(1234567890),
            total_private_memory: None, // unavailable
            free_private_memory: None,  // unavailable
            hardware_version: Version::new(0, 255),
            firmware_version: Version::new(255, 0),
            utc_time: Some(UtcTime {
                year: 1970,
                month: 1,
                day: 1,
                hour: 0,
                minute: 0,
                second: 0,
            }),
        };
        let expected = r#"TokenInfo {
    label: "Token Label",
    manufacturer_id: "Manufacturer ID",
    model: "Token Model",
    serial_number: "Serial Number",
    flags: (empty),
    max_session_count: Max(
        100,
    ),
    session_count: None,
    max_rw_session_count: Infinite,
    rw_session_count: Some(
        1,
    ),
    max_pin_len: 16,
    min_pin_len: 4,
    total_public_memory: Some(
        1073741824,
    ),
    free_public_memory: Some(
        1234567890,
    ),
    total_private_memory: None,
    free_private_memory: None,
    hardware_version: Version {
        major: 0,
        minor: 255,
    },
    firmware_version: Version {
        major: 255,
        minor: 0,
    },
    utc_time: Some(
        UtcTime {
            year: 1970,
            month: 1,
            day: 1,
            hour: 0,
            minute: 0,
            second: 0,
        },
    ),
}"#;
        let observed = format!("{info:#?}");
        assert_eq!(observed, expected);
    }
}
