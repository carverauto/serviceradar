#![allow(clippy::too_many_arguments)]
use futures_util::FutureExt;
use libc::c_void;
use std::{
	io,
	ptr::null_mut,
	sync::{
		Arc,
		Mutex,
	},
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
	error::Error,
	ffi,
	notify::{
		Notified,
		Notify,
	},
};

// More typesafe than raw "ffi", but still not quite done

struct ManagedService(ffi::DNSServiceRef);

unsafe impl Send for ManagedService {}
unsafe impl Sync for ManagedService {}

impl Drop for ManagedService {
	fn drop(&mut self) {
		unsafe {
			ffi::DNSServiceRefDeallocate(self.0);
		}
	}
}

/// Keeps the service alive
#[derive(Clone)]
pub struct ServiceHandle {
	managed_service: Arc<ManagedService>,
}

impl ServiceHandle {
	fn new(raw: ffi::DNSServiceRef) -> Self {
		Self {
			managed_service: Arc::new(ManagedService(raw)),
		}
	}

	fn as_raw(&self) -> ffi::DNSServiceRef {
		self.managed_service.0
	}
}

pub(crate) trait EventedService: Unpin {
	// in various places we need to drive the underlying (possibly shared)
	// state machine, which will set other readiness events we then check.
	//
	// this underlying state machine will never complete, so there is
	// no need to return a Poll<..> result; but we do need a context to
	// drive the underlying service.
	fn poll_service(&mut self, cx: &mut Context<'_>) -> io::Result<()>;
}

/// Many places can keep the service alive, but a single active user
pub(crate) struct OwnedService {
	handle: ServiceHandle,
	processing: crate::evented::ReadProcessor,
}

impl OwnedService {
	fn new(raw: ffi::DNSServiceRef) -> io::Result<Self> {
		let fd = unsafe { ffi::DNSServiceRefSockFD(raw) };
		let handle = ServiceHandle::new(raw);
		let processing = crate::evented::ReadProcessor::new(fd)?;
		Ok(Self { handle, processing })
	}

	pub(crate) fn share(self) -> SharedService {
		let bg_fail_notify = Notify::new();
		let bg_fail_notified = bg_fail_notify.notified();
		let inner = Arc::new(Mutex::new(SharedInner {
			handle: self.handle,
			bg_error_buf: None,
			bg_failed: false,
			bg_fail_notify,
		}));
		let bg_inner = inner.clone();
		let mut processing = self.processing;

		let bg_task = futures_util::future::poll_fn(move |cx| {
			let mut inner = bg_inner.lock().unwrap();
			let raw = inner.handle.as_raw();
			let r = processing.process(cx, || {
				Error::from(unsafe { ffi::DNSServiceProcessResult(raw) })?;
				Ok(())
			});
			match r {
				Ok(()) => Poll::Pending, // run "forever"
				Err(e) => {
					inner.bg_error_buf = Some(e);
					inner.bg_failed = true;
					inner.bg_fail_notify.notify_waiters();
					Poll::Ready(()) // stop on errors
				},
			}
		});
		SharedService {
			inner,
			_bg_task_handle: Arc::new(AbortHandle(tokio::spawn(bg_task))),
			bg_fail_notified,
		}
	}

	// -----

	pub(crate) fn enumerate_domains(
		flags: ffi::DNSServiceFlags,
		interface_index: u32,
		callback: ffi::DNSServiceDomainEnumReply,
		context: *mut c_void,
	) -> Result<Self, Error> {
		let mut sd_ref: ffi::DNSServiceRef = null_mut();
		Error::from(unsafe {
			ffi::DNSServiceEnumerateDomains(&mut sd_ref, flags, interface_index, callback, context)
		})?;
		Ok(Self::new(sd_ref)?)
	}

	pub(crate) fn register(
		flags: ffi::DNSServiceFlags,
		interface_index: u32,
		name: &cstr::NullableCStr<'_>,
		reg_type: &cstr::CStr<'_>,
		domain: &cstr::NullableCStr<'_>,
		host: &cstr::NullableCStr<'_>,
		port: u16,
		txt: &[u8],
		callback: ffi::DNSServiceRegisterReply,
		context: *mut c_void,
	) -> Result<Self, Error> {
		let txt_len = txt.len();
		assert!(txt_len < (1 << 16));
		let txt_len = txt_len as u16;
		let txt_record = txt.as_ptr();

		let mut sd_ref: ffi::DNSServiceRef = null_mut();
		Error::from(unsafe {
			ffi::DNSServiceRegister(
				&mut sd_ref,
				flags,
				interface_index,
				name.as_ptr(),
				reg_type.as_ptr(),
				domain.as_ptr(),
				host.as_ptr(),
				port,
				txt_len,
				txt_record,
				callback,
				context,
			)
		})?;
		Ok(Self::new(sd_ref)?)
	}

