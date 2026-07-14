/// Owned payload of a Router Solicitation message (RFC 4861, Section 4.1).
///
/// The full packet layout is:
/// ```text
///  0                   1                   2                   3
///  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |     Type      |     Code      |          Checksum             |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                            Reserved                           |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |   Options ...
/// +-+-+-+-+-+-+-+-+-+-+-+-
/// ```
///
/// In this crate, the first 8 bytes (including `Reserved`) are represented by
/// [`crate::Icmpv6Type::RouterSolicitation`], so this payload struct has no fixed bytes.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub struct RouterSolicitationPayload;

impl RouterSolicitationPayload {
    /// Fixed payload length in bytes after the ICMPv6 header.
    pub const LEN: usize = 0;

    /// Convert to on-the-wire bytes.
    pub const fn to_bytes(&self) -> [u8; Self::LEN] {
        []
    }
}
