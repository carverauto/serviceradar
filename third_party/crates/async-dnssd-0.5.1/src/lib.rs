#![doc(html_root_url = "https://docs.rs/async-dnssd/0.5.1")]
#![warn(missing_docs)]
#![warn(rust_2018_idioms)]
#![warn(unused_extern_crates, unused_qualifications)]
//! # Asynchronous wrapper for DNS-SD C libraries
//!
//! Interesting entry points:
//!
//! * [Browse for available services][`browse`]
//! * [Create Connection to register records with][`connect`]
//! * [Enumerate domains that are recommended for registration or browsing][`enumerate_domains`]
//! * [Query for an arbitrary DNS record][`query_record`]
//! * [Register a service][`register`]
//! * [Add a record to a registered service][`Registration::add_record`]
//! * [Register record][`Connection::register_record`]
//! * [Find hostname and port (and more) for a service][`resolve`]
//!
//! Also the following things might be interesting:
//!
//! * [Purge record from cache][`reconfirm_record`]
//! * [Construct full name][`FullName::construct`]
//! * [Stream timeouts][`TimeoutStream`]
//!
//! ## Porting from dnssd C API
//!
//! | C API                           | functionality in this crate                                  |
//! |---------------------------------|--------------------------------------------------------------|
//! | [`DNSServiceAddRecord`]         | [`Registration::add_record`], [`Register::add_record`]       |
//! | [`DNSServiceBrowse`]            | [`browse`]                                                   |
//! | [`DNSServiceConstructFullName`] | [`FullName::construct`]                                      |
//! | [`DNSServiceCreateConnection`]  | [`connect`]                                                  |
//! | [`DNSServiceEnumerateDomains`]  | [`enumerate_domains`]                                        |
//! | [`DNSServiceQueryRecord`]       | [`query_record`]                                             |
//! | [`DNSServiceReconfirmRecord`]   | [`reconfirm_record`]                                         |
//! | [`DNSServiceRegister`]          | [`register`]                                                 |
//! | [`DNSServiceRegisterRecord`]    | [`Connection::register_record`]                              |
//! | [`DNSServiceResolve`]           | [`resolve`]                                                  |
//! | [`DNSServiceUpdateRecord`]      | [`Record::update_record`], [`RegisterRecord::update_record`] |
//!
//! The following functions are called automatically when needed:
//! * [`DNSServiceProcessResult`] driving callbacks (event loop)
//! * [`DNSServiceRefDeallocate`] called when dropping various resource handles
//! * [`DNSServiceRefSockFD`] used for integration with tokio (event loop)
//! * [`DNSServiceRemoveRecord`] called when dropping [`Record`](struct.Record.html)
//!
//! The `TXTRecord*` "TXT Record Construction Functions" are not
//! wrapped; [`TxtRecord`] provides a native rust implementation with
//! similar functionality.
//!
//! [`DNSServiceAddRecord`]: https://developer.apple.com/documentation/dnssd/1804730-dnsserviceaddrecord
//! [`DNSServiceBrowse`]: https://developer.apple.com/documentation/dnssd/1804742-dnsservicebrowse
//! [`DNSServiceConstructFullName`]: https://developer.apple.com/documentation/dnssd/1804753-dnsserviceconstructfullname
//! [`DNSServiceCreateConnection`]: https://developer.apple.com/documentation/dnssd/1804724-dnsservicecreateconnection
//! [`DNSServiceEnumerateDomains`]: https://developer.apple.com/documentation/dnssd/1804754-dnsserviceenumeratedomains
//! [`DNSServiceQueryRecord`]: https://developer.apple.com/documentation/dnssd/1804747-dnsservicequeryrecord
//! [`DNSServiceReconfirmRecord`]: https://developer.apple.com/documentation/dnssd/1804726-dnsservicereconfirmrecord
//! [`DNSServiceRegister`]: https://developer.apple.com/documentation/dnssd/1804733-dnsserviceregister
//! [`DNSServiceRegisterRecord`]: https://developer.apple.com/documentation/dnssd/1804727-dnsserviceregisterrecord
//! [`DNSServiceResolve`]: https://developer.apple.com/documentation/dnssd/1804744-dnsserviceresolve
//! [`DNSServiceUpdateRecord`]: https://developer.apple.com/documentation/dnssd/1804739-dnsserviceupdaterecord
//! [`DNSServiceProcessResult`]: https://developer.apple.com/documentation/dnssd/1804696-dnsserviceprocessresult
//! [`DNSServiceRefDeallocate`]: https://developer.apple.com/documentation/dnssd/1804697-dnsservicerefdeallocate
//! [`DNSServiceRefSockFD`]: https://developer.apple.com/documentation/dnssd/1804698-dnsservicerefsockfd
//! [`DNSServiceRemoveRecord`]: https://developer.apple.com/documentation/dnssd/1804736-dnsserviceremoverecord
//! [`Registration::add_record`]: struct.Registration.html#method.add_record
//! [`Register::add_record`]: struct.Register.html#method.add_record
//! [`browse`]: fn.browse.html
//! [`FullName::construct`]: struct.FullName.html#method.construct
//! [`connect`]: fn.connect.html
//! [`enumerate_domains`]: fn.enumerate_domains.html
//! [`query_record`]: fn.query_record.html
//! [`reconfirm_record`]: fn.reconfirm_record.html
//! [`register`]: fn.register.html
//! [`Connection::register_record`]: struct.Connection.html#method.register_record
//! [`resolve`]: fn.resolve.html
//! [`Record::update_record`]: struct.Record.html#method.update_record
//! [`RegisterRecord::update_record`]: struct.RegisterRecord.html#method.update_record
//! [`TimeoutStream`]: struct.TimeoutStream.html
//! [`TxtRecord`]: struct.TxtRecord.html

pub use self::{
	dns_consts::{
		Class,
		Type,
	},
	error::Error,
	ffi::MAX_DOMAIN_NAME,
	interface::{
		Interface,
		InterfaceIndex,
	},
	service::*,
	timeout_stream::{
		StreamTimeoutExt,
		TimeoutStream,
	},
	txt_record::{
		TxtRecord,
		TxtRecordError,
		TxtRecordIter,
	},
};

mod cstr;
mod dns_consts;
mod error;
mod evented;
mod ffi;
mod fused_err_stream;
mod future;
mod inner;
mod interface;
mod non_exhaustive_struct;
mod notify;
mod service;
mod stream;
mod timeout_stream;
mod txt_record;

fn init() {
	#[cfg(all(unix, not(any(target_os = "macos", target_os = "ios"))))]
	{
		use std::sync::Once;

		static INIT: Once = Once::new();
		INIT.call_once(|| {
			const AVAHI_COMPAT_NOWARN: &str = "AVAHI_COMPAT_NOWARN";
			if std::env::var_os(AVAHI_COMPAT_NOWARN).is_none() {
				std::env::set_var(AVAHI_COMPAT_NOWARN, "1");
			}
		});
	}
}
