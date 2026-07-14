use bgpkit_parser::parse_ris_live_message;
use bgpkit_parser::rislive::messages::{RisLiveClientMessage, RisSubscribe};
use tungstenite::{connect, Message};

const RIS_LIVE_URL: &str = "ws://ris-live.ripe.net/v1/ws/?client=bgpkit-parser-example";

/// This is an example of subscribing to RIS-Live's streaming data from one host (`rrc21`).
///
/// For more RIS-Live details, check out their documentation at https://ris-live.ripe.net/manual/
fn main() {
    // connect to RIPE RIS Live websocket server
    let (mut socket, _response) =
        connect(RIS_LIVE_URL).expect("Can't connect to RIS Live websocket server");

    // subscribe to messages from one collector
    let msg = RisSubscribe::new().host("rrc21");
    socket
        .send(Message::Text(msg.to_json_string().into()))
        .unwrap();

    loop {
        let msg = socket.read().expect("Error reading message").to_string();
        if msg.is_empty() {
            continue;
        }
        match parse_ris_live_message(msg.as_str()) {
            Ok(elems) => {
                for elem in elems {
                    println!("{elem}");
                }
            }
            Err(error) => {
                println!("{error:?}");
            }
        }
    }
}
