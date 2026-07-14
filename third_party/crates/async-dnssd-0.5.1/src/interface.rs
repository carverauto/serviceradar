use std::fmt;

use crate::ffi;

/// Network interface index
///
/// Identifies a single interface by index.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct InterfaceIndex(u32);

impl InterfaceIndex {
	/// Construct new `InterfaceIndex` from raw index and makes sure
	/// not to use the special reserved values.
	pub fn from_raw(ndx: u32) -> Option<Self> {
		match ndx {
			ffi::INTERFACE_INDEX_ANY => None,
			ffi::INTERFACE_INDEX_LOCAL_ONLY => None,
			ffi::INTERFACE_INDEX_UNICAST => None,
			ffi::INTERFACE_INDEX_P2P => None,
			_ => Some(Self(ndx)),
		}
	}

	/// raw index
	pub fn into_raw(self) -> u32 {
		self.0
	}
}

impl From<InterfaceIndex> for u32 {
	fn from(ndx: InterfaceIndex) -> Self {
		ndx.into_raw()
	}
}

impl fmt::Debug for InterfaceIndex {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		fmt::Debug::fmt(&self.0, f)
	}
}

/// Network interface
///
/// Either identifies a single interface (by index) or the special "Any"
/// or "LocalOnly" interfaces.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Debug)]
#[non_exhaustive]
pub enum Interface {
	/// Any interface; depending on domain name this means either
	/// multicast or unicast
	Any,
	/// Single interface
	Index(InterfaceIndex),
	/// Local machine only
	LocalOnly,
	/// See [`kDNSServiceInterfaceIndexUnicast`](https://developer.apple.com/documentation/dnssd/kdnsserviceinterfaceindexunicast)
	Unicast,
	/// See [`kDNSServiceInterfaceIndexP2P`](https://developer.apple.com/documentation/dnssd/kdnsserviceinterfaceindexp2p)
	PeerToPeer,
}

impl Default for Interface {
	fn default() -> Self {
		Self::Any
	}
}

impl Interface {
	/// Construct from raw value
	pub fn from_raw(raw: u32) -> Self {
		match raw {
			ffi::INTERFACE_INDEX_ANY => Self::Any,
			ffi::INTERFACE_INDEX_LOCAL_ONLY => Self::LocalOnly,
			ffi::INTERFACE_INDEX_UNICAST => Self::Unicast,
			ffi::INTERFACE_INDEX_P2P => Self::PeerToPeer,
			_ => Self::Index(InterfaceIndex(raw)),
		}
	}

	/// Convert to raw value
	pub fn into_raw(self) -> u32 {
		match self {
			Self::Any => ffi::INTERFACE_INDEX_ANY,
			Self::Index(InterfaceIndex(raw)) => raw,
			Self::LocalOnly => ffi::INTERFACE_INDEX_LOCAL_ONLY,
			Self::Unicast => ffi::INTERFACE_INDEX_UNICAST,
			Self::PeerToPeer => ffi::INTERFACE_INDEX_P2P,
		}
	}

	/// Extract scope id / interface index
	///
	/// Returns the interface index (or zero if not a single interface is selected)
	pub fn scope_id(self) -> u32 {
		match self {
			Self::Index(InterfaceIndex(scope_id)) => scope_id,
			_ => 0,
		}
	}
}

impl From<Interface> for u32 {
	fn from(i: Interface) -> u32 {
		i.into_raw()
	}
}
