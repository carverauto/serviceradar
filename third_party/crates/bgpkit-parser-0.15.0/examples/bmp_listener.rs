use bgpkit_parser::bmp::messages::BmpMessageBody;
use bgpkit_parser::parse_bmp_msg;
use bytes::{Buf, Bytes};
use std::io::Read;
use std::net::{TcpListener, TcpStream};
use std::thread;

fn handle_client(mut stream: TcpStream) {
    let mut buffer = [0; 102400];

    loop {
        match stream.read(&mut buffer) {
            Ok(bytes_read) => {
                if bytes_read == 0 {
                    println!("Client disconnected.");
                    break;
                }

                // Convert the received data to a hexadecimal string
                let hex_string = buffer[..bytes_read]
                    .iter()
                    .map(|b| format!("{b:02X}"))
                    .collect::<Vec<String>>()
                    .join(" ");
                println!("Received data (hex): {hex_string}");

                let mut data = Bytes::from(buffer[..bytes_read].to_vec());
                while data.remaining() > 0 {
                    let msg = parse_bmp_msg(&mut data).unwrap();
                    if let BmpMessageBody::RouteMonitoring(mon_msg) = &msg.message_body {
                        if mon_msg.is_end_of_rib() {
                            dbg!("end of RIB");
                        }
                    }
                    dbg!(msg);
                }
            }
            Err(e) => {
                eprintln!("Error reading from socket: {e}");
                break;
            }
        }
    }
}

fn main() {
    let listener = TcpListener::bind("0.0.0.0:11019").expect("Failed to bind to address");

    println!("Server listening on 0.0.0.0:11019...");

    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                println!("Accepted a new connection");
                let child_thread = thread::spawn(move || {
                    handle_client(stream);
                });
                child_thread.join().expect("Thread panicked");
            }
            Err(e) => {
                eprintln!("Error accepting connection: {e}");
            }
        }
    }
}
