fn main() {
    // listen on the device named "any", which is only available on Linux. This is only for
    // demonstration purposes.
    let mut cap = pcap::Capture::from_device("any")
        .unwrap()
        .immediate_mode(true)
        .open()
        .unwrap();

    // filter out all packets that don't have 127.0.0.1 as a source or destination.
    cap.filter("host 127.0.0.1", true).unwrap();

    while let Ok(packet) = cap.next_packet() {
        println!("got packet! {packet:?}");
    }
}
