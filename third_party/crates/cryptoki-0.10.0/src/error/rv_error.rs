// Copyright 2021 Contributors to the Parsec project.
// SPDX-License-Identifier: Apache-2.0
//! Function types

use std::fmt;

#[derive(Debug, Copy, Clone, PartialEq, Eq)]
/// Description of a return value error
pub enum RvError {
    /// When a function executing in serial with an application decides to give the application a chance to do some work, it calls an application-supplied function with a CKN_SURRENDER callback (see Section 5.16).  If the callback returns the value CKR_CANCEL, then the function aborts and returns CKR_FUNCTION_CANCELED.
    Cancel,
    /// The computer that the Cryptoki library is running on has insufficient memory to perform the requested function.
    HostMemory,
    /// The specified slot ID is not valid.
    SlotIdInvalid,
    /// Some horrible, unrecoverable error has occurred.  In the worst case, it is possible that the function only partially succeeded, and that the computer and/or token is in an inconsistent state.
    GeneralError,
    /// The requested function could not be performed, but detailed information about why not is not available in this error return.  If the failed function uses a session, it is possible that the CK_SESSION_INFO structure that can be obtained by calling C_GetSessionInfo will hold useful information about what happened in its ulDeviceError field.  In any event, although the function call failed, the situation is not necessarily totally hopeless, as it is likely to be when CKR_GENERAL_ERROR is returned.  Depending on what the root cause of the error actually was, it is possible that an attempt to make the exact same function call again would succeed.
    FunctionFailed,
    /// This is a rather generic error code which indicates that the arguments supplied to the Cryptoki function were in some way not appropriate.
    ArgumentsBad,
    /// This value can only be returned by C_GetSlotEvent.  It is returned when C_GetSlotEvent is called in non-blocking mode and there are no new slot events to return.
    NoEvent,
    /// This value can only be returned by C_Initialize.  It is returned when two conditions hold: 1. The application called C_Initialize in a way which tells the Cryptoki library that application threads executing calls to the library cannot use native operating system methods to spawn new threads. 2. The library cannot function properly without being able to spawn new threads in the above fashion.
    NeedToCreateThreads,
    /// This value can only be returned by C_Initialize.  It means that the type of locking requested by the application for thread-safety is not available in this library, and so the application cannot make use of this library in the specified fashion.
    CantLock,
    /// An attempt was made to set a value for an attribute which may not be set by the application, or which may not be modified by the application.  See Section 4.1 for more information.
    AttributeReadOnly,
    /// An attempt was made to obtain the value of an attribute of an object which cannot be satisfied because the object is either sensitive or un-extractable.
    AttributeSensitive,
    /// An invalid attribute type was specified in a template.  See Section 4.1 for more information.
    AttributeTypeInvalid,
    /// An invalid value was specified for a particular attribute in a template.  See Section 4.1 for more information.
    AttributeValueInvalid,
    ///  This value can only be returned by C_CopyObject, C_SetAttributeValue and C_DestroyObject. It denotes that the action may not be taken, either because of underlying policy restrictions on the token, or because the object has the the relevant CKA_COPYABLE, CKA_MODIFIABLE or CKA_DESTROYABLE policy attribute set to CK_FALSE.
    ActionProhibited,
    /// The plaintext input data to a cryptographic operation is invalid.  This return value has lower priority than CKR_DATA_LEN_RANGE.
    DataInvalid,
    /// The plaintext input data to a cryptographic operation has a bad length.  Depending on the operation’s mechanism, this could mean that the plaintext data is too short, too long, or is not a multiple of some particular block size.  This return value has higher priority than CKR_DATA_INVALID.
    DataLenRange,
    /// Some problem has occurred with the token and/or slot.  This error code can be returned by more than just the functions mentioned above; in particular, it is possible for C_GetSlotInfo to return CKR_DEVICE_ERROR.
    DeviceError,
    /// The token does not have sufficient memory to perform the requested function.
    DeviceMemory,
    /// The token was removed from its slot during the execution of the function.
    DeviceRemoved,
    /// The encrypted input to a decryption operation has been determined to be invalid ciphertext.  This return value has lower priority than CKR_ENCRYPTED_DATA_LEN_RANGE.
    EncryptedDataInvalid,
    /// The ciphertext input to a decryption operation has been determined to be invalid ciphertext solely on the basis of its length.  Depending on the operation’s mechanism, this could mean that the ciphertext is too short, too long, or is not a multiple of some particular block size.  This return value has higher priority than CKR_ENCRYPTED_DATA_INVALID.
    EncryptedDataLenRange,
    /// The function was canceled in mid-execution.  This happens to a cryptographic function if the function makes a CKN_SURRENDER application callback which returns CKR_CANCEL (see CKR_CANCEL). It also happens to a function that performs PIN entry through a protected path. The method used to cancel a protected path PIN entry operation is device dependent.
    FunctionCanceled,
    /// There is currently no function executing in parallel in the specified session.  This is a legacy error code which is only returned by the legacy functions C_GetFunctionStatus and C_CancelFunction.
    FunctionNotParallel,
    /// The requested function is not supported by this Cryptoki library.  Even unsupported functions in the Cryptoki API should have a “stub” in the library; this stub should simply return the value CKR_FUNCTION_NOT_SUPPORTED.
    FunctionNotSupported,
    ///  This curve is not supported by this token.  Used with Elliptic Curve mechanisms.
    CurveNotSupported,
    /// The specified key handle is not valid.  It may be the case that the specified handle is a valid handle for an object which is not a key.  We reiterate here that 0 is never a valid key handle.
    KeyHandleInvalid,
    /// Although the requested keyed cryptographic operation could in principle be carried out, this Cryptoki library (or the token) is unable to actually do it because the supplied key‘s size is outside the range of key sizes that it can handle.
    KeySizeRange,
    /// The specified key is not the correct type of key to use with the specified mechanism.  This return value has a higher priority than CKR_KEY_FUNCTION_NOT_PERMITTED.
    KeyTypeInconsistent,
    /// An extraneous key was supplied to C_SetOperationState.  For example, an attempt was made to restore a session that had been performing a message digesting operation, and an encryption key was supplied.
    KeyNotNeeded,
    /// This value is only returned by C_SetOperationState.  It indicates that one of the keys specified is not the same key that was being used in the original saved session.
    KeyChanged,
    /// This value is only returned by C_SetOperationState.  It indicates that the session state cannot be restored because C_SetOperationState needs to be supplied with one or more keys that were being used in the original saved session.
    KeyNeeded,
    /// This error code can only be returned by C_DigestKey.  It indicates that the value of the specified key cannot be digested for some reason (perhaps the key isn’t a secret key, or perhaps the token simply can’t digest this kind of key).
    KeyIndigestible,
    /// An attempt has been made to use a key for a cryptographic purpose that the key’s attributes are not set to allow it to do.  For example, to use a key for performing encryption, that key MUST have its CKA_ENCRYPT attribute set to CK_TRUE (the fact that the key MUST have a CKA_ENCRYPT attribute implies that the key cannot be a private key).  This return value has lower priority than CKR_KEY_TYPE_INCONSISTENT.
    KeyFunctionNotPermitted,
    /// Although the specified private or secret key does not have its CKA_EXTRACTABLE attribute set to CK_FALSE, Cryptoki (or the token) is unable to wrap the key as requested (possibly the token can only wrap a given key with certain types of keys, and the wrapping key specified is not one of these types).  Compare with CKR_KEY_UNEXTRACTABLE.
    KeyNotWrappable,
    /// The specified private or secret key can’t be wrapped because its CKA_EXTRACTABLE attribute is set to CK_FALSE.  Compare with CKR_KEY_NOT_WRAPPABLE.
    KeyUnextractable,
    /// An invalid mechanism was specified to the cryptographic operation.  This error code is an appropriate return value if an unknown mechanism was specified or if the mechanism specified cannot be used in the selected token with the selected function.
    MechanismInvalid,
    /// Invalid parameters were supplied to the mechanism specified to the cryptographic operation.  Which parameter values are supported by a given mechanism can vary from token to token.
    MechanismParamInvalid,
    /// The specified object handle is not valid.  We reiterate here that 0 is never a valid object handle.
    ObjectHandleInvalid,
    /// There is already an active operation (or combination of active operations) which prevents Cryptoki from activating the specified operation.  For example, an active object-searching operation would prevent Cryptoki from activating an encryption operation with C_EncryptInit.  Or, an active digesting operation and an active encryption operation would prevent Cryptoki from activating a signature operation.  Or, on a token which doesn’t support simultaneous dual cryptographic operations in a session (see the description of the CKF_DUAL_CRYPTO_OPERATIONS flag in the CK_TOKEN_INFO structure), an active signature operation would prevent Cryptoki from activating an encryption operation.
    OperationActive,
    /// There is no active operation of an appropriate type in the specified session.  For example, an application cannot call C_Encrypt in a session without having called C_EncryptInit first to activate an encryption operation.
    OperationNotInitialized,
    /// The specified PIN is incorrect, i.e., does not match the PIN stored on the token.  More generally-- when authentication to the token involves something other than a PIN-- the attempt to authenticate the user has failed.
    PinIncorrect,
    /// The specified PIN has invalid characters in it.  This return code only applies to functions which attempt to set a PIN.
    PinInvalid,
    /// The specified PIN is too long or too short.  This return code only applies to functions which attempt to set a PIN.
    PinLenRange,
    /// The specified PIN has expired, and the requested operation cannot be carried out unless C_SetPIN is called to change the PIN value.  Whether or not the normal user’s PIN on a token ever expires varies from token to token.
    PinExpired,
    /// The specified PIN is “locked”, and cannot be used.  That is, because some particular number of failed authentication attempts has been reached, the token is unwilling to permit further attempts at authentication.  Depending on the token, the specified PIN may or may not remain locked indefinitely.
    PinLocked,
    /// The session was closed during the execution of the function.  Note that, as stated in [PKCS11-UG], the behavior of Cryptoki is undefined if multiple threads of an application attempt to access a common Cryptoki session simultaneously.  Therefore, there is actually no guarantee that a function invocation could ever return the value CKR_SESSION_CLOSED.  An example of multiple threads accessing a common session simultaneously is where one thread is using a session when another thread closes that same session.
    SessionClosed,
    /// This value can only be returned by C_OpenSession.  It indicates that the attempt to open a session failed, either because the token has too many sessions already open, or because the token has too many read/write sessions already open.
    SessionCount,
    /// The specified session handle was invalid at the time that the function was invoked.  Note that this can happen if the session’s token is removed before the function invocation, since removing a token closes all sessions with it.
    SessionHandleInvalid,
    /// The specified token does not support parallel sessions.  This is a legacy error code—in Cryptoki Version 2.01 and up, no token supports parallel sessions.  CKR_SESSION_PARALLEL_NOT_SUPPORTED can only be returned by C_OpenSession, and it is only returned when C_OpenSession is called in a particular `deprecated` way.
    SessionParallelNotSupported,
    /// The specified session was unable to accomplish the desired action because it is a read-only session.  This return value has lower priority than CKR_TOKEN_WRITE_PROTECTED.
    SessionReadOnly,
    /// This value can only be returned by C_InitToken.  It indicates that a session with the token is already open, and so the token cannot be initialized.
    SessionExists,
    /// A read-only session already exists, and so the SO cannot be logged in.
    SessionReadOnlyExists,
    /// A read/write SO session already exists, and so a read-only session cannot be opened.
    SessionReadWriteSoExists,
    /// The provided signature/MAC is invalid.  This return value has lower priority than CKR_SIGNATURE_LEN_RANGE.
    SignatureInvalid,
    /// The provided signature/MAC can be seen to be invalid solely on the basis of its length.  This return value has higher priority than CKR_SIGNATURE_INVALID.
    SignatureLenRange,
    /// The template specified for creating an object is incomplete, and lacks some necessary attributes.  See Section 4.1 for more information.
    TemplateIncomplete,
    /// The template specified for creating an object has conflicting attributes.  See Section 4.1 for more information.
    TemplateInconsistent,
    /// The token was not present in its slot at the time that the function was invoked.
    TokenNotPresent,
    /// The Cryptoki library and/or slot does not recognize the token in the slot.
    TokenNotRecognized,
    /// The requested action could not be performed because the token is write-protected.  This return value has higher priority than CKR_SESSION_READ_ONLY.
    TokenWriteProtected,
    /// This value can only be returned by C_UnwrapKey.  It indicates that the key handle specified to be used to unwrap another key is not valid.
    UnwrappingKeyHandleInvalid,
    /// This value can only be returned by C_UnwrapKey.  It indicates that although the requested unwrapping operation could in principle be carried out, this Cryptoki library (or the token) is unable to actually do it because the supplied key’s size is outside the range of key sizes that it can handle.
    UnwrappingKeySizeRange,
    /// This value can only be returned by C_UnwrapKey.  It indicates that the type of the key specified to unwrap another key is not consistent with the mechanism specified for unwrapping.
    UnwrappingKeyTypeInconsistent,
    /// This value can only be returned by C_Login.  It indicates that the specified user cannot be logged into the session, because it is already logged into the session.  For example, if an application has an open SO session, and it attempts to log the SO into it, it will receive this error code.
    UserAlreadyLoggedIn,
    /// The desired action cannot be performed because the appropriate user (or an appropriate user) is not logged in.  One example is that a session cannot be logged out unless it is logged in.  Another example is that a private object cannot be created on a token unless the session attempting to create it is logged in as the normal user.  A final example is that cryptographic operations on certain tokens cannot be performed unless the normal user is logged in.
    UserNotLoggedIn,
    /// This value can only be returned by C_Login.  It indicates that the normal user’s PIN has not yet been initialized with C_InitPIN.
    UserPinNotInitialized,
    /// An invalid value was specified as a CK_USER_TYPE.  Valid types are CKU_SO, CKU_USER, and CKU_CONTEXT_SPECIFIC.
    UserTypeInvalid,
    /// This value can only be returned by C_Login.  It indicates that the specified user cannot be logged into the session, because another user is already logged into the session.  For example, if an application has an open SO session, and it attempts to log the normal user into it, it will receive this error code.
    UserAnotherAlreadyLoggedIn,
    /// An attempt was made to have more distinct users simultaneously logged into the token than the token and/or library permits.  For example, if some application has an open SO session, and another application attempts to log the normal user into a session, the attempt may return this error.  It is not required to, however.  Only if the simultaneous distinct users cannot be supported does C_Login have to return this value.  Note that this error code generalizes to true multi-user tokens.
    UserTooManyTypes,
    /// This value can only be returned by C_UnwrapKey.  It indicates that the provided wrapped key is not valid.  If a call is made to C_UnwrapKey to unwrap a particular type of key (i.e., some particular key type is specified in the template provided to C_UnwrapKey), and the wrapped key provided to C_UnwrapKey is recognizably not a wrapped key of the proper type, then C_UnwrapKey should return CKR_WRAPPED_KEY_INVALID.  This return value has lower priority than CKR_WRAPPED_KEY_LEN_RANGE.
    WrappedKeyInvalid,
    /// This value can only be returned by C_UnwrapKey.  It indicates that the provided wrapped key can be seen to be invalid solely on the basis of its length.  This return value has higher priority than CKR_WRAPPED_KEY_INVALID.
    WrappedKeyLenRange,
    /// This value can only be returned by C_WrapKey.  It indicates that the key handle specified to be used to wrap another key is not valid.
    WrappingKeyHandleInvalid,
    /// This value can only be returned by C_WrapKey.  It indicates that although the requested wrapping operation could in principle be carried out, this Cryptoki library (or the token) is unable to actually do it because the supplied wrapping key’s size is outside the range of key sizes that it can handle.
    WrappingKeySizeRange,
    /// This value can only be returned by C_WrapKey.  It indicates that the type of the key specified to wrap another key is not consistent with the mechanism specified for wrapping.
    WrappingKeyTypeInconsistent,
    /// This value can only be returned by C_SeedRandom.  It indicates that the token’s random number generator does not accept seeding from an application.  This return value has lower priority than CKR_RANDOM_NO_RNG.
    RandomSeedNotSupported,
    /// This value can be returned by C_SeedRandom and C_GenerateRandom.  It indicates that the specified token doesn’t have a random number generator.  This return value has higher priority than CKR_RANDOM_SEED_NOT_SUPPORTED.
    RandomNoRng,
    /// Invalid or unsupported domain parameters were supplied to the function.  Which representation methods of domain parameters are supported by a given mechanism can vary from token to token.
    DomainParamsInvalid,
    /// The output of the function is too large to fit in the supplied buffer.
    BufferTooSmall,
    /// This value can only be returned by C_SetOperationState.  It indicates that the supplied saved cryptographic operations state is invalid, and so it cannot be restored to the specified session.
    SavedStateInvalid,
    /// The information requested could not be obtained because the token considers it sensitive, and is not able or willing to reveal it.
    InformationSensitive,
    /// The cryptographic operations state of the specified session cannot be saved for some reason (possibly the token is simply unable to save the current state).  This return value has lower priority than CKR_OPERATION_NOT_INITIALIZED.
    StateUnsaveable,
    /// This value can be returned by any function other than C_Initialize and C_GetFunctionList.  It indicates that the function cannot be executed because the Cryptoki library has not yet been initialized by a call to C_Initialize.
    CryptokiNotInitialized,
    /// This value can only be returned by C_Initialize.  It means that the Cryptoki library has already been initialized (by a previous call to C_Initialize which did not have a matching C_Finalize call).
    CryptokiAlreadyInitialized,
    /// This error code can be returned by mutex-handling functions that are passed a bad mutex object as an argument.  Unfortunately, it is possible for such a function not to recognize a bad mutex object.  There is therefore no guarantee that such a function will successfully detect bad mutex objects and return this value.
    MutexBad,
    /// This error code can be returned by mutex-unlocking functions.  It indicates that the mutex supplied to the mutex-unlocking function was not locked.
    MutexNotLocked,
    /// CKR_NEW_PIN_MODE
    NewPinMode,
    /// CKR_NEXT_OTP
    NextOtp,
    /// An iterative algorithm (for key pair generation, domain parameter generation etc.) failed because we have exceeded the maximum number of iterations.  This error code has precedence over CKR_FUNCTION_FAILED. Examples of iterative algorithms include DSA signature generation (retry if either r = 0 or s = 0) and generation of DSA primes p and q specified in FIPS 186-4.
    ExceededMaxIterations,
    /// A FIPS 140-2 power-up self-test or conditional self-test failed.  The token entered an error state.  Future calls to cryptographic functions on the token will return CKR_GENERAL_ERROR.  CKR_FIPS_SELF_TEST_FAILED has a higher precedence over CKR_GENERAL_ERROR. This error may be returned by C_Initialize, if a power-up self-test  failed, by C_GenerateRandom or C_SeedRandom, if the continuous random number generator test failed, or by C_GenerateKeyPair, if the pair-wise consistency test failed.
    FipsSelfTestFailed,
    /// The Cryptoki library could not load a dependent shared library.
    LibraryLoadFailed,
    /// The specified PIN is too weak so that it could be easy to guess.  If the PIN is too short, CKR_PIN_LEN_RANGE should be returned instead. This return code only applies to functions which attempt to set a PIN.
    PinTooWeak,
    /// The public key fails a public key validation.  For example, an EC public key fails the public key validation specified in Section 5.2.2 of ANSI X9.62. This error code may be returned by C_CreateObject, when the public key is created, or by C_VerifyInit or C_VerifyRecoverInit, when the public key is used.  It may also be returned by C_DeriveKey, in preference to  CKR_MECHANISM_PARAM_INVALID, if the other party's public key specified in the mechanism's parameters is invalid.
    PublicKeyInvalid,
    /// The signature request is rejected by the user.
    FunctionRejected,
    /// CKR_VENDOR_DEFINED
    VendorDefined,
}

