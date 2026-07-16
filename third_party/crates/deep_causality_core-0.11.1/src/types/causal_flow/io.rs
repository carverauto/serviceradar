/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

// =============================================================================
// IO bridge: enter a flow from a read, run a value-preserving write as a step
// =============================================================================
//
// A read and a write are not symmetric, so they are not one method:
//   * a read **produces** the value, so it is a constructor (`source` / `read_*_from`);
//   * a write runs for its **effect**, so it is a value-preserving step (`commit` / `write_*_to`)
//     that passes the carried value through unchanged — a write never collapses `CausalFlow<V>` to
//     `CausalFlow<()>`.
//
// `source` / `commit` are the generic bridge over any `IoAction`; the format-qualified verbs are
// thin wrappers over them plus the `std`-only file actions in `crate::types::io`.

use crate::types::causal_flow::{err_leaf, ok_leaf};
use crate::{CausalFlow, CausalityError};
use deep_causality_haft::{IoAction, LogAddEntry};

impl<Value> CausalFlow<Value, (), ()> {
    /// Start a flow from a composed [`IoAction`]: run it, and its `Output` becomes the initial value
    /// (or the error channel on failure). Records an `EffectLog` audit entry. Use for the power case
    /// where an action is composed (`read_text(p).map(parse)`) before entering the flow.
    pub fn source<P>(io: P) -> Self
    where
        P: IoAction<Output = Value, Error = CausalityError>,
    {
        match io.run() {
            Ok(value) => {
                let mut inner = ok_leaf(value, (), None);
                inner.logs.add_entry("io: source");
                CausalFlow { inner }
            }
            Err(err) => CausalFlow {
                inner: err_leaf(err, (), None),
            },
        }
    }
}

impl<Value, State, Context> CausalFlow<Value, State, Context> {
    /// Run a value-preserving [`IoAction`] step built from the carried value: the action executes for
    /// its side effect, the carried value **passes through unchanged**, and an `EffectLog` audit entry
    /// is appended. A failure routes to the error channel and short-circuits the rest of the flow.
    pub fn commit<P, F>(self, build: F) -> Self
    where
        F: FnOnce(&Value) -> P,
        P: IoAction<Output = (), Error = CausalityError>,
    {
        let inner = self.inner.bind_or_error(
            |v, state, context| {
                let io = build(&v);
                match io.run() {
                    Ok(()) => {
                        let mut leaf = ok_leaf(v, state, context);
                        leaf.logs.add_entry("io: commit");
                        leaf
                    }
                    Err(e) => err_leaf(e, state, context),
                }
            },
            "commit received no value",
        );
        CausalFlow { inner }
    }
}

// --- Format-qualified file verbs (std-only: they use the file actions) --------------------------

#[cfg(feature = "std")]
mod file_verbs {
    use super::*;
    use crate::types::io::{read_csv, read_text, write_csv, write_text};
    use alloc::string::String;
    use alloc::vec::Vec;
    use std::path::PathBuf;

    impl CausalFlow<String, (), ()> {
        /// Read constructor: start a flow whose value is the full text of the file at `path`.
        pub fn read_text_from(path: impl Into<PathBuf>) -> Self {
            CausalFlow::source(read_text(path))
        }
    }

    impl CausalFlow<Vec<Vec<String>>, (), ()> {
        /// Read constructor: start a flow whose value is the parsed CSV rows of the file at `path`.
        pub fn read_csv_from(path: impl Into<PathBuf>) -> Self {
            CausalFlow::source(read_csv(path))
        }
    }

    impl<Value, State, Context> CausalFlow<Value, State, Context> {
        /// Value-preserving write step: render `contents` from the carried value and write it to
        /// `path` as text. The carried value flows on unchanged.
        pub fn write_text_to<F>(self, path: impl Into<PathBuf>, contents: F) -> Self
        where
            F: FnOnce(&Value) -> String,
        {
            let path = path.into();
            self.commit(move |v| write_text(path, contents(v)))
        }

        /// Value-preserving write step: render CSV `rows` from the carried value and write them under
        /// `header` to `path`. The carried value flows on unchanged.
        pub fn write_csv_to<F>(self, path: impl Into<PathBuf>, header: Vec<String>, rows: F) -> Self
        where
            F: FnOnce(&Value) -> Vec<Vec<String>>,
        {
            let path = path.into();
            self.commit(move |v| write_csv(path, header, rows(v)))
        }
    }
}
