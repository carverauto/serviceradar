//! Common supervisor utilities shared between X.509 and JWT source supervisors.
//!
//! This module contains reusable components for managing Workload API connections,
//! error tracking, and backoff policies.

use std::time::Duration;
use tokio::time::sleep;
use tokio_util::sync::CancellationToken;

/// Supervisor policy: maximum number of consecutive identical errors before suppressing WARN logs.
///
/// Applies to:
/// - client creation failures
/// - stream connection failures
/// - update validation rejections
pub(crate) const MAX_CONSECUTIVE_SAME_ERROR: u32 = 3;

/// Stream connection phase for diagnostics (distinguishes initial sync from steady-state supervisor).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum StreamPhase {
    /// Initial sync phase during source construction.
    InitialSync,
    /// Steady-state supervisor loop maintaining the stream.
    Supervisor,
}

/// Allocation-free key type for error tracking categories.
///
/// Used by `ErrorTracker` to group errors for log suppression without requiring
/// string literals or heap allocation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) enum ErrorKey {
    /// Client creation failures.
    ClientCreation,
    /// Stream connection failures.
    StreamConnect,
    /// Update rejection failures.
    UpdateRejected,
    /// No identity issued (expected transient state).
    NoIdentityIssued,
}

/// Helper for tracking repeated errors to suppress log noise.
///
/// This tracks consecutive occurrences of the same error kind and suppresses
/// log warnings after the first N consecutive occurrences. For the first N
/// consecutive occurrences of each error kind, logs are emitted at WARN level.
/// After that, logs are downgraded to DEBUG level to reduce noise.
///
/// When a different error kind occurs or errors stop, the counter resets.
pub(crate) struct ErrorTracker {
    last_error_kind: Option<ErrorKey>,
    consecutive_same_error: u32,
    max_consecutive: u32,
}

impl ErrorTracker {
    pub(crate) const fn new(max_consecutive: u32) -> Self {
        Self {
            last_error_kind: None,
            consecutive_same_error: 0,
            max_consecutive,
        }
    }

    pub(crate) fn record_error(&mut self, error_kind: ErrorKey) -> bool {
        let should_warn = self.last_error_kind != Some(error_kind)
            || self.consecutive_same_error < self.max_consecutive;

        if self.last_error_kind == Some(error_kind) {
            self.consecutive_same_error += 1;
        } else {
            self.consecutive_same_error = 1;
            self.last_error_kind = Some(error_kind);
        }

        should_warn
    }

    pub(crate) const fn reset(&mut self) {
        self.consecutive_same_error = 0;
        self.last_error_kind = None;
    }

    pub(crate) const fn consecutive_count(&self) -> u32 {
        self.consecutive_same_error
    }

    pub(crate) const fn last_error_kind(&self) -> Option<ErrorKey> {
        self.last_error_kind
    }
}

pub(crate) async fn sleep_or_cancel(token: &CancellationToken, dur: Duration) -> bool {
    tokio::select! {
        () = token.cancelled() => true,
        () = sleep(dur) => false,
    }
}

/// Exponential backoff with small jitter.
///
/// Computes the next backoff duration by:
/// 1. Doubling the current duration (exponential growth)
/// 2. Clamping to the maximum duration
/// 3. Adding small jitter (0-10% of the base) to prevent synchronized reconnect storms
///
/// The jitter is especially important in container fleets that start simultaneously.
///
/// Note: Jitter is calculated in milliseconds, which may result in sub-millisecond
/// precision loss for very small durations. This is acceptable for backoff purposes.
pub(crate) fn next_backoff(current: Duration, max: Duration) -> Duration {
    let cur = u64::try_from(current.as_millis()).unwrap_or(u64::MAX);
    let max = u64::try_from(max.as_millis()).unwrap_or(u64::MAX);

    let base = (cur.saturating_mul(2)).min(max);
    if base == 0 {
        return Duration::from_millis(0);
    }

    let jitter = base / 10;
    let add = if jitter > 0 {
        fastrand::u64(0..=jitter)
    } else {
        0
    };

    // Subtract jitter range from base before adding random jitter, so the
    // result stays within [base - jitter, base] instead of being clamped to
    // exactly `max` when base == max.
    let jitter_base = base.saturating_sub(jitter);
    Duration::from_millis(jitter_base.saturating_add(add))
}

