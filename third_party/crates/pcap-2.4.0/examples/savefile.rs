use pcap::*;

fn main() {
    {
        // open capture from default device
        let device = Device::lookup()
            .expect("device lookup failed")
            .expect("no device available");
        println!("Using device {}", device.name);

        // Setup Capture
        let mut cap = Capture::from_device(device)
            .unwrap()
            .immediate_mode(true)
            .open()
            .unwrap();

        // open savefile using the capture
        let mut savefile = cap.savefile("test.pcap").unwrap();

        // get a packet from the interface
        let p = cap.next_packet().unwrap();

        // print the packet out
        println!("packet received on network: {p:?}");

        // write the packet to the savefile
        savefile.write(&p);
    }

    // open a new capture from the test.pcap file we wrote to above
    let mut cap = Capture::from_file("test.pcap").unwrap();

    // get a packet
    let p = cap.next_packet().unwrap();

    // print that packet out -- it should be the same as the one we printed above
    println!("packet obtained from file: {p:?}");
}
