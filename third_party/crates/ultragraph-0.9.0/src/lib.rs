/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

#![forbid(unsafe_code)]

pub mod errors;

mod traits;
pub mod types;
pub mod utils;

// Errors
pub use crate::errors::graph_error::GraphError;
// Traits
pub use crate::traits::graph_algo::*;
pub use crate::traits::graph_freeze::Freezable;
pub use crate::traits::graph_mut::GraphMut;
pub use crate::traits::graph_traversal::GraphTraversal;
pub use crate::traits::graph_unfreeze::Unfreezable;
pub use crate::traits::graph_view::GraphView;
pub use crate::types::storage::graph_csm::CsmGraph;
pub use crate::types::storage::graph_dynamic::DynamicGraph;
pub use crate::types::storage::graph_state::GraphState;
// Types
pub use crate::types::ultra_graph::UltraGraph;
pub use crate::types::ultra_graph::UltraGraphContainer;
pub use crate::types::ultra_graph::UltraGraphWeighted;
