use std::net::SocketAddr;

use attohttpc::ErrorKind;
use axum::body::Body;
use axum::response::Response;
use axum::routing::get;
use axum::Router;
use http::StatusCode;

async fn make_server() -> Result<u16, anyhow::Error> {
    let addr = SocketAddr::from(([127, 0, 0, 1], 0));
    let incoming = tokio::net::TcpListener::bind(&addr).await?;
    let local_addr = incoming.local_addr()?;

    async fn x301() -> Response {
        Response::builder()
            .status(StatusCode::MOVED_PERMANENTLY)
            .header("Location", "/301")
            .body(Body::from(""))
            .unwrap()
    }

    async fn x304() -> Response {
        Response::builder()
            .status(StatusCode::NOT_MODIFIED)
            .body(Body::from(""))
            .unwrap()
    }

    let app = Router::new().route("/301", get(x301)).route("/304", get(x304));

    tokio::spawn(async move {
        axum::serve(incoming, app).await.unwrap();
    });

    Ok(local_addr.port())
}

#[tokio::test(flavor = "multi_thread")]
async fn test_redirection_default() -> Result<(), anyhow::Error> {
    let port = make_server().await?;

    match attohttpc::get(format!("http://localhost:{port}/301")).send() {
        Err(err) => match err.kind() {
            ErrorKind::TooManyRedirections => (),
            _ => panic!(),
        },
        _ => panic!(),
    }

    Ok(())
}

#[tokio::test(flavor = "multi_thread")]
async fn test_redirection_0() -> Result<(), anyhow::Error> {
    let port = make_server().await?;

    match attohttpc::get(format!("http://localhost:{port}/301"))
        .max_redirections(0)
        .send()
    {
        Err(err) => match err.kind() {
            ErrorKind::TooManyRedirections => (),
            _ => panic!(),
        },
        _ => panic!(),
    }

    Ok(())
}

#[tokio::test(flavor = "multi_thread")]
async fn test_redirection_disallowed() -> Result<(), anyhow::Error> {
    let port = make_server().await?;

    let resp = attohttpc::get(format!("http://localhost:{port}/301"))
        .follow_redirects(false)
        .send()
        .unwrap();

    assert!(resp.status().is_redirection());

    Ok(())
}

#[tokio::test(flavor = "multi_thread")]
async fn test_redirection_not_redirect() -> Result<(), anyhow::Error> {
    let port = make_server().await?;

    match attohttpc::get(format!("http://localhost:{port}/304")).send() {
        Ok(_) => (),
        _ => panic!(),
    }

    Ok(())
}
