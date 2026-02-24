//! Structures related to the physical mapping of generic topology tuples
//! into an actual analytical `Hypergraph` capable of solving causal inference.

/// A structured intermediate representation of a parsed network topology.
///
/// This intermediary struct builds the required indexing metadata and tallies
/// to convert user-submitted NIF node/edge arrays into the highly optimized
/// `CsrMatrix`-based incidence matrices necessary for standard `Hypergraph` engines.
#[derive(Debug, Clone, Default)]
pub(crate) struct HypergraphProjection {
    /// The exact count of active, bounded nodes derived from the raw sequence limits.
    pub(crate) num_nodes: usize,
    /// The computed total number of "hyperedges" acting upon this layout.
    pub(crate) num_hyperedges: usize,
    /// The linear cache of matrix triplet coordinates mapping connections: `(NodeIdx, EdgeIdx, Weight)`.
    pub(crate) incidence_triplets: Vec<(usize, usize, i8)>,
    /// The total count of anomalous edges that were purged due to out-of-range bounds errors.
    pub(crate) dropped_edges: usize,
}
