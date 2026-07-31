/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::types::storage::graph_csm::CsrAdjacency;
use crate::{CsmGraph, DynamicGraph, Freezable, GraphView};

// Refers to the number of outgoing edges for a single node,
// which is also known as the node's degree.
const RADIX_SORT_THRESHOLD: usize = 128;

// This implementation requires that the edge weight `W` is both `Clone` (to be
// duplicated for the forward and backward graphs) and `Default` (to allow for
// efficient, safe allocation of the final adjacency vectors).
impl<N, W> Freezable<N, W> for DynamicGraph<N, W>
where
    N: Clone,
    W: Clone + Default,
{
    /// Consumes the dynamic graph to create a static, high-performance `CsmGraph`.
    ///
    /// This is a computationally intensive "stop the world" operation with O(V + E)
    /// complexity. It performs several key optimizations:
    ///   1. Removes "tombstoned" (deleted) nodes and re-indexes the graph.
    ///   2. Builds both forward and backward CSR structures in a single pass to save memory.
    ///   3. Sorts all adjacency lists for fast O(log degree) edge checking in the `CsmGraph`.
    ///
    /// # Infallibility and Design
    ///
    /// This method is **infallible** and does not return a `Result`. This is a
    /// deliberate architectural choice based on the following guarantees:
    ///
    /// 1.  **Guaranteed Input Integrity:** The `freeze` method consumes `self`, taking
    ///     ownership of a `DynamicGraph`. The internal structure of `DynamicGraph`,
    ///     while flexible, is always in a valid, well-defined state (e.g., its
    ///     `nodes` and `edges` vectors are guaranteed to be of equal length).
    ///
    /// 2.  **Deterministic Transformation:** The entire operation is a deterministic
    ///     data transformation. It converts one valid data structure into another.
    ///     Every step—compacting nodes, remapping indices, counting degrees, and
    ///     placing edges—is based on the state of the input graph. There are no
    ///     external inputs or logical conditions that can cause a recoverable runtime
    ///     failure.
    ///
    /// An error such as an out-of-bounds index during this process would indicate a
    /// critical bug in the `freeze` implementation itself. Such a programmer error
    /// should rightly cause a `panic`, as it represents an invalid program state,
    /// not a runtime error that a user could handle. This infallible signature
    /// provides a strong guarantee: transitioning from an evolutionary state to an
    /// analysis state is always a safe and predictable operation.
    fn freeze(self) -> CsmGraph<N, W> {
        //  Add a guard clause for an empty graph.
        if self.is_empty() {
            return CsmGraph::new();
        }

        // --- First Pass: Counting and Compacting ---

        let old_nodes = self.nodes;
        let old_edges = self.edges;
        let old_root_index = self.root_index;

        let mut compacted_nodes = Vec::with_capacity(old_nodes.len());
        let mut remapping_table = vec![0; old_nodes.len()];
        let mut is_tombstoned = vec![false; old_nodes.len()];
        let mut new_root_index = None;
        let mut total_edges = 0;

        // Compact the node list, create the remapping table, and track tombstones.
        for (old_index, node_opt) in old_nodes.into_iter().enumerate() {
            if let Some(node) = node_opt {
                let new_index = compacted_nodes.len();
                remapping_table[old_index] = new_index;
                compacted_nodes.push(node);

                if old_root_index == Some(old_index) {
                    new_root_index = Some(new_index);
                }
            } else {
                // Mark this index as tombstoned for later checks.
                is_tombstoned[old_index] = true;
            }
        }
        compacted_nodes.shrink_to_fit();
        let num_new_nodes = compacted_nodes.len();

        if num_new_nodes == 0 {
            return CsmGraph::new();
        }

        // Count degrees for the new, compacted graph.
        let mut out_degrees = vec![0; num_new_nodes];
        let mut in_degrees = vec![0; num_new_nodes];

        for (old_source_idx, edge_list) in old_edges.iter().enumerate() {
            if !is_tombstoned[old_source_idx] {
                let new_source_idx = remapping_table[old_source_idx];
                for (old_target_idx, _) in edge_list {
                    if !is_tombstoned[*old_target_idx] {
                        let new_target_idx = remapping_table[*old_target_idx];
                        out_degrees[new_source_idx] += 1;
                        in_degrees[new_target_idx] += 1;
                        total_edges += 1;
                    }
                }
            }
        }

        // --- Offset Calculation ---
        // Use the fast sequential helper for this step.
        let fwd_offsets = calculate_offsets_sequential(&out_degrees);
        let back_offsets = calculate_offsets_sequential(&in_degrees);

        // --- Second Pass: Placement ---
        let mut fwd_targets = vec![0; total_edges];
        let mut fwd_weights = vec![W::default(); total_edges];
        let mut back_targets = vec![0; total_edges];
        let mut back_weights = vec![W::default(); total_edges];

        let mut fwd_offsets_copy = fwd_offsets.clone();
        let mut back_offsets_copy = back_offsets.clone();

        // Place each edge into its correct position in the CSR arrays.
        for (old_source_idx, edge_list) in old_edges.into_iter().enumerate() {
            if !is_tombstoned[old_source_idx] {
                let new_source_idx = remapping_table[old_source_idx];
                for (old_target_idx, weight) in edge_list {
                    if !is_tombstoned[old_target_idx] {
                        let new_target_idx = remapping_table[old_target_idx];

                        // Forward placement
                        let fwd_write_head = fwd_offsets_copy[new_source_idx];
                        fwd_targets[fwd_write_head] = new_target_idx;
                        fwd_weights[fwd_write_head] = weight.clone();
                        fwd_offsets_copy[new_source_idx] += 1;

                        // Backward placement
                        let back_write_head = back_offsets_copy[new_target_idx];
                        back_targets[back_write_head] = new_source_idx;
                        back_weights[back_write_head] = weight;
                        back_offsets_copy[new_target_idx] += 1;
                    }
                }
            }
        }

        // --- Final Step: Sequential Sorting ---
        // Sort the adjacency lists for each node to enable binary search lookups.
        for i in 0..num_new_nodes {
            // Sort forward edges
            let start = fwd_offsets[i];
            let end = fwd_offsets[i + 1];
            if start < end {
                sort_single_adjacency_list(
                    &mut fwd_targets[start..end],
                    &mut fwd_weights[start..end],
                );
            }

            // Sort backward edges
            let start = back_offsets[i];
            let end = back_offsets[i + 1];
            if start < end {
                sort_single_adjacency_list(
                    &mut back_targets[start..end],
                    &mut back_weights[start..end],
                );
            }
        }

        // --- Final Construction ---
        let forward_edges = CsrAdjacency {
            offsets: fwd_offsets,
            targets: fwd_targets,
            weights: fwd_weights,
        };
        let backward_edges = CsrAdjacency {
            offsets: back_offsets,
            targets: back_targets,
            weights: back_weights,
        };

        CsmGraph::construct(
            compacted_nodes,
            forward_edges,
            backward_edges,
            new_root_index,
        )
    }
}

