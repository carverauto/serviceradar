use std::sync::mpsc::{sync_channel, Receiver, SyncSender};
use std::time::Duration;

use axum::extract::{DefaultBodyLimit, Multipart, State};
use axum::routing::post;
use axum::Router;
use bytes::Bytes;

#[derive(Debug, PartialEq, Eq)]
struct Part {
    name: Option<String>,
    file_name: Option<String>,
    content_type: Option<String>,
    data: Bytes,
}

async fn start_server() -> (u16, Receiver<Vec<Part>>) {
    let (send, recv) = sync_channel(1);

    async fn accept_form(State(send): State<SyncSender<Vec<Part>>>, mut multipart: Multipart) -> &'static str {
        let mut parts = Vec::new();
        while let Some(field) = multipart.next_field().await.unwrap() {
            parts.push(Part {
                name: field.name().map(|s| s.to_string()),
                file_name: field.file_name().map(|s| s.to_string()),
                content_type: field.content_type().map(|s| s.to_string()),
                data: field.bytes().await.unwrap(),
            });
        }
        send.send(parts).unwrap();
        "OK"
    }

    let app = Router::new()
        .route("/multipart", post(accept_form))
        .layer(DefaultBodyLimit::disable())
        .with_state(send);

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    (port, recv)
}

#[tokio::test(flavor = "multi_thread")]
async fn test_multipart_default() -> attohttpc::Result<()> {
    let file = attohttpc::MultipartFile::new("file", b"abc123")
        .with_type("text/plain")?
        .with_filename("hello.txt");
    let form = attohttpc::MultipartBuilder::new()
        .with_text("Hello", "world!")
        .with_file(file)
        .build()?;

    let (port, recv) = start_server().await;

    attohttpc::post(format!("http://localhost:{port}/multipart"))
        .body(form)
        .send()?
        .text()?;

    let parts = recv.recv_timeout(Duration::from_secs(5)).unwrap();
    assert_eq!(parts.len(), 2);
    assert_eq!(
        parts,
        vec![
            Part {
                name: Some("Hello".to_string()),
                file_name: None,
                content_type: None,
                data: Bytes::from(&b"world!"[..])
            },
            Part {
                name: Some("file".to_string()),
                file_name: Some("hello.txt".to_string()),
                content_type: Some("text/plain".to_string()),
                data: Bytes::from(&b"abc123"[..])
            }
        ]
    );

    Ok(())
}
