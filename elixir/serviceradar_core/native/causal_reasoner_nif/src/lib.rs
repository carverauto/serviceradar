mod detector;
mod runtime;
mod signal;
mod stats;
#[cfg(test)]
mod tests;
mod types;
mod window;

use detector::reason_impl;
use runtime::{
    ReasonIndexedEventResult, ReasonIndexedSeriesInput, ReasonIndexedValueInput,
    ReasonIndexedValueTupleInput, ReasonSeriesInput, RuntimeShardState, forget_series_impl,
    new_runtime_shard_state, reason_state_batch_changes_impl, reason_state_batch_events_impl,
    reason_state_batch_impl, reason_state_value_tuples_changes_impl,
    reason_state_values_changes_impl,
};
use rustler::ResourceArc;
use types::{
    ReasonBatchInput, ReasonBatchResult, ReasonContext, ReasonEventBatchResult, ReasonSample,
    ReasonVerdict,
};

const DEFAULT_MIN_SAMPLES: usize = 30;
const DEFAULT_WINDOW_SIZE: usize = 300;
const DEFAULT_N_SIGMA: f64 = 3.0;
const DEFAULT_CONFIRM_SLOTS: usize = 5;
const WINDOW_CAPACITY_MULTIPLE: usize = 2;

#[rustler::nif(schedule = "DirtyCpu")]
fn reason(context: ReasonContext, sample: ReasonSample) -> Result<ReasonVerdict, String> {
    reason_impl(context, sample)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn reason_batch(inputs: Vec<ReasonBatchInput>) -> Vec<ReasonBatchResult> {
    reason_batch_impl(inputs)
}

#[rustler::nif]
fn new_shard_state() -> ResourceArc<RuntimeShardState> {
    new_runtime_shard_state()
}

#[rustler::nif(schedule = "DirtyCpu")]
fn reason_state_batch(
    state: ResourceArc<RuntimeShardState>,
    inputs: Vec<ReasonSeriesInput>,
) -> Vec<ReasonBatchResult> {
    reason_state_batch_impl(state, inputs)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn reason_state_batch_events(
    state: ResourceArc<RuntimeShardState>,
    inputs: Vec<ReasonSeriesInput>,
) -> Vec<ReasonEventBatchResult> {
    reason_state_batch_events_impl(state, inputs)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn reason_state_batch_changes(
    state: ResourceArc<RuntimeShardState>,
    inputs: Vec<ReasonIndexedSeriesInput>,
) -> Vec<ReasonIndexedEventResult> {
    reason_state_batch_changes_impl(state, inputs)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn reason_state_values_changes(
    state: ResourceArc<RuntimeShardState>,
    inputs: Vec<ReasonIndexedValueInput>,
) -> Vec<ReasonIndexedEventResult> {
    reason_state_values_changes_impl(state, inputs)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn reason_state_value_tuples_changes(
    state: ResourceArc<RuntimeShardState>,
    inputs: Vec<ReasonIndexedValueTupleInput>,
) -> Vec<ReasonIndexedEventResult> {
    reason_state_value_tuples_changes_impl(state, inputs)
}

#[rustler::nif]
fn forget_series(state: ResourceArc<RuntimeShardState>, series_key: String) -> bool {
    forget_series_impl(state, series_key)
}

pub(crate) fn reason_batch_impl(inputs: Vec<ReasonBatchInput>) -> Vec<ReasonBatchResult> {
    inputs
        .into_iter()
        .map(|input| match reason_impl(input.context, input.sample) {
            Ok(verdict) => ReasonBatchResult {
                ok: Some(verdict),
                error: None,
            },
            Err(error) => ReasonBatchResult {
                ok: None,
                error: Some(error),
            },
        })
        .collect()
}

rustler::init!(
    "Elixir.ServiceRadar.Observability.CausalReasoner.Native",
    load = runtime::on_load
);
