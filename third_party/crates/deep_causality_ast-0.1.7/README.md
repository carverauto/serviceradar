# `deep_causality_ast`

[![Crates.io][crates-badge]][crates-url]
[![Docs.rs][docs-badge]][docs-url]
[![MIT licensed][mit-badge]][mit-url]
![Tests][test-url]

[crates-badge]: https://img.shields.io/badge/Crates.io-Latest-blue
[crates-url]: https://crates.io/crates/deep_causality_ast

[docs-badge]: https://img.shields.io/badge/Docs.rs-Latest-blue
[docs-url]: https://docs.rs/deep_causality_ast/latest/deep_causality_ast/

[mit-badge]: https://img.shields.io/badge/License-MIT-blue.svg
[mit-url]: https://github.com/deepcausality-rs/deep_causality/blob/main/LICENSE

[test-url]: https://github.com/deepcausality-rs/deep_causality/actions/workflows/run_tests.yml/badge.svg


A persistent, immutable, thread-safe tree data structure for the `deep_causality` project.

## Overview

This crate provides `ConstTree<T>`, a foundational Abstract Syntax Tree (AST) structure designed for efficiency and safety in concurrent environments. It is a persistent data structure, meaning that all modifications are non-destructive and return a new instance of the tree, sharing as much of the underlying data as possible with the original.

This copy-on-write behavior makes it highly efficient to pass trees around and create modified versions without incurring the cost of deep copies.

## Core Features

*   **Persistent & Immutable**: Operations that "modify" the tree are non-destructive. They return a new, modified `ConstTree`, leaving the original unchanged.
*   **Efficient Cloning**: `ConstTree` is built on `std::sync::Arc`. Cloning a tree is a cheap, constant-time operation that simply increments a reference count.
*   **Thread-Safe**: It is `Send` and `Sync` (if `T` is `Send` and `Sync`), allowing it to be safely shared across threads without locks.
*   **Rich API**: Includes a comprehensive API for construction, traversal, searching, and functional mapping.
    *   Multiple iteration strategies (pre-order, post-order, level-order, consuming).
    *   Consuming (`into_map`) and non-consuming (`map`) mapping methods.
    *   Monadic `join` method to flatten a `ConstTree<ConstTree<T>>`.

## Usage

Here is a basic example of how to create and interact with a `ConstTree`.

```rust
use deep_causality_ast::ConstTree;

fn main() {
    // Create a tree with a root value and some children.
    let leaf1 = ConstTree::new(10);
    let leaf2 = ConstTree::from(20); // `From<T>` is implemented.
    let tree = ConstTree::with_children(5, vec![leaf1, leaf2]);

    // --- Inspection ---
    assert_eq!(*tree.value(), 5);
    assert_eq!(tree.children().len(), 2);
    assert_eq!(tree.depth(), 2);
    assert_eq!(tree.size(), 3);

    // --- Iteration ---
    // The tree can be iterated over in several ways.
    let values: Vec<i32> = tree.iter_pre_order().copied().collect();
    assert_eq!(values, vec![5, 10, 20]);

    // --- Modification ---
    // `add_child` returns a new tree; the original is unchanged.
    let leaf3 = ConstTree::new(30);
    let modified_tree = tree.add_child(leaf3);

    assert_eq!(tree.children().len(), 2); // Original is unaffected.
    assert_eq!(modified_tree.children().len(), 3);
    assert_eq!(*modified_tree.children()[2].value(), 30);

    // --- Mapping ---
    // `map` creates a new tree with a different value type.
    let string_tree = modified_tree.map(&mut |v| format!("val: {}", v));
    assert_eq!(*string_tree.value(), "val: 5");
    assert_eq!(*string_tree.children()[0].value(), "val: 10");

    // `into_map` consumes the tree.
    let owned_string_tree = modified_tree.into_map(|v| format!("owned: {}", v));
    assert_eq!(*owned_string_tree.value(), "owned: 5");
}
```

## 👨‍💻👩‍💻 Contribution

Contributions are welcomed especially related to documentation, example code, and fixes.
If unsure where to start, just open an issue and ask.

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in deep_causality by you,
shall be licensed under the MIT licence, without any additional terms or conditions.

## 📜 Licence

This project is licensed under the [MIT license](LICENSE).

## 👮️ Security

For details about security, please read
the [security policy](https://github.com/deepcausality-rs/deep_causality/blob/main/SECURITY.md).