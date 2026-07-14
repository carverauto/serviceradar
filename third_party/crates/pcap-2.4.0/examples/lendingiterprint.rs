//! Example of using lending iterators that print paquet
use pcap::{Capture, Device};
use std::error;

use gat_std::gatify;

#[gatify]
fn main() -> Result<(), Box<dyn error::Error>> {
    let device = Device::lookup()?.ok_or("no device available")?;

    // get the default Device
    println!("Using device {}", device.name);

    let cap = Capture::from_device(device)?.immediate_mode(true).open()?;

    for packet in cap {
        let packet = packet?;

        println!("{packet:?}");
    }

    Ok(())
}
