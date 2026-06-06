use tokio::sync::mpsc::{self as channel, error::TrySendError};

use tokio::sync::mpsc::error::TryRecvError;

#[derive(Clone, Debug)]
pub struct EventSender<T> {
    inner: channel::Sender<T>,
}

#[derive(Debug)]
pub struct EventReceiver<T> {
    inner: channel::Receiver<T>,
}

pub fn bounded<T>(capacity: usize) -> (EventSender<T>, EventReceiver<T>) {
    let (tx, rx) = channel::channel(capacity);
    (EventSender { inner: tx }, EventReceiver { inner: rx })
}

impl<T> EventSender<T> {
    pub fn try_send(&self, event: T) -> Result<(), TrySendError<T>> {
        self.inner.try_send(event)
    }
}

impl<T> EventReceiver<T> {
    pub async fn recv(&mut self) -> Option<T> {
        self.inner.recv().await
    }

    pub fn try_recv(&mut self) -> Result<T, TryRecvError> {
        self.inner.try_recv()
    }
}
