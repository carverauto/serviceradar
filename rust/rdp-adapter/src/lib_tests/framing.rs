use super::*;

#[test]
fn read_frame_rejects_oversized_frame() {
    let mut input = Vec::new();
    input.extend_from_slice(&(MAX_FRAME_LENGTH + 1).to_be_bytes());
    input.push(MSG_MEDIA_FRAME);

    let err = read_frame(&mut input.as_slice()).expect_err("oversized frame rejected");

    assert!(matches!(
        err,
        ProtocolError::InvalidFrameLength(length) if length == MAX_FRAME_LENGTH + 1
    ));
}

#[test]
fn read_frame_rejects_oversized_control_frame_before_payload_read() {
    let mut input = Vec::new();
    input.extend_from_slice(&(MAX_CONTROL_FRAME_LENGTH + 1).to_be_bytes());
    input.push(MSG_ERROR);

    let err = read_frame(&mut input.as_slice()).expect_err("oversized control frame rejected");

    assert!(matches!(
        err,
        ProtocolError::InvalidFrameLength(length) if length == MAX_CONTROL_FRAME_LENGTH + 1
    ));
}

#[test]
fn read_frame_rejects_zero_length_before_message_type() {
    let mut input = Vec::new();
    input.extend_from_slice(&0u32.to_be_bytes());
    input.push(99);

    let err = read_frame(&mut input.as_slice()).expect_err("zero-length frame rejected");

    assert!(matches!(err, ProtocolError::InvalidFrameLength(0)));
}

#[test]
fn read_frame_rejects_unsupported_type_before_payload_read() {
    let mut input = Vec::new();
    input.extend_from_slice(&1024u32.to_be_bytes());
    input.push(99);

    let err = read_frame(&mut input.as_slice()).expect_err("unsupported frame rejected");

    assert!(matches!(err, ProtocolError::UnexpectedMessage(99)));
}

#[test]
fn write_frame_rejects_oversized_media_payload() {
    let payload = vec![0u8; MAX_FRAME_LENGTH as usize];
    let mut output = Vec::new();

    let err = write_frame(&mut output, MSG_MEDIA_FRAME, &payload).expect_err("payload rejected");

    assert!(matches!(
        err,
        ProtocolError::InvalidFrameLength(length) if length == MAX_FRAME_LENGTH + 1
    ));
    assert!(output.is_empty());
}

#[test]
fn write_frame_keeps_large_payloads_media_only() {
    let payload = vec![0u8; MAX_CONTROL_FRAME_LENGTH as usize];
    let mut output = Vec::new();

    let err = write_frame(&mut output, MSG_CLOSE, &payload).expect_err("control rejected");

    assert!(matches!(
        err,
        ProtocolError::InvalidFrameLength(length) if length == MAX_CONTROL_FRAME_LENGTH + 1
    ));
    assert!(output.is_empty());

    write_frame(&mut output, MSG_MEDIA_FRAME, &payload).expect("media accepted");
    let frame = read_frame(&mut output.as_slice())
        .expect("media read")
        .expect("media frame");
    assert_eq!(frame.message_type, MSG_MEDIA_FRAME);
    assert_eq!(frame.payload.len(), payload.len());
}

#[test]
fn write_frame_allows_bounded_open_payloads_for_ca_bundles() {
    let payload = vec![0u8; 256 * 1024];
    let mut output = Vec::new();

    write_frame(&mut output, MSG_OPEN, &payload).expect("bounded open accepted");
    let frame = read_frame(&mut output.as_slice())
        .expect("open read")
        .expect("open frame");
    assert_eq!(frame.message_type, MSG_OPEN);
    assert_eq!(frame.payload.len(), payload.len());
}
