fn main() {
    // list all of the devices pcap tells us are available
    for device in pcap::Device::list().expect("device lookup failed") {
        println!("Found device! {device:?}");

        // now you can create a Capture with this Device if you want.
        // see example/easylisten.rs for how
    }
}