/// Slower backoff policy for "no identity issued" condition.
///
/// This is an expected transient state (workload may not be registered yet),
/// so we use a gentler backoff: starts at 1s, exponential up to the effective
/// maximum (the lesser of the user-configured `max` and the default 10s cap),
/// with jitter.
pub(crate) fn next_backoff_for_no_identity(current: Duration, max: Duration) -> Duration {
    const MIN_BACKOFF_MS: u64 = 1000; // 1 second
    const DEFAULT_MAX_BACKOFF_MS: u64 = 10000; // 10 seconds

    let max_ms = u64::try_from(max.as_millis()).unwrap_or(u64::MAX);
    let effective_max = max_ms.min(DEFAULT_MAX_BACKOFF_MS);

    let current_with_min = current.max(Duration::from_millis(MIN_BACKOFF_MS));
    next_backoff(current_with_min, Duration::from_millis(effective_max))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn next_backoff_at_max_preserves_jitter() {
        let max = Duration::from_secs(30);
        let lo = max.saturating_sub(max / 10);

        // Run multiple times to exercise the random jitter path.
        for _ in 0..100 {
            let result = next_backoff(max, max);
            // Result should be in [max - 10%, max].
            assert!(
                result >= lo && result <= max,
                "expected backoff in [{lo:?}, {max:?}], got {result:?}"
            );
        }

        // Verify that not all values are identical (jitter is present).
        let mut results = std::collections::HashSet::new();
        for _ in 0..100 {
            results.insert(next_backoff(max, max).as_millis());
        }
        assert!(
            results.len() > 1,
            "expected jitter to produce varying results, got {results:?}"
        );
    }

    #[test]
    fn no_identity_backoff_starts_at_minimum_1s() {
        // Even with a very small current backoff, the minimum is clamped to 1s,
        // then doubled to 2s by next_backoff. With jitter (0-10%), the result
        // lands in [1.8s, 2.0s].
        let result =
            next_backoff_for_no_identity(Duration::from_millis(100), Duration::from_secs(30));
        assert!(
            result >= Duration::from_millis(1800),
            "expected >= 1800ms (2s - 10% jitter), got {}ms",
            result.as_millis()
        );
    }

    #[test]
    fn no_identity_backoff_respects_default_10s_cap() {
        // Even with a high user-configured max, the effective max is 10s.
        let result = next_backoff_for_no_identity(Duration::from_secs(8), Duration::from_secs(60));
        assert!(
            result <= Duration::from_secs(11),
            "expected <= 11s (10s + jitter), got {}ms",
            result.as_millis()
        );
    }

    #[test]
    fn no_identity_backoff_respects_user_max_below_default() {
        // If user-configured max is 3s (below the 10s default), that should be the cap.
        let result = next_backoff_for_no_identity(Duration::from_secs(2), Duration::from_secs(3));
        assert!(
            result <= Duration::from_millis(3300),
            "expected <= 3.3s (3s + jitter), got {}ms",
            result.as_millis()
        );
    }

    #[test]
    fn no_identity_backoff_grows_exponentially() {
        let first = next_backoff_for_no_identity(Duration::from_secs(1), Duration::from_secs(30));
        let second = next_backoff_for_no_identity(first, Duration::from_secs(30));

        // Second backoff should be larger than first (exponential growth)
        assert!(
            second > first,
            "expected growth: first={}ms, second={}ms",
            first.as_millis(),
            second.as_millis()
        );
    }
}
