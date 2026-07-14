use std::net::SocketAddr;

use futures_util::{SinkExt, StreamExt};
use tokio::net::TcpListener;
use tokio_websockets::{Config, Error, Limits, ServerBuilder};

const PORT: u16 = 3000;

async fn run() -> Result<(), Error> {
    let addr = SocketAddr::from(([127, 0, 0, 1], PORT));
    let listener = TcpListener::bind(addr).await?;

    loop {
        let (conn, _) = listener.accept().await?;

        tokio::spawn(tokio::task::unconstrained(async move {
            let mut server = unsafe {
                ServerBuilder::new()
                    .config(Config::default().frame_size(usize::MAX))
                    .limits(Limits::unlimited())
                    .accept(conn)
                    .await
                    .unwrap_unchecked()
            };

            while let Some(Ok(item)) = server.next().await {
                if item.is_text() || item.is_binary() {
                    unsafe { server.send(item).await.unwrap_unchecked() };
                }
            }
        }));
    }
}

fn main() -> Result<(), Error> {
    let rt = unsafe {
        tokio::runtime::Builder::new_current_thread()
            .enable_io()
            .build()
            .unwrap_unchecked()
    };

    rt.block_on(run())
}
