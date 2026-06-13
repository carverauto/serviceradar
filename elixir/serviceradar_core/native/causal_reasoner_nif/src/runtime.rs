use crate::detector::reason_impl;
use crate::stats::WelfordAcc;
use crate::types::{
    ReasonBatchResult, ReasonContext, ReasonEventBatchResult, ReasonEventVerdict, ReasonSample,
    ReasonVerdict,
};
use rustler::{NifMap, ResourceArc};
use std::collections::HashMap;
use std::sync::Mutex;

const RECOMPUTE_AFTER_EVICTIONS: usize = 1024;

pub(crate) struct RuntimeShardState {
    series: Mutex<HashMap<String, RuntimeSeriesState>>,
}

#[rustler::resource_impl]
impl rustler::Resource for RuntimeShardState {}

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
    let Ok(mut guard) = state.series.try_lock() else {
        return inputs
            .into_iter()
            .map(|_input| ReasonBatchResult {
                ok: None,
                error: Some("runtime shard state lock unavailable".to_string()),
            })
            .collect();
    };

    inputs
        .into_iter()
        .map(|input| {
            let series_key = input.series_key;
            let runtime = guard.entry(series_key.clone()).or_default().clone();
            let template = input.context;
            let context = runtime.context(template.clone());

            match reason_impl(context, input.sample) {
                Ok(verdict) => {
                    guard.insert(
                        series_key,
                        RuntimeSeriesState::from_verdict_after(&runtime, &template, &verdict),
                    );

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
    let Ok(mut guard) = state.series.try_lock() else {
        return inputs
            .into_iter()
            .map(|_input| ReasonEventBatchResult {
                ok: None,
                error: Some("runtime shard state lock unavailable".to_string()),
            })
            .collect();
    };

    inputs
        .into_iter()
        .map(|input| {
            let series_key = input.series_key;
            let runtime = guard.entry(series_key.clone()).or_default().clone();
            let template = input.context;
            let context = runtime.context(template.clone());

            match reason_impl(context, input.sample) {
                Ok(verdict) => {
                    guard.insert(
                        series_key,
                        RuntimeSeriesState::from_verdict_after(&runtime, &template, &verdict),
                    );

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
    let Ok(mut guard) = state.series.try_lock() else {
        return inputs
            .into_iter()
            .map(|input| ReasonIndexedEventResult {
                index: input.index,
                ok: None,
                error: Some("runtime shard state lock unavailable".to_string()),
            })
            .collect();
    };

    inputs
        .into_iter()
        .filter_map(|input| {
            let index = input.index;
            let series_key = input.series_key;
            let runtime = guard.entry(series_key.clone()).or_default().clone();
            let template = input.context;
            let context = runtime.context(template.clone());

            match reason_impl(context, input.sample) {
                Ok(verdict) => {
                    let emit = (verdict.anomalous && !runtime.active)
                        || (!verdict.breached && runtime.active);
                    let mut next_runtime =
                        RuntimeSeriesState::from_verdict_after(&runtime, &template, &verdict);
                    next_runtime.active = if verdict.anomalous {
                        true
                    } else if !verdict.breached {
                        false
                    } else {
                        runtime.active
                    };
                    guard.insert(series_key, next_runtime);

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
        "runtime shard state lock unavailable",
    )
}

pub(crate) fn reason_state_value_tuples_changes_impl(
    state: ResourceArc<RuntimeShardState>,
    inputs: Vec<ReasonIndexedValueTupleInput>,
) -> Vec<ReasonIndexedEventResult> {
    reason_state_value_items_changes_impl(state, inputs, "runtime shard state lock unavailable")
}

fn reason_state_value_items_changes_impl(
    state: ResourceArc<RuntimeShardState>,
    inputs: Vec<ReasonIndexedValueTupleInput>,
    lock_error: &'static str,
) -> Vec<ReasonIndexedEventResult> {
    let Ok(mut guard) = state.series.try_lock() else {
        return inputs
            .into_iter()
            .map(|input| ReasonIndexedEventResult {
                index: input.0,
                ok: None,
                error: Some(lock_error.to_string()),
            })
            .collect();
    };

    inputs
        .into_iter()
        .filter_map(|input| {
            let (index, series_key, input_context, value, observed_at_unix_nano) = input;
            let runtime = guard.entry(series_key).or_default();
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

            match reason_impl(context, sample) {
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
    let Ok(mut guard) = state.series.try_lock() else {
        return false;
    };

    guard.remove(&series_key).is_some()
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
            context: None,
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
