use futures_util::{SinkExt, StreamExt};
use http::Uri;
use tokio_websockets::{ClientBuilder, Error, Message};

#[tokio::main]
async fn main() -> Result<(), Error> {
    let uri = Uri::from_static("ws://127.0.0.1:3000");
    let (mut client, _) = ClientBuilder::from_uri(uri).connect().await?;

    client.send(Message::text("Hello, world!")).await?;

    while let Some(item) = client.next().await {
        println!("{item:?}");
    }

    Ok(())
}
