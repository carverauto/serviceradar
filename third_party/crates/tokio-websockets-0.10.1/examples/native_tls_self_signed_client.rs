use futures_util::{SinkExt, StreamExt};
use http::Uri;
use tokio_native_tls::native_tls::{Certificate, TlsConnector};
use tokio_websockets::{ClientBuilder, Error};

#[tokio::main]
async fn main() -> Result<(), Error> {
    let uri = Uri::from_static("wss://127.0.0.1:8080");
    let bytes = std::fs::read("certs/localhost.crt")?;
    let cert = Certificate::from_pem(&bytes)?;
    let connector = TlsConnector::builder().add_root_certificate(cert).build()?;
    let connector = tokio_websockets::Connector::NativeTls(connector.into());

    let (mut client, _) = ClientBuilder::from_uri(uri)
        .connector(&connector)
        .connect()
        .await?;

    let msg = client.next().await;

    println!("Got message: {msg:?}");

    client.close().await?;

    Ok(())
}
