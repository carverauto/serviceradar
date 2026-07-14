use futures_util::{
	StreamExt,
	TryStreamExt,
};
use std::{
	fmt,
	io,
	net::{
		IpAddr,
		Ipv4Addr,
		Ipv6Addr,
		SocketAddr,
		SocketAddrV4,
		SocketAddrV6,
	},
	pin::Pin,
	task::{
		Context,
		Poll,
	},
};

use crate::{
	dns_consts::{
		Class,
		Type,
	},
	ffi,
	interface::Interface,
	service::{
		query_record_extended,
		QueryRecordData,
		QueryRecordFlags,
		QueryRecordResult,
	},
};

fn decode_a(a: QueryRecordResult, port: u16) -> Option<ResolveHostResult> {
	if a.rr_class == Class::IN && a.rr_type == Type::A && a.rdata.len() == 4 {
		let mut octets = [0u8; 4];
		octets.clone_from_slice(&a.rdata);
		let ip = IpAddr::V4(Ipv4Addr::from(octets));
		let addr = ScopedSocketAddr::new(ip, port, a.interface.scope_id());
		Some(ResolveHostResult {
			flags: ResolvedHostFlags::from_bits_truncate(a.flags.bits()),
			address: addr,
		})
	} else {
		println!("Invalid A response: {:?}", a);
		None
	}
}

fn decode_aaaa(a: QueryRecordResult, port: u16) -> Option<ResolveHostResult> {
	if a.rr_class == Class::IN && a.rr_type == Type::AAAA && a.rdata.len() == 16 {
		let mut octets = [0u8; 16];
		octets.clone_from_slice(&a.rdata);
		let ip = IpAddr::V6(Ipv6Addr::from(octets));
		let addr = ScopedSocketAddr::new(ip, port, a.interface.scope_id());
		Some(ResolveHostResult {
			flags: ResolvedHostFlags::from_bits_truncate(a.flags.bits()),
			address: addr,
		})
	} else {
		println!("Invalid AAAA response: {:?}", a);
		None
	}
}

bitflags::bitflags! {
	/// Flags for [`ResolveHostResult`](struct.ResolveHostResult.html)
	///
	/// Doesn't include `MORE_COMING` as there are two underlying streams.
	#[derive(Default)]
	pub struct ResolvedHostFlags: ffi::DNSServiceFlags {
		/// Indicates the result is new.  If not set indicates the result
		/// was removed.
		///
		/// See [`kDNSServiceFlagsAdd`](https://developer.apple.com/documentation/dnssd/1823436-anonymous/kdnsserviceflagsadd).
		const ADD = ffi::FLAGS_ADD;
	}
}

/// Optional data when querying for a record; either use its default
/// value or customize it like:
///
/// ```
/// # use async_dnssd::ResolveHostData;
/// # use async_dnssd::QueryRecordFlags;
/// ResolveHostData {
///     flags: QueryRecordFlags::LONG_LIVED_QUERY,
///     ..Default::default()
/// };
/// ```
#[derive(Clone, Copy, Default, PartialEq, Eq, PartialOrd, Ord, Hash, Debug)]
pub struct ResolveHostData {
	/// flags for query
	pub flags: QueryRecordFlags,
	/// interface to query records on
	pub interface: Interface,
	#[doc(hidden)]
	pub _non_exhaustive: crate::non_exhaustive_struct::NonExhaustiveMarker,
}

/// Pending resolve
#[must_use = "streams do nothing unless polled"]
pub struct ResolveHost {
	inner: Pin<
		Box<dyn futures_core::Stream<Item = io::Result<ResolveHostResult>> + 'static + Send + Sync>,
	>,
}

impl futures_core::Stream for ResolveHost {
	type Item = io::Result<ResolveHostResult>;

	fn poll_next(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
		self.inner.poll_next_unpin(cx)
	}
}

/// Resolve host result
///
/// See [`DNSServiceResolveReply`](https://developer.apple.com/documentation/dnssd/dnsserviceresolvereply).
#[derive(Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Debug)]
pub struct ResolveHostResult {
	/// flags
	pub flags: ResolvedHostFlags,
	/// address
	pub address: ScopedSocketAddr,
}

