// #![allow(dead_code)]

use std::os::raw::{
	c_char,
	c_int,
	c_void,
};

// type without an instance
pub enum DNSServiceT {}
pub type DNSServiceRef = *mut DNSServiceT;

// type without an instance
pub enum DNSRecordT {}
pub type DNSRecordRef = *mut DNSRecordT;

pub type DNSServiceFlags = u32;
// pub const FLAGS_NONE                 : DNSServiceFlags = 0x0;
pub const FLAGS_MORE_COMING: DNSServiceFlags = 0x1;
pub const FLAGS_ADD: DNSServiceFlags = 0x2;
pub const FLAGS_DEFAULT: DNSServiceFlags = 0x4;
pub const FLAGS_NO_AUTO_RENAME: DNSServiceFlags = 0x8;
pub const FLAGS_SHARED: DNSServiceFlags = 0x10;
pub const FLAGS_UNIQUE: DNSServiceFlags = 0x20;
pub const FLAGS_BROWSE_DOMAINS: DNSServiceFlags = 0x40;
pub const FLAGS_REGISTRATION_DOMAINS: DNSServiceFlags = 0x80;
// unix only?
#[cfg(unix)]
pub const FLAGS_LONG_LIVED_QUERY: DNSServiceFlags = 0x100;
#[cfg(not(unix))]
pub const FLAGS_LONG_LIVED_QUERY: DNSServiceFlags = 0;
// avahi only?
// pub const FLAGS_ALLOW_REMOTE_QUERY: DNSServiceFlags = 0x200;
// pub const FLAGS_FORCE_MULTICAS: DNSServiceFlags = 0x400;
// pub const FLAGS_RETURN_CNAME: DNSServiceFlags = 0x800;

/// Maximum length of full name including trailing dot and terminating NULL
///
/// See [`kDNSServiceMaxDomainName`](https://developer.apple.com/documentation/dnssd/kdnsservicemaxdomainname)
pub const MAX_DOMAIN_NAME: usize = 1009;

pub const INTERFACE_INDEX_ANY: u32 = 0;
pub const INTERFACE_INDEX_LOCAL_ONLY: u32 = !0;
pub const INTERFACE_INDEX_UNICAST: u32 = !1;
pub const INTERFACE_INDEX_P2P: u32 = !2;

