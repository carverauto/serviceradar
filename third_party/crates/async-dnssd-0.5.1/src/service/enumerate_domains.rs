use std::{
	io,
	os::raw::{
		c_char,
		c_void,
	},
	pin::Pin,
	task::{
		Context,
		Poll,
	},
};

use crate::{
	cstr,
	ffi,
	inner,
	interface::Interface,
};

type CallbackStream = crate::stream::ServiceStream<inner::OwnedService, EnumerateResult>;

/// Whether to enumerate domains which are browsed or domains for which
/// registrations can be made.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Debug)]
pub enum Enumerate {
	/// enumerate domains which can be browsed
	BrowseDomains,
	/// enumerate domains to register services/records on
	RegistrationDomains,
}

impl From<Enumerate> for ffi::DNSServiceFlags {
	fn from(e: Enumerate) -> Self {
		match e {
			Enumerate::BrowseDomains => ffi::FLAGS_BROWSE_DOMAINS,
			Enumerate::RegistrationDomains => ffi::FLAGS_REGISTRATION_DOMAINS,
		}
	}
}

bitflags::bitflags! {
	/// Flags for [`EnumerateDomains`](struct.EnumerateDomains.html)
	#[derive(Default)]
	pub struct EnumeratedFlags: ffi::DNSServiceFlags {
		/// Indicates at least one more result is pending in the queue.  If
		/// not set there still might be more results coming in the future.
		///
		/// See [`kDNSServiceFlagsMoreComing`](https://developer.apple.com/documentation/dnssd/1823436-anonymous/kdnsserviceflagsmorecoming).
		const MORE_COMING = ffi::FLAGS_MORE_COMING;

		/// Indicates the result is new.  If not set indicates the result
		/// was removed.
		///
		/// See [`kDNSServiceFlagsAdd`](https://developer.apple.com/documentation/dnssd/1823436-anonymous/kdnsserviceflagsadd).
		const ADD = ffi::FLAGS_ADD;

		/// Indicates this is the default domain to search (always combined with `Add`).
		///
		/// See [`kDNSServiceFlagsDefault`](https://developer.apple.com/documentation/dnssd/1823436-anonymous/kdnsserviceflagsdefault).
		const DEFAULT = ffi::FLAGS_DEFAULT;
	}
}

/// Pending domain enumeration
#[must_use = "streams do nothing unless polled"]
pub struct EnumerateDomains {
	stream: crate::fused_err_stream::FusedErrorStream<CallbackStream>,
}

impl EnumerateDomains {
	pin_utils::unsafe_pinned!(stream: crate::fused_err_stream::FusedErrorStream<CallbackStream>);
}

impl futures_core::Stream for EnumerateDomains {
	type Item = io::Result<EnumerateResult>;

	fn poll_next(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
		self.stream().poll_next(cx)
	}
}

/// Domain enumeration result
///
/// See [DNSServiceDomainEnumReply](https://developer.apple.com/documentation/dnssd/dnsservicedomainenumreply).
#[derive(Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Debug)]
pub struct EnumerateResult {
	/// flags
	pub flags: EnumeratedFlags,
	/// interface domain was found on
	pub interface: Interface,
	/// domain name
	pub domain: String,
}

unsafe extern "C" fn enumerate_callback(
	_sd_ref: ffi::DNSServiceRef,
	flags: ffi::DNSServiceFlags,
	interface_index: u32,
	error_code: ffi::DNSServiceErrorType,
	reply_domain: *const c_char,
	context: *mut c_void,
) {
	CallbackStream::run_callback(context, error_code, || {
		let reply_domain = cstr::from_cstr(reply_domain)?;

		Ok(EnumerateResult {
			flags: EnumeratedFlags::from_bits_truncate(flags),
			interface: Interface::from_raw(interface_index),
			domain: reply_domain.to_string(),
		})
	});
}

/// Enumerate domains that are recommended for registration or browsing
///
/// See [`DNSServiceEnumerateDomains`](https://developer.apple.com/documentation/dnssd/1804754-dnsserviceenumeratedomains).
#[doc(alias = "DNSServiceEnumerateDomains")]
pub fn enumerate_domains(enumerate: Enumerate, interface: Interface) -> EnumerateDomains {
	crate::init();

	let stream = CallbackStream::new(move |sender| {
		inner::OwnedService::enumerate_domains(
			enumerate.into(),
			interface.into_raw(),
			Some(enumerate_callback),
			sender,
		)
	})
	.into();

	EnumerateDomains { stream }
}
