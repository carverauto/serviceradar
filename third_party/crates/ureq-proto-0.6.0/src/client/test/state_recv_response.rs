use http::{StatusCode, Version, header};

use crate::client::test::scenario::Scenario;
use crate::ext::HeaderIterExt;

// This is a complete response.
const RESPONSE: &[u8] = b"\
        HTTP/1.1 200 OK\r\n\
        Content-Length: 123\r\n\
        Content-Type: text/plain\r\n\
        \r\n";

#[test]
fn receive_incomplete_response() {
    // -1 to never reach the end
    for i in 14..RESPONSE.len() - 1 {
        let scenario = Scenario::builder().get("https://q.test").build();
        let mut call = scenario.to_recv_response();

        let (input_used, maybe_response) = call.try_response(&RESPONSE[..i], true).unwrap();
        assert_eq!(input_used, 0);
        assert!(maybe_response.is_none());
        assert!(!call.can_proceed());
    }
}

#[test]
fn receive_complete_response() {
    let scenario = Scenario::builder().get("https://q.test").build();
    let mut call = scenario.to_recv_response();

    let (input_used, maybe_response) = call.try_response(RESPONSE, true).unwrap();
    assert_eq!(input_used, 66);
    assert!(maybe_response.is_some());

    let response = maybe_response.unwrap();

    assert_eq!(response.version(), Version::HTTP_11);
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        response.headers().get(header::CONTENT_LENGTH).unwrap(),
        "123"
    );
    assert!(
        response
            .headers()
            .iter()
            .has(header::CONTENT_TYPE, "text/plain")
    );

    assert!(call.can_proceed());
}

#[test]
fn prepended_100_continue() {
    // In the case of expect-100-continue, there's a chance the 100-continue
    // arrives after we started sending the request body, in which case
    // we receive it before the actual response.
    let scenario = Scenario::builder()
        .post("https://q.test")
        .header("expect", "100-continue")
        .build();

    let mut call = scenario.to_recv_response();

    // incomplete 100-continue should be ignored.
    let (input_used, maybe_response) = call
        .try_response(b"HTTP/1.1 100 Continue\r\n", true)
        .unwrap();
    assert_eq!(input_used, 0);
    assert!(maybe_response.is_none());
    assert!(!call.can_proceed());

    // complete 100-continue should be consumed without producing a request
    let (input_used, maybe_response) = call
        .try_response(b"HTTP/1.1 100 Continue\r\n\r\n", true)
        .unwrap();
    assert_eq!(input_used, 25);
    assert!(maybe_response.is_none());
    assert!(!call.can_proceed());

    // full response after prepended 100-continue
    let (input_used, maybe_response) = call.try_response(RESPONSE, true).unwrap();
    assert_eq!(input_used, 66);
    assert!(maybe_response.is_some());
    assert!(call.can_proceed());
}

#[test]
fn expect_100_without_100_continue() {
    // In the case of expect-100-continue
    let scenario = Scenario::builder()
        .post("https://q.test")
        .header("expect", "100-continue")
        .build();

    let mut call = scenario.to_recv_response();

    // full response and no 100-continue
    let (input_used, maybe_response) = call.try_response(RESPONSE, true).unwrap();
    assert_eq!(input_used, 66);
    assert!(maybe_response.is_some());
    assert!(call.can_proceed());
}

#[test]
fn unsolicited_100_continue_on_get() {
    // Bug: server sends 100-continue on a regular GET request
    // without the client sending Expect: 100-continue header.
    // This reproduces the issue from https://github.com/algesten/ureq/issues/1137
    let scenario = Scenario::builder().get("https://q.test").build();

    let mut call = scenario.to_recv_response();

    // Server sends unsolicited 100-continue
    let (input_used, maybe_response) = call
        .try_response(b"HTTP/1.1 100 Continue\r\n\r\n", true)
        .unwrap();
    assert_eq!(input_used, 25);
    assert!(
        maybe_response.is_none(),
        "100-continue should be consumed, not returned"
    );
    assert!(!call.can_proceed());

    // Server then sends the actual response
    let (input_used, maybe_response) = call.try_response(RESPONSE, true).unwrap();
    assert_eq!(input_used, 66);
    assert!(maybe_response.is_some());
    assert!(call.can_proceed());

    let response = maybe_response.unwrap();
    assert_eq!(response.status(), StatusCode::OK);
}

#[test]
fn unsolicited_102_processing() {
    // Server sends unsolicited 102 Processing response
    let scenario = Scenario::builder().get("https://q.test").build();

    let mut call = scenario.to_recv_response();

    // Server sends 102 Processing
    let processing = b"HTTP/1.1 102 Processing\r\n\r\n";
    let (input_used, maybe_response) = call.try_response(processing, true).unwrap();
    assert_eq!(input_used, processing.len());
    assert!(
        maybe_response.is_none(),
        "102 Processing should be consumed, not returned"
    );

    // Server then sends the actual response
    let (input_used, maybe_response) = call.try_response(RESPONSE, true).unwrap();
    assert_eq!(input_used, 66);
    assert!(maybe_response.is_some());
    assert!(call.can_proceed());

    let response = maybe_response.unwrap();
    assert_eq!(response.status(), StatusCode::OK);
}

