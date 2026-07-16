use http::{Response, StatusCode};

use crate::Error;

use super::scenario::Scenario;

#[test]
fn provide_successful_response() {
    // Create a scenario with a GET request
    let scenario = Scenario::builder().get("/path").build();

    // Get a Reply in the ProvideResponse state
    let reply = scenario.to_provide_response();

    // Create a successful response
    let response = Response::builder()
        .status(StatusCode::OK)
        .header("content-type", "text/plain")
        .body(())
        .unwrap();

    // Provide the response
    let reply = reply.provide(response).unwrap();

    // Verify the state transition
    assert!(reply.inner().response.is_some());
    assert!(reply.inner().state.writer.is_some());

    // Verify the status code
    let status = reply.inner().response.as_ref().unwrap().prelude().1;
    assert_eq!(status, StatusCode::OK);
}

#[test]
fn provide_error_response() {
    // Create a scenario with a GET request
    let scenario = Scenario::builder().get("/path").build();

    // Get a Reply in the ProvideResponse state
    let reply = scenario.to_provide_response();

    // Create an error response
    let response = Response::builder()
        .status(StatusCode::NOT_FOUND)
        .header("content-type", "text/plain")
        .body(())
        .unwrap();

    // Provide the response
    let reply = reply.provide(response).unwrap();

    // Verify the state transition
    assert!(reply.inner().response.is_some());
    assert!(reply.inner().state.writer.is_some());

    // Verify the status code
    let status = reply.inner().response.as_ref().unwrap().prelude().1;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

#[test]
fn provide_response_after_reject_100() {
    // Create a scenario with a POST request with Expect: 100-continue
    let scenario = Scenario::builder()
        .post("/path")
        .header("expect", "100-continue")
        .build();

    // Get a Reply in the Send100 state
    let reply = scenario.to_send_100();

    // Reject the 100-continue request
    let reply = reply.reject();

    // Create an error response (required after rejecting 100-continue)
    let response = Response::builder()
        .status(StatusCode::BAD_REQUEST)
        .header("content-type", "text/plain")
        .body(())
        .unwrap();

    // Provide the response
    let reply = reply.provide(response).unwrap();

    // Verify the state transition
    assert!(reply.inner().response.is_some());
    assert!(reply.inner().state.writer.is_some());

    // Verify the status code
    let status = reply.inner().response.as_ref().unwrap().prelude().1;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

#[test]
fn error_when_providing_success_after_reject_100() {
    // Create a scenario with a POST request with Expect: 100-continue
    let scenario = Scenario::builder()
        .post("/path")
        .header("expect", "100-continue")
        .build();

    // Get a Reply in the Send100 state
    let reply = scenario.to_send_100();

    // Reject the 100-continue request
    let reply = reply.reject();

    // Create a successful response (invalid after rejecting 100-continue)
    let response = Response::builder()
        .status(StatusCode::OK)
        .header("content-type", "text/plain")
        .body(())
        .unwrap();

    // Provide the response (should fail)
    let result = reply.provide(response);

    // Verify the error
    assert!(result.is_err());
    match result.unwrap_err() {
        Error::BadReject100Status(status) => {
            assert_eq!(status, StatusCode::OK);
        }
        _ => panic!("Expected BadReject100Status error"),
    }
}

#[test]
fn provide_response_with_content_length() {
    // Create a scenario with a GET request
    let scenario = Scenario::builder().get("/path").build();

    // Get a Reply in the ProvideResponse state
    let reply = scenario.to_provide_response();

    // Create a response with content-length
    let response = Response::builder()
        .status(StatusCode::OK)
        .header("content-type", "text/plain")
        .header("content-length", "11")
        .body(())
        .unwrap();

    // Provide the response
    let reply = reply.provide(response).unwrap();

    // Verify the state transition
    assert!(reply.inner().response.is_some());
    assert!(reply.inner().state.writer.is_some());

    // Verify the content-length header is present
    let has_content_length = reply
        .inner()
        .response
        .as_ref()
        .unwrap()
        .headers()
        .any(|(name, value)| name == "content-length" && value == "11");
    assert!(has_content_length);
}

#[test]
fn provide_response_with_chunked_encoding() {
    // Create a scenario with a GET request
    let scenario = Scenario::builder().get("/path").build();

    // Get a Reply in the ProvideResponse state
    let reply = scenario.to_provide_response();

    // Create a response with chunked encoding
    let response = Response::builder()
        .status(StatusCode::OK)
        .header("content-type", "text/plain")
        .header("transfer-encoding", "chunked")
        .body(())
        .unwrap();

    // Provide the response
    let reply = reply.provide(response).unwrap();

    // Verify the state transition
    assert!(reply.inner().response.is_some());
    assert!(reply.inner().state.writer.is_some());

    // Verify the transfer-encoding header is present
    let has_chunked = reply
        .inner()
        .response
        .as_ref()
        .unwrap()
        .headers()
        .any(|(name, value)| name == "transfer-encoding" && value == "chunked");
    assert!(has_chunked);
}
