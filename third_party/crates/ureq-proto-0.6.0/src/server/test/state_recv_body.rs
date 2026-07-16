use super::scenario::Scenario;

#[test]
fn read_content_length_body() {
    // Create a scenario with a POST request with content-length
    let scenario = Scenario::builder()
        .post("/path")
        .request_body(b"hello world", false)
        .build();

    // Get a Reply in the RecvBody state
    let mut reply = scenario.to_recv_body();

    // Read the request body
    let mut output = vec![0; 1024];
    let (input_used, output_used) = reply.read(b"hello world", &mut output).unwrap();

    // Verify the results
    assert_eq!(input_used, 11);
    assert_eq!(output_used, 11);
    assert_eq!(&output[..output_used], b"hello world");

    // Verify the body is fully received
    assert!(reply.is_ended());
}

#[test]
fn read_chunked_body() {
    // Create a scenario with a POST request with chunked encoding
    let scenario = Scenario::builder()
        .post("/path")
        .request_body(b"hello world", true)
        .build();

    // Get a Reply in the RecvBody state
    let mut reply = scenario.to_recv_body();

    // Read the chunked request body
    let mut output = vec![0; 1024];
    let chunked_input = b"b\r\nhello world\r\n0\r\n\r\n";
    let (input_used, output_used) = reply.read(chunked_input, &mut output).unwrap();

    // Verify the results
    assert_eq!(input_used, 21);
    assert_eq!(output_used, 11);
    assert_eq!(&output[..output_used], b"hello world");

    // Verify the body is fully received
    assert!(reply.is_ended());
}

#[test]
fn read_chunked_body_in_parts() {
    // Create a scenario with a POST request with chunked encoding
    let scenario = Scenario::builder()
        .post("/path")
        .request_body(b"hello world", true)
        .build();

    // Get a Reply in the RecvBody state
    let mut reply = scenario.to_recv_body();

    // Enable stopping on chunk boundaries
    reply.stop_on_chunk_boundary(true);

    // Read the first chunk
    let mut output = vec![0; 1024];
    let chunk1 = b"5\r\nhello\r\n";
    let (input_used1, output_used1) = reply.read(chunk1, &mut output).unwrap();

    // Verify the first chunk
    assert_eq!(input_used1, 10);
    assert_eq!(output_used1, 5);
    assert_eq!(&output[..output_used1], b"hello");
    assert!(reply.is_on_chunk_boundary());
    assert!(!reply.is_ended());

    // Read the second chunk
    let chunk2 = b"6\r\n world\r\n";
    let (input_used2, output_used2) = reply.read(chunk2, &mut output[output_used1..]).unwrap();

    // Verify the second chunk
    assert_eq!(input_used2, 11);
    assert_eq!(output_used2, 6);
    assert_eq!(
        &output[output_used1..output_used1 + output_used2],
        b" world"
    );
    assert!(reply.is_on_chunk_boundary());
    assert!(!reply.is_ended());

    // Read the end marker
    let end_marker = b"0\r\n\r\n";
    let (input_used3, output_used3) = reply
        .read(end_marker, &mut output[output_used1 + output_used2..])
        .unwrap();

    // Verify the end marker
    assert_eq!(input_used3, 5);
    assert_eq!(output_used3, 0);
    assert!(reply.is_ended());
}

#[test]
fn proceed_to_provide_response() {
    // Create a scenario with a POST request with content-length
    let scenario = Scenario::builder()
        .post("/path")
        .request_body(b"hello", false)
        .build();

    // Get a Reply in the RecvBody state
    let mut reply = scenario.to_recv_body();

    // Read the request body
    let mut output = vec![0; 1024];
    reply.read(b"hello", &mut output).unwrap();

    // Verify the body is fully received
    assert!(reply.is_ended());

    // Proceed to ProvideResponse
    let reply = reply.proceed().unwrap();

    // Verify the state transition
    assert!(reply.inner().state.reader.is_some());
}

#[test]
#[should_panic]
fn proceed_before_body_ended() {
    // Create a scenario with a POST request with content-length
    let scenario = Scenario::builder()
        .post("/path")
        .request_body(b"hello world", false)
        .build();

    // Get a Reply in the RecvBody state
    let mut reply = scenario.to_recv_body();

    // Read only part of the request body
    let mut output = vec![0; 1024];
    reply.read(b"hello", &mut output).unwrap();

    // Verify the body is not fully received
    assert!(!reply.is_ended());

    // This should panic because the body is not fully received
    let _ = reply.proceed();
}

#[test]
fn read_after_end() {
    // Create a scenario with a POST request with content-length
    let scenario = Scenario::builder()
        .post("/path")
        .request_body(b"hello", false)
        .build();

    // Get a Reply in the RecvBody state
    let mut reply = scenario.to_recv_body();

    // Read the request body
    let mut output = vec![0; 1024];
    reply.read(b"hello", &mut output).unwrap();

    // Verify the body is fully received
    assert!(reply.is_ended());

    // Try to read more after the body is fully received
    let (input_used, output_used) = reply.read(b"more data", &mut output).unwrap();

    // Should not consume any input or produce any output
    assert_eq!(input_used, 0);
    assert_eq!(output_used, 0);
}
