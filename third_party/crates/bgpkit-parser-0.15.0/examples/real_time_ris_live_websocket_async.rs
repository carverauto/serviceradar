use bgpkit_parser::parse_ris_live_message;
use bgpkit_parser::rislive::messages::{RisLiveClientMessage, RisSubscribe};
use futures_util::{SinkExt, StreamExt};
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;

const RIS_LIVE_URL: &str = "ws://ris-live.ripe.net/v1/ws/?client=bgpkit-parser-example-async";

#[tokio::main]
async fn main() {
    // connect to websocket server
    let (ws_stream, _response) = connect_async(RIS_LIVE_URL).await.unwrap();

    // send a subscription message
    let msg = RisSubscribe::new().host("rrc21");
    let (mut write, mut read) = ws_stream.split();
    write
        .send(Message::Text(msg.to_json_string().into()))
        .await
        .unwrap();

    // read loop
    while let Some(Ok(msg)) = read.next().await {
        if msg.is_empty() {
            continue;
        }

        let msg_str = msg.to_string();

        match parse_ris_live_message(msg_str.as_str()) {
            Ok(elems) => {
                for elem in elems {
                    println!("{elem}");
                }
            }
            Err(err) => {
                eprintln!("{err}");
            }
        }
    }
}
