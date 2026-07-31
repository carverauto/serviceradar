/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

/// Type-state marker for a transaction that may mutate and commit.
///
/// See [`Txn`](crate::Txn).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ReadWrite;
