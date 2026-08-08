//! Cumulative decoded-output accounting shared by NetFlow v9 and IPFIX.

use crate::variable_versions::wire::{
    RecordBodyKind, minimum_record_size, record_body_is_complete,
};

/// Default maximum number of decoded field values returned by one message.
pub const DEFAULT_MAX_DECODED_FIELD_VALUES_PER_MESSAGE: usize = 65_536;

/// Default maximum number of decoded field payload bytes returned by one message.
pub const DEFAULT_MAX_DECODED_FIELD_PAYLOAD_BYTES_PER_MESSAGE: usize = 4 * 1024 * 1024;

/// The cumulative decoded-output limit that rejected a message.
#[non_exhaustive]
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
pub enum DecodedOutputLimit {
    /// Number of materialized field values.
    FieldValues,
    /// Sum of materialized field content bytes.
    FieldPayloadBytes,
}

/// Finite limits for advanced one-body `Data` and `OptionsData` parsing.
///
/// Use [`DecodedOutputLimits::new`] to override the same finite defaults used
/// by the stateful parser. All three values must be greater than zero.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DecodedOutputLimits {
    max_records: usize,
    max_field_values: usize,
    max_field_payload_bytes: usize,
}

impl DecodedOutputLimits {
    /// Validate and create a bounded one-body parsing policy.
    pub fn new(
        max_records: usize,
        max_field_values: usize,
        max_field_payload_bytes: usize,
    ) -> Result<Self, crate::ConfigError> {
        if max_records == 0 {
            return Err(crate::ConfigError::InvalidRecordsPerFlowset(0));
        }
        if max_field_values == 0 {
            return Err(crate::ConfigError::InvalidDecodedFieldValueLimit(0));
        }
        if max_field_payload_bytes == 0 {
            return Err(crate::ConfigError::InvalidDecodedFieldPayloadByteLimit(0));
        }
        Ok(Self {
            max_records,
            max_field_values,
            max_field_payload_bytes,
        })
    }

    pub(crate) fn max_records(self) -> usize {
        self.max_records
    }

    pub(crate) fn budget(self) -> DecodedOutputBudget {
        DecodedOutputBudget::new(self.max_field_values, self.max_field_payload_bytes)
    }
}

