use std::io;

use crate::{
	dns_consts::Type,
	inner,
};

/// A successful record registration
///
/// Releases the record when dropped (unless it is a
/// [`Registration::get_default_txt_record`] or a
/// [`Register::get_default_txt_record`])
///
/// Also keeps the underlying [`Registration`] or [`Connection`] alive.
///
/// [`Registration::get_default_txt_record`]: struct.Registration.html#method.get_default_txt_record
/// [`Register::get_default_txt_record`]: struct.Register.html#method.get_default_txt_record
/// [`Registration`]: struct.Registration.html
/// [`Connection`]: struct.Connection.html
pub struct Record(inner::DNSRecord);

impl Record {
	/// Type of the record
	pub fn rr_type(&self) -> Type {
		self.0.rr_type()
	}

	/// Update record
	///
	/// Cannot change type or class of record.
	///
	/// See [`DNSServiceUpdateRecord`](https://developer.apple.com/documentation/dnssd/1804739-dnsserviceupdaterecord).
	#[doc(alias = "DNSServiceUpdateRecord")]
	pub fn update_record(&self, rdata: &[u8], ttl: u32) -> io::Result<()> {
		self.0.update_record(0 /* no flags */, rdata, ttl)?;
		Ok(())
	}

	/// Keep record alive for as long as the underlying
	/// [`Registration`](struct.Registration.html) or
	/// [`Connection`](struct.Connection.html) lives
	pub fn keep(self) {
		self.0.keep()
	}
}

impl From<inner::DNSRecord> for Record {
	fn from(r: inner::DNSRecord) -> Self {
		Self(r)
	}
}
