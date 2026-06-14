use crate::detector::reason_impl;
use crate::stats::WelfordAcc;
use crate::types::{
    ReasonBatchResult, ReasonContext, ReasonEventBatchResult, ReasonEventVerdict, ReasonSample,
    ReasonVerdict,
};
use rustler::{NifMap, ResourceArc};
use std::collections::HashMap;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::Mutex;
use std::sync::MutexGuard;

const RECOMPUTE_AFTER_EVICTIONS: usize = 1024;

pub(crate) struct RuntimeShardState {
    series: Mutex<HashMap<String, RuntimeSeriesState>>,
}

#[rustler::resource_impl]
impl rustler::Resource for RuntimeShardState {}

/// Acquire the shard lock with a blocking `lock()`, recovering from poisoning.
///
/// The per-batch critical sections are bounded and there is no lock-ordering
/// hazard, so blocking is safe and avoids the silent data loss that `try_lock`
/// caused when it mapped the whole batch to lock-unavailable errors if the
/// single-writer invariant was ever violated. Poisoning (a prior panic while the
/// lock was held) is recovered with `into_inner` because the protected map is a
/// plain key/value store with no broken cross-field invariant. (review finding 3)
fn lock_series(state: &RuntimeShardState) -> MutexGuard<'_, HashMap<String, RuntimeSeriesState>> {
    state
        .series
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Run a single batch item's evaluation, isolating panics so one bad item
/// becomes an error result instead of aborting the whole NIF call (rustler wraps
/// the entire NIF body in catch_unwind). The closure is `AssertUnwindSafe`
/// because callers either touch no shared state on the panicking path or only
/// hold a `&mut` to a per-series entry they overwrite on success. (review finding 1)
pub(crate) fn catch_item_panic<T, F>(body: F) -> Result<T, String>
where
    F: FnOnce() -> Result<T, String>,
{
    match catch_unwind(AssertUnwindSafe(body)) {
        Ok(result) => result,
        Err(panic) => Err(format!(
            "reasoner item panicked: {}",
            panic_message(&*panic)
        )),
    }
}

fn panic_message(panic: &(dyn std::any::Any + Send)) -> String {
    if let Some(message) = panic.downcast_ref::<&str>() {
        (*message).to_string()
    } else if let Some(message) = panic.downcast_ref::<String>() {
        message.clone()
    } else {
        "unknown panic".to_string()
    }
}

#[derive(Clone, Debug, Default)]
struct RuntimeSeriesState {
    context: Option<ReasonContext>,
    window_tail: Vec<f64>,
    rolling_acc: WelfordAcc,
    consecutive_anomalous: usize,
    evictions_since_recompute: usize,
    active: bool,
}

#[derive(Clone, Debug, NifMap)]
pub(crate) struct ReasonSeriesInput {
    pub(crate) series_key: String,
    pub(crate) context: ReasonContext,
    pub(crate) sample: ReasonSample,
}

#[derive(Clone, Debug, NifMap)]
pub(crate) struct ReasonIndexedSeriesInput {
    pub(crate) index: usize,
    pub(crate) series_key: String,
    pub(crate) context: ReasonContext,
    pub(crate) sample: ReasonSample,
}

#[derive(Clone, Debug, NifMap)]
pub(crate) struct ReasonIndexedValueInput {
    pub(crate) index: usize,
    pub(crate) series_key: String,
    pub(crate) context: Option<ReasonContext>,
    pub(crate) value: f64,
    pub(crate) observed_at_unix_nano: Option<u64>,
}

pub(crate) type ReasonIndexedValueTupleInput =
    (usize, String, Option<ReasonContext>, f64, Option<u64>);

#[derive(Clone, Debug, NifMap)]
pub(crate) struct RuntimeSeriesSnapshot {
    pub(crate) version: usize,
    pub(crate) series_key: String,
    pub(crate) context: Option<ReasonContext>,
    pub(crate) window_tail: Vec<f64>,
    pub(crate) rolling_acc: WelfordAcc,
    pub(crate) consecutive_anomalous: usize,
    pub(crate) evictions_since_recompute: usize,
    pub(crate) active: bool,
}

