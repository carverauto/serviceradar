# ultragraph

[![Crates.io][crates-badge]][crates-url]
[![Docs.rs][docs-badge]][docs-url]
[![MIT licensed][mit-badge]][mit-url]
![Tests][test-url]

[ossf-badge]: https://bestpractices.coreinfrastructure.org/projects/7568/badge

[crates-badge]: https://img.shields.io/badge/Crates.io-Latest-blue

[crates-url]: https://crates.io/crates/ultragraph

[docs-badge]: https://img.shields.io/badge/Docs.rs-Latest-blue

[docs-url]: https://docs.rs/ultragraph/latest/ultragraph/

[mit-badge]: https://img.shields.io/badge/License-MIT-blue.svg

[mit-url]: https://github.com/deepcausality-rs/deep_causality/blob/main/LICENSE

[test-url]: https://github.com/deepcausality-rs/deep_causality/actions/workflows/run_tests.yml/badge.svg

## 📣 Goal

ultragraph provides a high-performance, ergonomic, and directed graph data structure. It is designed around a
state-machine architecture that offers both a flexible, mutable graph and a blazing-fast, immutable graph, allowing
users to choose the right tool for the right phase of their application.

## 🎁 Features

* **Dual-State Architecture:** A `DynamicGraph` for easy mutations and a `Static` (frozen) `CsmGraph` for extreme read
  performance.
* **Ergonomic Mutations:** Simple `add_node`, `add_edge`, `remove_node`, etc., in the dynamic state.
* **High-Performance Algorithms:** A suite of algorithms (`shortest_path`, `topological_sort`, `has_cycle`) that operate
  on the frozen graph.
* **Efficient Traversals:** Cache-friendly neighbor iteration (`outbound_edges`) on the frozen graph.
* **Full Lifecycle:** Seamlessly `freeze()` a graph for analysis and `unfreeze()` it to resume mutations.

## ⚡️ Implementation

`ultragraph`'s power comes from its state-machine design, which separates the concerns of graph *construction* from
graph *analysis*.

### 1. The Dynamic State: `DynamicGraph`

This is the default state, optimized for flexibility and mutations.

* **Underlying Structure:** A standard adjacency list (`Vec<Vec<...>>`).
* **Best For:** Building and modifying your graph topology. Adding, removing, and updating nodes and edges is
  straightforward.
* **Performance:** While flexible, this representation is not ideal for high-speed traversals due to scattered memory
  allocation, which can lead to CPU cache misses.

### 2. The Transition: `freeze()`

This is the bridge between the two states. Calling `g.freeze()` consumes the `DynamicGraph` and transforms it into a
`CsmGraph`. Think of this as a one-time "compilation" step that prepares your graph for high-speed analysis.

### 3. The Static State: `CsmGraph` (Frozen)

This is the high-performance, read-only state.

* **Underlying Structure:** A **Compressed Sparse Row (CSR)** format. This layout stores all graph edges in a few large,
  contiguous memory blocks, making it extremely cache-friendly for the CPU.
* **Best For:** Running algorithms, performing complex traversals, and any read-heavy workload.
* **Performance:** Because of its exceptional data locality, traversals and algorithms on a `CsmGraph` are orders of
  magnitude faster than on a `DynamicGraph`. All methods on the `GraphAlgorithms` trait require the graph to be in this
  state.

### 4. The Reverse Transition: `unfreeze()`

If you need to make further changes after a period of analysis, `g.unfreeze()` efficiently converts the `CsmGraph` back
into a `DynamicGraph`, allowing the cycle of mutation and analysis to begin again.

## ⚙️ Graph Algorithms

The `UltraGraph` crate provides a suite of high-performance, read-only analytical algorithms for
graph analysis. These algorithms are implemented on static, optimized graph structures for efficient
computation.

* **`find_cycle()`**: Finds a single cycle in the
  graph and returns the path of nodes that form it.
  Returns `None` if the graph is a Directed Acyclic Graph
  (DAG).

* **`has_cycle()`**: Checks if the graph contains any
  directed cycles.

* **`topological_sort()`**: Computes a topological
  sort of the graph if it is a DAG. Returns `None` if the
  graph contains a cycle.

* **`is_reachable(start_index, stop_index)`**: Checks
  if a path of any length exists from a start node to a
  stop node.

* **`shortest_path_len(start_index, stop_index)`**:
  Returns the length (number of nodes) of the shortest
  path from a start node to a stop node.

* **`shortest_path(start_index, stop_index)`**: Finds
  the complete shortest path (sequence of nodes) from a
  start node to a stop node.

