// This is a benchmark for utf-8 validation in tokio-websockets.
// In order to properly be able to benchmark a WebSocket library, this client
// must not use a WebSocket library. In the end, we want to benchmark the
// server, not the client.
//
// The client sends a single WebSocket message over and over again. This message
// is split into a configurable amount of frames and sent in a configurable
// amount of chops.
// It expects to receive the message back. Benchmark performance is measured in
// messages sent by the server per second.

use std::{
    env,
    io::{self, Read, Write},
    os::unix::net::UnixStream,
    time::Instant,
};

use bytes::{BufMut, Bytes, BytesMut};

const DELIMITER: char = '+';

// No-op mask
const MASK: [u8; 4] = [0, 0, 0, 0];

fn encode_message(data: Vec<u8>, frame_size: usize) -> Bytes {
    let mut dst = BytesMut::new();

    let mut chunks = data.chunks(frame_size).peekable();
    let mut next_chunk = Some(chunks.next().unwrap_or_default());
    let mut chunk_number = 0;

    while let Some(chunk) = next_chunk {
        let opcode_value = if chunk_number == 0 { 1 } else { 0 };

        let is_final = chunks.peek().is_none();
        let chunk_size = chunk.len();

        let initial_byte = (u8::from(is_final) << 7) + opcode_value;

        dst.put_u8(initial_byte);

        if u16::try_from(chunk_size).is_err() {
            dst.put_u8(255);
            dst.put_u64(chunk_size as u64);
        } else if chunk_size > 125 {
            dst.put_u8(254);
            dst.put_u16(chunk_size as u16);
        } else {
            dst.put_u8(chunk_size as u8 + 128);
        }

        dst.extend_from_slice(&MASK);

        dst.extend_from_slice(chunk);

        next_chunk = chunks.next();
        chunk_number += 1;
    }

    dst.freeze()
}

fn main() -> io::Result<()> {
    let message_size: usize = env::var("MSG_SIZE")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(64 * 1024 * 1024);
    let frame_size: usize = env::var("FRAME_SIZE")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(4 * 1024);
    let chop_size = env::var("CHOP_SIZE")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(1024);

    let mut payload: String = std::iter::repeat_with(fastrand::alphanumeric)
        .take(message_size - 1)
        .collect();
    payload.push(DELIMITER);

    let encoded_message = encode_message(payload.into_bytes(), frame_size);

    // We use Unix sockets because they are a lot faster than TCP and have no
    // buffering
    let mut stream = UnixStream::connect("/tmp/tokio-websockets.sock")?;

    let start = Instant::now();
    let mut messages_received = 0;

    // This has to be lower than encoded_message since we don't know how big the
    // client chunks the frames
    let mut buf = vec![0; message_size];

    // We expect the server to assume that this is a websocket connection (i.e. skip
    // the handshake)
    loop {
        // Now just write the message in chops
        for chop in encoded_message.chunks(chop_size) {
            stream.write_all(chop)?;
        }

        loop {
            let n = stream.read(&mut buf)?;

            if n == 0 {
                panic!("should never happen");
            }

            let last_byte_read = unsafe { buf.get_unchecked(n - 1) };

            if *last_byte_read == DELIMITER as u8 {
                break;
            }
        }

        messages_received += 1;

        if messages_received % 100 == 0 {
            let time_taken = Instant::now().duration_since(start);
            let msg_per_sec = messages_received as f64 / time_taken.as_secs_f64();
            println!("{messages_received} messages received: {msg_per_sec} msg/s");
        }
    }
}
