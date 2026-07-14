use crate::packet::Packet;

/// This trait is used to implement Stream and Iterator feature.
/// This is almost like `map()`.
///
// This is needed cause we don't have GaTs
// Once GaTs are stable we could use them to implement better Iterator
pub trait PacketCodec {
    type Item;

    fn decode(&mut self, packet: Packet<'_>) -> Self::Item;
}

// GRCOV_EXCL_START
#[cfg(test)]
pub mod testmod {
    use crate::packet::PacketHeader;

    use super::*;

    pub struct Codec;

    #[derive(Debug, PartialEq, Eq)]
    pub struct PacketOwned {
        pub header: PacketHeader,
        pub data: Box<[u8]>,
    }

    impl PacketCodec for Codec {
        type Item = PacketOwned;

        fn decode(&mut self, pkt: Packet) -> Self::Item {
            PacketOwned {
                header: *pkt.header,
                data: pkt.data.into(),
            }
        }
    }
}
// GRCOV_EXCL_STOP
