use core::net::Ipv6Addr;

/// Owned payload of a Redirect message (RFC 4861, Section 4.5).
///
/// The full packet layout is:
/// ```text
///  0                   1                   2                   3
///  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |     Type      |     Code      |          Checksum             |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                           Reserved                            |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                                                               |
/// +                                                               +
/// |                                                               |
/// +                       Target Address                          +
/// |                                                               |
/// +                                                               +
/// |                                                               |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                                                               |
/// +                                                               +
/// |                                                               |
/// +                     Destination Address                       +
/// |                                                               |
/// +                                                               +
/// |                                                               |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |   Options ...
/// +-+-+-+-+-+-+-+-+-+-+-+-
/// ```
///
/// In this crate, the first 8 bytes (including `Reserved`) are represented by
/// [`crate::Icmpv6Type::Redirect`]. This payload struct represents the fixed bytes:
/// - `Target Address`
/// - `Destination Address`
#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub struct RedirectPayload {
    /// Better first-hop target address.
    pub target_address: Ipv6Addr,
    /// Destination address being redirected.
    pub destination_address: Ipv6Addr,
}

impl RedirectPayload {
    /// Fixed payload length in bytes after the ICMPv6 header.
    pub const LEN: usize = 32;

    /// Convert to on-the-wire bytes.
    pub const fn to_bytes(&self) -> [u8; Self::LEN] {
        let mut out = [0u8; Self::LEN];
        // Safety: unwraps are safe because Self::LEN == 32, which is larger than the number of
        // octets in IPv6 address
        *out.first_chunk_mut().unwrap() = self.target_address.octets();
        *out.last_chunk_mut().unwrap() = self.destination_address.octets();
        out
    }
}