#[derive(Debug, NifMap)]
pub(crate) struct ReasonIndexedEventResult {
    pub(crate) index: usize,
    pub(crate) ok: Option<ReasonEventVerdict>,
    pub(crate) error: Option<String>,
}

pub(crate) fn new_runtime_shard_state() -> ResourceArc<RuntimeShardState> {
    ResourceArc::new(RuntimeShardState {
        series: Mutex::new(HashMap::new()),
    })
}

pub(crate) fn reason_state_batch_impl(
    state: ResourceArc<RuntimeShardState>,
    inputs: Vec<ReasonSeriesInput>,
) -> Vec<ReasonBatchResult> {
    // Blocking lock (poison-recovering) instead of try_lock so a momentary
    // contention never silently drops the whole batch. (review finding 3)
    let mut guard = lock_series(&state);

    inputs
        .into_iter()
        .map(|input| {
            let series_key = input.series_key;
            // Mutate the per-series entry in place rather than cloning the full
            // RuntimeSeriesState (window_tail Vec) per item. (review finding 4)
            let runtime = guard.entry(series_key).or_default();
            let template = input.context;
            let context = runtime.context(template.clone());

            // Isolate per-item panics: reason_impl runs before any mutation, so a
            // panic leaves the entry untouched and only this item errors. (finding 1)
            let outcome = catch_item_panic(|| reason_impl(context, input.sample));
            match outcome {
                Ok(verdict) => {
                    let next_runtime =
                        RuntimeSeriesState::from_verdict_after(runtime, &template, &verdict);
                    *runtime = next_runtime;

                    ReasonBatchResult {
                        ok: Some(verdict.without_runtime_tail()),
                        error: None,
                    }
                }
                Err(error) => ReasonBatchResult {
                    ok: None,
                    error: Some(error),
                },
            }
        })
        .collect()
}

pub(crate) fn reason_state_batch_events_impl(
    state: ResourceArc<RuntimeShardState>,
    inputs: Vec<ReasonSeriesInput>,
) -> Vec<ReasonEventBatchResult> {
    // Blocking lock (poison-recovering) instead of try_lock so a momentary
    // contention never silently drops the whole batch. (review finding 3)
    let mut guard = lock_series(&state);

    inputs
        .into_iter()
        .map(|input| {
            let series_key = input.series_key;
            // Mutate the per-series entry in place rather than cloning the full
            // RuntimeSeriesState (window_tail Vec) per item. (review finding 4)
            let runtime = guard.entry(series_key).or_default();
            let template = input.context;
            let context = runtime.context(template.clone());

            // Isolate per-item panics so one bad item errors instead of aborting
            // the whole batch; reason_impl runs before any mutation. (finding 1)
            let outcome = catch_item_panic(|| reason_impl(context, input.sample));
            match outcome {
                Ok(verdict) => {
                    let next_runtime =
                        RuntimeSeriesState::from_verdict_after(runtime, &template, &verdict);
                    *runtime = next_runtime;

                    ReasonEventBatchResult {
                        ok: Some(ReasonEventVerdict::from_verdict(verdict)),
                        error: None,
                    }
                }
                Err(error) => ReasonEventBatchResult {
                    ok: None,
                    error: Some(error),
                },
            }
        })
        .collect()
}