impl fmt::Display for RvError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            RvError::Cancel => write!(f, "When a function executing in serial with an application decides to give the application a chance to do some work, it calls an application-supplied function with a CKN_SURRENDER callback (see Section 5.16).  If the callback returns the value CKR_CANCEL, then the function aborts and returns CKR_FUNCTION_CANCELED."),
            RvError::HostMemory => write!(f, "The computer that the Cryptoki library is running on has insufficient memory to perform the requested function."),
            RvError::SlotIdInvalid => write!(f, "The specified slot ID is not valid."),
            RvError::GeneralError => write!(f, "Some horrible, unrecoverable error has occurred.  In the worst case, it is possible that the function only partially succeeded, and that the computer and/or token is in an inconsistent state."),
            RvError::FunctionFailed => write!(f, "The requested function could not be performed, but detailed information about why not is not available in this error return.  If the failed function uses a session, it is possible that the CK_SESSION_INFO structure that can be obtained by calling C_GetSessionInfo will hold useful information about what happened in its ulDeviceError field.  In any event, although the function call failed, the situation is not necessarily totally hopeless, as it is likely to be when CKR_GENERAL_ERROR is returned.  Depending on what the root cause of the error actually was, it is possible that an attempt to make the exact same function call again would succeed."),
            RvError::ArgumentsBad => write!(f, "This is a rather generic error code which indicates that the arguments supplied to the Cryptoki function were in some way not appropriate."),
            RvError::NoEvent => write!(f, "This value can only be returned by C_GetSlotEvent.  It is returned when C_GetSlotEvent is called in non-blocking mode and there are no new slot events to return."),
            RvError::NeedToCreateThreads => write!(f, "This value can only be returned by C_Initialize.  It is returned when two conditions hold: 1. The application called C_Initialize in a way which tells the Cryptoki library that application threads executing calls to the library cannot use native operating system methods to spawn new threads. 2. The library cannot function properly without being able to spawn new threads in the above fashion."),
            RvError::CantLock => write!(f, "This value can only be returned by C_Initialize.  It means that the type of locking requested by the application for thread-safety is not available in this library, and so the application cannot make use of this library in the specified fashion."),
            RvError::AttributeReadOnly => write!(f, "An attempt was made to set a value for an attribute which may not be set by the application, or which may not be modified by the application.  See Section 4.1 for more information."),
            RvError::AttributeSensitive => write!(f, "An attempt was made to obtain the value of an attribute of an object which cannot be satisfied because the object is either sensitive or un-extractable."),
            RvError::AttributeTypeInvalid => write!(f, "An invalid attribute type was specified in a template.  See Section 4.1 for more information."),
            RvError::AttributeValueInvalid => write!(f, "An invalid value was specified for a particular attribute in a template.  See Section 4.1 for more information."),
            RvError::ActionProhibited => write!(f, " This value can only be returned by C_CopyObject, C_SetAttributeValue and C_DestroyObject. It denotes that the action may not be taken, either because of underlying policy restrictions on the token, or because the object has the the relevant CKA_COPYABLE, CKA_MODIFIABLE or CKA_DESTROYABLE policy attribute set to CK_FALSE."),
            RvError::DataInvalid => write!(f, "The plaintext input data to a cryptographic operation is invalid.  This return value has lower priority than CKR_DATA_LEN_RANGE."),
            RvError::DataLenRange => write!(f, "The plaintext input data to a cryptographic operation has a bad length.  Depending on the operation’s mechanism, this could mean that the plaintext data is too short, too long, or is not a multiple of some particular block size.  This return value has higher priority than CKR_DATA_INVALID."),
            RvError::DeviceError => write!(f, "Some problem has occurred with the token and/or slot.  This error code can be returned by more than just the functions mentioned above; in particular, it is possible for C_GetSlotInfo to return CKR_DEVICE_ERROR."),
            RvError::DeviceMemory => write!(f, "The token does not have sufficient memory to perform the requested function."),
            RvError::DeviceRemoved => write!(f, "The token was removed from its slot during the execution of the function."),
            RvError::EncryptedDataInvalid => write!(f, "The encrypted input to a decryption operation has been determined to be invalid ciphertext.  This return value has lower priority than CKR_ENCRYPTED_DATA_LEN_RANGE."),
            RvError::EncryptedDataLenRange => write!(f, "The ciphertext input to a decryption operation has been determined to be invalid ciphertext solely on the basis of its length.  Depending on the operation’s mechanism, this could mean that the ciphertext is too short, too long, or is not a multiple of some particular block size.  This return value has higher priority than CKR_ENCRYPTED_DATA_INVALID."),
            RvError::FunctionCanceled => write!(f, "The function was canceled in mid-execution.  This happens to a cryptographic function if the function makes a CKN_SURRENDER application callback which returns CKR_CANCEL (see CKR_CANCEL). It also happens to a function that performs PIN entry through a protected path. The method used to cancel a protected path PIN entry operation is device dependent."),
            RvError::FunctionNotParallel => write!(f, "There is currently no function executing in parallel in the specified session.  This is a legacy error code which is only returned by the legacy functions C_GetFunctionStatus and C_CancelFunction."),
            RvError::FunctionNotSupported => write!(f, "The requested function is not supported by this Cryptoki library.  Even unsupported functions in the Cryptoki API should have a “stub” in the library; this stub should simply return the value CKR_FUNCTION_NOT_SUPPORTED."),
            RvError::CurveNotSupported => write!(f, " This curve is not supported by this token.  Used with Elliptic Curve mechanisms."),
            RvError::KeyHandleInvalid => write!(f, "The specified key handle is not valid.  It may be the case that the specified handle is a valid handle for an object which is not a key.  We reiterate here that 0 is never a valid key handle."),
            RvError::KeySizeRange => write!(f, "Although the requested keyed cryptographic operation could in principle be carried out, this Cryptoki library (or the token) is unable to actually do it because the supplied key‘s size is outside the range of key sizes that it can handle."),
            RvError::KeyTypeInconsistent => write!(f, "The specified key is not the correct type of key to use with the specified mechanism.  This return value has a higher priority than CKR_KEY_FUNCTION_NOT_PERMITTED."),
            RvError::KeyNotNeeded => write!(f, "An extraneous key was supplied to C_SetOperationState.  For example, an attempt was made to restore a session that had been performing a message digesting operation, and an encryption key was supplied."),
            RvError::KeyChanged => write!(f, "This value is only returned by C_SetOperationState.  It indicates that one of the keys specified is not the same key that was being used in the original saved session."),
            RvError::KeyNeeded => write!(f, "This value is only returned by C_SetOperationState.  It indicates that the session state cannot be restored because C_SetOperationState needs to be supplied with one or more keys that were being used in the original saved session."),
            RvError::KeyIndigestible => write!(f, "This error code can only be returned by C_DigestKey.  It indicates that the value of the specified key cannot be digested for some reason (perhaps the key isn’t a secret key, or perhaps the token simply can’t digest this kind of key)."),
            RvError::KeyFunctionNotPermitted => write!(f, "An attempt has been made to use a key for a cryptographic purpose that the key’s attributes are not set to allow it to do.  For example, to use a key for performing encryption, that key MUST have its CKA_ENCRYPT attribute set to CK_TRUE (the fact that the key MUST have a CKA_ENCRYPT attribute implies that the key cannot be a private key).  This return value has lower priority than CKR_KEY_TYPE_INCONSISTENT."),
            RvError::KeyNotWrappable => write!(f, "Although the specified private or secret key does not have its CKA_EXTRACTABLE attribute set to CK_FALSE, Cryptoki (or the token) is unable to wrap the key as requested (possibly the token can only wrap a given key with certain types of keys, and the wrapping key specified is not one of these types).  Compare with CKR_KEY_UNEXTRACTABLE."),
            RvError::KeyUnextractable => write!(f, "The specified private or secret key can’t be wrapped because its CKA_EXTRACTABLE attribute is set to CK_FALSE.  Compare with CKR_KEY_NOT_WRAPPABLE."),
            RvError::MechanismInvalid => write!(f, "An invalid mechanism was specified to the cryptographic operation.  This error code is an appropriate return value if an unknown mechanism was specified or if the mechanism specified cannot be used in the selected token with the selected function."),
            RvError::MechanismParamInvalid => write!(f, "Invalid parameters were supplied to the mechanism specified to the cryptographic operation.  Which parameter values are supported by a given mechanism can vary from token to token."),
            RvError::ObjectHandleInvalid => write!(f, "The specified object handle is not valid.  We reiterate here that 0 is never a valid object handle."),
            RvError::OperationActive => write!(f, "There is already an active operation (or combination of active operations) which prevents Cryptoki from activating the specified operation.  For example, an active object-searching operation would prevent Cryptoki from activating an encryption operation with C_EncryptInit.  Or, an active digesting operation and an active encryption operation would prevent Cryptoki from activating a signature operation.  Or, on a token which doesn’t support simultaneous dual cryptographic operations in a session (see the description of the CKF_DUAL_CRYPTO_OPERATIONS flag in the CK_TOKEN_INFO structure), an active signature operation would prevent Cryptoki from activating an encryption operation."),
            RvError::OperationNotInitialized => write!(f, "There is no active operation of an appropriate type in the specified session.  For example, an application cannot call C_Encrypt in a session without having called C_EncryptInit first to activate an encryption operation."),
            RvError::PinIncorrect => write!(f, "The specified PIN is incorrect, i.e., does not match the PIN stored on the token.  More generally-- when authentication to the token involves something other than a PIN-- the attempt to authenticate the user has failed."),
            RvError::PinInvalid => write!(f, "The specified PIN has invalid characters in it.  This return code only applies to functions which attempt to set a PIN."),
            RvError::PinLenRange => write!(f, "The specified PIN is too long or too short.  This return code only applies to functions which attempt to set a PIN."),
            RvError::PinExpired => write!(f, "The specified PIN has expired, and the requested operation cannot be carried out unless C_SetPIN is called to change the PIN value.  Whether or not the normal user’s PIN on a token ever expires varies from token to token."),
            RvError::PinLocked => write!(f, "The specified PIN is “locked”, and cannot be used.  That is, because some particular number of failed authentication attempts has been reached, the token is unwilling to permit further attempts at authentication.  Depending on the token, the specified PIN may or may not remain locked indefinitely."),
            RvError::SessionClosed => write!(f, "The session was closed during the execution of the function.  Note that, as stated in [PKCS11-UG], the behavior of Cryptoki is undefined if multiple threads of an application attempt to access a common Cryptoki session simultaneously.  Therefore, there is actually no guarantee that a function invocation could ever return the value CKR_SESSION_CLOSED.  An example of multiple threads accessing a common session simultaneously is where one thread is using a session when another thread closes that same session."),
            RvError::SessionCount => write!(f, "This value can only be returned by C_OpenSession.  It indicates that the attempt to open a session failed, either because the token has too many sessions already open, or because the token has too many read/write sessions already open."),
            RvError::SessionHandleInvalid => write!(f, "The specified session handle was invalid at the time that the function was invoked.  Note that this can happen if the session’s token is removed before the function invocation, since removing a token closes all sessions with it."),
            RvError::SessionParallelNotSupported => write!(f, "The specified token does not support parallel sessions.  This is a legacy error code—in Cryptoki Version 2.01 and up, no token supports parallel sessions.  CKR_SESSION_PARALLEL_NOT_SUPPORTED can only be returned by C_OpenSession, and it is only returned when C_OpenSession is called in a particular [deprecated] way."),
            RvError::SessionReadOnly => write!(f, "The specified session was unable to accomplish the desired action because it is a read-only session.  This return value has lower priority than CKR_TOKEN_WRITE_PROTECTED."),
            RvError::SessionExists => write!(f, "This value can only be returned by C_InitToken.  It indicates that a session with the token is already open, and so the token cannot be initialized."),
            RvError::SessionReadOnlyExists => write!(f, "A read-only session already exists, and so the SO cannot be logged in."),
            RvError::SessionReadWriteSoExists => write!(f, "A read/write SO session already exists, and so a read-only session cannot be opened."),
            RvError::SignatureInvalid => write!(f, "The provided signature/MAC is invalid.  This return value has lower priority than CKR_SIGNATURE_LEN_RANGE."),
            RvError::SignatureLenRange => write!(f, "The provided signature/MAC can be seen to be invalid solely on the basis of its length.  This return value has higher priority than CKR_SIGNATURE_INVALID."),
            RvError::TemplateIncomplete => write!(f, "The template specified for creating an object is incomplete, and lacks some necessary attributes.  See Section 4.1 for more information."),
            RvError::TemplateInconsistent => write!(f, "The template specified for creating an object has conflicting attributes.  See Section 4.1 for more information."),
            RvError::TokenNotPresent => write!(f, "The token was not present in its slot at the time that the function was invoked."),
            RvError::TokenNotRecognized => write!(f, "The Cryptoki library and/or slot does not recognize the token in the slot."),
            RvError::TokenWriteProtected => write!(f, "The requested action could not be performed because the token is write-protected.  This return value has higher priority than CKR_SESSION_READ_ONLY."),
            RvError::UnwrappingKeyHandleInvalid => write!(f, "This value can only be returned by C_UnwrapKey.  It indicates that the key handle specified to be used to unwrap another key is not valid."),
            RvError::UnwrappingKeySizeRange => write!(f, "This value can only be returned by C_UnwrapKey.  It indicates that although the requested unwrapping operation could in principle be carried out, this Cryptoki library (or the token) is unable to actually do it because the supplied key’s size is outside the range of key sizes that it can handle."),
            RvError::UnwrappingKeyTypeInconsistent => write!(f, "This value can only be returned by C_UnwrapKey.  It indicates that the type of the key specified to unwrap another key is not consistent with the mechanism specified for unwrapping."),
            RvError::UserAlreadyLoggedIn => write!(f, "This value can only be returned by C_Login.  It indicates that the specified user cannot be logged into the session, because it is already logged into the session.  For example, if an application has an open SO session, and it attempts to log the SO into it, it will receive this error code."),
            RvError::UserNotLoggedIn => write!(f, "The desired action cannot be performed because the appropriate user (or an appropriate user) is not logged in.  One example is that a session cannot be logged out unless it is logged in.  Another example is that a private object cannot be created on a token unless the session attempting to create it is logged in as the normal user.  A final example is that cryptographic operations on certain tokens cannot be performed unless the normal user is logged in."),
            RvError::UserPinNotInitialized => write!(f, "This value can only be returned by C_Login.  It indicates that the normal user’s PIN has not yet been initialized with C_InitPIN."),
            RvError::UserTypeInvalid => write!(f, "An invalid value was specified as a CK_USER_TYPE.  Valid types are CKU_SO, CKU_USER, and CKU_CONTEXT_SPECIFIC."),
            RvError::UserAnotherAlreadyLoggedIn => write!(f, "This value can only be returned by C_Login.  It indicates that the specified user cannot be logged into the session, because another user is already logged into the session.  For example, if an application has an open SO session, and it attempts to log the normal user into it, it will receive this error code."),
            RvError::UserTooManyTypes => write!(f, "An attempt was made to have more distinct users simultaneously logged into the token than the token and/or library permits.  For example, if some application has an open SO session, and another application attempts to log the normal user into a session, the attempt may return this error.  It is not required to, however.  Only if the simultaneous distinct users cannot be supported does C_Login have to return this value.  Note that this error code generalizes to true multi-user tokens."),
            RvError::WrappedKeyInvalid => write!(f, "This value can only be returned by C_UnwrapKey.  It indicates that the provided wrapped key is not valid.  If a call is made to C_UnwrapKey to unwrap a particular type of key (i.e., some particular key type is specified in the template provided to C_UnwrapKey), and the wrapped key provided to C_UnwrapKey is recognizably not a wrapped key of the proper type, then C_UnwrapKey should return CKR_WRAPPED_KEY_INVALID.  This return value has lower priority than CKR_WRAPPED_KEY_LEN_RANGE."),
            RvError::WrappedKeyLenRange => write!(f, "This value can only be returned by C_UnwrapKey.  It indicates that the provided wrapped key can be seen to be invalid solely on the basis of its length.  This return value has higher priority than CKR_WRAPPED_KEY_INVALID."),
            RvError::WrappingKeyHandleInvalid => write!(f, "This value can only be returned by C_WrapKey.  It indicates that the key handle specified to be used to wrap another key is not valid."),
            RvError::WrappingKeySizeRange => write!(f, "This value can only be returned by C_WrapKey.  It indicates that although the requested wrapping operation could in principle be carried out, this Cryptoki library (or the token) is unable to actually do it because the supplied wrapping key’s size is outside the range of key sizes that it can handle."),
            RvError::WrappingKeyTypeInconsistent => write!(f, "This value can only be returned by C_WrapKey.  It indicates that the type of the key specified to wrap another key is not consistent with the mechanism specified for wrapping."),
            RvError::RandomSeedNotSupported => write!(f, "This value can only be returned by C_SeedRandom.  It indicates that the token’s random number generator does not accept seeding from an application.  This return value has lower priority than CKR_RANDOM_NO_RNG."),
            RvError::RandomNoRng => write!(f, "This value can be returned by C_SeedRandom and C_GenerateRandom.  It indicates that the specified token doesn’t have a random number generator.  This return value has higher priority than CKR_RANDOM_SEED_NOT_SUPPORTED."),
            RvError::DomainParamsInvalid => write!(f, "Invalid or unsupported domain parameters were supplied to the function.  Which representation methods of domain parameters are supported by a given mechanism can vary from token to token."),
            RvError::BufferTooSmall => write!(f, "The output of the function is too large to fit in the supplied buffer."),
            RvError::SavedStateInvalid => write!(f, "This value can only be returned by C_SetOperationState.  It indicates that the supplied saved cryptographic operations state is invalid, and so it cannot be restored to the specified session."),
            RvError::InformationSensitive => write!(f, "The information requested could not be obtained because the token considers it sensitive, and is not able or willing to reveal it."),
            RvError::StateUnsaveable => write!(f, "The cryptographic operations state of the specified session cannot be saved for some reason (possibly the token is simply unable to save the current state).  This return value has lower priority than CKR_OPERATION_NOT_INITIALIZED."),
            RvError::CryptokiNotInitialized => write!(f, "This value can be returned by any function other than C_Initialize and C_GetFunctionList.  It indicates that the function cannot be executed because the Cryptoki library has not yet been initialized by a call to C_Initialize."),
            RvError::CryptokiAlreadyInitialized => write!(f, "This value can only be returned by C_Initialize.  It means that the Cryptoki library has already been initialized (by a previous call to C_Initialize which did not have a matching C_Finalize call)."),
            RvError::MutexBad => write!(f, "This error code can be returned by mutex-handling functions that are passed a bad mutex object as an argument.  Unfortunately, it is possible for such a function not to recognize a bad mutex object.  There is therefore no guarantee that such a function will successfully detect bad mutex objects and return this value."),
            RvError::MutexNotLocked => write!(f, "This error code can be returned by mutex-unlocking functions.  It indicates that the mutex supplied to the mutex-unlocking function was not locked."),
            RvError::NewPinMode => write!(f, "CKR_NEW_PIN_MODE"),
            RvError::NextOtp => write!(f, "CKR_NEXT_OTP"),
            RvError::ExceededMaxIterations => write!(f, "An iterative algorithm (for key pair generation, domain parameter generation etc.) failed because we have exceeded the maximum number of iterations.  This error code has precedence over CKR_FUNCTION_FAILED. Examples of iterative algorithms include DSA signature generation (retry if either r = 0 or s = 0) and generation of DSA primes p and q specified in FIPS 186-4."),
            RvError::FipsSelfTestFailed => write!(f, "A FIPS 140-2 power-up self-test or conditional self-test failed.  The token entered an error state.  Future calls to cryptographic functions on the token will return CKR_GENERAL_ERROR.  CKR_FIPS_SELF_TEST_FAILED has a higher precedence over CKR_GENERAL_ERROR. This error may be returned by C_Initialize, if a power-up self-test  failed, by C_GenerateRandom or C_SeedRandom, if the continuous random number generator test failed, or by C_GenerateKeyPair, if the pair-wise consistency test failed."),
            RvError::LibraryLoadFailed => write!(f, "The Cryptoki library could not load a dependent shared library."),
            RvError::PinTooWeak => write!(f, "The specified PIN is too weak so that it could be easy to guess.  If the PIN is too short, CKR_PIN_LEN_RANGE should be returned instead. This return code only applies to functions which attempt to set a PIN."),
            RvError::PublicKeyInvalid => write!(f, "The public key fails a public key validation.  For example, an EC public key fails the public key validation specified in Section 5.2.2 of ANSI X9.62. This error code may be returned by C_CreateObject, when the public key is created, or by C_VerifyInit or C_VerifyRecoverInit, when the public key is used.  It may also be returned by C_DeriveKey, in preference to  CKR_MECHANISM_PARAM_INVALID, if the other party's public key specified in the mechanism's parameters is invalid."),
            RvError::FunctionRejected => write!(f, "The signature request is rejected by the user."),
            RvError::VendorDefined => write!(f, "CKR_VENDOR_DEFINED"),
        }
    }
}
