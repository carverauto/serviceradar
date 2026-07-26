/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

//! Operations available only on a read-only transaction.

use super::Txn;
use crate::types::read_only::ReadOnly;

impl Txn<ReadOnly> {
    /// Ask the alpha to serve reads from memory where it can, rather than fetching a
    /// timestamp from zero. This trades strict freshness for lower latency.
    ///
    /// Only exists on read-only transactions. The Go client exposes this on every
    /// transaction and panics at runtime when the transaction is not read-only; here the
    /// same mistake does not compile.
    pub fn best_effort(mut self) -> Self {
        self.best_effort = true;
        self
    }

    /// Whether best-effort reads were requested.
    pub fn is_best_effort(&self) -> bool {
        self.best_effort
    }
}