* **`shortest_weighted_path(start_index, stop_
 index)`**: Finds the shortest path in a weighted graph
  using Dijkstra's algorithm, returning the path and its
  total cost.

* **`strongly_connected_components()`**: Finds all
  Strongly Connected Components (SCCs) in the graph using
  Tarjan's algorithm, returning a list of node sets, where
  each set represents an SCC.

* **`betweenness_centrality()`**: Measures a node's importance by counting how often it
  appears on the shortest paths between all other pairs of nodes using Brandes' algorithm.

## 🚀 Benchmark Results

### Dynamic Graph

| Benchmark Name    | Graph Size | Operation  | Estimated Time (Median) | Outliers Detected |
|:------------------|:-----------|:-----------|:------------------------|:------------------|
| `small_add_node`  | 10         | `add_node` | 29.099 ns               | 14% (14 / 100)    |
| `medium_add_node` | 100        | `add_node` | 45.864 ns               | 12% (12 / 100)    |
| `large_add_node`  | 1,000      | `add_node` | 39.293 ns               | 11% (11 / 100)    |
| `small_get_node`  | 10         | `get_node` | 3.9417 ns               | 8% (8 / 100)      |
| `medium_get_node` | 100        | `get_node` | 3.9849 ns               | 2% (2 / 100)      |
| `large_get_node`  | 1,000      | `get_node` | 3.9916 ns               | 7% (7 / 100)      |

* SMALL = 10;
* MEDIUM = 100;
* LARGE = 1000;

Benchmark source code in [ultragraph/benches ](../ultragraph/benches/benchmarks)

---

* **`add_node` Performance:** Adding a node is consistently fast, with median times ranging from **29 to 46 nanoseconds
  **. This confirms it as an efficient O(1) operation. The minor time variations are expected and are due to
  system-level memory allocation behavior.
* **`get_node` Performance:** Accessing a node is extremely fast and stable across all graph sizes, with a median time
  of approximately **4 nanoseconds**. This demonstrates the O(1) efficiency of retrieving data from the underlying
  `Vec`.
* **Outliers:** The presence of outliers is normal for benchmarks running on a non-dedicated machine and indicates that
  `Criterion` is correctly identifying and filtering system-level interruptions to provide a more accurate measurement.

### Static CSM Graph

| Operation       | Scale | Graph Configuration                          |  Mean Time  | Throughput (Est.)        |
|:----------------|:------|:---------------------------------------------|:-----------:|:-------------------------|
| **Edge Lookup** | Tiny  | `contains_edge` (Linear Scan, degree < 64)   | **~7.7 ns** | ~130 Million lookups/sec |
|                 | Tiny  | `contains_edge` (Binary Search, degree > 64) | **~8.2 ns** | ~122 Million lookups/sec |
| **Algorithms**  | Small | `shortest_path` (1k nodes)                   | **~5.3 µs** | ~188,000 paths/sec       |
|                 | Small | `topological_sort` (1k nodes, DAG)           | **~5.2 µs** | ~192,000 sorts/sec       |
|                 | Small | `find_cycle` (1k nodes, has cycle)           | **~7.1 µs** | ~140,000 checks/sec      |
|                 | Large | `shortest_path` (1M nodes, 5M edges)         | **~482 µs** | ~2,000 paths/sec         |
|                 | Large | `topological_sort` (1M nodes, 5M edges)      | **~2.9 ms** | ~345 sorts/sec           |
| **Lifecycle**   | Small | `freeze` (1k nodes, 999 edges)               | **~42 µs**  | ~23,800 freezes/sec      |
|                 | Small | `unfreeze` (1k nodes, 999 edges)             | **~12 µs**  | ~81,600 unfreezes/sec    |
|                 | Large | `freeze` (1M nodes, 5M edges)                | **~75 ms**  | ~13 freezes/sec          |
|                 | Large | `unfreeze` (1M nodes, 5M edges)              | **~24 ms**  | ~41 unfreezes/sec        |

*(Note: Time units are nanoseconds (ns), microseconds (µs), and milliseconds (ms). Throughput is an approximate
calculation based on the mean time.)*

Benchmark source code in [deep_causality/benches ](../deep_causality/benches)

## Performance Design

The design of `ultragraph`'s static analysis structure, `CsmGraph`, is based on the principles for high-performance
sparse graph representation detailed in the paper "NWHy: A Framework for Hypergraph Analytics" (Liu et al.).
Specifically, `ultragraph` adopts the paper's foundational model of using two mutually-indexed Compressed Sparse Row (
CSR) structures to enable efficient, `O(degree)` bidirectional traversal—one for forward (outbound) edges and one for
the transposed graph for backward (inbound) edges.

