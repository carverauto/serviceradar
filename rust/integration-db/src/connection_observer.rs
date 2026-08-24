use std::{
    fmt::Write as _,
    future::Future,
    path::PathBuf,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use anyhow::{anyhow, bail, Context, Result};
use tokio::time::Instant;
use tokio_postgres::Client;

pub const SAMPLE_INTERVAL_MS: u64 = 500;
const OBSERVER_SESSIONS_EXCLUDED: u64 = 1;

pub const RUN_SCOPED_COUNT_SQL: &str = "SELECT \
    count(*) FILTER (WHERE datname = $1 \
        OR left(datname, char_length($1) + 1) = $1 || '_')::bigint, \
    count(*)::bigint \
 FROM pg_stat_activity \
 WHERE backend_type = 'client backend' \
   AND pid <> pg_backend_pid()";

const CAPACITY_SQL: &str = "SELECT \
    current_setting('max_connections')::bigint, \
    current_setting('superuser_reserved_connections')::bigint, \
    COALESCE(current_setting('reserved_connections', true), '0')::bigint";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ConnectionCounts {
    pub run_scoped: u64,
    pub fixture_wide: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Capacity {
    pub max: u64,
    pub superuser_reserved: u64,
    pub reserved: u64,
}

/// Fail-closed capacity values when startup cannot query the fixture. The summary retains every
/// required field without claiming usable slots that were never observed.
pub const UNAVAILABLE_CAPACITY: Capacity = Capacity {
    max: 0,
    superuser_reserved: 0,
    reserved: 0,
};

impl Capacity {
    pub fn usable_client_slots(self) -> u64 {
        self.max
            .saturating_sub(self.superuser_reserved)
            .saturating_sub(self.reserved)
    }

    /// Returns the largest pool allocation that keeps ten percent of usable client slots free.
    pub fn safe_client_slots(self) -> u64 {
        let usable_slots = self.usable_client_slots();
        let whole_tens = usable_slots / 10;
        let remainder = usable_slots % 10;
        whole_tens * 9 + remainder * 9 / 10
    }

    /// Rejects a requested pool allocation that would consume the required safety headroom.
    pub fn validate_required_pool_slots(self, required_pool_slots: u64) -> Result<()> {
        let safe_slots = self.safe_client_slots();
        if required_pool_slots > safe_slots {
            bail!(
                "required pool slots {required_pool_slots} exceed safe client slots {safe_slots}"
            );
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SampleWindow {
    pub start_ms: u64,
    pub end_ms: u64,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Peaks {
    pub samples: u64,
    pub run_scoped: u64,
    pub fixture_wide: u64,
}

impl Peaks {
    pub fn record(&mut self, run_scoped: u64, fixture_wide: u64) {
        self.samples += 1;
        self.run_scoped = self.run_scoped.max(run_scoped);
        self.fixture_wide = self.fixture_wide.max(fixture_wide);
    }

    pub fn summary_json(
        self,
        run_prefix: &str,
        window: SampleWindow,
        capacity: Capacity,
    ) -> String {
        format!(
            r#"{{"sample_interval_ms":{},"samples":{},"sample_window_start_ms":{},"sample_window_end_ms":{},"observer_sessions_excluded":{},"run_prefix":"{}","run_scoped_peak":{},"fixture_wide_peak":{},"max_connections":{},"superuser_reserved_connections":{},"reserved_connections":{},"usable_client_slots":{}}}"#,
            SAMPLE_INTERVAL_MS,
            self.samples,
            window.start_ms,
            window.end_ms,
            OBSERVER_SESSIONS_EXCLUDED,
            json_escape(run_prefix),
            self.run_scoped,
            self.fixture_wide,
            capacity.max,
            capacity.superuser_reserved,
            capacity.reserved,
            capacity.usable_client_slots(),
        )
    }
}

/// Samples all fixture client backends and the exact or underscore-delimited run database set.
pub async fn sample(client: &Client, run_prefix: &str) -> Result<ConnectionCounts> {
    let row = client
        .query_one(RUN_SCOPED_COUNT_SQL, &[&run_prefix])
        .await
        .context("sample pg_stat_activity")?;

    Ok(ConnectionCounts {
        run_scoped: checked_count(row.get(0), "run-scoped connection count")?,
        fixture_wide: checked_count(row.get(1), "fixture-wide connection count")?,
    })
}

/// Reads the live PostgreSQL connection capacity settings.
pub async fn capacity(client: &Client) -> Result<Capacity> {
    let row = client
        .query_one(CAPACITY_SQL, &[])
        .await
        .context("read PostgreSQL connection capacity")?;

    Ok(Capacity {
        max: checked_count(row.get(0), "max_connections")?,
        superuser_reserved: checked_count(row.get(1), "superuser_reserved_connections")?,
        reserved: checked_count(row.get(2), "reserved_connections")?,
    })
}

fn checked_count(value: i64, setting: &str) -> Result<u64> {
    u64::try_from(value).with_context(|| format!("{setting} must not be negative"))
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ObserverArgs {
    pub ready_file: PathBuf,
    pub suite_complete_file: PathBuf,
    pub quiescent_file: PathBuf,
    pub stop_file: PathBuf,
    pub max_seconds: u64,
    pub required_pool_slots: u64,
}

impl ObserverArgs {
    pub fn parse<I, S>(args: I) -> Result<Self>
    where
        I: IntoIterator<Item = S>,
        S: AsRef<str>,
    {
        let mut args = args.into_iter();
        let _program = args.next().ok_or_else(|| anyhow!("missing program name"))?;
        let mut ready_file = None;
        let mut suite_complete_file = None;
        let mut quiescent_file = None;
        let mut stop_file = None;
        let mut max_seconds = None;
        let mut required_pool_slots = None;

        while let Some(flag) = args.next() {
            let value = args
                .next()
                .ok_or_else(|| anyhow!("missing value for {}", flag.as_ref()))?;
            let value = value.as_ref();

            match flag.as_ref() {
                "--ready-file" => set_once(&mut ready_file, value, "--ready-file")?,
                "--suite-complete-file" => {
                    set_once(&mut suite_complete_file, value, "--suite-complete-file")?
                }
                "--quiescent-file" => set_once(&mut quiescent_file, value, "--quiescent-file")?,
                "--stop-file" => set_once(&mut stop_file, value, "--stop-file")?,
                "--max-seconds" => {
                    if max_seconds.is_some() {
                        bail!("duplicate --max-seconds");
                    }
                    let seconds = value
                        .parse::<u64>()
                        .with_context(|| format!("invalid --max-seconds value {value:?}"))?;
                    if seconds == 0 {
                        bail!("--max-seconds must be greater than zero");
                    }
                    max_seconds = Some(seconds);
                }
                "--required-pool-slots" => {
                    if required_pool_slots.is_some() {
                        bail!("duplicate --required-pool-slots");
                    }
                    let slots = value.parse::<u64>().with_context(|| {
                        format!("invalid --required-pool-slots value {value:?}")
                    })?;
                    if slots == 0 {
                        bail!("--required-pool-slots must be greater than zero");
                    }
                    required_pool_slots = Some(slots);
                }
                unknown => bail!("unknown flag {unknown}"),
            }
        }

        Ok(Self {
            ready_file: required_path(ready_file, "--ready-file")?,
            suite_complete_file: required_path(suite_complete_file, "--suite-complete-file")?,
            quiescent_file: required_path(quiescent_file, "--quiescent-file")?,
            stop_file: required_path(stop_file, "--stop-file")?,
            max_seconds: max_seconds.ok_or_else(|| anyhow!("missing --max-seconds"))?,
            required_pool_slots: required_pool_slots
                .ok_or_else(|| anyhow!("missing --required-pool-slots"))?,
        })
    }
}

fn set_once(slot: &mut Option<PathBuf>, value: &str, flag: &str) -> Result<()> {
    if slot.replace(PathBuf::from(value)).is_some() {
        bail!("duplicate {flag}");
    }
    Ok(())
}

fn required_path(value: Option<PathBuf>, flag: &str) -> Result<PathBuf> {
    value.ok_or_else(|| anyhow!("missing {flag}"))
}

#[derive(Debug, Default)]
pub struct Quiescence {
    post_suite_zero_samples: u8,
}

impl Quiescence {
    pub fn record(&mut self, suite_complete: bool, run_scoped: u64) -> bool {
        if !suite_complete {
            self.post_suite_zero_samples = 0;
            return false;
        }

        if run_scoped == 0 {
            self.post_suite_zero_samples = self.post_suite_zero_samples.saturating_add(1);
        } else {
            self.post_suite_zero_samples = 0;
        }

        self.post_suite_zero_samples >= 2
    }
}

pub fn completion_status(
    quiescent: bool,
    stopped: bool,
    deadline_elapsed: bool,
) -> std::result::Result<(), &'static str> {
    if deadline_elapsed {
        return Err("connection observer deadline elapsed before successful completion");
    }
    if stopped && !quiescent {
        return Err("connection observer stopped before two post-suite zero samples");
    }
    Ok(())
}

/// Returns the remaining observer budget, failing closed once its process-wide deadline passes.
pub fn remaining_until(deadline: Instant) -> Result<Duration> {
    deadline
        .checked_duration_since(Instant::now())
        .ok_or_else(|| anyhow!("connection observer deadline elapsed"))
}

/// Runs one async observer operation only while its process-wide deadline still has budget.
pub async fn within_deadline<F, T>(deadline: Instant, operation: F, description: &str) -> Result<T>
where
    F: Future<Output = Result<T>>,
{
    let remaining = remaining_until(deadline)?;
    tokio::time::timeout(remaining, operation)
        .await
        .with_context(|| format!("connection observer deadline elapsed during {description}"))?
}

/// Emits exactly one observer summary before returning the terminal status unchanged.
pub fn emit_terminal_summary<F>(status: Result<()>, summary: String, emit: F) -> Result<()>
where
    F: FnOnce(&str),
{
    emit(&summary);
    status
}

pub fn terminal_summary_line(
    peaks: Peaks,
    run_prefix: &str,
    window: SampleWindow,
    capacity: Capacity,
) -> String {
    format!(
        "SERVICERADAR_CONNECTION_OBSERVER {}",
        peaks.summary_json(run_prefix, window, capacity)
    )
}

/// Emits a contract-shaped summary when startup fails before live capacity is available.
pub fn emit_startup_terminal_summary<F>(
    status: Result<()>,
    peaks: Peaks,
    run_prefix: &str,
    window: SampleWindow,
    emit: F,
) -> Result<()>
where
    F: FnOnce(&str),
{
    emit_terminal_summary(
        status,
        terminal_summary_line(peaks, run_prefix, window, UNAVAILABLE_CAPACITY),
        emit,
    )
}

pub fn epoch_millis() -> Result<u64> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .context("system clock is before the Unix epoch")
        .map(|duration| duration.as_millis() as u64)
}

fn json_escape(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());
    for character in value.chars() {
        match character {
            '"' => escaped.push_str("\\\""),
            '\\' => escaped.push_str("\\\\"),
            '\n' => escaped.push_str("\\n"),
            '\r' => escaped.push_str("\\r"),
            '\t' => escaped.push_str("\\t"),
            control if control.is_control() => {
                write!(escaped, "\\u{:04x}", control as u32)
                    .expect("writing to String cannot fail");
            }
            other => escaped.push(other),
        }
    }
    escaped
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn records_independent_run_and_fixture_peaks() {
        let mut peaks = Peaks::default();
        peaks.record(7, 31);
        peaks.record(12, 29);
        peaks.record(9, 44);
        assert_eq!(
            peaks,
            Peaks {
                samples: 3,
                run_scoped: 12,
                fixture_wide: 44
            }
        );
    }

    #[test]
    fn summary_is_one_machine_readable_log_line() {
        let peaks = Peaks {
            samples: 4,
            run_scoped: 16,
            fixture_wide: 51,
        };
        assert_eq!(
            peaks.summary_json(
                "sr_core_test_deadbeef",
                SampleWindow {
                    start_ms: 1_777_000_000_000,
                    end_ms: 1_777_000_003_000
                },
                Capacity {
                    max: 200,
                    superuser_reserved: 3,
                    reserved: 0
                },
            ),
            r#"{"sample_interval_ms":500,"samples":4,"sample_window_start_ms":1777000000000,"sample_window_end_ms":1777000003000,"observer_sessions_excluded":1,"run_prefix":"sr_core_test_deadbeef","run_scoped_peak":16,"fixture_wide_peak":51,"max_connections":200,"superuser_reserved_connections":3,"reserved_connections":0,"usable_client_slots":197}"#
        );
    }

    #[test]
    fn run_prefix_query_uses_an_exact_or_underscore_delimited_scope() {
        assert!(RUN_SCOPED_COUNT_SQL.contains("datname = $1"));
        assert!(RUN_SCOPED_COUNT_SQL.contains("left(datname, char_length($1) + 1) = $1 || '_'"));
        assert!(!RUN_SCOPED_COUNT_SQL.contains("left(datname, char_length($1)) = $1"));
        assert!(!RUN_SCOPED_COUNT_SQL.contains("LIKE"));
    }

    #[test]
    fn parser_rejects_missing_duplicate_and_unknown_flags() {
        assert!(ObserverArgs::parse(["observe_connections"]).is_err());
        assert!(ObserverArgs::parse([
            "observe_connections",
            "--stop-file",
            "a",
            "--stop-file",
            "b"
        ])
        .is_err());
        assert!(ObserverArgs::parse(["observe_connections", "--wat", "x"]).is_err());
    }

    #[test]
    fn parser_requires_and_parses_positive_required_pool_slots() {
        let missing = ObserverArgs::parse([
            "observe_connections",
            "--ready-file",
            "ready",
            "--suite-complete-file",
            "suite-complete",
            "--quiescent-file",
            "quiescent",
            "--stop-file",
            "stop",
            "--max-seconds",
            "60",
        ])
        .unwrap_err();
        assert_eq!(missing.to_string(), "missing --required-pool-slots");

        let zero = ObserverArgs::parse([
            "observe_connections",
            "--ready-file",
            "ready",
            "--suite-complete-file",
            "suite-complete",
            "--quiescent-file",
            "quiescent",
            "--stop-file",
            "stop",
            "--max-seconds",
            "60",
            "--required-pool-slots",
            "0",
        ])
        .unwrap_err();
        assert_eq!(
            zero.to_string(),
            "--required-pool-slots must be greater than zero"
        );

        let parsed = ObserverArgs::parse([
            "observe_connections",
            "--ready-file",
            "ready",
            "--suite-complete-file",
            "suite-complete",
            "--quiescent-file",
            "quiescent",
            "--stop-file",
            "stop",
            "--max-seconds",
            "60",
            "--required-pool-slots",
            "177",
        ])
        .unwrap();
        assert_eq!(parsed.required_pool_slots, 177);
    }

    #[test]
    fn capacity_rejects_required_pool_slots_above_safe_headroom() {
        let capacity = Capacity {
            max: 200,
            superuser_reserved: 3,
            reserved: 0,
        };

        let error = capacity.validate_required_pool_slots(178).unwrap_err();

        assert_eq!(
            error.to_string(),
            "required pool slots 178 exceed safe client slots 177"
        );
    }

    #[test]
    fn capacity_accepts_required_pool_slots_at_safe_headroom() {
        let capacity = Capacity {
            max: 200,
            superuser_reserved: 3,
            reserved: 0,
        };

        capacity.validate_required_pool_slots(177).unwrap();
    }

    #[test]
    fn quiescence_requires_two_post_suite_zero_samples() {
        let mut state = Quiescence::default();
        assert!(!state.record(false, 0));
        assert!(!state.record(true, 0));
        assert!(!state.record(true, 1));
        assert!(!state.record(true, 0));
        assert!(state.record(true, 0));
    }

    #[test]
    fn completion_fails_closed_on_deadline_or_early_stop() {
        assert!(completion_status(false, false, true).is_err());
        assert!(completion_status(false, true, false).is_err());
        assert_eq!(completion_status(true, true, false), Ok(()));
    }

    #[test]
    fn expired_deadline_has_no_remaining_operation_time() {
        let deadline = tokio::time::Instant::now() - std::time::Duration::from_millis(1);
        assert!(remaining_until(deadline).is_err());
    }

    #[tokio::test]
    async fn deadline_bounds_an_in_flight_operation() {
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_millis(1);
        let result = within_deadline(
            deadline,
            std::future::pending::<Result<()>>(),
            "sample pg_stat_activity",
        )
        .await;
        assert!(result.is_err());
    }

    #[test]
    fn deadline_failure_emits_exactly_one_summary_line() {
        let mut output = Vec::new();
        let result = emit_terminal_summary(
            Err(anyhow!(
                "connection observer deadline elapsed during sample interval"
            )),
            "SERVICERADAR_CONNECTION_OBSERVER {\"samples\":1}".to_string(),
            |line| output.push(line.to_string()),
        );
        assert!(result.is_err());
        assert_eq!(output, ["SERVICERADAR_CONNECTION_OBSERVER {\"samples\":1}"]);
    }

    #[test]
    fn connection_stage_failure_emits_one_fail_closed_summary() {
        assert_startup_failure_summary("admin connection");
    }

    #[test]
    fn capacity_stage_failure_emits_one_fail_closed_summary() {
        assert_startup_failure_summary("connection capacity");
    }

    fn assert_startup_failure_summary(stage: &str) {
        let mut output = Vec::new();
        let result = emit_startup_terminal_summary(
            Err(anyhow!(
                "connection observer deadline elapsed during {stage}"
            )),
            Peaks::default(),
            "sr_core_test_deadbeef",
            SampleWindow {
                start_ms: 11,
                end_ms: 22,
            },
            |line| output.push(line.to_string()),
        );
        assert!(result.is_err());
        assert_eq!(
            output,
            [
                r#"SERVICERADAR_CONNECTION_OBSERVER {"sample_interval_ms":500,"samples":0,"sample_window_start_ms":11,"sample_window_end_ms":22,"observer_sessions_excluded":1,"run_prefix":"sr_core_test_deadbeef","run_scoped_peak":0,"fixture_wide_peak":0,"max_connections":0,"superuser_reserved_connections":0,"reserved_connections":0,"usable_client_slots":0}"#
            ]
        );
    }
}
