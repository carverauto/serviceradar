use flowparser_sflow::SflowParser;
use tokio::net::UdpSocket;

#[tokio::main]
async fn main() {
    let socket = UdpSocket::bind("0.0.0.0:6343")
        .await
        .expect("Failed to bind to port 6343");
    println!("Listening for sFlow datagrams on 0.0.0.0:6343 (tokio)...");

    let parser = SflowParser::default();
    let mut buf = [0u8; 65535];

    loop {
        match socket.recv_from(&mut buf).await {
            Ok((size, src)) => {
                let result = parser.parse_bytes(&buf[..size]);
                for datagram in &result.datagrams {
                    println!(
                        "From {}: seq={} samples={}",
                        src,
                        datagram.sequence_number,
                        datagram.samples.len()
                    );
                }
                if let Some(err) = &result.error {
                    eprintln!("Parse error: {}", err);
                }
            }
            Err(e) => eprintln!("Receive error: {}", e),
        }
    }
}
