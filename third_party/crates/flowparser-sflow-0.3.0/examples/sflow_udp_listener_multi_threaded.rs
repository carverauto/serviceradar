use flowparser_sflow::SflowParser;
use std::net::UdpSocket;
use std::sync::Arc;
use std::thread;

fn main() {
    let socket =
        Arc::new(UdpSocket::bind("0.0.0.0:6343").expect("Failed to bind to port 6343"));
    println!("Listening for sFlow datagrams on 0.0.0.0:6343 (multi-threaded)...");

    let num_threads = num_cpus();
    let mut handles = Vec::new();

    for i in 0..num_threads {
        let socket = Arc::clone(&socket);
        handles.push(thread::spawn(move || {
            let parser = SflowParser::default();
            let mut buf = [0u8; 65535];
            loop {
                match socket.recv_from(&mut buf) {
                    Ok((size, src)) => {
                        let result = parser.parse_bytes(&buf[..size]);
                        for datagram in &result.datagrams {
                            println!(
                                "[thread {}] From {}: seq={} samples={}",
                                i,
                                src,
                                datagram.sequence_number,
                                datagram.samples.len()
                            );
                        }
                        if let Some(err) = &result.error {
                            eprintln!("[thread {}] Parse error: {}", i, err);
                        }
                    }
                    Err(e) => eprintln!("[thread {}] Receive error: {}", i, e),
                }
            }
        }));
    }

    for handle in handles {
        handle.join().unwrap();
    }
}

fn num_cpus() -> usize {
    thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(4)
}