/// A fast, sequential implementation of a prefix sum (cumulative sum).
/// This is used to calculate the CSR offset arrays. While it's sequential, it is
/// extremely cache-friendly and often faster than a parallel version for all but
/// the most massive graphs due to the lack of coordination overhead.
fn calculate_offsets_sequential(degrees: &[usize]) -> Vec<usize> {
    let mut offsets = Vec::with_capacity(degrees.len() + 1);
    let mut total = 0;
    offsets.push(total);
    for &degree in degrees {
        total += degree;
        offsets.push(total);
    }
    offsets
}

/// Helper function to sort a single adjacency list within the CSR arrays.
/// This is now an ADAPTIVE sorter when targets.len exceeds RADIX_SORT_THRESHOLD
fn sort_single_adjacency_list<W>(targets: &mut [usize], weights: &mut [W])
where
    W: Clone + Default,
{
    if targets.len() < RADIX_SORT_THRESHOLD {
        // For small lists, the overhead of Radix Sort isn't worth it.
        // The simple, allocation-based comparison sort is faster.
        let mut slice_to_sort: Vec<_> = targets
            .iter()
            .zip(weights.iter())
            .map(|(&t, w)| (t, w.clone()))
            .collect();

        slice_to_sort.sort_unstable_by_key(|(target, _)| *target);

        for (j, (target, weight)) in slice_to_sort.into_iter().enumerate() {
            targets[j] = target;
            weights[j] = weight;
        }
    } else {
        // For larger lists, use the allocation-free,
        // high-performance Radix Sort.
        radix_sort_adjacencies(targets, weights);
    }
}
/// A highly optimized, allocation-free Radix Sort for our specific CSR layout.
///
/// This function sorts the `targets` slice and applies the exact same swaps to the
/// `weights` slice in lockstep, ensuring they remain synchronized. It uses LSD
/// Radix Sort, which is not a comparison sort and can be significantly faster
/// than `sort_unstable` for integer keys.
///
/// # Arguments
/// * `targets`: The slice of `usize` node indices to be sorted.
/// * `weights`: The slice of corresponding edge weights that must be reordered.
fn radix_sort_adjacencies<W>(targets: &mut [usize], weights: &mut [W])
where
    W: Default + Clone,
{
    let len = targets.len();
    if len < 2 {
        // A list of 0 or 1 elements is already sorted.
        return;
    }

    // Create scratch buffers once to avoid allocations inside the loop.
    let mut targets_buffer = vec![0; len];
    let mut weights_buffer = vec![W::default(); len];

    // We will "ping-pong" between the original slices and the buffer slices.
    // `current_` points to the data to be sorted in this pass.
    // `next_` points to where the sorted data will be written.
    let mut current_targets = &mut *targets;
    let mut current_weights = &mut *weights;
    let mut next_targets = &mut targets_buffer[..];
    let mut next_weights = &mut weights_buffer[..];

    // Process the `usize` keys 8 bits (1 byte) at a time.
    for i in 0..std::mem::size_of::<usize>() {
        let shift = i * 8;

        // 1. Counting pass: Count occurrences of each byte value in the current data.
        let mut counts = [0; 256];
        for &target in current_targets.iter() {
            let key = (target >> shift) & 0xFF;
            counts[key] += 1;
        }

        // 2. Prefix sum: Calculate the starting offset for each byte value.
        let mut offsets = [0; 256];
        for j in 1..256 {
            offsets[j] = offsets[j - 1] + counts[j - 1];
        }

        // 3. Placement pass: Move elements from `current` to `next` buffers.
        for j in 0..len {
            let target = current_targets[j];
            let key = (target >> shift) & 0xFF;
            let write_pos = offsets[key];

            next_targets[write_pos] = target;
            // Use mem::take to move the weight without cloning, preserving data.
            next_weights[write_pos] = std::mem::take(&mut current_weights[j]);

            offsets[key] += 1;
        }

        // 4. Swap buffers: The `next` buffer is now the `current` for the next pass.
        std::mem::swap(&mut current_targets, &mut next_targets);
        std::mem::swap(&mut current_weights, &mut next_weights);
    }

    // After all passes, the data is fully sorted. Because we swap an even number
    // of times (8 passes for a 64-bit usize), the final sorted data will always
    // end up back in the original `targets` and `weights` slices.
    // No final copy-back is needed.
}
