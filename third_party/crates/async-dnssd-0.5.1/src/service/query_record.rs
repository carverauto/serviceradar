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
	dns_consts::{
		Class,
		Type,
	},
	ffi,
	inner,
	interface::Interface,
};

type CallbackStream = crate::stream::ServiceStream<inner::OwnedService, QueryRecordResult>;

bitflags::bitflags! {
	/// Flags used to query for a record
	#[derive(Default)]
	pub struct QueryRecordFlags: ffi::DNSServiceFlags {
		/// long-lived unicast query
		///
		/// See [`kDNSServiceFlagsLongLivedQuery`](https://developer.apple.com/documentation/dnssd/1823436-anonymous/kdnsserviceflagslonglivedquery).
		const LONG_LIVED_QUERY = ffi::FLAGS_LONG_LIVED_QUERY;
	}
}

bitflags::bitflags! {
	/// Flags for [`QueryRecordResult`](struct.QueryRecordResult.html)
	#[derive(Default)]
	pub struct QueriedRecordFlags: ffi::DNSServiceFlags {
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
	}
}

/// Pending query
#[must_use = "streams do nothing unless polled"]
pub struct QueryRecord {
	stream: crate::fused_err_stream::FusedErrorStream<CallbackStream>,
}

impl QueryRecord {
	pin_utils::unsafe_pinned!(stream: crate::fused_err_stream::FusedErrorStream<CallbackStream>);
}

impl futures_core::Stream for QueryRecord {
	type Item = io::Result<QueryRecordResult>;

	fn poll_next(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
		self.stream().poll_next(cx)
	}
}

/// Query result
///
/// See [`DNSServiceQueryRecordReply`](https://developer.apple.com/documentation/dnssd/dnsservicequeryrecordreply).
#[derive(Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Debug)]
pub struct QueryRecordResult {
	/// flags
	pub flags: QueriedRecordFlags,
	/// interface the record was found on
	pub interface: Interface,
	/// name of record
	pub fullname: String,
	/// type of record
	pub rr_type: Type,
	/// class of record
	pub rr_class: Class,
	/// wire RDATA of record
	pub rdata: Vec<u8>,
	/// TTL (time to live) of record
	pub ttl: u32,
}

unsafe extern "C" fn query_record_callback(
	_sd_ref: ffi::DNSServiceRef,
	flags: ffi::DNSServiceFlags,
	interface_index: u32,
	error_code: ffi::DNSServiceErrorType,
	fullname: *const c_char,
	rr_type: u16,
	rr_class: u16,
	rd_len: u16,
	rdata: *const u8,
	ttl: u32,
	context: *mut c_void,
) {
	CallbackStream::run_callback(context, error_code, || {
		let fullname = cstr::from_cstr(fullname)?;
		let rdata = ::std::slice::from_raw_parts(rdata, rd_len as usize);

		Ok(QueryRecordResult {
			flags: QueriedRecordFlags::from_bits_truncate(flags),
			interface: Interface::from_raw(interface_index),
			fullname: fullname.to_string(),
			rr_type: Type(rr_type),
			rr_class: Class(rr_class),
			rdata: rdata.into(),
			ttl,
		})
	});
}

/// Optional data when querying for a record; either use its default
/// value or customize it like:
///
/// ```
/// # use async_dnssd::QueryRecordData;
/// # use async_dnssd::QueryRecordFlags;
/// QueryRecordData {
///     flags: QueryRecordFlags::LONG_LIVED_QUERY,
///     ..Default::default()
/// };
/// ```
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Debug)]
pub struct QueryRecordData {
	/// flags for query
	pub flags: QueryRecordFlags,
	/// interface to query records on
	pub interface: Interface,
	/// class of the resource record (default: `IN`)
	pub rr_class: Class,
	#[doc(hidden)]
	pub _non_exhaustive: crate::non_exhaustive_struct::NonExhaustiveMarker,
}

impl Default for QueryRecordData {
	fn default() -> Self {
		Self {
			flags: QueryRecordFlags::default(),
			interface: Interface::default(),
			rr_class: Class::IN,
			_non_exhaustive: crate::non_exhaustive_struct::NonExhaustiveMarker,
		}
	}
}

fn _query_record_extended(
	fullname: &str,
	rr_type: Type,
	data: QueryRecordData,
) -> io::Result<QueryRecord> {
	crate::init();

	let fullname = cstr::CStr::from(&fullname)?;

	let stream = CallbackStream::new(move |sender| {
		inner::OwnedService::query_record(
			data.flags.bits(),
			data.interface.into_raw(),
			&fullname,
			rr_type,
			data.rr_class,
			Some(query_record_callback),
			sender,
		)
	})
	.into();

	Ok(QueryRecord { stream })
}

/// Query for an arbitrary DNS record
///
/// See [`DNSServiceQueryRecord`](https://developer.apple.com/documentation/dnssd/1804747-dnsservicequeryrecord).
#[doc(alias = "DNSServiceQueryRecord")]
pub fn query_record_extended(fullname: &str, rr_type: Type, data: QueryRecordData) -> QueryRecord {
	match _query_record_extended(fullname, rr_type, data) {
		Ok(qr) => qr,
		Err(e) => QueryRecord {
			stream: Err(e).into(),
		},
	}
}

/// Query for an arbitrary DNS record
///
/// Uses [`query_record_extended`] with default [`QueryRecordData`].
///
/// See [`DNSServiceQueryRecord`](https://developer.apple.com/documentation/dnssd/1804747-dnsservicequeryrecord).
///
/// [`query_record_extended`]: fn.query_record_extended.html
/// [`QueryRecordData`]: struct.QueryRecordData.html
#[doc(alias = "DNSServiceQueryRecord")]
pub fn query_record(fullname: &str, rr_type: Type) -> QueryRecord {
	query_record_extended(fullname, rr_type, QueryRecordData::default())
}
