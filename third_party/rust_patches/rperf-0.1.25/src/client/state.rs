// rperf/src/client/state.rs
use crate::protocol::state::RunState;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};

pub(crate) const KILL_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Clone, Debug)]
pub struct ClientRunState {
    alive: Arc<AtomicBool>,
    kill_timer_start: Arc<Mutex<Option<SystemTime>>>,
}

impl ClientRunState {
    pub fn new() -> Self {
        Self {
            alive: Arc::new(AtomicBool::new(true)),
            kill_timer_start: Arc::new(Mutex::new(None)),
        }
    }

    pub fn start_kill_timer(&self) {
        let mut timer_lock = self.kill_timer_start.lock().unwrap();
        if timer_lock.is_none() {
            log::info!(
                "Starting kill timer ({}s) while waiting for server results.",
                KILL_TIMEOUT.as_secs()
            );
            *timer_lock = Some(SystemTime::now());
        }
    }

    pub fn request_shutdown(&self) -> bool {
        log::warn!("Client run shutdown requested.");
        self.alive.swap(false, Ordering::Relaxed)
    }

    #[allow(dead_code)]
    pub fn reset(&self) {
        self.alive.store(true, Ordering::Relaxed);
        let mut timer_lock = self.kill_timer_start.lock().unwrap();
        *timer_lock = None;
    }
}

impl RunState for ClientRunState {
    fn is_alive(&self) -> bool {
        if !self.alive.load(Ordering::Relaxed) {
            return false;
        }
        let timer_lock = self.kill_timer_start.lock().unwrap();
        if let Some(start_time) = *timer_lock {
            if start_time.elapsed().unwrap_or_default() >= KILL_TIMEOUT {
                log::warn!("Kill timer expired while waiting for server results.");
                return false;
            }
        }
        true
    }
}

impl Default for ClientRunState {
    fn default() -> Self {
        Self::new()
    }
}
