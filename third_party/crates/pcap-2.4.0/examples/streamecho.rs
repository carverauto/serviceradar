//! Example of using streams for an echo server.
//!
//! For brewity replies are sent with the same headers as the incoming
//! packets.
use futures::StreamExt;
use pcap::{Active, Capture, Device, Error, Packet, PacketCodec, PacketStream};
use std::error;

// Simple codec that returns owned copies, since the result may not
// reference the input packet.
pub struct BoxCodec;

impl PacketCodec for BoxCodec {
    type Item = Box<[u8]>;

    fn decode(&mut self, packet: Packet) -> Self::Item {
        packet.data.into()
    }
}

fn new_stream(device: Device) -> Result<PacketStream<Active, BoxCodec>, Error> {
    // get the default Device
    println!("Using device {}", device.name);

    let cap = Capture::from_device(device)?
        .immediate_mode(true)
        .open()?
        .setnonblock()?;
    cap.stream(BoxCodec)
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn error::Error>> {
    let device = Device::lookup()?.ok_or("no device available")?;
    let mut stream = new_stream(device)?;

    loop {
        // Here in the event loop we may await a bunch of other
        // futures too, using the select! macro from tokio.
        let data = stream.next().await.unwrap()?;
        stream.capture_mut().sendpacket(data)?;
    }
}
