use std::io;

use prost::Message;
use thiserror::Error;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

use crate::proto::netprobe::NetprobeFrame;

pub const MAX_FRAME_SIZE: usize = 4 * 1024 * 1024;

#[derive(Debug, Error)]
pub enum FramingError {
    #[error("frame size {0} exceeds max frame size {MAX_FRAME_SIZE}")]
    FrameTooLarge(usize),
    #[error("io error: {0}")]
    Io(#[from] io::Error),
    #[error("protobuf decode error: {0}")]
    Decode(#[from] prost::DecodeError),
    #[error("protobuf encode error: {0}")]
    Encode(#[from] prost::EncodeError),
}

pub async fn read_frame<R>(reader: &mut R) -> Result<Option<NetprobeFrame>, FramingError>
where
    R: AsyncRead + Unpin,
{
    let mut len_buf = [0u8; 4];
    match reader.read_exact(&mut len_buf).await {
        Ok(_) => {}
        Err(err) if err.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(err) => return Err(err.into()),
    }

    let len = u32::from_be_bytes(len_buf) as usize;
    if len > MAX_FRAME_SIZE {
        return Err(FramingError::FrameTooLarge(len));
    }

    let mut body = vec![0u8; len];
    reader.read_exact(&mut body).await?;
    Ok(Some(NetprobeFrame::decode(body.as_slice())?))
}

pub async fn write_frame<W>(writer: &mut W, frame: &NetprobeFrame) -> Result<(), FramingError>
where
    W: AsyncWrite + Unpin,
{
    let mut body = Vec::new();
    write_frame_with_buffer(writer, frame, &mut body).await?;
    Ok(())
}

pub async fn write_frame_with_buffer<W>(
    writer: &mut W,
    frame: &NetprobeFrame,
    body: &mut Vec<u8>,
) -> Result<bool, FramingError>
where
    W: AsyncWrite + Unpin,
{
    let len = frame.encoded_len();
    if len > MAX_FRAME_SIZE {
        return Err(FramingError::FrameTooLarge(len));
    }

    let frame_len = len + 4;
    let reused = body.capacity() >= frame_len;
    body.clear();
    body.extend_from_slice(&(len as u32).to_be_bytes());
    frame.encode(&mut *body)?;
    writer.write_all(body.as_slice()).await?;

    Ok(reused)
}

#[cfg(test)]
mod tests {
    use tokio::io::AsyncWriteExt;
    use tokio::io::duplex;

    use super::{FramingError, MAX_FRAME_SIZE, read_frame, write_frame};
    use crate::proto::netprobe::{NetprobeFrame, Ping, netprobe_frame};

    #[tokio::test]
    async fn round_trips_frame() {
        let (mut client, mut server) = duplex(1024);
        let frame = NetprobeFrame {
            sequence: 7,
            payload: Some(netprobe_frame::Payload::Ping(Ping {
                sent_at_unix_nano: 42,
            })),
        };

        write_frame(&mut client, &frame).await.unwrap();
        let decoded = read_frame(&mut server).await.unwrap().unwrap();

        assert_eq!(decoded.sequence, 7);
        match decoded.payload.unwrap() {
            netprobe_frame::Payload::Ping(ping) => {
                assert_eq!(ping.sent_at_unix_nano, 42);
            }
            other => panic!("unexpected payload: {other:?}"),
        }
    }

    #[tokio::test]
    async fn rejects_oversized_frame() {
        let (mut client, mut server) = duplex(16);
        client
            .write_all(&((MAX_FRAME_SIZE + 1) as u32).to_be_bytes())
            .await
            .unwrap();

        let err = read_frame(&mut server).await.unwrap_err();
        assert!(matches!(err, FramingError::FrameTooLarge(_)));
    }
}
