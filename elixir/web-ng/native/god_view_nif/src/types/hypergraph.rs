#[derive(Debug, Clone, Default)]
pub struct HypergraphProjection {
    pub num_nodes: usize,
    pub num_hyperedges: usize,
    pub incidence_triplets: Vec<(usize, usize, i8)>,
    pub dropped_edges: usize,
}
