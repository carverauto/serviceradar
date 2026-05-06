// rperf/src/server/state.rs
use crate::protocol::state::RunState;
use std::sync::atomic::{AtomicBool, AtomicU16, Ordering};
use std::sync::Arc;

#[derive(Clone, Debug)]
pub struct ServerRunState {
    alive: Arc<AtomicBool>,
    clients: Arc<AtomicU16>,
}

impl ServerRunState {
    pub fn new() -> Self {
        Self {
            alive: Arc::new(AtomicBool::new(true)),
            clients: Arc::new(AtomicU16::new(0)),
        }
    }

    pub fn request_shutdown(&self) -> bool {
        log::warn!("Server shutdown requested.");
        self.alive.swap(false, Ordering::Relaxed)
    }

    pub fn client_connected(&self) -> u16 {
        self.clients.fetch_add(1, Ordering::Relaxed) + 1
    }

    pub fn client_disconnected(&self) -> u16 {
        self.clients.fetch_sub(1, Ordering::Relaxed)
    }

    pub fn client_count(&self) -> u16 {
        self.clients.load(Ordering::Relaxed)
    }
}

impl RunState for ServerRunState {
    fn is_alive(&self) -> bool {
        self.alive.load(Ordering::Relaxed)
    }
}

impl Default for ServerRunState {
    fn default() -> Self {
        Self::new()
    }
}