/// IP address with port and "scope id" (even for IPv4)
///
/// When converting to `SocketAddr` the "scope id" is lost for IPv4; when converting to
/// `SocketAddrV6` it uses `to_ipv6_mapped()` for IPv4 addresses.
#[derive(Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum ScopedSocketAddr {
	/// IPv4 target
	V4 {
		/// IP address
		address: Ipv4Addr,
		/// Port
		port: u16,
		/// Scope id (interface index; 0 for any)
		scope_id: u32,
	},
	/// IPv6 target
	V6 {
		/// IP address
		address: Ipv6Addr,
		/// Port
		port: u16,
		/// Scope id (interface index; 0 for any)
		scope_id: u32,
	},
}

impl ScopedSocketAddr {
	/// Create new `ScopedSocketAddr`
	pub fn new(address: IpAddr, port: u16, scope_id: u32) -> Self {
		match address {
			IpAddr::V4(address) => Self::V4 {
				address,
				port,
				scope_id,
			},
			IpAddr::V6(address) => Self::V6 {
				address,
				port,
				scope_id,
			},
		}
	}
}

impl From<ScopedSocketAddr> for SocketAddr {
	fn from(scoped_addr: ScopedSocketAddr) -> Self {
		match scoped_addr {
			ScopedSocketAddr::V4 { address, port, .. } => {
				// doesn't use scope_id
				Self::V4(SocketAddrV4::new(address, port))
			},
			ScopedSocketAddr::V6 {
				address,
				port,
				scope_id,
			} => Self::V6(SocketAddrV6::new(address, port, 0, scope_id)),
		}
	}
}

impl From<ScopedSocketAddr> for SocketAddrV6 {
	fn from(scoped_addr: ScopedSocketAddr) -> Self {
		match scoped_addr {
			ScopedSocketAddr::V4 {
				address,
				port,
				scope_id,
			} => Self::new(address.to_ipv6_mapped(), port, 0, scope_id),
			ScopedSocketAddr::V6 {
				address,
				port,
				scope_id,
			} => Self::new(address, port, 0, scope_id),
		}
	}
}

impl fmt::Display for ScopedSocketAddr {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Self::V4 {
				address,
				port,
				scope_id: 0,
			} => write!(f, "{}:{}", address, port),
			Self::V4 {
				address,
				port,
				scope_id,
			} => write!(f, "[{}%{}]:{}", address, scope_id, port),
			Self::V6 {
				address,
				port,
				scope_id: 0,
			} => write!(f, "[{}]:{}", address, port),
			Self::V6 {
				address,
				port,
				scope_id,
			} => write!(f, "[{}%{}]:{}", address, scope_id, port),
		}
	}
}

impl fmt::Debug for ScopedSocketAddr {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		fmt::Display::fmt(self, f)
	}
}

/// Resolves hostname (with passed port) to stream of `ScopedSocketAddr`.
///
/// Uses
/// [`DNSServiceQueryRecord`](https://developer.apple.com/documentation/dnssd/1804747-dnsservicequeryrecord)
/// to query for `A` and `AAAA` records (in the `IN` class).
#[doc(alias = "DNSServiceQueryRecord")]
pub fn resolve_host_extended(host: &str, port: u16, data: ResolveHostData) -> ResolveHost {
	let qrdata = QueryRecordData {
		flags: data.flags,
		interface: data.interface,
		rr_class: Class::IN,
		..Default::default()
	};

	let inner_v6 = query_record_extended(host, Type::AAAA, qrdata)
		.try_filter_map(move |addr| async move { Ok(decode_aaaa(addr, port)) });
	let inner_v4 = query_record_extended(host, Type::A, qrdata)
		.try_filter_map(move |addr| async move { Ok(decode_a(addr, port)) });
	let inner = Box::pin(futures_util::stream::select(inner_v6, inner_v4));

	ResolveHost { inner }
}