#[test]
fn unsolicited_103_early_hints() {
    // Server sends unsolicited 103 Early Hints response
    let scenario = Scenario::builder().get("https://q.test").build();

    let mut call = scenario.to_recv_response();

    // Server sends 103 Early Hints with Link header
    let early_hints = b"HTTP/1.1 103 Early Hints\r\nLink: </style.css>; rel=preload\r\n\r\n";
    let (input_used, maybe_response) = call.try_response(early_hints, true).unwrap();
    assert_eq!(input_used, early_hints.len());
    assert!(
        maybe_response.is_none(),
        "103 Early Hints should be consumed, not returned"
    );

    // Server then sends the actual response
    let (input_used, maybe_response) = call.try_response(RESPONSE, true).unwrap();
    assert_eq!(input_used, 66);
    assert!(maybe_response.is_some());
    assert!(call.can_proceed());

    let response = maybe_response.unwrap();
    assert_eq!(response.status(), StatusCode::OK);
}

#[test]
fn multiple_1xx_responses_in_sequence() {
    // Server sends multiple 1xx responses before final response
    let scenario = Scenario::builder()
        .post("https://q.test")
        .header("expect", "100-continue")
        .build();

    let mut call = scenario.to_recv_response();

    // First: 103 Early Hints
    let early_hints = b"HTTP/1.1 103 Early Hints\r\nLink: </style.css>; rel=preload\r\n\r\n";
    let (input_used, maybe_response) = call.try_response(early_hints, true).unwrap();
    assert_eq!(input_used, early_hints.len());
    assert!(maybe_response.is_none());

    // Second: 100 Continue
    let continue_resp = b"HTTP/1.1 100 Continue\r\n\r\n";
    let (input_used, maybe_response) = call.try_response(continue_resp, true).unwrap();
    assert_eq!(input_used, continue_resp.len());
    assert!(maybe_response.is_none());

    // Third: 102 Processing
    let processing = b"HTTP/1.1 102 Processing\r\n\r\n";
    let (input_used, maybe_response) = call.try_response(processing, true).unwrap();
    assert_eq!(input_used, processing.len());
    assert!(maybe_response.is_none());

    // Finally: actual response
    let (input_used, maybe_response) = call.try_response(RESPONSE, true).unwrap();
    assert_eq!(input_used, 66);
    assert!(maybe_response.is_some());
    assert!(call.can_proceed());

    let response = maybe_response.unwrap();
    assert_eq!(response.status(), StatusCode::OK);
}

#[test]
fn switching_protocols_101_returned() {
    // 101 Switching Protocols should be returned to the caller, not consumed
    let scenario = Scenario::builder()
        .get("https://q.test")
        .header("upgrade", "websocket")
        .build();

    let mut call = scenario.to_recv_response();

    // Server sends 101 Switching Protocols
    let switching =
        b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n";
    let (input_used, maybe_response) = call.try_response(switching, true).unwrap();
    assert_eq!(input_used, switching.len());
    assert!(
        maybe_response.is_some(),
        "101 Switching Protocols should be returned, not consumed"
    );
    assert!(call.can_proceed());

    let response = maybe_response.unwrap();
    assert_eq!(response.status(), StatusCode::SWITCHING_PROTOCOLS);
    assert_eq!(response.headers().get("upgrade").unwrap(), "websocket");

    // Verify connection is marked for protocol switch
    let result = call.proceed().unwrap();
    let has_protocol_switch = match &result {
        crate::client::RecvResponseResult::RecvBody(call) => call
            .inner
            .close_reason
            .iter()
            .any(|r| *r == crate::CloseReason::ProtocolSwitch),
        crate::client::RecvResponseResult::Redirect(call) => call
            .inner
            .close_reason
            .iter()
            .any(|r| *r == crate::CloseReason::ProtocolSwitch),
        crate::client::RecvResponseResult::Cleanup(call) => call
            .inner
            .close_reason
            .iter()
            .any(|r| *r == crate::CloseReason::ProtocolSwitch),
    };
    assert!(
        has_protocol_switch,
        "Connection should be marked with ProtocolSwitch"
    );
}

#[test]
fn multiple_103_before_final_response() {
    // Server sends multiple 103 Early Hints before final response
    let scenario = Scenario::builder().get("https://q.test").build();

    let mut call = scenario.to_recv_response();

    // First 103 with CSS preload hint
    let early_hints1 = b"HTTP/1.1 103 Early Hints\r\nLink: </style.css>; rel=preload\r\n\r\n";
    let (input_used, maybe_response) = call.try_response(early_hints1, true).unwrap();
    assert_eq!(input_used, early_hints1.len());
    assert!(maybe_response.is_none());

    // Second 103 with JS preload hint
    let early_hints2 = b"HTTP/1.1 103 Early Hints\r\nLink: </script.js>; rel=preload\r\n\r\n";
    let (input_used, maybe_response) = call.try_response(early_hints2, true).unwrap();
    assert_eq!(input_used, early_hints2.len());
    assert!(maybe_response.is_none());

    // Final response
    let (input_used, maybe_response) = call.try_response(RESPONSE, true).unwrap();
    assert_eq!(input_used, 66);
    assert!(maybe_response.is_some());

    let response = maybe_response.unwrap();
    assert_eq!(response.status(), StatusCode::OK);
}
