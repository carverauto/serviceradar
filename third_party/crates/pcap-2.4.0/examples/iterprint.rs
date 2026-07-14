//! Example of using iterators that print paquet
use pcap::{Capture, Device, Packet, PacketCodec, PacketHeader};
use std::error;

/// Represents a owned packet
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PacketOwned {
    pub header: PacketHeader,
    pub data: Box<[u8]>,
}

/// Simple codec that tranform [`pcap::Packet`] into [`PacketOwned`]
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

fn main() -> Result<(), Box<dyn error::Error>> {
    let device = Device::lookup()?.ok_or("no device available")?;

    // get the default Device
    println!("Using device {}", device.name);

    let cap = Capture::from_device(device)?.immediate_mode(true).open()?;

    for packet in cap.iter(Codec) {
        let packet = packet?;

        println!("{packet:?}");
    }

    Ok(())
}