	pub(crate) fn browse(
		flags: ffi::DNSServiceFlags,
		interface_index: u32,
		reg_type: &cstr::CStr<'_>,
		domain: &cstr::NullableCStr<'_>,
		callback: ffi::DNSServiceBrowseReply,
		context: *mut c_void,
	) -> Result<Self, Error> {
		let mut sd_ref: ffi::DNSServiceRef = null_mut();
		Error::from(unsafe {
			ffi::DNSServiceBrowse(
				&mut sd_ref,
				flags,
				interface_index,
				reg_type.as_ptr(),
				domain.as_ptr(),
				callback,
				context,
			)
		})?;
		Ok(Self::new(sd_ref)?)
	}

	pub(crate) fn resolve(
		flags: ffi::DNSServiceFlags,
		interface_index: u32,
		name: &cstr::CStr<'_>,
		reg_type: &cstr::CStr<'_>,
		domain: &cstr::CStr<'_>,
		callback: ffi::DNSServiceResolveReply,
		context: *mut c_void,
	) -> Result<Self, Error> {
		let mut sd_ref: ffi::DNSServiceRef = null_mut();
		Error::from(unsafe {
			ffi::DNSServiceResolve(
				&mut sd_ref,
				flags,
				interface_index,
				name.as_ptr(),
				reg_type.as_ptr(),
				domain.as_ptr(),
				callback,
				context,
			)
		})?;
		Ok(Self::new(sd_ref)?)
	}

	pub(crate) fn query_record(
		flags: ffi::DNSServiceFlags,
		interface_index: u32,
		fullname: &cstr::CStr<'_>,
		rr_type: Type,
		rr_class: Class,
		callback: ffi::DNSServiceQueryRecordReply,
		context: *mut c_void,
	) -> Result<Self, Error> {
		let mut sd_ref: ffi::DNSServiceRef = null_mut();
		Error::from(unsafe {
			ffi::DNSServiceQueryRecord(
				&mut sd_ref,
				flags,
				interface_index,
				fullname.as_ptr(),
				rr_type.0,
				rr_class.0,
				callback,
				context,
			)
		})?;
		Ok(Self::new(sd_ref)?)
	}
}

impl EventedService for OwnedService {
	fn poll_service(&mut self, cx: &mut Context<'_>) -> io::Result<()> {
		let raw = self.handle.as_raw();
		self.processing.process(cx, || {
			Error::from(unsafe { ffi::DNSServiceProcessResult(raw) })?;
			Ok(())
		})
	}
}

struct AbortHandle(tokio::task::JoinHandle<()>);

impl Drop for AbortHandle {
	fn drop(&mut self) {
		self.0.abort();
	}
}

struct SharedInner {
	// protect ffi calls
	handle: ServiceHandle,
	// forward error from background task
	bg_error_buf: Option<io::Error>,
	// but we can extract error only once, so remember it failed
	bg_failed: bool,
	//
	bg_fail_notify: Notify,
}

#[derive(Clone)]
pub(crate) struct SharedService {
	inner: Arc<Mutex<SharedInner>>,
	// make sure we kill the background task once all users are gone
	_bg_task_handle: Arc<AbortHandle>,
	bg_fail_notified: Notified,
}

impl EventedService for SharedService {
	fn poll_service(&mut self, cx: &mut Context<'_>) -> io::Result<()> {
		// service is run in background task; just make sure there wasn't
		// an error yet and to get notified of future errors.
		let mut inner = self.inner.lock().unwrap();
		if let Some(e) = inner.bg_error_buf.take() {
			return Err(e);
		}
		if inner.bg_failed {
			return Err(io::Error::new(io::ErrorKind::NotConnected, "service gone"));
		}
		// should be pending, because we just checked for errors:
		let _ = self.bg_fail_notified.poll_unpin(cx);
		Ok(())
	}
}

impl SharedService {
	pub(crate) fn get_default_txt_record(self) -> DNSRecord {
		DNSRecord {
			service: self,
			raw: DNSRecordRef(null_mut()),
			rr_type: Type::TXT,
		}
	}

