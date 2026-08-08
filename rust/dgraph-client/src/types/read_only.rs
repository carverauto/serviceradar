/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

/// Type-state marker for a transaction that may only read.
///
/// Mutating or committing one is a compile error rather than a runtime error, and
/// best-effort reads are available only on this state.
///
/// See [`Txn`](crate::Txn).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ReadOnly;
