use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::sync::watch;

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct ActiveCaptureStream {
    pub stream_id: String,
    pub stream_type: CaptureStreamType,
    pub target: String,
    pub started_at_unix_secs: u64,
}

#[derive(Debug, Copy, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CaptureStreamType {
    RfObservation,
    Spectrum,
}

#[derive(Debug)]
pub struct CaptureRegistration {
    stream_id: String,
    control: Arc<CaptureControl>,
}

#[derive(Debug)]
pub struct CaptureControl {
    next_stream_id: AtomicU64,
    stop_generation: AtomicU64,
    stop_sender: watch::Sender<u64>,
    active: Mutex<HashMap<String, ActiveCaptureStream>>,
}

impl CaptureControl {
    pub fn new() -> Arc<Self> {
        let (stop_sender, _stop_receiver) = watch::channel(0);

        Arc::new(Self {
            next_stream_id: AtomicU64::new(1),
            stop_generation: AtomicU64::new(0),
            stop_sender,
            active: Mutex::new(HashMap::new()),
        })
    }

    pub fn register(
        self: &Arc<Self>,
        stream_type: CaptureStreamType,
        target: impl Into<String>,
    ) -> CaptureRegistration {
        let sequence = self.next_stream_id.fetch_add(1, Ordering::Relaxed);
        let stream_id = format!("capture-{sequence}");
        let stream = ActiveCaptureStream {
            stream_id: stream_id.clone(),
            stream_type,
            target: target.into(),
            started_at_unix_secs: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|duration| duration.as_secs())
                .unwrap_or_default(),
        };

        self.active
            .lock()
            .expect("capture mutex poisoned")
            .insert(stream_id.clone(), stream);

        CaptureRegistration {
            stream_id,
            control: Arc::clone(self),
        }
    }

    pub fn subscribe_stop(&self) -> watch::Receiver<u64> {
        self.stop_sender.subscribe()
    }

    pub fn stop_all(&self) -> u64 {
        let generation = self.stop_generation.fetch_add(1, Ordering::Relaxed) + 1;
        let _ = self.stop_sender.send(generation);
        generation
    }

    pub fn active_streams(&self) -> Vec<ActiveCaptureStream> {
        let mut streams: Vec<_> = self
            .active
            .lock()
            .expect("capture mutex poisoned")
            .values()
            .cloned()
            .collect();
        streams.sort_by(|left, right| left.stream_id.cmp(&right.stream_id));
        streams
    }

    fn unregister(&self, stream_id: &str) {
        self.active
            .lock()
            .expect("capture mutex poisoned")
            .remove(stream_id);
    }
}

impl Drop for CaptureRegistration {
    fn drop(&mut self) {
        self.control.unregister(&self.stream_id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn registers_active_streams_and_broadcasts_stop() {
        let control = CaptureControl::new();
        let mut stop_rx = control.subscribe_stop();

        let registration = control.register(CaptureStreamType::RfObservation, "wlan2");
        assert_eq!(control.active_streams().len(), 1);

        let generation = control.stop_all();
        stop_rx.changed().await.unwrap();
        assert_eq!(*stop_rx.borrow(), generation);

        drop(registration);
        assert!(control.active_streams().is_empty());
    }
}
