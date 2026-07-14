use futures::StreamExt;
use pcap::{Active, Capture, Device, Error, Packet, PacketCodec, PacketStream};
use std::error;

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

#[tokio::main(flavor = "multi_thread", worker_threads = 10)]
async fn main() -> Result<(), Box<dyn error::Error>> {
    let device = Device::lookup()?.ok_or("no device available")?;
    let stream = start_new_stream(device).await;

    let fut = stream.for_each(move |s| {
        println!("{s:?}");
        futures::future::ready(())
    });
    fut.await;
    Ok(())
}
