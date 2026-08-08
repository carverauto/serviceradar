/// Why a scoped parser implicitly removed a source.
#[non_exhaustive]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SourceRemovalCause {
    /// A new source displaced the least-recently-used source at capacity.
    CapacityPressure,
    /// The source exceeded the caller's idle threshold.
    Idle,
    /// Reducing the configured source capacity displaced the source.
    CapacityReduced,
}

/// Exact information about one implicitly removed scoped parser.
#[non_exhaustive]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SourceRemoval<K> {
    /// Exact source key owned by the removed child parser.
    pub source: K,
    /// Why the parser removed this source.
    pub cause: SourceRemovalCause,
}

/// Error returned by a source-removal reporter.
pub type SourceRemovalReporterError = Box<dyn std::error::Error + Send + Sync>;

/// Aggregate source-removal metrics retained by a scoped parser.
#[non_exhaustive]
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct SourceRemovalMetrics {
    /// Sources removed because a new source arrived at capacity.
    pub capacity_pressure: u64,
    /// Sources removed by idle pruning.
    pub idle: u64,
    /// Sources removed because the configured capacity was reduced.
    pub capacity_reduced: u64,
    /// Reporter calls that returned an error or panicked.
    pub reporter_failures: u64,
}

impl SourceRemovalMetrics {
    fn record_removal(&mut self, cause: SourceRemovalCause) {
        match cause {
            SourceRemovalCause::CapacityPressure => {
                self.capacity_pressure = self.capacity_pressure.saturating_add(1);
            }
            SourceRemovalCause::Idle => {
                self.idle = self.idle.saturating_add(1);
            }
            SourceRemovalCause::CapacityReduced => {
                self.capacity_reduced = self.capacity_reduced.saturating_add(1);
            }
        }
    }

    fn record_reporter_failure(&mut self) {
        self.reporter_failures = self.reporter_failures.saturating_add(1);
    }
}

pub(super) fn ignore_source_removal<K>(
    _removal: &SourceRemoval<K>,
) -> Result<(), SourceRemovalReporterError> {
    Ok(())
}

pub(super) fn report_source_removal<K, F>(
    source: K,
    cause: SourceRemovalCause,
    metrics: &mut SourceRemovalMetrics,
    reporter: &mut F,
) where
    F: FnMut(&SourceRemoval<K>) -> Result<(), SourceRemovalReporterError>,
{
    metrics.record_removal(cause);
    let removal = SourceRemoval { source, cause };
    let delivered =
        std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| reporter(&removal).is_ok()))
            .unwrap_or(false);
    if !delivered {
        metrics.record_reporter_failure();
    }
}