pub(crate) fn reason_state_batch_changes_impl(
    state: ResourceArc<RuntimeShardState>,
    inputs: Vec<ReasonIndexedSeriesInput>,
) -> Vec<ReasonIndexedEventResult> {
    // Blocking lock (poison-recovering) instead of try_lock so a momentary
    // contention never silently drops the whole batch. (review finding 3)
    let mut guard = lock_series(&state);

    inputs
        .into_iter()
        .filter_map(|input| {
            let index = input.index;
            let series_key = input.series_key;
            // Mutate the per-series entry in place rather than cloning the full
            // RuntimeSeriesState per item. (review finding 4)
            let runtime = guard.entry(series_key).or_default();
            // active is Copy; snapshot it so the borrow is free for reason_impl.
            let active = runtime.active;
            let template = input.context;
            let context = runtime.context(template.clone());

            // Isolate per-item panics so one bad item errors instead of aborting
            // the whole batch; reason_impl runs before any mutation. (finding 1)
            let outcome = catch_item_panic(|| reason_impl(context, input.sample));
            match outcome {
                Ok(verdict) => {
                    // Active-edge emit: fire once on open (anomalous && !active) and
                    // once on clear (!breached && active), not on every breached tick.
                    let emit = (verdict.anomalous && !active) || (!verdict.breached && active);
                    let mut next_runtime =
                        RuntimeSeriesState::from_verdict_after(runtime, &template, &verdict);
                    next_runtime.active = if verdict.anomalous {
                        true
                    } else if !verdict.breached {
                        false
                    } else {
                        active
                    };
                    *runtime = next_runtime;

                    emit.then(|| ReasonIndexedEventResult {
                        index,
                        ok: Some(ReasonEventVerdict::from_verdict(verdict)),
                        error: None,
                    })
                }
                Err(error) => Some(ReasonIndexedEventResult {
                    index,
                    ok: None,
                    error: Some(error),
                }),
            }
        })
        .collect()
}

pub(crate) fn reason_state_values_changes_impl(
    state: ResourceArc<RuntimeShardState>,
    inputs: Vec<ReasonIndexedValueInput>,
) -> Vec<ReasonIndexedEventResult> {
    reason_state_value_items_changes_impl(
        state,
        inputs
            .into_iter()
            .map(|input| {
                (
                    input.index,
                    input.series_key,
                    input.context,
                    input.value,
                    input.observed_at_unix_nano,
                )
            })
            .collect(),
    )
}

pub(crate) fn reason_state_value_tuples_changes_impl(
    state: ResourceArc<RuntimeShardState>,
    inputs: Vec<ReasonIndexedValueTupleInput>,
) -> Vec<ReasonIndexedEventResult> {
    reason_state_value_items_changes_impl(state, inputs)
}

// The lock_error parameter was removed: the batch paths now block on the lock
// instead of mapping the whole batch to a lock-unavailable error. (review finding 3)
fn reason_state_value_items_changes_impl(
    state: ResourceArc<RuntimeShardState>,
    inputs: Vec<ReasonIndexedValueTupleInput>,
) -> Vec<ReasonIndexedEventResult> {
    // Blocking lock (poison-recovering) instead of try_lock so a momentary
    // contention never silently drops the whole batch. (review finding 3)
    let mut guard = lock_series(&state);
    // The lock-free core is split out so it can be unit-tested without the BEAM
    // (ResourceArc::new requires a registered resource type, unavailable in
    // `cargo test`); the production path just locks then delegates.
    reason_state_value_items_on_map(&mut guard, inputs)
}

fn reason_state_value_items_on_map(
    series: &mut HashMap<String, RuntimeSeriesState>,
    inputs: Vec<ReasonIndexedValueTupleInput>,
) -> Vec<ReasonIndexedEventResult> {
    inputs
        .into_iter()
        .filter_map(|input| {
            let (index, series_key, input_context, value, observed_at_unix_nano) = input;
            let runtime = series.entry(series_key).or_default();
            let active = runtime.active;

            let Some(template) = input_context.or_else(|| runtime.context.clone()) else {
                return Some(ReasonIndexedEventResult {
                    index,
                    ok: None,
                    error: Some("series context missing".to_string()),
                });
            };

            let context = runtime.context(template.clone());
            let sample = ReasonSample {
                value,
                observed_at_unix_nano,
            };

            // Isolate per-item panics so one bad item errors instead of aborting
            // the whole batch; reason_impl runs before any mutation. (finding 1)
            let outcome = catch_item_panic(|| reason_impl(context, sample));
            match outcome {
                Ok(verdict) => {
                    let emit = (verdict.anomalous && !active) || (!verdict.breached && active);
                    let mut next_runtime =
                        RuntimeSeriesState::from_verdict_after(runtime, &template, &verdict);
                    next_runtime.context = Some(runtime_context_template(template));
                    next_runtime.active = if verdict.anomalous {
                        true
                    } else if !verdict.breached {
                        false
                    } else {
                        active
                    };
                    *runtime = next_runtime;

                    emit.then(|| ReasonIndexedEventResult {
                        index,
                        ok: Some(ReasonEventVerdict::from_verdict(verdict)),
                        error: None,
                    })
                }
                Err(error) => Some(ReasonIndexedEventResult {
                    index,
                    ok: None,
                    error: Some(error),
                }),
            }
        })
        .collect()
}

