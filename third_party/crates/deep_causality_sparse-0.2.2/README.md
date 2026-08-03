# deep_causality_sparse

[![Crates.io](https://img.shields.io/crates/v/deep_causality_sparse.svg)](https://crates.io/crates/deep_causality_sparse)
[![Docs.rs](https://docs.rs/deep_causality_sparse/badge.svg)](https://docs.rs/deep_causality_sparse)

[![MIT licensed][mit-badge]][mit-url]
![Tests][test-url]

[mit-badge]: https://img.shields.io/badge/License-MIT-blue.svg
[mit-url]: https://github.com/deepcausality-rs/deep_causality/blob/main/LICENSE
[test-url]: https://github.com/deepcausality-rs/deep_causality/actions/workflows/run_tests.yml/badge.svg


# CausalSparse - Efficient Sparse Matrix Operations

`deep_causality_sparse` is a Rust library providing an efficient implementation of Compressed Sparse Row (CSR) matrices. It is designed for scenarios where data is predominantly zero, offering significant memory savings and computational performance improvements over dense matrix representations. This crate enables robust and fast operations on sparse data, crucial for many scientific computing, machine learning, and data analysis tasks.

## Key Features

*   **Compressed Sparse Row (CSR) Format:** Leverages the CSR storage format for optimal memory usage and efficient row-wise access, ideal for sparse matrices.
*   **Intuitive Construction:** Easily create `CsrMatrix` instances from triplet lists (`(row, col, value)`) with automatic handling of duplicate entries and zero-valued elements.
*   **Comprehensive Operations:** Supports a wide range of matrix operations, including:
    *   **Arithmetic:** Addition (`add_matrix`), Subtraction (`sub_matrix`), Scalar Multiplication (`scalar_mult`).
    *   **Vector & Matrix Multiplication:** Efficient matrix-vector product (`vec_mult`) and matrix-matrix product (`mat_mult`).
    *   **Transformation:** Transpose (`transpose`).
*   **Robust Error Handling:** Provides clear `SparseMatrixError` types for dimension mismatches, shape incompatibilities, and index out-of-bounds conditions, ensuring reliable computations.
*   **Efficient Element Access & Iteration:** `get_value_at` for individual element retrieval, and various iterators (`iter_non_zeros`, `iter_rows`, `iter_cols`) for efficient traversal of non-zero elements.
*   **Memory Efficiency:** By storing only non-zero elements, `CsrMatrix` is highly memory-efficient for sparse datasets.

## Installation

Add `deep_causality_sparse` to your `Cargo.toml` file:

```toml
[dependencies]
deep_causality_sparse = "0.1.0" # Or the latest version
```

## Usage

Here are some basic examples demonstrating the core functionalities of `deep_causality_sparse`.

### Basic Matrix Operations

```rust
use deep_causality_sparse::CsrMatrix;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("Demonstrating basic CsrMatrix operations:");

    // 1. Create a CsrMatrix from triplets (2x3 matrix)
    println!("\n--- Matrix A (2x3) from triplets ---");
    let triplets_a = vec![(0, 0, 1.0), (0, 2, 2.0), (1, 1, 3.0)];
    let a = CsrMatrix::from_triplets(2, 3, &triplets_a)?;
    // A = [[1.0, 0.0, 2.0],
    //      [0.0, 3.0, 0.0]]
    println!("Matrix A:\n{}", a); // Using the Display trait
    println!("A[0,0]: {}", a.get_value_at(0, 0));
    println!("A[0,1]: {}", a.get_value_at(0, 1)); // Should be 0.0

    // 2. Scalar Multiplication (A * 2.0)
    println!("\n--- Scalar Multiplication (A * 2.0) ---");
    let scalar = 2.0;
    let b = a.scalar_mult(scalar);
    // B = [[2.0, 0.0, 4.0],
    //      [0.0, 6.0, 0.0]]
    println!("Matrix B (A *{}):\n{}", scalar, b);

    // 3. Matrix Addition (A + C)
    println!("\n--- Matrix Addition (A + C) ---");
    let triplets_c = vec![(0, 1, 5.0), (1, 0, 6.0)];
    let c = CsrMatrix::from_triplets(2, 3, &triplets_c)?;
    // C = [[0.0, 5.0, 0.0],
    //      [6.0, 0.0, 0.0]]
    println!("Matrix C:\n{}", c);

    let d = a.add_matrix(&c)?;
    // D = A + C = [[1.0, 5.0, 2.0],
    //              [6.0, 3.0, 0.0]]
    println!("Matrix D (A + C):\n{}", d);

    // 4. Matrix-Vector Multiplication (A * x)
    println!("\n--- Matrix-Vector Multiplication (A * x) ---");
    let x = vec![1.0, 2.0, 3.0];
    let y = a.vec_mult(&x)?;
    // y = Ax = [(1.0*1.0 + 0.0*2.0 + 2.0*3.0), (0.0*1.0 + 3.0*2.0 + 0.0*3.0)] = [7.0, 6.0]
    println!("Vector x: {:?}", x);
    println!("Result y = Ax: {:?}", y);

    // 5. Matrix Multiplication (A * E)
    println!("\n--- Matrix Multiplication (A * E) ---");
    let triplets_e = vec![(0, 0, 4.0), (1, 1, 5.0), (2, 0, 6.0)];
    let e = CsrMatrix::from_triplets(3, 2, &triplets_e)?;
    // E (3x2) = [[4.0, 0.0],
    //            [0.0, 5.0],
    //            [6.0, 0.0]]
    println!("Matrix E:\n{}", e);

    let f = a.mat_mult(&e)?;
    // F = A * E (2x2) = [[16.0, 0.0],
    //                    [0.0, 15.0]]
    println!("Matrix F (A * E):\n{}", f);

    // 6. Transpose (A^T)
    println!("\n--- Transpose (A^T) ---");
    let a_t = a.transpose();
    // A^T (3x2) = [[1.0, 0.0],
    //              [0.0, 3.0],
    //              [2.0, 0.0]]
    println!("Matrix A^T:\n{}", a_t);

    // 7. Error Handling Example (DimensionMismatch)
    println!("\n--- Error Handling (Dimension Mismatch) ---");
    let x_invalid = vec![1.0, 2.0]; // Incorrect length for A (2x3)
    match a.vec_mult(&x_invalid) {
        Ok(_) => println!("Unexpected success with invalid vector length"),
        Err(e) => println!("Caught expected error: {}", e),
    }
    
    Ok(())
}
```

To run this example, use `cargo run --example basic_matrix_ops`.

## Technical Details

### Compressed Sparse Row (CSR) Format
The `CsrMatrix` internally stores the sparse matrix using three main vectors:
*   `row_indices`: A vector of length `rows + 1`. `row_indices[i]` stores the index in `col_indices` and `values` where the non-zero elements of row `i` begin. `row_indices[rows]` stores the total number of non-zero elements.
*   `col_indices`: Stores the column index for each non-zero element. These are ordered by row, then by column within each row.
*   `values`: Stores the actual non-zero values, corresponding one-to-one with `col_indices`.

This format is particularly efficient for operations that process data row by row, such as matrix-vector multiplication, as it allows direct access to the non-zero elements of any given row.

### Efficient Operations
Operations like matrix addition and subtraction iterate through the non-zero elements of both matrices simultaneously, merging them efficiently. Matrix-vector and matrix-matrix multiplications are optimized to leverage the sparse structure, avoiding multiplications by zero.

## Docs

*   [Examples](examples)
*   [Test](tests)

## Contribution

Contributions are welcomed especially related to documentation, example code, and fixes.
If unsure where to start, just open an issue and ask.

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in deep_causality by you,
shall be licensed under the MIT licence, without any additional terms or conditions.

## Licence

This project is licensed under the [MIT license](LICENSE).

## Security

For details about security, please read
the [security policy](https://github.com/deepcausality-rs/deep_causality/blob/main/SECURITY.md).

