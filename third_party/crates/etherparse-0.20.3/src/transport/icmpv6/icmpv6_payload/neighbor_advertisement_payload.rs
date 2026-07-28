use core::net::Ipv6Addr;

/// Owned payload of a Neighbor Advertisement message (RFC 4861, Section 4.4).
///
/// The full packet layout is:
/// ```text
///  0                   1                   2                   3
///  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |     Type      |     Code      |          Checksum             |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |R|S|O|                     Reserved                            |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                                                               |
/// +                                                               +
/// |                                                               |
/// +                       Target Address                          +
/// |                                                               |
/// +                                                               +
/// |                                                               |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |   Options ...
/// +-+-+-+-+-+-+-+-+-+-+-+-
/// ```
///
/// In this crate, `R`, `S`, and `O` are represented by
/// [`crate::icmpv6::NeighborAdvertisementHeader`] in
/// [`crate::Icmpv6Type::NeighborAdvertisement`]. This payload struct represents
/// the fixed `Target Address` bytes.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub struct NeighborAdvertisementPayload {
    /// Target IPv6 address.
    pub target_address: Ipv6Addr,
}

impl NeighborAdvertisementPayload {
    /// Fixed payload length in bytes after the ICMPv6 header.
    pub const LEN: usize = 16;

    /// Convert to on-the-wire bytes.
    pub const fn to_bytes(&self) -> [u8; Self::LEN] {
        self.target_address.octets()
    }
}
