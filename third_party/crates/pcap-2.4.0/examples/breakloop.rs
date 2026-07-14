use std::{thread, time::Duration};

fn main() {
    // Get the default device
    let device = pcap::Device::lookup()
        .expect("device lookup failed")
        .expect("no device available");
    println!("Using device {}", device.name);

    // Setup capture
    let mut cap = pcap::Capture::from_device(device)
        .unwrap()
        .immediate_mode(true)
        .open()
        .unwrap();
    println!("Using device");

    let break_handle = cap.breakloop_handle();

    // Start capture in a separate thread
    let capture_thread = thread::spawn(move || {
        while cap.next_packet().is_ok() {
            println!("got packet!");
        }
        println!("capture loop exited");
    });

    // Send break_handle to a separate thread (e.g. user input, signal handler, etc.)
    thread::spawn(move || {
        thread::sleep(Duration::from_secs(1));
        println!("break loop called!");
        break_handle.breakloop();
    });

    capture_thread.join().unwrap();
}
