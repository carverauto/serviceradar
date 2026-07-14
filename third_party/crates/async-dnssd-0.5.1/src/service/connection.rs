use futures_util::FutureExt;
use std::{
	future::Future,
	io,
	os::raw::c_void,
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

type CallbackFuture = crate::future::ServiceFuture<inner::SharedService, RegisterRecordResult>;

/// Connection to register records with
pub struct Connection(inner::SharedService);

/// Create [`Connection`](struct.Connection.html) to register records
/// with
///
/// See [`DNSServiceCreateConnection`](https://developer.apple.com/documentation/dnssd/1804724-dnsservicecreateconnection).
#[doc(alias = "DNSServiceCreateConnection")]
pub fn connect() -> io::Result<Connection> {
	crate::init();

	Ok(Connection(inner::SharedService::create_connection()?))
}

bitflags::bitflags! {
	/// Flags used to register a record
	#[derive(Default)]
	pub struct RegisterRecordFlags: ffi::DNSServiceFlags {
		/// Indicates there might me multiple records with the given name, type and class.
		///
		/// See [`kDNSServiceFlagsShared`](https://developer.apple.com/documentation/dnssd/1823436-anonymous/kdnsserviceflagsshared).
		const SHARED = ffi::FLAGS_SHARED;

		/// Indicates the records with the given name, type and class is unique.
		///
		/// See [`kDNSServiceFlagsUnique`](https://developer.apple.com/documentation/dnssd/1823436-anonymous/kdnsserviceflagsunique).
		const UNIQUE = ffi::FLAGS_UNIQUE;
	}
}

/// Pending record registration
///
/// Becomes invalid when the future completes; use the returned
/// [`Record`](struct.Record.html) instead.
// the future gets canceled by dropping the record; must
// not drop the future without dropping the record.
#[must_use = "futures do nothing unless polled"]
pub struct RegisterRecord {
	future: CallbackFuture,
	record: Option<crate::Record>,
}

impl RegisterRecord {
	pin_utils::unsafe_pinned!(future: CallbackFuture);

	pin_utils::unsafe_unpinned!(record: Option<crate::Record>);
}

impl Future for RegisterRecord {
	type Output = io::Result<crate::Record>;

	fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
		futures_core::ready!(self.as_mut().future().poll(cx))?;
		Poll::Ready(Ok(self.record().take().unwrap()))
	}
}

#[derive(Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Debug)]
struct RegisterRecordResult;

unsafe extern "C" fn register_record_callback(
	_sd_ref: ffi::DNSServiceRef,
	_record_ref: ffi::DNSRecordRef,
	_flags: ffi::DNSServiceFlags,
	error_code: ffi::DNSServiceErrorType,
	context: *mut c_void,
) {
	CallbackFuture::run_callback(context, error_code, || Ok(RegisterRecordResult));
}

/// Optional data when registering a record; either use its default
/// value or customize it like:
///
/// ```
/// # use async_dnssd::RegisterRecordData;
/// RegisterRecordData {
///     ttl: 60,
///     ..Default::default()
/// };
/// ```
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Debug)]
pub struct RegisterRecordData {
	/// flags for registration
	pub flags: RegisterRecordFlags,
	/// interface to register record on
	pub interface: Interface,
	/// class of the resource record (default: `IN`)
	pub rr_class: Class,
	/// time to live of the resource record in seconds (passing 0 will
	/// select a sensible default)
	pub ttl: u32,
	#[doc(hidden)]
	pub _non_exhaustive: crate::non_exhaustive_struct::NonExhaustiveMarker,
}

impl Default for RegisterRecordData {
	fn default() -> Self {
		Self {
			flags: RegisterRecordFlags::default(),
			interface: Interface::default(),
			rr_class: Class::IN,
			ttl: 0,
			_non_exhaustive: crate::non_exhaustive_struct::NonExhaustiveMarker,
		}
	}
}

impl Connection {
	/// Register record on interface with given name, type, class, rdata
	/// and ttl
	///
	/// See [`DNSServiceRegisterRecord`](https://developer.apple.com/documentation/dnssd/1804727-dnsserviceregisterrecord).
	#[doc(alias = "DNSServiceRegisterRecord")]
	pub fn register_record_extended(
		&self,
		fullname: &str,
		rr_type: Type,
		rdata: &[u8],
		data: RegisterRecordData,
	) -> io::Result<RegisterRecord> {
		let fullname = cstr::CStr::from(&fullname)?;

		let (future, record) = CallbackFuture::new_with(self.0.clone(), move |sender| {
			self.0.clone().register_record(
				data.flags.bits(),
				data.interface.into_raw(),
				&fullname,
				rr_type,
				data.rr_class,
				rdata,
				data.ttl,
				Some(register_record_callback),
				sender,
			)
		})?;

		Ok(RegisterRecord {
			future,
			record: Some(record.into()),
		})
	}

	/// Register record on interface with given name, type, class, rdata
	/// and ttl
	///
	/// Uses [`register_record_extended`] with default [`RegisterRecordData`].
	///
	/// See [`DNSServiceRegisterRecord`](https://developer.apple.com/documentation/dnssd/1804727-dnsserviceregisterrecord).
	///
	/// [`register_record_extended`]: fn.register_record_extended.html
	/// [`RegisterRecordData`]: struct.RegisterRecordData.html
	#[doc(alias = "DNSServiceRegisterRecord")]
	pub fn register_record(
		&self,
		fullname: &str,
		rr_type: Type,
		rdata: &[u8],
	) -> io::Result<RegisterRecord> {
		self.register_record_extended(fullname, rr_type, rdata, RegisterRecordData::default())
	}
}

impl RegisterRecord {
	fn inner_record(&self) -> &crate::Record {
		self.record.as_ref().expect("RegisterRecord future is done")
	}

	/// Type of the record
	///
	/// # Panics
	///
	/// Panics after the future completed.  Use the returned
	/// [`Record`](struct.Record.html) instead.
	pub fn rr_type(&self) -> Type {
		self.inner_record().rr_type()
	}

	/// Update record
	///
	/// Cannot change type or class of record.
	///
	/// # Panics
	///
	/// Panics after the future completed.  Use the returned
	/// [`Record`](struct.Record.html) instead.
	///
	/// See [`DNSServiceUpdateRecord`](https://developer.apple.com/documentation/dnssd/1804739-dnsserviceupdaterecord).
	#[doc(alias = "DNSServiceUpdateRecord")]
	pub fn update_record(&self, rdata: &[u8], ttl: u32) -> io::Result<()> {
		self.inner_record().update_record(rdata, ttl)
	}

	/// Keep record for as long as the underlying connection lives.
	///
	/// Keep the a handle to the underlying connection (either the
	/// [`Connection`](struct.Connection.html) or some other record from
	/// the same `Connection`) alive.
	///
	/// Due to some implementation detail the underlying connection
	/// might live until this future successfully completes.
	///
	/// # Panics
	///
	/// Panics after the future completed.  Use the returned
	/// [`Record`](struct.Record.html) instead.
	// - implementation detail: this drives the future to continuation,
	//   it is not possible to drop the (shared) underlying service
	//   before. instead we could store the callback context with the
	//   underyling service, and drop it either when dropping the
	//   service or the callback was called.
	pub fn keep(self) {
		let (fut, rec) = (
			self.future,
			self.record.expect("RegisterRecord future is done"),
		);
		// drive future to continuation, ignore errors
		tokio::spawn(fut.map(|_| ()));
		rec.keep();
	}
}
