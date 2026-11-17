//! Batches of normalized records for one NATS message each.
//!
//! A batch holds records normalized by one ruleset. It closes when it reaches
//! its record or byte limit, when a record of another ruleset arrives, or when
//! its oldest record has waited the age limit. A record larger than the byte
//! limit is a batch of its own.

use super::frame;
use std::time::Duration;
use tokio::time::Instant;

#[derive(Clone, Copy, Debug)]
pub(crate) struct Limits {
    pub records: usize,
    pub bytes: usize,
    pub age: Duration,
}

/// A closed batch: a serialized `ExportLogsServiceRequest` and the digest of
/// the ruleset that normalized every record in it.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Batch {
    pub ruleset: String,
    pub payload: Vec<u8>,
    pub records: usize,
}

pub(crate) struct Batcher {
    limits: Limits,
    open: Option<(Batch, Instant)>,
}

impl Batcher {
    pub(crate) fn new(limits: Limits) -> Self {
        Self { limits, open: None }
    }

    /// Adds a framed record received at `now`. Returns the batch this closed,
    /// if any: the open batch when the record does not belong in it, or the
    /// batch the record completed.
    pub(crate) fn push(
        &mut self,
        record: &[u8],
        now: Instant,
    ) -> Result<Option<Batch>, &'static str> {
        let (ruleset, request) = frame::decode(record)?;
        let limits = self.limits;
        let belongs = self.open.as_ref().is_none_or(|(open, _)| {
            open.ruleset == ruleset && open.payload.len() + request.len() <= limits.bytes
        });
        let closed = if belongs { None } else { self.flush() };
        let (open, _) = self.open.get_or_insert_with(|| {
            let batch = Batch {
                ruleset: ruleset.to_owned(),
                payload: Vec::with_capacity(limits.bytes.min(request.len() * 16)),
                records: 0,
            };
            (batch, now + limits.age)
        });
        open.payload.extend_from_slice(request);
        open.records += 1;
        if closed.is_some() {
            return Ok(closed);
        }
        let full = open.records >= limits.records || open.payload.len() >= limits.bytes;
        Ok(if full { self.flush() } else { None })
    }

    /// When the open batch must be published even if no record arrives.
    pub(crate) fn deadline(&self) -> Option<Instant> {
        self.open.as_ref().map(|(_, deadline)| *deadline)
    }

    /// Closes the open batch.
    pub(crate) fn flush(&mut self) -> Option<Batch> {
        self.open.take().map(|(batch, _)| batch)
    }
}
