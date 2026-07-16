use crate::Error;

use super::scenario::Scenario;

#[test]
fn accept_100_continue() {
    // Create a scenario with a request that includes Expect: 100-continue
    let scenario = Scenario::builder()
        .post("/path")
        .header("expect", "100-continue")
        .build();

    // Get a Reply in the Send100 state
    let reply = scenario.to_send_100();

    // Accept the 100-continue request
    let mut output = vec![0; 1024];
    let (output_used, reply) = reply.accept(&mut output).unwrap();

    // Verify the output
    assert_eq!(output_used, 25);
    assert_eq!(&output[..output_used], b"HTTP/1.1 100 Continue\r\n\r\n");

    // Verify the state transition
    assert!(reply.inner().state.reader.is_some());
}

#[test]
fn reject_100_continue() {
    // Create a scenario with a request that includes Expect: 100-continue
    let scenario = Scenario::builder()
        .post("/path")
        .header("expect", "100-continue")
        .build();

    // Get a Reply in the Send100 state
    let reply = scenario.to_send_100();

    // Reject the 100-continue request
    let reply = reply.reject();

    // Verify the state transition
    assert!(reply.inner().expect_100_reject);
}

#[test]
fn short_buffer() {
    // Create a scenario with a request that includes Expect: 100-continue
    let scenario = Scenario::builder()
        .post("/path")
        .header("expect", "100-continue")
        .build();

    // Get a Reply in the Send100 state
    let reply = scenario.to_send_100();

    // Try to accept with a buffer that's too small
    let mut output = vec![0; 10]; // Too small for "HTTP/1.1 100 Continue\r\n\r\n"
    let result = reply.accept(&mut output);

    // Verify the error
    assert!(result.is_err());
    assert_eq!(result.unwrap_err(), Error::OutputOverflow);
}
