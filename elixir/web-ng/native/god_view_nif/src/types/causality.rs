//! Representation of inference and root-cause analysis conclusions.
//!
//! Contains bindings mapped directly back into Elixir formats using `NifMap`.

use rustler::NifMap;

/// Describes a single node's determined causal status in a network topology graph.
///
/// Used broadly by God View causal evaluations to return rich human-readable
/// reasons and contextual metrics about why a specific state (e.g. affectation
/// or root failure) was projected onto a device.
#[derive(Debug, Clone, NifMap)]
pub(crate) struct CausalStateReasonRow {
    /// The resulting encoded state (e.g., 0 = root, 1 = affected, 2 = healthy, 3 = unknown).
    pub(crate) state: u8,
    /// The textual, programmatic reason why this specific state was assigned.
    pub(crate) reason: String,
    /// The integer array index pointing back to the core node flagged as the `root` failure.
    pub(crate) root_index: i64,
    /// The nearest parent node leading back to the `root` failure node in the hierarchy.
    pub(crate) parent_index: i64,
    /// The traversal distance (in hops) calculated between this node and the root node.
    pub(crate) hop_distance: i64,
}
