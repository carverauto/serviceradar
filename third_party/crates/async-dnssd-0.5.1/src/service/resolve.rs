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
	service::{
		resolve_host_extended,
		ResolveHost,
		ResolveHostData,
	},
};

type CallbackStream = crate::stream::ServiceStream<inner::OwnedService, ResolveResult>;

bitflags::bitflags! {
	/// Flags for [`ResolveResult`](struct.ResolveResult.html)
	#[derive(Default)]
	pub struct ResolvedFlags: ffi::DNSServiceFlags {
		/// Indicates at least one more result is pending in the queue.  If
		/// not set there still might be more results coming in the future.
		///
		/// See [`kDNSServiceFlagsMoreComing`](https://developer.apple.com/documentation/dnssd/1823436-anonymous/kdnsserviceflagsmorecoming).
		const MORE_COMING = ffi::FLAGS_MORE_COMING;
	}
}

/// Pending resolve request
#[must_use = "streams do nothing unless polled"]
pub struct Resolve {
	stream: crate::fused_err_stream::FusedErrorStream<CallbackStream>,
}

impl Resolve {
	pin_utils::unsafe_pinned!(stream: crate::fused_err_stream::FusedErrorStream<CallbackStream>);
}

impl futures_core::Stream for Resolve {
	type Item = io::Result<ResolveResult>;

	fn poll_next(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
		self.stream().poll_next(cx)
	}
}

/// Resolve result
///
/// See [`DNSServiceResolveReply`](https://developer.apple.com/documentation/dnssd/dnsserviceresolvereply).
#[derive(Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Debug)]
pub struct ResolveResult {
	/// flags
	pub flags: ResolvedFlags,
	/// interface service was resolved on
	pub interface: Interface,
	/// full name of service
	pub fullname: String,
	/// hostname the service is provided on
	pub host_target: String,
	/// port the service is provided on (native endian)
	pub port: u16,
	/// TXT RDATA describing service parameters
	pub txt: Vec<u8>,
}

impl ResolveResult {
	/// Lookup socket addresses for resolved service
	pub fn resolve_socket_address(&self) -> ResolveHost {
		let rhdata = ResolveHostData {
			interface: self.interface,
			..Default::default()
		};
		resolve_host_extended(&self.host_target, self.port, rhdata)
	}
}

unsafe extern "C" fn resolve_callback(
	_sd_ref: ffi::DNSServiceRef,
	flags: ffi::DNSServiceFlags,
	interface_index: u32,
	error_code: ffi::DNSServiceErrorType,
	fullname: *const c_char,
	host_target: *const c_char,
	port: u16,
	txt_len: u16,
	txt_record: *const u8,
	context: *mut c_void,
) {
	CallbackStream::run_callback(context, error_code, || {
		let fullname = cstr::from_cstr(fullname)?;
		let host_target = cstr::from_cstr(host_target)?;
		let txt = ::std::slice::from_raw_parts(txt_record, txt_len as usize);

		Ok(ResolveResult {
			flags: ResolvedFlags::from_bits_truncate(flags),
			interface: Interface::from_raw(interface_index),
			fullname: fullname.to_string(),
			host_target: host_target.to_string(),
			port: u16::from_be(port),
			txt: txt.into(),
		})
	});
}

fn _resolve(interface: Interface, name: &str, reg_type: &str, domain: &str) -> io::Result<Resolve> {
	crate::init();

	let name = cstr::CStr::from(&name)?;
	let reg_type = cstr::CStr::from(&reg_type)?;
	let domain = cstr::CStr::from(&domain)?;

	let stream = CallbackStream::new(move |sender| {
		inner::OwnedService::resolve(
			0, // no flags
			interface.into_raw(),
			&name,
			&reg_type,
			&domain,
			Some(resolve_callback),
			sender,
		)
	})
	.into();

	Ok(Resolve { stream })
}

/// Find hostname and port (and more) for a service
///
/// You probably want to use [`BrowseResult::resolve`] instead.
///
/// See [`DNSServiceResolve`](https://developer.apple.com/documentation/dnssd/1804744-dnsserviceresolve).
///
/// [`BrowseResult::resolve`]: struct.BrowseResult.html#method.resolve
#[doc(alias = "DNSServiceResolve")]
pub fn resolve(interface: Interface, name: &str, reg_type: &str, domain: &str) -> Resolve {
	match _resolve(interface, name, reg_type, domain) {
		Ok(r) => r,
		Err(e) => Resolve {
			stream: Err(e).into(),
		},
	}
}
