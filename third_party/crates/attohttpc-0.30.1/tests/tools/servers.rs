use std::net::SocketAddr;

use axum::body::Body;
use axum::http::StatusCode;
use axum::response::Response;
use axum::routing::get;
use axum::Router;
use axum_server::tls_rustls::{from_tcp_rustls, RustlsConfig};

pub async fn start_hello_world_server(tls: bool) -> anyhow::Result<u16> {
    let addr = SocketAddr::from(([127, 0, 0, 1], 0));
    let incoming = tokio::net::TcpListener::bind(&addr).await?;
    let local_addr = incoming.local_addr()?;

    async fn hello_world() -> Response {
        Response::builder()
            .status(StatusCode::OK)
            .body(Body::from("hello"))
            .unwrap()
    }

    let app = Router::new().route("/", get(hello_world));

    if tls {
        let config = RustlsConfig::from_pem(include_bytes!("cert.pem").to_vec(), include_bytes!("key.pem").to_vec())
            .await
            .unwrap();

        tokio::spawn(async move {
            from_tcp_rustls(incoming.into_std().unwrap(), config)
                .serve(app.into_make_service())
                .await
                .unwrap();
        });
    } else {
        tokio::spawn(async move {
            axum::serve(incoming, app).await.unwrap();
        });
    }

    Ok(local_addr.port())
}
