use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

/// Helper that restarts the current process once when KV changes are observed.
#[derive(Clone, Debug)]
pub struct RestartHandle {
    triggered: Arc<AtomicBool>,
    service: Arc<str>,
    kv_key: Arc<str>,
    delay: Duration,
}

impl RestartHandle {
    /// Create a new restart helper for a given service + KV key.
    pub fn new(service: impl Into<String>, kv_key: impl Into<String>) -> Self {
        Self {
            triggered: Arc::new(AtomicBool::new(false)),
            service: Arc::from(service.into()),
            kv_key: Arc::from(kv_key.into()),
            delay: Duration::from_millis(200),
        }
    }

    /// Override the default delay before exiting (defaults to 200ms).
    pub fn with_delay(mut self, delay: Duration) -> Self {
        self.delay = delay;
        self
    }

    /// Trigger a restart if one has not already been scheduled.
    pub fn trigger(&self) {
        if self
            .triggered
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .is_err()
        {
            return;
        }

        let service = self.service.clone();
        let kv_key = self.kv_key.clone();
        let delay = self.delay;
        tokio::spawn(async move {
            tracing::warn!(
                %service,
                %kv_key,
                "KV update detected; restarting process to apply new config"
            );
            tokio::time::sleep(delay).await;
            match std::env::current_exe() {
                Ok(exe) => {
                    let args: Vec<std::ffi::OsString> = std::env::args_os().skip(1).collect();
                    let mut cmd = std::process::Command::new(exe);
                    cmd.args(args);
                    if let Err(err) = cmd.spawn() {
                        tracing::error!(%service, error = %err, "failed to spawn replacement process");
                    }
                }
                Err(err) => {
                    tracing::error!(%service, error = %err, "failed to determine current executable");
                }
            }
            std::process::exit(0);
        });
    }
}
