use crate::Error;

use super::super::SendResponseResult;
use super::scenario::Scenario;

#[test]
fn write_response() {
    // Create a scenario with a GET request
    let scenario = Scenario::builder().get("/path").build();

    // Get a Reply in the SendResponse state
    let mut reply = scenario.to_send_response();

    // Create a buffer to write the response to
    let mut output = [0u8; 1024];

    // Write the response
    let bytes_written = reply.write(&mut output).unwrap();

    // Verify that some bytes were written
    assert!(bytes_written > 0);

    // Verify the response contains the expected status line
    let response_str = std::str::from_utf8(&output[..bytes_written]).unwrap();
    assert!(response_str.starts_with("HTTP/1.1 200 OK\r\n"));
}

#[test]
fn short_buffer() {
    // Create a scenario with a GET request and many headers
    let scenario = Scenario::builder()
        .get("/path")
        .header("header1", "value1")
        .header("header2", "value2")
        .header("header3", "value3")
        .header("header4", "value4")
        .header("header5", "value5")
        .build();

    // Get a Reply in the SendResponse state
    let mut reply = scenario.to_send_response();

    // Create a very small buffer to force overflow
    let mut output = [0u8; 20];

    // Write the response (should succeed but not write everything)
    let bytes_written = reply.write(&mut output).unwrap();

    // Verify that some bytes were written
    assert!(bytes_written > 0);
    assert!(bytes_written <= 20);

    // Verify the response is not finished
    assert!(!reply.is_finished());

    // Write more of the response
    let mut output2 = [0u8; 1024];
    let bytes_written2 = reply.write(&mut output2).unwrap();

    // Verify that more bytes were written
    assert!(bytes_written2 > 0);

    // Continue writing until finished
    while !reply.is_finished() {
        let mut output3 = [0u8; 1024];
        let _ = reply.write(&mut output3).unwrap();
    }

    // Verify the response is now finished
    assert!(reply.is_finished());
}

#[test]
fn proceed_to_send_body() {
    // Create a scenario with a GET request that should have a body
    let scenario = Scenario::builder()
        .get("/path")
        .header("content-type", "text/plain")
        .build();

    // Get a Reply in the SendResponse state
    let mut reply = scenario.to_send_response();

    // Create a buffer to write the response to
    let mut output = [0u8; 1024];

    // Write the response until finished
    while !reply.is_finished() {
        let _ = reply.write(&mut output).unwrap();
    }

    // Proceed and verify we get SendBody variant
    match reply.proceed() {
        SendResponseResult::SendBody(_) => {}
        SendResponseResult::Cleanup(_) => panic!("Expected SendBody variant"),
    }
}

#[test]
fn proceed_to_cleanup() {
    // Create a scenario with a HEAD request (should never have a body)
    let scenario = Scenario::builder()
        .head("/path")
        .header("content-type", "text/plain")
        .build();

    // Get a Reply in the SendResponse state
    let mut reply = scenario.to_send_response();

    // Create a buffer to write the response to
    let mut output = [0u8; 1024];

    // Write the response until finished
    while !reply.is_finished() {
        let _ = reply.write(&mut output).unwrap();
    }

    // Proceed and verify we get Cleanup variant
    match reply.proceed() {
        SendResponseResult::Cleanup(_) => {}
        SendResponseResult::SendBody(_) => panic!("Expected Cleanup variant"),
    }
}

#[test]
#[should_panic]
fn proceed_before_finished_panics() {
    // Create a scenario with a GET request and many headers
    let scenario = Scenario::builder()
        .get("/path")
        .header("header1", "value1")
        .header("header2", "value2")
        .header("header3", "value3")
        .header("header4", "value4")
        .header("header5", "value5")
        .build();

    // Get a Reply in the SendResponse state
    let mut reply = scenario.to_send_response();

    // Create a small buffer to ensure we don't finish writing
    let mut output = [0u8; 20];
    let _ = reply.write(&mut output).unwrap();

    // Verify the response is not finished
    assert!(!reply.is_finished());

    // Proceed to SendBody (should panic)
    let _ = reply.proceed();
}

#[test]
fn buffer_overflow() {
    // Create a scenario with a GET request and many headers
    let scenario = Scenario::builder()
        .get("/path")
        .header("header1", "value1")
        .header("header2", "value2")
        .header("header3", "value3")
        .header("header4", "value4")
        .header("header5", "value5")
        .build();

    // Get a Reply in the SendResponse state
    let mut reply = scenario.to_send_response();

    // Create an empty buffer to force overflow
    let mut output = [0u8; 0];

    // Write the response (should fail with OutputOverflow)
    let result = reply.write(&mut output);

    // Verify the error
    assert!(result.is_err());
    match result.unwrap_err() {
        Error::OutputOverflow => {}
        _ => panic!("Expected OutputOverflow error"),
    }
}