impl Default for DecodedOutputLimits {
    fn default() -> Self {
        Self {
            max_records: crate::DEFAULT_MAX_RECORDS_PER_FLOWSET,
            max_field_values: DEFAULT_MAX_DECODED_FIELD_VALUES_PER_MESSAGE,
            max_field_payload_bytes: DEFAULT_MAX_DECODED_FIELD_PAYLOAD_BYTES_PER_MESSAGE,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct OutputBudgetExceeded {
    pub(crate) limit: DecodedOutputLimit,
    pub(crate) configured: usize,
    pub(crate) attempted: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PendingOutputError {
    TemporarilyDoesNotFit,
    NeverFits,
    Invalid,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PendingReplayOutcome {
    Replayed,
    TemporarilyDoesNotFit,
    Failed,
}

/// Exact allocation-free framing and decoded-cost result for one queued body.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct PendingOutputPreflight {
    field_values: usize,
    field_payload_bytes: usize,
    remainder_len: usize,
}

impl PendingOutputPreflight {
    #[inline]
    fn cost(self) -> (usize, usize) {
        (self.field_values, self.field_payload_bytes)
    }
}

impl From<PendingOutputError> for PendingReplayOutcome {
    fn from(error: PendingOutputError) -> Self {
        match error {
            PendingOutputError::TemporarilyDoesNotFit => Self::TemporarilyDoesNotFit,
            PendingOutputError::NeverFits | PendingOutputError::Invalid => Self::Failed,
        }
    }
}

/// Per-message accounting state. It is reset before every independently parsed
/// v9/IPFIX message and deliberately performs no allocation.
#[derive(Debug, Clone)]
pub(crate) struct DecodedOutputBudget {
    max_values: usize,
    max_payload_bytes: usize,
    used_values: usize,
    used_payload_bytes: usize,
    exceeded: Option<OutputBudgetExceeded>,
}

impl DecodedOutputBudget {
    pub(crate) fn new(max_values: usize, max_payload_bytes: usize) -> Self {
        Self {
            max_values,
            max_payload_bytes,
            used_values: 0,
            used_payload_bytes: 0,
            exceeded: None,
        }
    }

    #[inline]
    pub(crate) fn reset(&mut self) {
        self.used_values = 0;
        self.used_payload_bytes = 0;
        self.exceeded = None;
    }

    pub(crate) fn set_limits(&mut self, max_values: usize, max_payload_bytes: usize) {
        self.max_values = max_values;
        self.max_payload_bytes = max_payload_bytes;
        self.reset();
    }

    #[inline]
    pub(crate) fn checkpoint(&self) -> (usize, usize) {
        (self.used_values, self.used_payload_bytes)
    }

    #[inline]
    pub(crate) fn rollback(&mut self, checkpoint: (usize, usize)) {
        self.used_values = checkpoint.0;
        self.used_payload_bytes = checkpoint.1;
        self.exceeded = None;
    }

    #[inline]
    pub(crate) fn reserve(
        &mut self,
        values: usize,
        payload_bytes: usize,
    ) -> Result<(), OutputBudgetExceeded> {
        let Some(attempted_values) = self.used_values.checked_add(values) else {
            return Err(self.record_exceeded(DecodedOutputLimit::FieldValues, usize::MAX));
        };
        if attempted_values > self.max_values {
            return Err(self.record_exceeded(DecodedOutputLimit::FieldValues, attempted_values));
        }

        let Some(attempted_payload) = self.used_payload_bytes.checked_add(payload_bytes) else {
            return Err(self.record_exceeded(DecodedOutputLimit::FieldPayloadBytes, usize::MAX));
        };
        if attempted_payload > self.max_payload_bytes {
            return Err(
                self.record_exceeded(DecodedOutputLimit::FieldPayloadBytes, attempted_payload)
            );
        }

        self.used_values = attempted_values;
        self.used_payload_bytes = attempted_payload;
        Ok(())
    }

    #[inline]
    fn record_exceeded(
        &mut self,
        limit: DecodedOutputLimit,
        attempted: usize,
    ) -> OutputBudgetExceeded {
        let configured = match limit {
            DecodedOutputLimit::FieldValues => self.max_values,
            DecodedOutputLimit::FieldPayloadBytes => self.max_payload_bytes,
        };
        let exceeded = OutputBudgetExceeded {
            limit,
            configured,
            attempted,
        };
        self.exceeded.get_or_insert(exceeded);
        exceeded
    }

    #[inline]
    pub(crate) fn take_exceeded(&mut self) -> Option<OutputBudgetExceeded> {
        self.exceeded.take()
    }

    #[inline]
    pub(crate) fn is_exceeded(&self) -> bool {
        self.exceeded.is_some()
    }

    #[inline]
    pub(crate) fn used(&self) -> (usize, usize) {
        (self.used_values, self.used_payload_bytes)
    }

    #[inline]
    pub(crate) fn remaining(&self) -> (usize, usize) {
        (
            self.max_values.saturating_sub(self.used_values),
            self.max_payload_bytes
                .saturating_sub(self.used_payload_bytes),
        )
    }

    /// Preflight one queued body, materialize it only when it fits the current
    /// message, then commit its actual decoded cost.
    pub(crate) fn materialize_pending<'a, T, E>(
        &mut self,
        preflight: Option<PendingOutputPreflight>,
        parse: impl FnOnce(&mut DecodedOutputBudget) -> Result<(&'a [u8], T), E>,
    ) -> Result<(T, usize), PendingOutputError> {
        let preflight = self.validate_pending_full_budget(preflight)?;
        self.validate_pending_remaining(preflight)?;
        let measured = preflight.cost();

        let mut scratch = Self::new(self.max_values, self.max_payload_bytes);
        let (remaining, value) =
            parse(&mut scratch).map_err(|_| PendingOutputError::Invalid)?;
        let actual = scratch.used();
        if actual != measured || remaining.len() != preflight.remainder_len {
            return Err(PendingOutputError::Invalid);
        }
        if self.reserve(actual.0, actual.1).is_err() {
            return Err(PendingOutputError::Invalid);
        }
        Ok((value, preflight.remainder_len))
    }

    pub(crate) fn validate_pending_full_budget(
        &self,
        preflight: Option<PendingOutputPreflight>,
    ) -> Result<PendingOutputPreflight, PendingOutputError> {
        let Some(preflight) = preflight else {
            return Err(PendingOutputError::Invalid);
        };
        let measured = preflight.cost();
        if measured.0 > self.max_values || measured.1 > self.max_payload_bytes {
            return Err(PendingOutputError::NeverFits);
        }
        Ok(preflight)
    }

    pub(crate) fn validate_pending_remaining(
        &self,
        preflight: PendingOutputPreflight,
    ) -> Result<(), PendingOutputError> {
        let measured = preflight.cost();
        let remaining = self.remaining();
        if measured.0 > remaining.0 || measured.1 > remaining.1 {
            return Err(PendingOutputError::TemporarilyDoesNotFit);
        }
        Ok(())
    }
}

pub(crate) fn measure_fixed_output<T>(
    input: &[u8],
    fields: &[T],
    max_records: usize,
    width: impl Fn(&T) -> u16,
    body_kind: RecordBodyKind,
) -> Option<PendingOutputPreflight> {
    if fields.is_empty() {
        return None;
    }
    measure_fixed_widths(
        input,
        fields.len(),
        fields.iter().map(width),
        max_records,
        body_kind,
    )
}

pub(crate) fn measure_fixed_widths(
    input: &[u8],
    field_count: usize,
    widths: impl IntoIterator<Item = u16>,
    max_records: usize,
    body_kind: RecordBodyKind,
) -> Option<PendingOutputPreflight> {
    if field_count == 0 {
        return None;
    }
    let payload_per_record = minimum_record_size(widths, None)?;
    if payload_per_record == 0 {
        return None;
    }
    let records = (input.len() / payload_per_record).min(max_records);
    let consumed = records.checked_mul(payload_per_record)?;
    let remainder = input.get(consumed..)?;
    if !record_body_is_complete(records, remainder, payload_per_record, body_kind) {
        return None;
    }
    Some(PendingOutputPreflight {
        field_values: records.checked_mul(field_count)?,
        field_payload_bytes: consumed,
        remainder_len: remainder.len(),
    })
}

pub(crate) fn measure_variable_output<T>(
    mut input: &[u8],
    fields: &[T],
    max_records: usize,
    width: impl Fn(&T) -> u16,
    body_kind: RecordBodyKind,
) -> Option<PendingOutputPreflight> {
    if fields.is_empty() {
        return None;
    }

    let minimum_record_size = minimum_record_size(fields.iter().map(&width), Some(u16::MAX))?;
    if minimum_record_size == 0 {
        return None;
    }

    let mut records = 0usize;
    let mut payload_bytes = 0usize;
    while !input.is_empty() && records < max_records {
        let Some((remaining, record_payload)) = scan_variable_record(input, fields, &width)
        else {
            break;
        };
        input = remaining;
        records = records.checked_add(1)?;
        payload_bytes = payload_bytes.checked_add(record_payload)?;
    }
    if !record_body_is_complete(records, input, minimum_record_size, body_kind) {
        return None;
    }
    Some(PendingOutputPreflight {
        field_values: records.checked_mul(fields.len())?,
        field_payload_bytes: payload_bytes,
        remainder_len: input.len(),
    })
}

/// Scan one complete variable-width record without allocating. The returned
/// payload excludes RFC 7011 length prefixes. `None` means the bytes form only
/// an incomplete trailing record/padding or the template cannot make progress.
pub(crate) fn scan_variable_record<'a, T>(
    input: &'a [u8],
    fields: &[T],
    width: impl Fn(&T) -> u16,
) -> Option<(&'a [u8], usize)> {
    let mut remaining = input;
    let mut payload_bytes = 0usize;
    for field in fields {
        let content_length = match width(field) {
            u16::MAX => {
                let (&first, rest) = remaining.split_first()?;
                remaining = rest;
                if first == 255 {
                    let bytes = remaining.get(..2)?;
                    remaining = &remaining[2..];
                    usize::from(u16::from_be_bytes([bytes[0], bytes[1]]))
                } else {
                    usize::from(first)
                }
            }
            fixed => usize::from(fixed),
        };
        remaining = remaining.get(content_length..)?;
        payload_bytes = payload_bytes.checked_add(content_length)?;
    }
    (remaining.len() < input.len()).then_some((remaining, payload_bytes))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    fn preflight(field_values: usize, field_payload_bytes: usize) -> PendingOutputPreflight {
        PendingOutputPreflight {
            field_values,
            field_payload_bytes,
            remainder_len: 0,
        }
    }

    #[test]
    fn pending_preflight_does_not_materialize_when_current_message_is_full() {
        let mut budget = DecodedOutputBudget::new(2, 2);
        budget.reserve(1, 1).unwrap();
        let called = Cell::new(false);

        let result =
            budget.materialize_pending(Some(preflight(2, 2)), |_: &mut DecodedOutputBudget| {
                called.set(true);
                Ok::<_, ()>((&[][..], ()))
            });

        assert_eq!(result, Err(PendingOutputError::TemporarilyDoesNotFit));
        assert!(!called.get());
    }

    #[test]
    fn pending_preflight_does_not_materialize_an_entry_that_can_never_fit() {
        for cost in [(3, 1), (1, 3)] {
            let mut budget = DecodedOutputBudget::new(2, 2);
            let called = Cell::new(false);

            let result = budget.materialize_pending(
                Some(preflight(cost.0, cost.1)),
                |_: &mut DecodedOutputBudget| {
                    called.set(true);
                    Ok::<_, ()>((&[][..], ()))
                },
            );

            assert_eq!(result, Err(PendingOutputError::NeverFits));
            assert!(!called.get());
        }
    }

    #[test]
    fn pending_materialization_rejects_a_preflight_cost_mismatch() {
        let mut budget = DecodedOutputBudget::new(3, 3);

        let result = budget.materialize_pending(Some(preflight(1, 1)), |scratch| {
            scratch.reserve(2, 1).unwrap();
            Ok::<_, ()>((&[][..], ()))
        });

        assert_eq!(result, Err(PendingOutputError::Invalid));
        assert_eq!(budget.used(), (0, 0));
    }

    #[test]
    fn pending_materialization_rejects_a_preflight_boundary_mismatch() {
        let mut budget = DecodedOutputBudget::new(3, 3);
        let expected = PendingOutputPreflight {
            field_values: 1,
            field_payload_bytes: 1,
            remainder_len: 1,
        };

        let result = budget.materialize_pending(Some(expected), |scratch| {
            scratch.reserve(1, 1).unwrap();
            Ok::<_, ()>((&[][..], ()))
        });

        assert_eq!(result, Err(PendingOutputError::Invalid));
        assert_eq!(budget.used(), (0, 0));
    }

    #[test]
    fn wire_preflight_counts_both_zero_length_prefixes_as_progress() {
        let widths = [u16::MAX, 1];
        for input in [&[0, 7][..], &[255, 0, 0, 7][..]] {
            assert_eq!(
                scan_variable_record(input, &widths, |width| *width),
                Some((&[][..], 1))
            );
            assert_eq!(
                measure_variable_output(
                    input,
                    &widths,
                    1,
                    |width| *width,
                    RecordBodyKind::Ipfix,
                )
                .map(PendingOutputPreflight::cost),
                Some((2, 1)),
            );
        }
    }

    #[test]
    fn exact_limits_succeed_and_one_over_is_reported() {
        let mut budget = DecodedOutputBudget::new(2, 4);
        assert!(budget.reserve(2, 4).is_ok());
        assert_eq!(budget.used(), (2, 4));

        let error = budget.reserve(1, 0).unwrap_err();
        assert_eq!(error.limit, DecodedOutputLimit::FieldValues);
        assert_eq!(error.configured, 2);
        assert_eq!(error.attempted, 3);
        assert_eq!(budget.used(), (2, 4));
    }

    #[test]
    fn checked_overflow_is_a_limit_failure() {
        let mut budget = DecodedOutputBudget::new(usize::MAX - 1, usize::MAX - 1);
        assert!(budget.reserve(usize::MAX - 2, 0).is_ok());
        let error = budget.reserve(4, 0).unwrap_err();
        assert_eq!(error.attempted, usize::MAX);
    }

    #[test]
    fn value_overflow_is_rejected_at_the_maximum_limit() {
        let mut budget = DecodedOutputBudget::new(usize::MAX, usize::MAX);
        assert!(budget.reserve(usize::MAX - 1, 0).is_ok());

        let error = budget.reserve(2, 0).unwrap_err();
        assert_eq!(error.limit, DecodedOutputLimit::FieldValues);
        assert_eq!(error.configured, usize::MAX);
        assert_eq!(error.attempted, usize::MAX);
        assert_eq!(budget.used(), (usize::MAX - 1, 0));
    }

    #[test]
    fn payload_overflow_is_rejected_at_the_maximum_limit() {
        let mut budget = DecodedOutputBudget::new(usize::MAX, usize::MAX);
        assert!(budget.reserve(0, usize::MAX - 1).is_ok());

        let error = budget.reserve(0, 2).unwrap_err();
        assert_eq!(error.limit, DecodedOutputLimit::FieldPayloadBytes);
        assert_eq!(error.configured, usize::MAX);
        assert_eq!(error.attempted, usize::MAX);
        assert_eq!(budget.used(), (0, usize::MAX - 1));
    }

    #[test]
    fn rollback_restores_both_counters_and_failure_state() {
        let mut budget = DecodedOutputBudget::new(2, 2);
        let checkpoint = budget.checkpoint();
        assert!(budget.reserve(2, 2).is_ok());
        assert!(budget.reserve(1, 0).is_err());
        budget.rollback(checkpoint);
        assert_eq!(budget.used(), (0, 0));
        assert!(budget.take_exceeded().is_none());
    }

    #[test]
    fn public_limits_reject_zero_values() {
        assert!(DecodedOutputLimits::new(0, 1, 1).is_err());
        assert!(DecodedOutputLimits::new(1, 0, 1).is_err());
        assert!(DecodedOutputLimits::new(1, 1, 0).is_err());
    }
}