macro_rules! c_api_enum {
	($(#[$m:meta])* $name:ident : $ty:tt => $($case:ident = $val:expr,)* ) => (
		#[derive(Clone,Copy,Eq,PartialEq,Ord,PartialOrd,Hash,Debug)]
		#[repr($ty)]
		$(#[$m])*
		pub enum $name {
			$($case = $val,)*
		}
		impl $name {
			pub fn try_from(value: $ty) -> Option<Self> {
				$(if value == $val {
					Some(Self::$case)
				} else)* {
					None
				}
			}
		}
	)
}

pub type DNSServiceErrorType = i32;

c_api_enum! {
#[non_exhaustive]
DNSServiceNoError: i32 =>
	NoError               = 0,
	// windows "TCP Connection Status"
	ConnectionPending     = -65570,
	ConnectionFailed      = -65571,
	ConnectionEstablished = -65572,
	// windows "Non-error values"
	GrowCache             = -65790,
	ConfigChanged         = -65791,
	MemFree               = -65792,
}

c_api_enum! {
/// Known error codes
///
/// See [`DNSServiceErrorType`](https://developer.apple.com/documentation/dnssd/1823426-anonymous)
#[non_exhaustive]
DNSServiceError: i32 =>
	Unknown               = -65537,
	NoSuchName            = -65538,
	NoMemory              = -65539,
	BadParam              = -65540,
	BadReference          = -65541,
	BadState              = -65542,
	BadFlags              = -65543,
	Unsupported           = -65544,
	NotInitialized        = -65545,
	NoCache               = -65546,
	AlreadyRegistered     = -65547,
	NameConflict          = -65548,
	Invalid               = -65549,
	Incompatible          = -65551,
	BadInterfaceIndex     = -65552,
	Refused               = -65553,
	NoSuchRecord          = -65554,
	NoAuth                = -65555,
	NoSuchKey             = -65556,
	NoValue               = -65557,
	BufferTooSmall        = -65558,
}

pub type DNSServiceDomainEnumReply = Option<
	unsafe extern "C" fn(
		sd_ref: DNSServiceRef,
		flags: DNSServiceFlags,
		interface_index: u32,
		error_code: DNSServiceErrorType,
		reply_domain: *const c_char,
		context: *mut c_void,
	),
>;
pub type DNSServiceRegisterReply = Option<
	unsafe extern "C" fn(
		sd_ref: DNSServiceRef,
		flags: DNSServiceFlags,
		error_code: DNSServiceErrorType,
		name: *const c_char,
		reg_type: *const c_char,
		domain: *const c_char,
		context: *mut c_void,
	),
>;
pub type DNSServiceBrowseReply = Option<
	unsafe extern "C" fn(
		sd_ref: DNSServiceRef,
		flags: DNSServiceFlags,
		interface_index: u32,
		error_code: DNSServiceErrorType,
		service_name: *const c_char,
		reg_type: *const c_char,
		reply_domain: *const c_char,
		context: *mut c_void,
	),
>;
pub type DNSServiceResolveReply = Option<
	unsafe extern "C" fn(
		sd_ref: DNSServiceRef,
		flags: DNSServiceFlags,
		interface_index: u32,
		error_code: DNSServiceErrorType,
		fullname: *const c_char,
		host_target: *const c_char,
		port: u16,
		txt_len: u16,
		txt_record: *const u8,
		context: *mut c_void,
	),
>;
pub type DNSServiceRegisterRecordReply = Option<
	unsafe extern "C" fn(
		sd_ref: DNSServiceRef,
		record_ref: DNSRecordRef,
		flags: DNSServiceFlags,
		error_code: DNSServiceErrorType,
		context: *mut c_void,
	),
>;
pub type DNSServiceQueryRecordReply = Option<
	unsafe extern "C" fn(
		sd_ref: DNSServiceRef,
		flags: DNSServiceFlags,
		interface_index: u32,
		error_code: DNSServiceErrorType,
		fullname: *const c_char,
		rr_type: u16,
		rr_class: u16,
		rd_len: u16,
		rdata: *const u8,
		ttl: u32,
		context: *mut c_void,
	),
>;

extern "C" {
	pub fn DNSServiceRefSockFD(sd_ref: DNSServiceRef) -> c_int;
	pub fn DNSServiceProcessResult(sd_ref: DNSServiceRef) -> DNSServiceErrorType;
	pub fn DNSServiceRefDeallocate(sd_ref: DNSServiceRef);
	pub fn DNSServiceEnumerateDomains(
		sd_ref: *mut DNSServiceRef,
		flags: DNSServiceFlags,
		interface_index: u32,
		callback: DNSServiceDomainEnumReply,
		context: *mut c_void,
	) -> DNSServiceErrorType;
	pub fn DNSServiceRegister(
		sd_ref: *mut DNSServiceRef,
		flags: DNSServiceFlags,
		interface_index: u32,
		name: *const c_char,
		reg_type: *const c_char,
		domain: *const c_char,
		host: *const c_char,
		port: u16,
		txt_len: u16,
		txt_record: *const u8,
		callback: DNSServiceRegisterReply,
		context: *mut c_void,
	) -> DNSServiceErrorType;
	pub fn DNSServiceAddRecord(
		sd_ref: DNSServiceRef,
		record_ref: *mut DNSRecordRef,
		flags: DNSServiceFlags,
		rr_type: u16,
		rd_len: u16,
		rdata: *const u8,
		ttl: u32,
	) -> DNSServiceErrorType;
	pub fn DNSServiceUpdateRecord(
		sd_ref: DNSServiceRef,
		record_ref: DNSRecordRef,
		flags: DNSServiceFlags,
		rd_len: u16,
		rdata: *const u8,
		ttl: u32,
	) -> DNSServiceErrorType;
	pub fn DNSServiceRemoveRecord(
		sd_ref: DNSServiceRef,
		record_ref: DNSRecordRef,
		flags: DNSServiceFlags,
	) -> DNSServiceErrorType;
	pub fn DNSServiceBrowse(
		sd_ref: *mut DNSServiceRef,
		flags: DNSServiceFlags,
		interface_index: u32,
		reg_type: *const c_char,
		domain: *const c_char,
		callback: DNSServiceBrowseReply,
		context: *mut c_void,
	) -> DNSServiceErrorType;
	pub fn DNSServiceResolve(
		sd_ref: *mut DNSServiceRef,
		flags: DNSServiceFlags,
		interface_index: u32,
		name: *const c_char,
		reg_type: *const c_char,
		domain: *const c_char,
		callback: DNSServiceResolveReply,
		context: *mut c_void,
	) -> DNSServiceErrorType;
	pub fn DNSServiceCreateConnection(sd_ref: *mut DNSServiceRef) -> DNSServiceErrorType;
	pub fn DNSServiceRegisterRecord(
		sd_ref: DNSServiceRef,
		record_ref: *mut DNSRecordRef,
		flags: DNSServiceFlags,
		interface_index: u32,
		fullname: *const c_char,
		rr_type: u16,
		rr_class: u16,
		rd_len: u16,
		rdata: *const u8,
		ttl: u32,
		callback: DNSServiceRegisterRecordReply,
		context: *mut c_void,
	) -> DNSServiceErrorType;
	pub fn DNSServiceQueryRecord(
		sd_ref: *mut DNSServiceRef,
		flags: DNSServiceFlags,
		interface_index: u32,
		fullname: *const c_char,
		rr_type: u16,
		rr_class: u16,
		callback: DNSServiceQueryRecordReply,
		context: *mut c_void,
	) -> DNSServiceErrorType;
	pub fn DNSServiceReconfirmRecord(
		flags: DNSServiceFlags,
		interface_index: u32,
		fullname: *const c_char,
		rr_type: u16,
		rr_class: u16,
		rd_len: u16,
		rdata: *const u8,
	) -> DNSServiceErrorType;
	pub fn DNSServiceConstructFullName(
		fullName: *mut c_char,
		service: *const c_char,
		reg_type: *const c_char,
		domain: *const c_char,
	) -> c_int;
}

// TXTRecordRef utils not wrapped - should be easy enough to implement
// in pure rust

/* Not used so far:
#[cfg(windows)]
mod ffi_windows {
	use super::DNSServiceErrorType;
	use std::os::raw::{
		c_int,
		c_void,
	};

	pub type DNSServiceInitializeFlags = u32;
	pub const INITIALIZE_FLAGS_NONE: DNSServiceInitializeFlags = 0x0;
	pub const INITIALIZE_FLAGS_ADVERTISE: DNSServiceInitializeFlags = 0x1;
	pub const INITIALIZE_FLAGS_NO_SERVER_CHECK: DNSServiceInitializeFlags = 0x2;

	pub type DNSPropertyCode = u32;

	pub const PROPERTY_CODE_VERSION: DNSPropertyCode = 0x76657273;
	#[repr(C)]
	pub struct DnsPropertyVersion {
		pub code: DNSPropertyCode,

		pub client_current_version: u32,
		pub client_oldest_server_version: u32,
		pub server_current_version: u32,
		pub server_oldest_client_version: u32,
	}

	extern "C" {
		pub fn DNSServiceInitialize(
			inFlags: DNSServiceInitializeFlags,
			inCacheEntryCount: c_int,
		) -> DNSServiceErrorType;
		pub fn DNSServiceFinalize();
		pub fn DNSServiceCheckVersion() -> DNSServiceErrorType;

		// TODO? DNSPropertyData on windows.
		// the c API uses a union... - using void instead here
		pub fn DNSServiceCopyProperty(
			inCode: DNSPropertyCode,
			outData: *mut c_void,
		) -> DNSServiceErrorType;
		pub fn DNSServiceReleaseProperty(
			inData: *mut c_void,
		) -> DNSServiceErrorType;
	}
}
#[cfg(windows)]
pub use self::ffi_windows::*;
*/
