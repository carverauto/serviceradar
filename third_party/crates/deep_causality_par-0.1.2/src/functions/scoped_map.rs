/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Scoped fork-join over slices: the minimal in-house parallel-map surface
//! the workspace uses for **few, long-running, data-independent tasks**
//! such as counterfactual branch fan-outs and per-candidate evaluation
//! loops.
//!
//! [`scoped_map`] maps a function over a slice and returns the results in
//! input order. With the `parallel` feature the slice is split into
//! contiguous chunks, one per available core, and each chunk runs on a
//! [`std::thread::scope`] thread. The closure may therefore borrow from
//! the caller's stack; no thread pool is spun up, and a panic in any task
//! propagates on join. Without the feature it is exactly
//! `items.iter().map(f).collect()`; the [`MaybeParallel`] bounds are then
//! vacuous, so serial consumers see no `Send + Sync` requirements.
//!
//! This is deliberately not a work-stealing scheduler. Tasks are assumed
//! to be coarse and similar in cost, which is where a plain fork-join
//! matches Rayon without the dependency. For many small, irregular tasks a
//! real scheduler would win; nothing in the workspace needs one.

use crate::MaybeParallel;

/// Map `f` over `items`, preserving input order in the returned `Vec`.
///
/// With the `parallel` feature the work fans out over scoped threads, one
/// contiguous chunk per available core; without it the map runs inline.
/// For a deterministic `f` the results are identical in both modes. The
/// split only changes where each element is computed, never the order of
/// the output.
///
/// # Panics
/// If `f` panics on any element, the panic propagates to the caller when
/// the scope joins (parallel) or immediately (serial).
pub fn scoped_map<T, U, F>(items: &[T], f: F) -> Vec<U>
where
    T: MaybeParallel,
    U: MaybeParallel,
    F: Fn(&T) -> U + MaybeParallel,
{
    #[cfg(not(feature = "parallel"))]
    {
        items.iter().map(f).collect()
    }
    #[cfg(feature = "parallel")]
    {
        let threads = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(1)
            .min(items.len());
        if threads <= 1 {
            return items.iter().map(f).collect();
        }
        let mut out: Vec<Option<U>> = Vec::with_capacity(items.len());
        out.resize_with(items.len(), || None);
        let chunk = items.len().div_ceil(threads);
        let f_ref = &f;
        std::thread::scope(|scope| {
            for (in_chunk, out_chunk) in items.chunks(chunk).zip(out.chunks_mut(chunk)) {
                scope.spawn(move || {
                    for (item, slot) in in_chunk.iter().zip(out_chunk.iter_mut()) {
                        *slot = Some(f_ref(item));
                    }
                });
            }
        });
        out.into_iter()
            .map(|slot| slot.expect("scoped_map fills every slot"))
            .collect()
    }
}
