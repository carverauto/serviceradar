/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

use super::Txn;

// Drop cannot await, so it deliberately performs no I/O. A mutated transaction that was
// never completed leaves server-side state behind until the cluster times it out; warn
// loudly rather than pretend otherwise or spawn hidden work on an unknown runtime.
impl<State> Drop for Txn<State> {
    fn drop(&mut self) {
        if self.mutated && !self.finished {
            tracing::warn!(
                start_ts = self.start_ts,
                "transaction dropped after mutating without commit or discard; server-side state \
                 will persist until the cluster times it out. Call commit() or discard()."
            );
        }
    }
}
