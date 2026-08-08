//! Shapes for the serialized causal-state bitmaps returned across the NIF boundary.

use rustler::Binary;

/// The four serialized causal-state bitmaps plus their cardinalities.
///
/// Tuple layout: `(root, affected, healthy, unknown, (root_count, affected_count,
/// healthy_count, unknown_count))`. The binaries are Roaring bitmaps over node
/// indexes, ordered to match the state encoding used by the causal evaluator.
pub(crate) type CausalStateBitmaps<'a> = (
    Binary<'a>,
    Binary<'a>,
    Binary<'a>,
    Binary<'a>,
    (u32, u32, u32, u32),
);
