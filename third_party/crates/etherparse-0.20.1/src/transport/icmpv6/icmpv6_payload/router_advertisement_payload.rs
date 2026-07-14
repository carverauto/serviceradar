/// Owned payload of a Router Advertisement message (RFC 4861, Section 4.2).
///
/// The full packet layout is:
/// ```text
///  0                   1                   2                   3
///  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |     Type      |     Code      |          Checksum             |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// | Cur Hop Limit |M|O|  Reserved |       Router Lifetime         |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                         Reachable Time                        |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                          Retrans Timer                        |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |   Options ...
/// +-+-+-+-+-+-+-+-+-+-+-+-
/// ```
///
/// In this crate, `Cur Hop Limit`, `M`, `O`, and `Router Lifetime` are represented by
/// [`crate::icmpv6::RouterAdvertisementHeader`] in [`crate::Icmpv6Type::RouterAdvertisement`].
/// This payload struct represents the fixed bytes after that:
/// - `Reachable Time`
/// - `Retrans Timer`
#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub struct RouterAdvertisementPayload {
    /// Reachable time in milliseconds.
    pub reachable_time: u32,
    /// Retransmit timer in milliseconds.
    pub retrans_timer: u32,
}

impl RouterAdvertisementPayload {
    /// Fixed payload length in bytes after the ICMPv6 header.
    pub const LEN: usize = 8;

    /// Convert to on-the-wire bytes.
    pub fn to_bytes(&self) -> [u8; Self::LEN] {
        let mut out = [0u8; Self::LEN];

        // Safety: unwraps are safe because Self::LEN == 8, which is larger than the number of
        // octets in u32
        *out.first_chunk_mut().unwrap() = self.reachable_time.to_be_bytes();
        *out.last_chunk_mut().unwrap() = self.retrans_timer.to_be_bytes();

        out
    }
}
