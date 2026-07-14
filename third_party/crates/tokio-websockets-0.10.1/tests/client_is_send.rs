use tokio::net::TcpListener;
use tokio_websockets::{ClientBuilder, ServerBuilder};

#[tokio::test]
async fn test_client_is_send() {
    let tcp_listener = TcpListener::bind("127.0.0.1:4443").await.unwrap();

    tokio::spawn(async {
        let res = ClientBuilder::new()
            .uri("ws://127.0.0.1:4443")
            .unwrap()
            .connect()
            .await;
        assert!(res.is_ok());
    });

    let (conn, _) = tcp_listener.accept().await.unwrap();
    let res = ServerBuilder::new().accept(conn).await;
    assert!(res.is_ok());
}
