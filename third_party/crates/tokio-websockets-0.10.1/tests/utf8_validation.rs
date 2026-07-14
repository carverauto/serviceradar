// Autobahn does test all edge cases for UTF-8 validation - except one:
// When a text message is split into multiple frames and the invalid UTF-8 is
// part of a continuation frame, it only expects clients to fail fast after the
// entire frame has been received. We should, however, fail immediately.
#![cfg(feature = "server")]

use bytes::{BufMut, Bytes, BytesMut};
use futures_util::StreamExt;
use tokio::io::{duplex, AsyncWriteExt};
use tokio_websockets::{proto::ProtocolError, Error, ServerBuilder};

const MASK: [u8; 4] = [0, 0, 0, 0];

fn encode_frame(opcode: u8, payload: &[u8], payload_size: usize, is_final: bool) -> Bytes {
    let mut dst = BytesMut::new();

    let initial_byte = (u8::from(is_final) << 7) + opcode;

    dst.put_u8(initial_byte);

    if u16::try_from(payload_size).is_err() {
        dst.put_u8(255);
        dst.put_u64(payload_size as u64);
    } else if payload_size > 125 {
        dst.put_u8(254);
        dst.put_u16(payload_size as u16);
    } else {
        dst.put_u8(payload_size as u8 + 128);
    }

    dst.extend_from_slice(&MASK);

    dst.extend_from_slice(payload);

    dst.freeze()
}

#[tokio::test]
async fn test_utf8_fail_fast_incomplete_continuation() {
    let (one, mut two) = duplex(usize::MAX);
    let mut server = ServerBuilder::new().serve(one);

    // [240, 159, 152, 132] is a UTF-8 emoji (grinning face)

    let mut frame1_payload: Vec<u8> = std::iter::repeat_with(|| fastrand::alphanumeric() as u8)
        .take(4096)
        .collect();
    // We omit the last byte of the emoji, since it is *already* invalid at the 0.
    // This should catch even more edge cases
    let frame3_payload = [159, 0];

    let frame1 = encode_frame(1, &frame1_payload, 4096, false);
    frame1_payload[4095] = 240; // Second frame has a trailing partial UTF-8 codepoint
    let frame2 = encode_frame(0, &frame1_payload, 4096, false);
    let frame3 = encode_frame(0, &frame3_payload, 4096, false); // Pretend the rest of the payload will be written later

    two.write_all(&frame1).await.unwrap();
    two.write_all(&frame2).await.unwrap();
    two.write_all(&frame3).await.unwrap();

    assert!(matches!(
        server.next().await,
        Some(Err(Error::Protocol(ProtocolError::InvalidUtf8)))
    ));
}
