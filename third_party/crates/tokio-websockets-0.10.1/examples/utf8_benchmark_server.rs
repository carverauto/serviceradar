use std::fs::remove_file;

use futures_util::{SinkExt, StreamExt};
use tokio::net::UnixListener;
use tokio_websockets::{Error, Limits, ServerBuilder};

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Error> {
    // The socket might still exist from an earlier run!
    let _ = remove_file("/tmp/tokio-websockets.sock");

    let listener = UnixListener::bind("/tmp/tokio-websockets.sock")?;
    let (stream, _) = listener.accept().await?;

    let mut ws = ServerBuilder::new()
        .limits(Limits::unlimited())
        .serve(stream);

    while let Some(Ok(msg)) = ws.next().await {
        ws.send(msg).await?;
    }

    Ok(())
}