	// only valid when `service` was created through "register"
	//
	// still needs a SharedService to synchronize ffi calls
	pub(crate) fn add_record(
		self,
		flags: ffi::DNSServiceFlags,
		rr_type: Type,
		rdata: &[u8],
		ttl: u32,
	) -> Result<DNSRecord, Error> {
		let rd_len = rdata.len();
		assert!(rd_len < (1 << 16));
		let rd_len = rd_len as u16;
		let rdata = rdata.as_ptr();

		let inner = self.inner.lock().unwrap();

		let mut record_ref: ffi::DNSRecordRef = null_mut();
		Error::from(unsafe {
			ffi::DNSServiceAddRecord(
				inner.handle.as_raw(),
				&mut record_ref,
				flags,
				rr_type.0,
				rd_len,
				rdata,
				ttl,
			)
		})?;

		drop(inner);

		Ok(DNSRecord {
			service: self,
			raw: DNSRecordRef(record_ref),
			rr_type,
		})
	}

	pub(crate) fn create_connection() -> Result<Self, Error> {
		let mut sd_ref: ffi::DNSServiceRef = null_mut();
		Error::from(unsafe { ffi::DNSServiceCreateConnection(&mut sd_ref) })?;
		Ok(OwnedService::new(sd_ref)?.share())
	}

	// only valid when `service` was created through "create_connection"
	pub(crate) fn register_record(
		self,
		flags: ffi::DNSServiceFlags,
		interface_index: u32,
		fullname: &cstr::CStr<'_>,
		rr_type: Type,
		rr_class: Class,
		rdata: &[u8],
		ttl: u32,
		callback: ffi::DNSServiceRegisterRecordReply,
		context: *mut c_void,
	) -> Result<DNSRecord, Error> {
		let rd_len = rdata.len();
		assert!(rd_len < (1 << 16));
		let rd_len = rd_len as u16;
		let rdata = rdata.as_ptr();

		let inner = self.inner.lock().unwrap();

		let mut record_ref: ffi::DNSRecordRef = null_mut();
		Error::from(unsafe {
			ffi::DNSServiceRegisterRecord(
				inner.handle.as_raw(),
				&mut record_ref,
				flags,
				interface_index,
				fullname.as_ptr(),
				rr_type.0,
				rr_class.0,
				rd_len,
				rdata,
				ttl,
				callback,
				context,
			)
		})?;

		drop(inner);

		Ok(DNSRecord {
			service: self,
			raw: DNSRecordRef(record_ref),
			rr_type,
		})
	}
}

// so we don't have to unsafe impl for whole `DNSRecord`
//
// can only be used in combination with service handle, which is protected by mutex
struct DNSRecordRef(ffi::DNSRecordRef);

unsafe impl Sync for DNSRecordRef {}
unsafe impl Send for DNSRecordRef {}

pub(crate) struct DNSRecord {
	service: SharedService,
	raw: DNSRecordRef,
	rr_type: Type,
}

impl Drop for DNSRecord {
	fn drop(&mut self) {
		if !self.raw.0.is_null() {
			let inner = self.service.inner.lock().unwrap();
			unsafe {
				ffi::DNSServiceRemoveRecord(
					inner.handle.as_raw(),
					self.raw.0,
					0, // no flags
				);
			}
		}
	}
}

impl DNSRecord {
	pub(crate) fn update_record(
		&self,
		flags: ffi::DNSServiceFlags,
		rdata: &[u8],
		ttl: u32,
	) -> Result<(), Error> {
		let rd_len = rdata.len();
		assert!(rd_len < (1 << 16));
		let rd_len = rd_len as u16;
		let rdata = rdata.as_ptr();

		let inner = self.service.inner.lock().unwrap();

		Error::from(unsafe {
			ffi::DNSServiceUpdateRecord(
				inner.handle.as_raw(),
				self.raw.0,
				flags,
				rd_len,
				rdata,
				ttl,
			)
		})
	}

	pub(crate) fn rr_type(&self) -> Type {
		self.rr_type
	}

	// keep "forever" (until service is dropped)
	pub(crate) fn keep(mut self) {
		self.raw.0 = null_mut();
	}
}

pub fn reconfirm_record(
	flags: ffi::DNSServiceFlags,
	interface_index: u32,
	fullname: &cstr::CStr<'_>,
	rr_type: Type,
	rr_class: Class,
	rdata: &[u8],
) {
	let rd_len = rdata.len();
	assert!(rd_len < (1 << 16));
	let rd_len = rd_len as u16;
	let rdata = rdata.as_ptr();

	unsafe {
		ffi::DNSServiceReconfirmRecord(
			flags,
			interface_index,
			fullname.as_ptr(),
			rr_type.0,
			rr_class.0,
			rd_len,
			rdata,
		);
	}
}
