use http::{Request, Response, Version};

use crate::CloseReason;

use super::scenario::Scenario;

#[test]
fn http10_with_keep_alive() {
    // Create a scenario with an HTTP/1.0 request with "connection: keep-alive" header
    let scenario = Scenario::builder()
        .request(
            Request::get("/path")
                .version(Version::HTTP_10)
                .header("connection", "keep-alive")
                .body(())
                .unwrap(),
        )
        .response(
            Response::builder()
                .status(200)
                .header("content-length", "0")
                .body(())
                .unwrap(),
        )
        .build();

    // Get a Reply in the Cleanup state
    let reply = scenario.to_cleanup();

    // Verify that we don't need to close the connection
    assert!(!reply.must_close_connection());
}

#[test]
fn reuse_connection() {
    // Create a scenario with a GET request and a response
    let scenario = Scenario::builder()
        .get("/path")
        .response(
            Response::builder()
                .status(200)
                .header("content-length", "0")
                .body(())
                .unwrap(),
        )
        .build();

    // Get a Reply in the Cleanup state
    let reply = scenario.to_cleanup();

    // Verify that we don't need to close the connection
    assert!(!reply.must_close_connection());
}

#[test]
fn close_due_to_client_connection_close() {
    // Create a scenario with a GET request with "connection: close" header
    let scenario = Scenario::builder()
        .request(
            Request::get("/path")
                .header("connection", "close")
                .body(())
                .unwrap(),
        )
        .response(
            Response::builder()
                .status(200)
                .header("content-length", "0")
                .body(())
                .unwrap(),
        )
        .build();

    // Get a Reply in the Cleanup state
    let reply = scenario.to_cleanup();

    // Verify that we must close the connection
    assert!(reply.must_close_connection());

    // Verify the close reason
    let inner = reply.inner();
    assert_eq!(
        *inner.close_reason.first().unwrap(),
        CloseReason::ClientConnectionClose
    );
}

#[test]
fn close_due_to_server_connection_close() {
    // Create a scenario with a GET request and a response with "connection: close" header
    let scenario = Scenario::builder()
        .get("/path")
        .response(
            Response::builder()
                .status(200)
                .header("connection", "close")
                .header("content-length", "0")
                .body(())
                .unwrap(),
        )
        .build();

    // Get a Reply in the Cleanup state
    let reply = scenario.to_cleanup();

    // Verify that we must close the connection
    assert!(reply.must_close_connection());

    // Verify the close reason
    let inner = reply.inner();
    assert_eq!(
        *inner.close_reason.first().unwrap(),
        CloseReason::ServerConnectionClose
    );
}

#[test]
fn close_due_to_http10() {
    // Create a scenario with an HTTP/1.0 request
    let scenario = Scenario::builder()
        .request(
            Request::get("/path")
                .version(Version::HTTP_10)
                .body(())
                .unwrap(),
        )
        .response(
            Response::builder()
                .status(200)
                .header("content-length", "0")
                .body(())
                .unwrap(),
        )
        .build();

    // Get a Reply in the Cleanup state
    let reply = scenario.to_cleanup();

    // Verify that we must close the connection
    assert!(reply.must_close_connection());

    // Verify the close reason
    let inner = reply.inner();
    assert_eq!(
        *inner.close_reason.first().unwrap(),
        CloseReason::CloseDelimitedBody
    );
}
