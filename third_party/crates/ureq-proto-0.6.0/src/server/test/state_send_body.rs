use crate::Error;

use super::scenario::Scenario;

#[test]
fn write_response_body() {
    // Create a scenario with a GET request and a response with content-length
    let mut scenario = Scenario::builder()
        .get("/path")
        .response(
            http::Response::builder()
                .status(200)
                .header("content-length", "13")
                .body(())
                .unwrap(),
        )
        .build()
        .to_send_body();

    // Create a buffer to write the response body to
    let mut output = [0u8; 1024];

    // Write some response body data
    let body = b"Hello, world!";
    let (input_used, output_used) = scenario.write(body, &mut output).unwrap();

    // Verify that all input was consumed
    assert_eq!(input_used, body.len());

    // Verify that the output contains the body
    assert_eq!(&output[..output_used], body);
}

#[test]
fn write_chunked_response_body() {
    // Create a scenario with a GET request and a chunked response
    let mut scenario = Scenario::builder()
        .get("/path")
        .response(
            http::Response::builder()
                .status(200)
                .header("transfer-encoding", "chunked")
                .body(())
                .unwrap(),
        )
        .build()
        .to_send_body();

    // Create a buffer to write the response body to
    let mut output = [0u8; 1024];

    // Write some response body data
    let body = b"Hello, world!";
    let (input_used, output_used) = scenario.write(body, &mut output).unwrap();

    // Verify that all input was consumed
    assert_eq!(input_used, body.len());

    // Verify that the output contains the chunked body
    let output_str = std::str::from_utf8(&output[..output_used]).unwrap();
    assert!(output_str.starts_with("d\r\n")); // 13 bytes in hex
    assert!(output_str.contains("Hello, world!"));
    assert!(output_str.ends_with("\r\n"));

    // Verify that the response is chunked
    assert!(scenario.is_chunked());

    // Verify that the response is not finished yet
    assert!(!scenario.is_finished());

    // Write an empty chunk to finish the response
    let (input_used, output_used) = scenario.write(&[], &mut output).unwrap();
    assert_eq!(input_used, 0);
    assert!(output_used > 0);

    // Verify that the response is now finished
    assert!(scenario.is_finished());
}

#[test]
fn calculate_max_input() {
    // Create a scenario with a GET request and a content-length response
    let scenario = Scenario::builder()
        .get("/path")
        .response(
            http::Response::builder()
                .status(200)
                .header("content-length", "100")
                .body(())
                .unwrap(),
        )
        .build()
        .to_send_body();

    // For non-chunked responses, max input equals output length
    assert_eq!(scenario.calculate_max_input(100), 100);

    // Create a scenario with a GET request and a chunked response
    let scenario = Scenario::builder()
        .get("/path")
        .response(
            http::Response::builder()
                .status(200)
                .header("transfer-encoding", "chunked")
                .body(())
                .unwrap(),
        )
        .build()
        .to_send_body();

    // For chunked responses, max input is less than output length
    assert!(scenario.calculate_max_input(100) < 100);
}

#[test]
fn proceed_to_cleanup() {
    // Create a scenario with a GET request and a response with content-length
    let mut scenario = Scenario::builder()
        .get("/path")
        .response(
            http::Response::builder()
                .header("content-length", "13")
                .body(())
                .unwrap(),
        )
        .build()
        .to_send_body();

    // Create a buffer to write the response body to
    let mut output = [0u8; 1024];

    // Write the response body
    let body = b"Hello, world!";
    let (input_used, _) = scenario.write(body, &mut output).unwrap();
    assert_eq!(input_used, body.len());

    // Verify that the response is now finished
    assert!(scenario.is_finished());

    // Proceed to Cleanup
    let _cleanup = scenario.proceed();

    // The type system ensures that _cleanup is now Reply<Cleanup>
}

#[test]
#[should_panic]
fn proceed_before_finished_panics() {
    // Create a scenario with a GET request and a response with content-length
    let scenario = Scenario::builder()
        .get("/path")
        .response(
            http::Response::builder()
                .header("content-length", "100")
                .body(())
                .unwrap(),
        )
        .build()
        .to_send_body();

    // Verify that the response is not finished
    assert!(!scenario.is_finished());

    // Proceed to Cleanup (should panic)
    let _ = scenario.proceed();
}

#[test]
fn error_writing_after_finished() {
    // Create a scenario with a GET request and a response with content-length
    let mut scenario = Scenario::builder()
        .get("/path")
        .response(
            http::Response::builder()
                .header("content-length", "13")
                .body(())
                .unwrap(),
        )
        .build()
        .to_send_body();

    // Create a buffer to write the response body to
    let mut output = [0u8; 1024];

    // Write the response body
    let body = b"Hello, world!";
    let (input_used, _) = scenario.write(body, &mut output).unwrap();
    assert_eq!(input_used, body.len());

    // Verify that the response is now finished
    assert!(scenario.is_finished());

    // Try to write more data (should fail)
    let result = scenario.write(b"More data", &mut output);
    assert!(result.is_err());
    match result.unwrap_err() {
        Error::BodyContentAfterFinish => {}
        _ => panic!("Expected BodyContentAfterFinish error"),
    }
}

#[test]
fn error_writing_more_than_content_length() {
    // Create a scenario with a GET request and a response with content-length
    let mut scenario = Scenario::builder()
        .get("/path")
        .response(
            http::Response::builder()
                .header("content-length", "10")
                .body(())
                .unwrap(),
        )
        .build()
        .to_send_body();

    // Create a buffer to write the response body to
    let mut output = [0u8; 1024];

    // Try to write more data than the content-length (should fail)
    let result = scenario.write(b"Hello, world!", &mut output);
    assert!(result.is_err());
    match result.unwrap_err() {
        Error::BodyLargerThanContentLength => {}
        _ => panic!("Expected BodyLargerThanContentLength error"),
    }
}

#[test]
fn consume_direct_write() {
    // Create a scenario with a GET request and a response with content-length
    let mut scenario = Scenario::builder()
        .get("/path")
        .response(
            http::Response::builder()
                .header("content-length", "13")
                .body(())
                .unwrap(),
        )
        .build()
        .to_send_body();

    // Consume direct write
    scenario.consume_direct_write(13).unwrap();

    // Verify that the response is now finished
    assert!(scenario.is_finished());
}

#[test]
fn error_consuming_more_than_content_length() {
    // Create a scenario with a GET request and a response with content-length
    let mut scenario = Scenario::builder()
        .get("/path")
        .response(
            http::Response::builder()
                .header("content-length", "10")
                .body(())
                .unwrap(),
        )
        .build()
        .to_send_body();

    // Try to consume more than the content-length (should fail)
    let result = scenario.consume_direct_write(11);
    assert!(result.is_err());
    match result.unwrap_err() {
        Error::BodyLargerThanContentLength => {}
        _ => panic!("Expected BodyLargerThanContentLength error"),
    }
}

#[test]
fn error_consuming_direct_write_with_chunked() {
    // Create a scenario with a GET request and a chunked response
    let mut scenario = Scenario::builder()
        .get("/path")
        .response(
            http::Response::builder()
                .header("transfer-encoding", "chunked")
                .body(())
                .unwrap(),
        )
        .build()
        .to_send_body();

    // Try to consume direct write with chunked encoding (should fail)
    let result = scenario.consume_direct_write(10);
    assert!(result.is_err());
    match result.unwrap_err() {
        Error::BodyIsChunked => {}
        _ => panic!("Expected BodyIsChunked error"),
    }
}
