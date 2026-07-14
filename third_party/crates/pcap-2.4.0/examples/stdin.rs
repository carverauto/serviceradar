//! Example of reading a pcap dump file stream from stdin. This is useful
//! for integrating with other tools, such as tcpdump. For example,
//!
//!    tcpdump -i en0 -U -w - | cargo run --example stdin
//!

#[cfg(not(windows))]
mod inner {
    use pcap::{Packet, PacketCodec, PacketHeader};

    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct PacketOwned {
        pub header: PacketHeader,
        pub data: Box<[u8]>,
    }

    pub struct Codec;

    impl PacketCodec for Codec {
        type Item = PacketOwned;

        fn decode(&mut self, packet: Packet) -> Self::Item {
            PacketOwned {
                header: *packet.header,
                data: packet.data.into(),
            }
        }
    }
}

#[cfg(not(windows))]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    use inner::*;
    use pcap::Capture;
    use std::{io, os::unix::io::AsRawFd};

    let stdin = io::stdin();

    let cap = unsafe { Capture::from_raw_fd(stdin.as_raw_fd())? };

    for packet in cap.iter(Codec) {
        let packet = packet?;

        println!("{packet:?}");
    }

    Ok(())
}

#[cfg(windows)]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    eprintln!("Program not supported on Windows");
    Ok(())
}
