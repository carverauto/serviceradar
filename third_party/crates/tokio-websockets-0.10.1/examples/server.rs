use futures_util::{SinkExt, StreamExt};
use tokio::net::TcpListener;
use tokio_websockets::{Error, ServerBuilder};

#[tokio::main]
async fn main() -> Result<(), Error> {
    let listener = TcpListener::bind("127.0.0.1:3000").await?;

    loop {
        let (conn, _) = listener.accept().await?;
        let mut server = ServerBuilder::new().accept(conn).await?;

        while let Some(Ok(item)) = server.next().await {
            println!("Received: {item:?}");
            server.send(item).await?;
        }
    }
}
