/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! CPU implementation of Hypergraph constructors.

use crate::{Hypergraph, TopologyError};
use deep_causality_num::Zero;
use deep_causality_sparse::CsrMatrix;
use deep_causality_tensor::CausalTensor;

impl<T> Hypergraph<T>
where
    T: Default + Copy + Clone + PartialEq + Zero,
{
    /// CPU implementation of Hypergraph constructor.
    pub(crate) fn new_impl(
        incidence: CsrMatrix<i8>,
        data: CausalTensor<T>,
        cursor: usize,
    ) -> Result<Self, TopologyError> {
        let (num_nodes, num_hyperedges) = incidence.shape();
        if num_nodes == 0 || num_hyperedges == 0 {
            return Err(TopologyError::InvalidInput(
                "Hypergraph must have at least one node and one hyperedge".to_string(),
            ));
        }

        if data.len() != num_nodes {
            return Err(TopologyError::InvalidInput(
                "Data size must match number of nodes".to_string(),
            ));
        }

        if cursor >= num_nodes {
            return Err(TopologyError::IndexOutOfBounds(
                "Initial cursor out of bounds for Hypergraph".to_string(),
            ));
        }

        for &val in incidence.values() {
            if val != 0 && val != 1 {
                return Err(TopologyError::HypergraphError(
                    "Incidence matrix values must be 0 or 1".to_string(),
                ));
            }
        }

        Ok(Self {
            num_nodes,
            num_hyperedges,
            incidence,
            data,
            cursor,
        })
    }
}