pub(crate) fn forget_series_impl(
    state: ResourceArc<RuntimeShardState>,
    series_key: String,
) -> bool {
    let mut guard = lock_series(&state);
    guard.remove(&series_key).is_some()
}

pub(crate) fn export_series_impl(
    state: ResourceArc<RuntimeShardState>,
    series_key: String,
) -> Result<Option<RuntimeSeriesSnapshot>, String> {
    let guard = lock_series(&state);

    Ok(guard.get(&series_key).map(|runtime| RuntimeSeriesSnapshot {
        version: 1,
        series_key,
        context: runtime.context.clone(),
        window_tail: runtime.window_tail.clone(),
        rolling_acc: runtime.rolling_acc,
        consecutive_anomalous: runtime.consecutive_anomalous,
        evictions_since_recompute: runtime.evictions_since_recompute,
        active: runtime.active,
    }))
}

pub(crate) fn import_series_impl(
    state: ResourceArc<RuntimeShardState>,
    snapshot: RuntimeSeriesSnapshot,
) -> Result<bool, String> {
    if snapshot.version != 1 {
        return Err(format!(
            "unsupported runtime series snapshot version {}",
            snapshot.version
        ));
    }

    if snapshot.series_key.is_empty() {
        return Err("runtime series snapshot missing series_key".to_string());
    }

    let window_tail = snapshot
        .window_tail
        .into_iter()
        .filter(|value| value.is_finite())
        .collect::<Vec<_>>();
    let rolling_acc = if snapshot.rolling_acc.valid_for_count(window_tail.len()) {
        snapshot.rolling_acc
    } else {
        WelfordAcc::from_values(&window_tail)
    };
    let context = snapshot.context.map(runtime_context_template);
    let active = snapshot.active;
    let series_key = snapshot.series_key;

    let mut guard = lock_series(&state);
    guard.insert(
        series_key,
        RuntimeSeriesState {
            context,
            window_tail,
            rolling_acc,
            consecutive_anomalous: snapshot.consecutive_anomalous,
            evictions_since_recompute: snapshot.evictions_since_recompute,
            active,
        },
    );

    Ok(active)
}

pub(crate) fn on_load(_env: rustler::Env, _info: rustler::Term) -> bool {
    true
}

impl RuntimeSeriesState {
    fn context(&self, mut context: ReasonContext) -> ReasonContext {
        context.baseline.clear();
        context.window_tail = Some(self.window_tail.clone());
        context.rolling_acc = Some(self.rolling_acc);
        context.consecutive_anomalous = Some(self.consecutive_anomalous);
        context
    }

    fn from_verdict_after(
        previous: &RuntimeSeriesState,
        template: &ReasonContext,
        verdict: &ReasonVerdict,
    ) -> Self {
        let window_size = template
            .window_size
            .unwrap_or(crate::DEFAULT_WINDOW_SIZE)
            .max(1);
        let evicted = verdict.include_in_baseline
            && previous.window_tail.len() >= window_size
            && verdict.next_window_tail.len() >= window_size;
        let evictions_since_recompute = if evicted {
            previous.evictions_since_recompute.saturating_add(1)
        } else {
            previous.evictions_since_recompute
        };
        let should_recompute = evictions_since_recompute >= RECOMPUTE_AFTER_EVICTIONS
            || !verdict
                .next_rolling_acc
                .valid_for_count(verdict.next_window_tail.len());

        let rolling_acc = if should_recompute {
            WelfordAcc::from_values(&verdict.next_window_tail)
        } else {
            verdict.next_rolling_acc
        };

        Self {
            window_tail: verdict.next_window_tail.clone(),
            rolling_acc,
            consecutive_anomalous: verdict.next_consecutive_anomalous,
            evictions_since_recompute: if should_recompute {
                0
            } else {
                evictions_since_recompute
            },
            active: false,
            context: Some(runtime_context_template(template.clone())),
        }
    }
}

