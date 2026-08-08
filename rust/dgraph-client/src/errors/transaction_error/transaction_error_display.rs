/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

use core::fmt::{Display, Formatter};

use super::{TransactionError, TransactionErrorEnum};

impl Display for TransactionError {
    fn fmt(&self, f: &mut Formatter<'_>) -> core::fmt::Result {
        match self.kind() {
            TransactionErrorEnum::Finished => write!(
                f,
                "Transaction Finished: the transaction has already been committed, discarded, or \
                 poisoned by a failed mutation"
            ),
            TransactionErrorEnum::ReadOnly => write!(
                f,
                "Read-Only Transaction: a read-only transaction cannot run mutations or be \
                 committed"
            ),
            TransactionErrorEnum::Aborted { code, message } => write!(
                f,
                "Transaction Aborted: the server aborted this transaction ({code:?}: {message}); \
                 retry in a new transaction"
            ),
            TransactionErrorEnum::StartTsMismatch {
                expected, found, ..
            } => write!(
                f,
                "Start Timestamp Mismatch: transaction was established at {expected} but the \
                 server reported {found}"
            ),
        }
    }
}
