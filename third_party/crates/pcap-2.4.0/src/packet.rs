use std::{fmt, ops::Deref};

/// Represents a packet returned from pcap.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Packet<'a> {
    /// The packet header provided by pcap, including the timeval, captured length, and packet
    /// length
    pub header: &'a PacketHeader,
    /// The captured packet data
    pub data: &'a [u8],
}

impl<'a> Packet<'a> {
    #[doc(hidden)]
    pub fn new(header: &'a PacketHeader, data: &'a [u8]) -> Packet<'a> {
        Packet { header, data }
    }
}

impl Deref for Packet<'_> {
    type Target = [u8];

    fn deref(&self) -> &[u8] {
        self.data
    }
}

#[repr(C)]
#[derive(Copy, Clone)]
/// Represents a packet header provided by pcap, including the timeval, caplen and len.
pub struct PacketHeader {
    /// The time when the packet was captured
    pub ts: libc::timeval,
    /// The number of bytes of the packet that are available from the capture
    pub caplen: u32,
    /// The length of the packet, in bytes (which might be more than the number of bytes available
    /// from the capture, if the length of the packet is larger than the maximum number of bytes to
    /// capture)
    pub len: u32,
}

impl fmt::Debug for PacketHeader {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "PacketHeader {{ ts: {}.{:06}, caplen: {}, len: {} }}",
            self.ts.tv_sec, self.ts.tv_usec, self.caplen, self.len
        )
    }
}

impl PartialEq for PacketHeader {
    fn eq(&self, rhs: &PacketHeader) -> bool {
        self.ts.tv_sec == rhs.ts.tv_sec
            && self.ts.tv_usec == rhs.ts.tv_usec
            && self.caplen == rhs.caplen
            && self.len == rhs.len
    }
}

impl Eq for PacketHeader {}

#[cfg(test)]
mod tests {
    use crate::raw;

    use super::*;

    static HEADER: PacketHeader = PacketHeader {
        ts: libc::timeval {
            tv_sec: 5,
            tv_usec: 50,
        },
        caplen: 5,
        len: 9,
    };

    #[test]
    fn test_packet_header_size() {
        use std::mem::size_of;
        assert_eq!(size_of::<PacketHeader>(), size_of::<raw::pcap_pkthdr>());
    }

    #[test]
    fn test_packet_header_clone() {
        // For code coverag purposes.
        #[allow(clippy::clone_on_copy)]
        let header_clone = HEADER.clone();
        assert_eq!(header_clone, HEADER);
    }

    #[test]
    fn test_packet_header_display() {
        assert!(!format!("{HEADER:?}").is_empty());
    }
}