However, `ultragraph` introduces three significant architectural enhancements over this baseline to provide optimal
performance and to support the specific requirements of dynamically evolving systems.

1. **Struct of Arrays (SoA) Memory Layout:** The internal CSR adjacency structures are implemented using a Struct of
   Arrays layout. Instead of a single `Vec<(target, weight)>`, `ultragraph` uses two parallel vectors: `Vec<target>` and
   `Vec<weight>`. This memory layout improves data locality for topology-only algorithms (e.g., reachability, cycle
   detection). By iterating exclusively over the `targets` vector, these algorithms avoid loading unused edge weight
   data into the CPU cache, which minimizes memory bandwidth usage and reduces cache pollution.

2. **Adaptive Edge Containment Checks:** The `contains_edge` method employs a hybrid algorithm that adapts to the data's
   shape at runtime. It performs an `O(1)` degree check on the source node and selects the optimal search strategy: a
   cache-friendly linear scan for low-degree nodes (where the number of neighbors is less than a compile-time threshold,
   e.g., 64) and a logarithmically faster binary search for high-degree nodes. This ensures the best possible lookup
   performance across varied graph structures.

3. **Formal Evolutionary Lifecycle:** The most significant architectural addition is a formal two-state model for graph
   evolution. `ultragraph` defines two distinct representations: a mutable `DynamicGraph` optimized for efficient `O(1)`
   node and edge additions, and the immutable `CsmGraph` optimized for analysis. The library provides high-performance
   `O(V + E)` `.freeze()` and `.unfreeze()` operations to transition between these states. This two-state model directly
   supports systems that require dynamic structural evolution, such as those modeling emergent causality, by providing a
   controlled mechanism to separate the mutation phase from the immutable analysis phase.

While the NWHypergraph paper provides an excellent blueprint for a high-performance static graph engine, these
modifications extend that foundation into a more flexible, cache-aware, and dynamically adaptable framework
purpose-built for the lifecycle of evolving graph systems.

## 🚀 Install

Just run:

```bash
cargo add ultragraph
```

Alternatively, add the following to your Cargo.toml

```toml
ultragraph = "current_version"
```

## ⭐ Usage

See:

* [Examples](examples)
* [Benchmarks](benches)
* [Tests](tests)

```rust
use ultragraph::*;

#[derive(Default, Debug, Copy, Clone, Hash, Eq, PartialEq)]
pub struct Data {
    x: u8,
}
impl Display for Data {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.x)
    }
}

pub fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut g = UltraGraph::with_capacity(10, None);
    assert!(g.is_empty());

    // Add nodes to the graph
    let root_index = g.add_root_node(Data { x: 3 })?;
    let node_a_index = g.add_node(Data { x: 7 })?;
    let node_b_index = g.add_node(Data { x: 9 })?;
    let node_c_index = g.add_node(Data { x: 11 })?;

    // Link nodes together
    g.add_edge(root_index, node_a_index, ())?;
    g.add_edge(node_a_index, node_b_index, ())?;
    g.add_edge(root_index, node_c_index, ())?;

    // Get node a
    let node = g.get_node(node_a_index);
    assert!(node.is_some());

    let data = node?;
    assert_eq!(data.x, 7);
    println!("Retrieved Node A with data: {data:?}");

    println!("Freeze the graph to enable high-performance traversal");
    g.freeze(); // This is the crucial step!

    // neighbors is just a vector of indices
    // so you can iterate over them to get the actual nodes
    println!("Neighbors of root node: ");
    println!("Iterating over neighbors of Node A with a for loop:");
    for neighbor_index in g.outbound_edges(root_index)? {
        // You can use the index to get the node's data
        let neighbor_data = g.get_node(neighbor_index)?;
        println!("- Found neighbor: {neighbor_data} at index {neighbor_index}");
    }

    Ok(())
}
```

## 🙏 Credits

The project took inspiration from:

* [petgraph](https://github.com/petgraph/petgraph)
* [Dachshund](https://github.com/facebookresearch/dachshund)
* [Hypergraph](https://github.com/yamafaktory/hypergraph)

## 👨‍💻👩‍💻 Contribution

Contributions are welcomed especially related to documentation, example code, and fixes.
If unsure where to start, just open an issue and ask.

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in deep_causality by you,
shall be licensed under the MIT licence, without any additional terms or conditions.

## 📜 Licence

This project is licensed under the [MIT license](LICENSE).

## 💻 Author

* Marvin Hansen, [GitHub](https://github.com/marvin-hansen).
* Github GPG key ID: 369D5A0B210D39BC
* GPG Fingerprint: 4B18 F7B2 04B9 7A72 967E 663E 369D 5A0B 210D 39BC