fn runtime_context_template(mut context: ReasonContext) -> ReasonContext {
    context.baseline.clear();
    context.window_tail = None;
    context.rolling_acc = None;
    context.consecutive_anomalous = None;
    context
}

trait RuntimeVerdict {
    fn without_runtime_tail(self) -> Self;
}

impl RuntimeVerdict for ReasonVerdict {
    fn without_runtime_tail(mut self) -> Self {
        self.next_window_tail.clear();
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::stats::sample_stats;

    const SERIES: &str = "if-1";

    /// Rolling-only context template; `window_tail`/`rolling_acc` are left None so
    /// the runtime supplies the retained compact state on every call.
    fn template(window_size: usize, min_samples: usize, confirm_slots: usize) -> ReasonContext {
        ReasonContext {
            baseline: Vec::new(),
            rolling_acc: None,
            window_tail: None,
            seasonal_baseline: None,
            trend_baseline: None,
            rolling_enabled: Some(true),
            seasonal_enabled: None,
            trend_enabled: None,
            min_samples: Some(min_samples),
            seasonal_min_samples: None,
            trend_min_samples: None,
            window_size: Some(window_size),
            n_sigma: Some(3.0),
            seasonal_n_sigma: None,
            trend_n_sigma: None,
            confirm_slots: Some(confirm_slots),
            consecutive_anomalous: Some(0),
        }
    }

    /// Feed one value through the lock-free core for `SERIES`, reusing the stored
    /// per-series state. Returns the emitted edge results (usually empty).
    fn feed(
        series: &mut HashMap<String, RuntimeSeriesState>,
        template: &ReasonContext,
        value: f64,
    ) -> Vec<ReasonIndexedEventResult> {
        reason_state_value_items_on_map(
            series,
            vec![(0, SERIES.to_string(), Some(template.clone()), value, None)],
        )
    }

    #[track_caller]
    fn assert_in_delta(actual: f64, expected: f64, tolerance: f64) {
        assert!(
            (actual - expected).abs() <= tolerance,
            "expected {actual} within {tolerance} of {expected}"
        );
    }

    // (a) Feeding N values one-at-a-time through the runtime yields a rolling_acc
    // that matches a two-pass from_values over the retained window_tail, including
    // after the window starts evicting. This is the O(1) Welford fold invariant.
    #[test]
    fn one_at_a_time_rolling_acc_matches_from_values_over_window_tail() {
        let window_size = 8;
        let template = template(window_size, 3, 5);
        let mut series = HashMap::new();

        // 30 clean values around 100 (tight jitter so nothing breaches and every
        // tick is admitted); the first window_size fill, the rest evict.
        for order in 0..30u64 {
            let value = 100.0 + ((order as f64) * 0.37).sin() * 0.5;
            feed(&mut series, &template, value);
        }

        let state = series.get(SERIES).expect("series state present");
        // Window retains exactly the last window_size admitted values.
        assert_eq!(state.window_tail.len(), window_size);
        // Incremental rolling_acc agrees with a fresh two-pass over that tail.
        let two_pass = WelfordAcc::from_values(&state.window_tail);
        assert_eq!(state.rolling_acc.count, two_pass.count);
        assert_in_delta(state.rolling_acc.mean, two_pass.mean, 1.0e-9);
        assert_in_delta(state.rolling_acc.m2, two_pass.m2, 1.0e-6);
    }

    // (b) The active-edge emit fires exactly once when an anomaly opens and once
    // when it clears, not on every breached tick in between.
    #[test]
    fn active_edge_emits_once_on_open_and_once_on_clear() {
        let window_size = 8;
        let confirm_slots = 3;
        let template = template(window_size, 3, confirm_slots);
        let mut series = HashMap::new();

        let mut emits: Vec<String> = Vec::new();

        // Warm up a clean, ready baseline (no emits expected: never active).
        for _ in 0..10 {
            for result in feed(&mut series, &template, 100.0) {
                emits.push(result.ok.unwrap().state);
            }
        }
        assert!(emits.is_empty(), "clean baseline must not emit edges");

        // Sustained breach: the first (confirm_slots - 1) ticks are pending
        // (breached, not yet confirmed, not active) and must NOT emit; the tick
        // that crosses the confirm gate becomes anomalous and emits once (open).
        for _ in 0..6 {
            for result in feed(&mut series, &template, 100_000.0) {
                emits.push(result.ok.unwrap().state);
            }
        }
        assert_eq!(
            emits,
            vec!["anomalous"],
            "breach must emit exactly once on open"
        );

        // Return to clean: the first clean tick clears the active edge and emits
        // once; subsequent clean ticks are not active and must not emit.
        for _ in 0..6 {
            for result in feed(&mut series, &template, 100.0) {
                emits.push(result.ok.unwrap().state);
            }
        }
        assert_eq!(
            emits,
            vec!["anomalous", "clean"],
            "anomaly must emit once on open and once on clear, not every tick"
        );
    }

    // (c) A panicking batch item is isolated: it becomes an error result and the
    // remaining items in the batch still return.
    #[test]
    fn panicking_item_does_not_lose_rest_of_batch() {
        // Direct mechanism check.
        let ok: Result<u32, String> = catch_item_panic(|| Ok(7));
        assert_eq!(ok, Ok(7));
        let boom: Result<u32, String> = catch_item_panic(|| panic!("kaboom"));
        assert!(boom.unwrap_err().contains("kaboom"));

        // Batch-shaped check mirroring the production .map closures: only the
        // middle item panics; the others still produce results.
        let results: Vec<Result<u32, String>> = [0u32, 1, 2]
            .into_iter()
            .map(|item| {
                catch_item_panic(move || {
                    if item == 1 {
                        panic!("item {item} exploded");
                    }
                    Ok(item * 10)
                })
            })
            .collect();

        assert_eq!(results.len(), 3);
        assert_eq!(results[0], Ok(0));
        assert!(results[1].as_ref().unwrap_err().contains("exploded"));
        assert_eq!(results[2], Ok(20));
    }

    // (d) A stream long enough to drive well past RECOMPUTE_AFTER_EVICTIONS, at
    // 1e9 magnitude (where naive incremental variance loses precision), keeps the
    // rolling_acc within a tight bound of a fresh two-pass over the window tail.
    #[test]
    fn long_eviction_stream_stays_within_tight_bound_of_two_pass() {
        let window_size = 8;
        let template = template(window_size, 3, 5);
        let mut series = HashMap::new();

        // window_size fill + > RECOMPUTE_AFTER_EVICTIONS admitted evictions.
        let total = window_size as u64 + RECOMPUTE_AFTER_EVICTIONS as u64 + 64;
        for order in 0..total {
            // Tight jitter around 1e9 so every tick stays clean/admitted and the
            // window keeps evicting.
            let value = 1.0e9 + ((order as f64) * 0.13).sin() * 1.5;
            feed(&mut series, &template, value);
        }

        let state = series.get(SERIES).expect("series state present");
        assert_eq!(state.window_tail.len(), window_size);

        let incremental = state.rolling_acc.stats().expect("stats available");
        let two_pass = sample_stats(&state.window_tail);
        // At value ~1e9 a 1e-3 absolute bound is a ~1e-12 relative error: the
        // RECOMPUTE_AFTER_EVICTIONS guard keeps incremental variance from drifting.
        assert_in_delta(incremental.mean, two_pass.mean, 1.0e-3);
        assert_in_delta(incremental.stddev, two_pass.stddev, 1.0e-3);
    }
}
