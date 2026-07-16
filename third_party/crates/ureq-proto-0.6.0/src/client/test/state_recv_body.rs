use http::Response;

use crate::CloseReason;
use crate::client::test::TestSliceExt;

use super::scenario::Scenario;

#[test]
fn recv_body_close_delimited() {
    let scenario = Scenario::builder().get("https://q.test").build();

    let mut call = scenario.to_recv_body();

    let mut output = vec![0; 1024];

    assert!(call.can_proceed());

    let (input_used, output_used) = call.read(b"hello", &mut output).unwrap();
    assert_eq!(input_used, 5);
    assert_eq!(output_used, 5);

    let inner = call.inner();
    let reason = *inner.close_reason.first().unwrap();

    assert_eq!(reason, CloseReason::CloseDelimitedBody);
    assert_eq!(output[..output_used].as_str(), "hello");
    assert!(call.can_proceed());
}

#[test]
fn recv_body_chunked_partial() {
    let scenario = Scenario::builder()
        .get("https://q.test")
        .response(
            Response::builder()
                .header("transfer-encoding", "chunked")
                .body(())
                .unwrap(),
        )
        .build();

    let mut call = scenario.to_recv_body();

    let mut output = vec![0; 1024];

    let (input_used, output_used) = call.read(b"5\r", &mut output).unwrap();
    assert_eq!(input_used, 0);
    assert_eq!(output_used, 0);
    assert!(!call.can_proceed());

    let (input_used, output_used) = call.read(b"5\r\nhel", &mut output).unwrap();
    assert_eq!(input_used, 6);
    assert_eq!(output_used, 3);
    assert!(!call.can_proceed());

    let (input_used, output_used) = call.read(b"lo", &mut output).unwrap();
    assert_eq!(input_used, 2);
    assert_eq!(output_used, 2);
    assert!(!call.can_proceed());

    let (input_used, output_used) = call.read(b"\r\n", &mut output).unwrap();
    assert_eq!(input_used, 2);
    assert_eq!(output_used, 0);
    assert!(!call.can_proceed());

    let (input_used, output_used) = call.read(b"0\r\n\r\n", &mut output).unwrap();
    assert_eq!(input_used, 5);
    assert_eq!(output_used, 0);
    assert!(call.can_proceed());
}

#[test]
fn recv_body_chunked_full() {
    let scenario = Scenario::builder()
        .get("https://q.test")
        .response(
            Response::builder()
                .header("transfer-encoding", "chunked")
                .body(())
                .unwrap(),
        )
        .build();

    let mut call = scenario.to_recv_body();

    let mut output = vec![0; 1024];

    // this is the default
    // call.stop_on_chunk_boundary(false);

    let (input_used, output_used) = call.read(b"5\r\nhello\r\n0\r\n\r\n", &mut output).unwrap();
    assert_eq!(input_used, 15);
    assert_eq!(output_used, 5);
    assert_eq!(output[..output_used].as_str(), "hello");
    assert!(call.can_proceed());
}

#[test]
fn recv_body_chunked_stop_boundary() {
    let scenario = Scenario::builder()
        .get("https://q.test")
        .response(
            Response::builder()
                .header("transfer-encoding", "chunked")
                .body(())
                .unwrap(),
        )
        .build();

    let mut call = scenario.to_recv_body();

    let mut output = vec![0; 1024];

    call.stop_on_chunk_boundary(true);

    // chunk reading starts on boundary.
    assert!(call.is_on_chunk_boundary());

    let (input_used, output_used) = call.read(b"5\r\nhello\r\n0\r\n\r\n", &mut output).unwrap();
    assert_eq!(input_used, 10);
    assert_eq!(output_used, 5);
    assert_eq!(output[..output_used].as_str(), "hello");

    // chunk reading stops on chunk boundary.
    assert!(call.is_on_chunk_boundary());

    let (input_used, output_used) = call.read(b"0\r\n\r\n", &mut output).unwrap();
    assert_eq!(input_used, 5);
    assert_eq!(output_used, 0);
    assert!(call.can_proceed());
}

#[test]
fn recv_body_content_length() {
    let scenario = Scenario::builder()
        .get("https://q.test")
        .response(
            Response::builder()
                .header("content-length", "5")
                .body(())
                .unwrap(),
        )
        .build();

    let mut call = scenario.to_recv_body();

    let mut output = vec![0; 1024];

    let (input_used, output_used) = call.read(b"hel", &mut output).unwrap();
    assert_eq!(input_used, 3);
    assert_eq!(output_used, 3);
    assert_eq!(output[..output_used].as_str(), "hel");
    assert!(!call.can_proceed());

    let (input_used, output_used) = call.read(b"lo", &mut output).unwrap();
    assert_eq!(input_used, 2);
    assert_eq!(output_used, 2);
    assert_eq!(output[..output_used].as_str(), "lo");
    assert!(call.can_proceed());
}
