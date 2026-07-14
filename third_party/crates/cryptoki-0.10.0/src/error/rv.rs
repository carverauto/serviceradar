// Copyright 2021 Contributors to the Parsec project.
// SPDX-License-Identifier: Apache-2.0
//! Function types

use crate::context::Function;

use super::{Error, Result, RvError};
use cryptoki_sys::*;
use log::error;

#[derive(Copy, Clone, Debug)]
/// Return value of a PKCS11 function
pub enum Rv {
    /// The function exited successfully
    Ok,
    /// There was an error
    Error(RvError),
}

impl From<CK_RV> for Rv {
    fn from(ck_rv: CK_RV) -> Self {
        match ck_rv {
            CKR_OK => Rv::Ok,
            CKR_CANCEL => Rv::Error(RvError::Cancel),
            CKR_HOST_MEMORY => Rv::Error(RvError::HostMemory),
            CKR_SLOT_ID_INVALID => Rv::Error(RvError::SlotIdInvalid),
            CKR_GENERAL_ERROR => Rv::Error(RvError::GeneralError),
            CKR_FUNCTION_FAILED => Rv::Error(RvError::FunctionFailed),
            CKR_ARGUMENTS_BAD => Rv::Error(RvError::ArgumentsBad),
            CKR_NO_EVENT => Rv::Error(RvError::NoEvent),
            CKR_NEED_TO_CREATE_THREADS => Rv::Error(RvError::NeedToCreateThreads),
            CKR_CANT_LOCK => Rv::Error(RvError::CantLock),
            CKR_ATTRIBUTE_READ_ONLY => Rv::Error(RvError::AttributeReadOnly),
            CKR_ATTRIBUTE_SENSITIVE => Rv::Error(RvError::AttributeSensitive),
            CKR_ATTRIBUTE_TYPE_INVALID => Rv::Error(RvError::AttributeTypeInvalid),
            CKR_ATTRIBUTE_VALUE_INVALID => Rv::Error(RvError::AttributeValueInvalid),
            CKR_ACTION_PROHIBITED => Rv::Error(RvError::ActionProhibited),
            CKR_DATA_INVALID => Rv::Error(RvError::DataInvalid),
            CKR_DATA_LEN_RANGE => Rv::Error(RvError::DataLenRange),
            CKR_DEVICE_ERROR => Rv::Error(RvError::DeviceError),
            CKR_DEVICE_MEMORY => Rv::Error(RvError::DeviceMemory),
            CKR_DEVICE_REMOVED => Rv::Error(RvError::DeviceRemoved),
            CKR_ENCRYPTED_DATA_INVALID => Rv::Error(RvError::EncryptedDataInvalid),
            CKR_ENCRYPTED_DATA_LEN_RANGE => Rv::Error(RvError::EncryptedDataLenRange),
            CKR_FUNCTION_CANCELED => Rv::Error(RvError::FunctionCanceled),
            CKR_FUNCTION_NOT_PARALLEL => Rv::Error(RvError::FunctionNotParallel),
            CKR_FUNCTION_NOT_SUPPORTED => Rv::Error(RvError::FunctionNotSupported),
            CKR_CURVE_NOT_SUPPORTED => Rv::Error(RvError::CurveNotSupported),
            CKR_KEY_HANDLE_INVALID => Rv::Error(RvError::KeyHandleInvalid),
            CKR_KEY_SIZE_RANGE => Rv::Error(RvError::KeySizeRange),
            CKR_KEY_TYPE_INCONSISTENT => Rv::Error(RvError::KeyTypeInconsistent),
            CKR_KEY_NOT_NEEDED => Rv::Error(RvError::KeyNotNeeded),
            CKR_KEY_CHANGED => Rv::Error(RvError::KeyChanged),
            CKR_KEY_NEEDED => Rv::Error(RvError::KeyNeeded),
            CKR_KEY_INDIGESTIBLE => Rv::Error(RvError::KeyIndigestible),
            CKR_KEY_FUNCTION_NOT_PERMITTED => Rv::Error(RvError::KeyFunctionNotPermitted),
            CKR_KEY_NOT_WRAPPABLE => Rv::Error(RvError::KeyNotWrappable),
            CKR_KEY_UNEXTRACTABLE => Rv::Error(RvError::KeyUnextractable),
            CKR_MECHANISM_INVALID => Rv::Error(RvError::MechanismInvalid),
            CKR_MECHANISM_PARAM_INVALID => Rv::Error(RvError::MechanismParamInvalid),
            CKR_OBJECT_HANDLE_INVALID => Rv::Error(RvError::ObjectHandleInvalid),
            CKR_OPERATION_ACTIVE => Rv::Error(RvError::OperationActive),
            CKR_OPERATION_NOT_INITIALIZED => Rv::Error(RvError::OperationNotInitialized),
            CKR_PIN_INCORRECT => Rv::Error(RvError::PinIncorrect),
            CKR_PIN_INVALID => Rv::Error(RvError::PinInvalid),
            CKR_PIN_LEN_RANGE => Rv::Error(RvError::PinLenRange),
            CKR_PIN_EXPIRED => Rv::Error(RvError::PinExpired),
            CKR_PIN_LOCKED => Rv::Error(RvError::PinLocked),
            CKR_SESSION_CLOSED => Rv::Error(RvError::SessionClosed),
            CKR_SESSION_COUNT => Rv::Error(RvError::SessionCount),
            CKR_SESSION_HANDLE_INVALID => Rv::Error(RvError::SessionHandleInvalid),
            CKR_SESSION_PARALLEL_NOT_SUPPORTED => Rv::Error(RvError::SessionParallelNotSupported),
            CKR_SESSION_READ_ONLY => Rv::Error(RvError::SessionReadOnly),
            CKR_SESSION_EXISTS => Rv::Error(RvError::SessionExists),
            CKR_SESSION_READ_ONLY_EXISTS => Rv::Error(RvError::SessionReadOnlyExists),
            CKR_SESSION_READ_WRITE_SO_EXISTS => Rv::Error(RvError::SessionReadWriteSoExists),
            CKR_SIGNATURE_INVALID => Rv::Error(RvError::SignatureInvalid),
            CKR_SIGNATURE_LEN_RANGE => Rv::Error(RvError::SignatureLenRange),
            CKR_TEMPLATE_INCOMPLETE => Rv::Error(RvError::TemplateIncomplete),
            CKR_TEMPLATE_INCONSISTENT => Rv::Error(RvError::TemplateInconsistent),
            CKR_TOKEN_NOT_PRESENT => Rv::Error(RvError::TokenNotPresent),
            CKR_TOKEN_NOT_RECOGNIZED => Rv::Error(RvError::TokenNotRecognized),
            CKR_TOKEN_WRITE_PROTECTED => Rv::Error(RvError::TokenWriteProtected),
            CKR_UNWRAPPING_KEY_HANDLE_INVALID => Rv::Error(RvError::UnwrappingKeyHandleInvalid),
            CKR_UNWRAPPING_KEY_SIZE_RANGE => Rv::Error(RvError::UnwrappingKeySizeRange),
            CKR_UNWRAPPING_KEY_TYPE_INCONSISTENT => {
                Rv::Error(RvError::UnwrappingKeyTypeInconsistent)
            }
            CKR_USER_ALREADY_LOGGED_IN => Rv::Error(RvError::UserAlreadyLoggedIn),
            CKR_USER_NOT_LOGGED_IN => Rv::Error(RvError::UserNotLoggedIn),
            CKR_USER_PIN_NOT_INITIALIZED => Rv::Error(RvError::UserPinNotInitialized),
            CKR_USER_TYPE_INVALID => Rv::Error(RvError::UserTypeInvalid),
            CKR_USER_ANOTHER_ALREADY_LOGGED_IN => Rv::Error(RvError::UserAnotherAlreadyLoggedIn),
            CKR_USER_TOO_MANY_TYPES => Rv::Error(RvError::UserTooManyTypes),
            CKR_WRAPPED_KEY_INVALID => Rv::Error(RvError::WrappedKeyInvalid),
            CKR_WRAPPED_KEY_LEN_RANGE => Rv::Error(RvError::WrappedKeyLenRange),
            CKR_WRAPPING_KEY_HANDLE_INVALID => Rv::Error(RvError::WrappingKeyHandleInvalid),
            CKR_WRAPPING_KEY_SIZE_RANGE => Rv::Error(RvError::WrappingKeySizeRange),
            CKR_WRAPPING_KEY_TYPE_INCONSISTENT => Rv::Error(RvError::WrappingKeyTypeInconsistent),
            CKR_RANDOM_SEED_NOT_SUPPORTED => Rv::Error(RvError::RandomSeedNotSupported),
            CKR_RANDOM_NO_RNG => Rv::Error(RvError::RandomNoRng),
            CKR_DOMAIN_PARAMS_INVALID => Rv::Error(RvError::DomainParamsInvalid),
            CKR_BUFFER_TOO_SMALL => Rv::Error(RvError::BufferTooSmall),
            CKR_SAVED_STATE_INVALID => Rv::Error(RvError::SavedStateInvalid),
            CKR_INFORMATION_SENSITIVE => Rv::Error(RvError::InformationSensitive),
            CKR_STATE_UNSAVEABLE => Rv::Error(RvError::StateUnsaveable),
            CKR_CRYPTOKI_NOT_INITIALIZED => Rv::Error(RvError::CryptokiNotInitialized),
            CKR_CRYPTOKI_ALREADY_INITIALIZED => Rv::Error(RvError::CryptokiAlreadyInitialized),
            CKR_MUTEX_BAD => Rv::Error(RvError::MutexBad),
            CKR_MUTEX_NOT_LOCKED => Rv::Error(RvError::MutexNotLocked),
            CKR_NEW_PIN_MODE => Rv::Error(RvError::NewPinMode),
            CKR_NEXT_OTP => Rv::Error(RvError::NextOtp),
            CKR_EXCEEDED_MAX_ITERATIONS => Rv::Error(RvError::ExceededMaxIterations),
            CKR_FIPS_SELF_TEST_FAILED => Rv::Error(RvError::FipsSelfTestFailed),
            CKR_LIBRARY_LOAD_FAILED => Rv::Error(RvError::LibraryLoadFailed),
            CKR_PIN_TOO_WEAK => Rv::Error(RvError::PinTooWeak),
            CKR_PUBLIC_KEY_INVALID => Rv::Error(RvError::PublicKeyInvalid),
            CKR_FUNCTION_REJECTED => Rv::Error(RvError::FunctionRejected),
            CKR_VENDOR_DEFINED => Rv::Error(RvError::VendorDefined),
            other => {
                error!(
                    "Can not find a corresponding error for {}, converting to GeneralError.",
                    other
                );
                Rv::Error(RvError::GeneralError)
            }
        }
    }
}

impl Rv {
    /// Convert the return value into a standard Result type
    pub fn into_result(self, function: Function) -> Result<()> {
        match self {
            Rv::Ok => Ok(()),
            Rv::Error(rv_error) => Err(Error::Pkcs11(rv_error, function)),
        }
    }
}
