use std::time::Duration;

use crossbeam_channel::{self as channel, TryRecvError};

const IDLE_RECV_SLEEP: Duration = Duration::from_millis(1);

#[derive(Clone, Debug)]
pub struct EventSender<T> {
    inner: channel::Sender<T>,
}

#[derive(Debug)]
pub struct EventReceiver<T> {
    inner: channel::Receiver<T>,
}

pub fn bounded<T>(capacity: usize) -> (EventSender<T>, EventReceiver<T>) {
    let (tx, rx) = channel::bounded(capacity);
    (EventSender { inner: tx }, EventReceiver { inner: rx })
}

impl<T> EventSender<T> {
    pub fn try_send(&self, event: T) -> Result<(), channel::TrySendError<T>> {
        self.inner.try_send(event)
    }
}

impl<T> EventReceiver<T> {
    pub async fn recv(&mut self) -> Option<T> {
        loop {
            match self.inner.try_recv() {
                Ok(event) => return Some(event),
                Err(TryRecvError::Empty) => tokio::time::sleep(IDLE_RECV_SLEEP).await,
                Err(TryRecvError::Disconnected) => return None,
            }
        }
    }

    #[cfg(test)]
    pub fn try_recv(&mut self) -> Result<T, TryRecvError> {
        self.inner.try_recv()
    }
}
