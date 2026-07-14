#![cfg(feature = "server")]
use std::{
    io,
    pin::Pin,
    task::{Context, Poll},
};

use futures_util::{task::noop_waker_ref, FutureExt, StreamExt};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio_websockets::ServerBuilder;

struct SuperSlow {
    buf: Vec<u8>,
    delays: u8,
}

impl SuperSlow {
    pub fn new() -> Self {
        let buf = b"\x89\x84\xe47D\xa4\xe55G\xa0".to_vec();

        Self { buf, delays: 0 }
    }
}

impl AsyncRead for SuperSlow {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        if self.delays == 0 {
            self.delays += 1;
            let a: Vec<u8> = self.buf.splice(..4, []).collect::<Vec<_>>();
            Pin::new(&mut a.as_slice()).poll_read(cx, buf)
        } else if self.delays == 1 {
            self.delays += 1;
            cx.waker().wake_by_ref();
            Poll::Pending
        } else {
            let a: Vec<u8> = self.buf.splice(.., []).collect::<Vec<_>>();
            Pin::new(&mut a.as_slice()).poll_read(cx, buf)
        }
    }
}

impl AsyncWrite for SuperSlow {
    fn is_write_vectored(&self) -> bool {
        false
    }

    fn poll_flush(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<Result<(), io::Error>> {
        Poll::Ready(Ok(()))
    }

    fn poll_shutdown(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<Result<(), io::Error>> {
        Poll::Ready(Ok(()))
    }

    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<Result<usize, io::Error>> {
        if self.delays != 10 {
            cx.waker().wake_by_ref();
            self.delays = 10;
            Poll::Pending
        } else {
            Poll::Ready(Ok(buf.len()))
        }
    }
}

const TO_SEND: &[u8] = &[1, 2, 3, 4];

#[tokio::test]
async fn test_cancellation_safety() {
    let stream = SuperSlow::new();

    let mut server = ServerBuilder::new().serve(stream);

    let mut cx = Context::from_waker(noop_waker_ref());

    loop {
        // Cancellable futures should be possible to re-create at any time and resume as
        // if they were created once and then polled a few times
        if let Poll::Ready(val) = server.next().poll_unpin(&mut cx) {
            let msg = val.expect("eof").expect("err");
            assert_eq!(&*msg.into_payload(), TO_SEND);
            break;
        }
    }
}
