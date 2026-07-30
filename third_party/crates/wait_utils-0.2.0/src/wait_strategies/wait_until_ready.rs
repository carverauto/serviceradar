/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The buildutils Authors and Contributors. All Rights Reserved.
 */

use std::fmt::Display;
use std::time::{Duration, Instant};

use crate::{Probe, WaitStrategyError};

/// Retry `probe` until it reports ready, it reports fatal, or `timeout` elapses.
///
/// Every [`WaitStrategy`](crate::WaitStrategy) variant is a fixed predicate this crate
/// implements. None of them can express "the operation I am about to perform succeeds", which
/// is the only predicate that is never wrong. That probe is caller code, so this is a
/// function taking a closure rather than another variant of the enum.
///
/// Bounded by a deadline rather than an attempt count: attempts multiplied by delay silently
/// shrinks the real wait whenever an attempt is itself slow, which is exactly what happens on
/// the loaded machine the budget exists for.
///
/// The probe always runs at least once, even when the timeout is zero.
///
/// Consecutive identical retry messages are collapsed in the debug log. A starting service
/// repeats the same refusal for as long as it takes, and printing it a hundred times buries
/// the one line that differs, which is always the interesting one.
///
/// # Arguments
///
/// * `dbg` - Whether to print the progress of the wait.
/// * `timeout` - How long to keep retrying before giving up.
/// * `retry_delay` - How long to wait between attempts.
/// * `probe` - The readiness check to run.
///
/// # Returns
///
/// Returns whatever the probe built, or a `WaitStrategyError` if the probe reported a fatal
/// failure or the timeout elapsed.
///
/// # Example
///
/// ```rust
/// use std::time::Duration;
/// use wait_utils::{Probe, wait_until_ready};
///
/// let mut attempts = 0;
/// let ready = wait_until_ready(false, Duration::from_secs(60), Duration::from_millis(1), || {
///     attempts += 1;
///     if attempts < 3 {
///         Probe::Retry("not yet".to_string())
///     } else {
///         Probe::Ready(attempts)
///     }
/// });
///
/// assert_eq!(ready.unwrap(), 3);
/// ```
pub fn wait_until_ready<T, E, F>(
    dbg: bool,
    timeout: Duration,
    retry_delay: Duration,
    mut probe: F,
) -> Result<T, WaitStrategyError>
where
    F: FnMut() -> Probe<T, E>,
    E: Display,
{
    let start = Instant::now();
    let mut attempt = 0u32;
    let mut log = Repeats::new(dbg);

    loop {
        attempt = attempt.saturating_add(1);

        // Declared per iteration: it is only ever read by the timeout check below, which is
        // reachable only through the Retry arm that assigns it.
        let last;

        match probe() {
            Probe::Ready(value) => {
                log.flush();
                if dbg {
                    println!("[wait_until_ready]: ready after {attempt} attempt(s)");
                }
                return Ok(value);
            }
            Probe::Fatal(err) => {
                log.flush();
                return Err(WaitStrategyError(format!(
                    "[wait_until_ready]: attempt {attempt} failed unrecoverably: {err}"
                )));
            }
            Probe::Retry(err) => {
                last = err.to_string();
                log.observe(attempt, &last);
            }
        }

        // Measured against the elapsed time rather than an absolute deadline, because
        // `Instant::now() + timeout` panics on overflow for a large enough Duration.
        if start.elapsed() >= timeout {
            log.flush();
            return Err(WaitStrategyError(format!(
                "[wait_until_ready]: !!Timeout!! Waited {timeout:?} over {attempt} attempt(s). Last error: {last}"
            )));
        }

        std::thread::sleep(retry_delay);
    }
}

/// Collapses consecutive identical retry messages into one line plus a count.
///
/// The current message is an `Option` rather than a plain `String` so that a probe whose
/// error formats as the empty string is still reported on its first occurrence, instead of
/// being mistaken for the initial state and swallowed.
struct Repeats {
    dbg: bool,
    current: Option<String>,
    count: u32,
}

impl Repeats {
    fn new(dbg: bool) -> Self {
        Self {
            dbg,
            current: None,
            count: 0,
        }
    }

    /// Records one retry message, printing it only when it differs from the previous one.
    fn observe(&mut self, attempt: u32, message: &str) {
        if self.current.as_deref() == Some(message) {
            self.count = self.count.saturating_add(1);
            return;
        }

        self.flush();

        if self.dbg {
            println!("[wait_until_ready]: attempt {attempt}: {message}");
        }

        self.current = Some(message.to_string());
        self.count = 0;
    }

    /// Reports how many further attempts repeated the current message, and resets.
    fn flush(&mut self) {
        if self.count > 0 && self.dbg {
            println!(
                "[wait_until_ready]:   (same for {} further attempt(s))",
                self.count
            );
        }

        self.current = None;
        self.count = 0;
    }
}
