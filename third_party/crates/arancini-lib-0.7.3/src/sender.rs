use anyhow::Result;
use std::future::Future;
use std::pin::Pin;
use tokio::sync::mpsc::Sender;

use crate::update::Update;

pub trait UpdateSender: Clone + Send + Sync + 'static {
    fn send<'a>(&'a self, update: Update) -> Pin<Box<dyn Future<Output = Result<()>> + Send + 'a>>;
}

impl UpdateSender for Sender<Update> {
    fn send<'a>(&'a self, update: Update) -> Pin<Box<dyn Future<Output = Result<()>> + Send + 'a>> {
        Box::pin(async move {
            self.send(update)
                .await
                .map_err(|err| anyhow::anyhow!("failed to send update: {}", err))
        })
    }
}
