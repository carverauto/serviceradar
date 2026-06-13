use crate::WINDOW_CAPACITY_MULTIPLE;
use crate::stats::WelfordAcc;
use crate::types::ReasonContext;
use deep_causality_data_structures::{SlidingWindow, VectorStorage, window_type};

pub(crate) type BaselineWindow = SlidingWindow<VectorStorage<f64>, f64>;

pub(crate) fn compact_rolling_state(
    context: &ReasonContext,
    window_size: usize,
) -> (Vec<f64>, WelfordAcc) {
    let source = context.window_tail.as_ref().unwrap_or(&context.baseline);
    let clean_values = clean_window_values(source, window_size);
    let acc = context
        .rolling_acc
        .filter(|acc| acc.valid_for_count(clean_values.len()))
        .unwrap_or_else(|| WelfordAcc::from_values(&clean_values));

    (clean_values, acc)
}

pub(crate) fn window_values(values: &[f64], window_size: usize) -> Vec<f64> {
    baseline_window(values, window_size)
        .vec()
        .unwrap_or_default()
}

fn baseline_window(values: &[f64], window_size: usize) -> BaselineWindow {
    let clean_values = clean_window_values(values, window_size);
    let effective_size = clean_values.len().min(window_size.max(1)).max(1);
    let mut window = window_type::new_with_vector_storage(effective_size, WINDOW_CAPACITY_MULTIPLE);

    for value in clean_values {
        window.push(value);
    }

    window
}

fn clean_window_values(values: &[f64], window_size: usize) -> Vec<f64> {
    values
        .iter()
        .copied()
        .filter(|value| value.is_finite())
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .take(window_size.max(1))
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect()
}
