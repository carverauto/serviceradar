// This example explicitly creates and uses a single-threaded tokio
// runtime.  See streamlisten_mt.rs for an example using tokio macros
// and multiple threads.
//
use futures::StreamExt;
use pcap::{Active, Capture, Device, Error, Packet, PacketCodec, PacketStream};

pub struct SimpleDumpCodec;

impl PacketCodec for SimpleDumpCodec {
    type Item = String;

    fn decode(&mut self, packet: Packet) -> Self::Item {
        format!("{packet:?}")
    }
}

async fn start_new_stream(device: Device) -> PacketStream<Active, SimpleDumpCodec> {
    match new_stream(device) {
        Ok(stream) => stream,
        Err(e) => {
            println!("{e:?}");
            std::process::exit(1);
        }
    }
}

fn new_stream(device: Device) -> Result<PacketStream<Active, SimpleDumpCodec>, Error> {
    // get the default Device
    println!("Using device {}", device.name);

    let cap = Capture::from_device(device)?
        .immediate_mode(true)
        .open()?
        .setnonblock()?;
    cap.stream(SimpleDumpCodec {})
}

fn main() {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_io()
        .build()
        .unwrap();

    let device = Device::lookup()
        .expect("device lookup failed")
        .expect("no device available");
    let stream = rt.block_on(start_new_stream(device));

    let fut = stream.for_each(move |s| {
        println!("{s:?}");
        futures::future::ready(())
    });
    rt.block_on(fut);
}
