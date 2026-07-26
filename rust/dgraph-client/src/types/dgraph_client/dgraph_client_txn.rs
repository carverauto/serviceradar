/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

//! Transaction constructors.

use super::DgraphClient;
use crate::types::read_only::ReadOnly;
use crate::types::read_write::ReadWrite;
use crate::types::txn::Txn;

impl DgraphClient {
    /// Start a read-write transaction.
    ///
    /// Complete it with `commit` or `discard`. Dropping one that mutated without
    /// completing leaks server-side state until the cluster times it out, and logs a
    /// warning.
    pub fn new_txn(&self) -> Txn<ReadWrite> {
        Txn::create(self.clone(), false)
    }

    /// Start a read-only transaction.
    ///
    /// Mutating or committing the result is a compile error. Chain
    /// [`best_effort`](Txn::best_effort) to allow the alpha to serve reads from memory.
    pub fn new_read_only_txn(&self) -> Txn<ReadOnly> {
        Txn::create(self.clone(), true)
    }
}
