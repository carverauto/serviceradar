/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::CsrMatrix;
use deep_causality_haft::{
    Adjunction, Applicative, CoMonad, Foldable, Functor, HKT, Monad, Pure, Satisfies,
};

/// `CsrMatrixWitness` is a zero-sized type that acts as a Higher-Kinded Type (HKT) witness
/// for the `CsrMatrix<T>` type constructor.
///
/// It enables `CsrMatrix` to participate in the unified monadic interface of DeepCausality,
/// allowing composition with Tensors, Multivectors, and Monadic Effects.
pub struct CsrMatrixWitness;

impl HKT for CsrMatrixWitness {
    /// Specifies that `CsrMatrixWitness` represents the `CsrMatrix<T>` type constructor.
    type Constraint = deep_causality_haft::NoConstraint;
    type Type<T>
        = CsrMatrix<T>
    where
        T: deep_causality_haft::Satisfies<deep_causality_haft::NoConstraint>;
}

// ----------------------------------------------------------------------------
// Functor
// ----------------------------------------------------------------------------
impl Functor<CsrMatrixWitness> for CsrMatrixWitness {
    fn fmap<A, B, Func>(m_a: CsrMatrix<A>, f: Func) -> CsrMatrix<B>
    where
        A: Satisfies<deep_causality_haft::NoConstraint>,
        B: Satisfies<deep_causality_haft::NoConstraint>,
        Func: FnMut(A) -> B,
    {
        // For sparse matrices, we typically only map the stored values.
        // Implicit zeros remain implicit zeros.
        // PRECONDITION: We assume f(0) is ignored or f(0) -> 0 to preserve sparsity structure.
        let new_values: Vec<B> = m_a.values.into_iter().map(f).collect();

        CsrMatrix {
            row_indices: m_a.row_indices,
            col_indices: m_a.col_indices,
            values: new_values,
            shape: m_a.shape,
        }
    }
}

// ----------------------------------------------------------------------------
// Foldable
// ----------------------------------------------------------------------------
impl Foldable<CsrMatrixWitness> for CsrMatrixWitness {
    fn fold<A, B, Func>(fa: CsrMatrix<A>, init: B, f: Func) -> B
    where
        A: Satisfies<deep_causality_haft::NoConstraint>,
        B: Satisfies<deep_causality_haft::NoConstraint>,
        Func: FnMut(B, A) -> B,
    {
        // Fold over stored non-zero values
        fa.values.into_iter().fold(init, f)
    }
}

// ----------------------------------------------------------------------------
// Pure
// ----------------------------------------------------------------------------
impl Pure<CsrMatrixWitness> for CsrMatrixWitness {
    fn pure<T>(value: T) -> CsrMatrix<T>
    where
        T: Satisfies<deep_causality_haft::NoConstraint>,
    {
        CsrMatrix {
            row_indices: vec![0, 1],
            col_indices: vec![0],
            values: vec![value],
            shape: (1, 1),
        }
    }
}

// ----------------------------------------------------------------------------
// Applicative
// ----------------------------------------------------------------------------
impl Applicative<CsrMatrixWitness> for CsrMatrixWitness {
    fn apply<A, B, Func>(funcs: CsrMatrix<Func>, args: CsrMatrix<A>) -> CsrMatrix<B>
    where
        A: Satisfies<deep_causality_haft::NoConstraint> + Clone,
        B: Satisfies<deep_causality_haft::NoConstraint>,
        Func: Satisfies<deep_causality_haft::NoConstraint> + FnMut(A) -> B,
    {
        // Production Grade Broadcast Logic:
        // 1. Scalar Broadcast: If funcs is 1x1, apply the single function to all elements of args.
        // 2. Element-wise Apply: If shapes match, apply f(x) where both f and x exist (intersection).

        if funcs.shape == (1, 1) && funcs.values.len() == 1 {
            // Scalar Broadcast
            let func = funcs.values.into_iter().next().unwrap();
            let new_values = args.values.into_iter().map(func).collect();
            CsrMatrix {
                row_indices: args.row_indices,
                col_indices: args.col_indices,
                values: new_values,
                shape: args.shape,
            }
        } else if funcs.shape == args.shape {
            // Element-wise Application (Structural Intersection)
            // We apply f(x) only where both the function matrix and the argument matrix have non-zero entries.
            // This preserves the sparse structure of the intersection.

            let (rows, _cols) = funcs.shape;
            let mut new_values = Vec::new();
            let mut new_col_indices = Vec::new();
            let mut new_row_indices = Vec::with_capacity(rows + 1);
            new_row_indices.push(0);

            let mut cumulative_count = 0;

            // Iterators for value consumption
            let mut f_vals = funcs.values.into_iter();
            let mut a_vals = args.values.into_iter();

            // Track exact position of iterators in the original value arrays
            let mut current_f_idx = 0;
            let mut current_a_idx = 0;

            for r in 0..rows {
                let start_f = funcs.row_indices[r];
                let end_f = funcs.row_indices[r + 1];
                let start_a = args.row_indices[r];
                let end_a = args.row_indices[r + 1];

                let mut ptr_f = start_f;
                let mut ptr_a = start_a;

                while ptr_f < end_f && ptr_a < end_a {
                    // Advance iterators to catch up to the current pointers.
                    // This creates a "peek" effect by ensuring the iterator is ready at the current index.
                    while current_f_idx < ptr_f {
                        f_vals.next();
                        current_f_idx += 1;
                    }
                    while current_a_idx < ptr_a {
                        a_vals.next();
                        current_a_idx += 1;
                    }

                    let col_f = funcs.col_indices[ptr_f];
                    let col_a = args.col_indices[ptr_a];

                    if col_f == col_a {
                        // Intersection match found
                        let mut func = f_vals.next().unwrap();
                        let val = a_vals.next().unwrap();
                        current_f_idx += 1;
                        current_a_idx += 1;

                        new_values.push(func(val));
                        new_col_indices.push(col_f);
                        cumulative_count += 1;

                        ptr_f += 1;
                        ptr_a += 1;
                    } else if col_f < col_a {
                        // Advance F
                        ptr_f += 1;
                    } else {
                        // Advance A
                        ptr_a += 1;
                    }
                }
                new_row_indices.push(cumulative_count);
            }

            CsrMatrix {
                row_indices: new_row_indices,
                col_indices: new_col_indices,
                values: new_values,
                shape: funcs.shape,
            }
        } else {
            panic!(
                "Applicative::apply: Shape mismatch. Expected {:?}, got {:?}. Broadcasting not supported for these shapes.",
                funcs.shape, args.shape
            );
        }
    }
}

// ----------------------------------------------------------------------------
// Monad
// ----------------------------------------------------------------------------
impl Monad<CsrMatrixWitness> for CsrMatrixWitness {
    fn bind<A, B, Func>(m_a: CsrMatrix<A>, mut f: Func) -> CsrMatrix<B>
    where
        A: Satisfies<deep_causality_haft::NoConstraint>,
        B: Satisfies<deep_causality_haft::NoConstraint>,
        Func: FnMut(A) -> CsrMatrix<B>,
    {
        let result_values: Vec<B> = m_a
            .values
            .into_iter()
            .flat_map(|val_a| f(val_a).values.into_iter())
            .collect();

        let count = result_values.len();

        CsrMatrix {
            row_indices: vec![0, count],
            col_indices: (0..count).collect(),
            values: result_values,
            shape: (1, count),
        }
    }
}

// ----------------------------------------------------------------------------
// CoMonad
// ----------------------------------------------------------------------------
impl CoMonad<CsrMatrixWitness> for CsrMatrixWitness {
    fn extract<A>(fa: &CsrMatrix<A>) -> A
    where
        A: Satisfies<deep_causality_haft::NoConstraint> + Clone,
    {
        // Extract returns the value at the current "focus".
        // For a CsrMatrix without an explicit cursor, we define the focus as the
        // first stored non-zero element (top-left-most).
        if !fa.values.is_empty() {
            fa.values[0].clone()
        } else {
            panic!("Comonad::extract cannot be called on an empty CsrMatrix");
        }
    }

    fn extend<A, B, Func>(fa: &CsrMatrix<A>, mut f: Func) -> CsrMatrix<B>
    where
        A: Satisfies<deep_causality_haft::NoConstraint> + Clone,
        B: Satisfies<deep_causality_haft::NoConstraint>,
        Func: FnMut(&CsrMatrix<A>) -> B,
    {
        // Spatial CoMonad Extension:
        // We iterate over every non-zero element in 'fa'.
        // For each element at (row, col), we create a "Shifted View" of the matrix,
        // effectively translating (row, col) to (0, 0).
        // Example: If original has value V at (r, c), the shifted view has V as its first element.
        // We then apply 'f' to this view. 'f' (via extract) will see V as the focus.
        let mut new_values = Vec::with_capacity(fa.values.len());

        // We need to iterate perfectly through existing structure.
        // Iterate rows
        for r in 0..fa.shape.0 {
            let start = fa.row_indices[r];
            let end = fa.row_indices[r + 1];

            for idx in start..end {
                let c = fa.col_indices[idx];

                // Construct the shifted view for focus at (r, c)
                let view = shift_view(fa, r, c);

                // Apply f to the view
                new_values.push(f(&view));
            }
        }

        // Reconstruct result matrix with IDENTICAL structure to input.
        // Only values change.
        CsrMatrix {
            row_indices: fa.row_indices.clone(),
            col_indices: fa.col_indices.clone(),
            values: new_values,
            shape: fa.shape,
        }
    }
}

/// Helper function to create a shifted view of a CsrMatrix.
/// The view contains all elements (r', c') from the original matrix such that
/// r' >= r_offset and c' >= c_offset.
/// In the new view, this element appears at (r' - r_offset, c' - c_offset).
/// The shape is adjusted accordingly.
fn shift_view<A: Clone>(matrix: &CsrMatrix<A>, r_offset: usize, c_offset: usize) -> CsrMatrix<A> {
    let (rows, cols) = matrix.shape;

    // New shape is reduced by offset
    // Calculate new dimensions with saturating subtraction
    let new_rows = rows.saturating_sub(r_offset);
    let new_cols = cols.saturating_sub(c_offset);

    if new_rows == 0 || new_cols == 0 {
        return CsrMatrix::new();
    }

    let mut new_values = Vec::new();
    let mut new_col_indices = Vec::new();
    let mut new_row_indices = vec![0; new_rows + 1]; // Initialize with correct size

    // Reconstruct CSR structure for the view.
    // Iterate through new rows (k) from 0 to new_rows-1.
    // Each new row k corresponds to original row `r_offset + k`.
    for k in 0..new_rows {
        let orig_row = r_offset + k;
        let start = matrix.row_indices[orig_row];
        let end = matrix.row_indices[orig_row + 1];

        for idx in start..end {
            let col = matrix.col_indices[idx];
            // Only include elements whose original column index is within the new view's bounds
            if col >= c_offset && col < c_offset + new_cols {
                new_col_indices.push(col - c_offset);
                new_values.push(matrix.values[idx].clone());
            }
        }
        // Update row pointer for the next row (k+1)
        new_row_indices[k + 1] = new_values.len();
    }

    CsrMatrix {
        row_indices: new_row_indices,
        col_indices: new_col_indices,
        values: new_values,
        shape: (new_rows, new_cols),
    }
}

// ----------------------------------------------------------------------------
// Adjunction
// ----------------------------------------------------------------------------
impl Adjunction<CsrMatrixWitness, CsrMatrixWitness, (usize, usize)> for CsrMatrixWitness {
    fn unit<A>(ctx: &(usize, usize), a: A) -> CsrMatrix<CsrMatrix<A>>
    where
        A: Satisfies<deep_causality_haft::NoConstraint>
            + Satisfies<deep_causality_haft::NoConstraint>
            + Clone,
    {
        let (rows, cols) = *ctx;
        if rows == 0 || cols == 0 {
            // Correctly handle empty context by returning a structure representing "Empty"
            // Since the outer matrix must contain something to be "unit",
            // but if the inner shape is 0, we basically have a 1x1 matrix containing an empty matrix.
            let inner = CsrMatrix {
                row_indices: vec![0],
                col_indices: vec![],
                values: vec![],
                shape: (0, 0),
            };

            return CsrMatrix {
                row_indices: vec![0, 1],
                col_indices: vec![0],
                values: vec![inner],
                shape: (1, 1),
            };
        }

        // Construct Inner Matrix at (0,0) with value 'a'
        let mut row_indices = vec![0; rows + 1];
        // Row 0 has 1 element.
        for idx in row_indices.iter_mut().skip(1) {
            *idx = 1;
        }

        let inner = CsrMatrix {
            row_indices,
            col_indices: vec![0],
            values: vec![a.clone()],
            shape: *ctx,
        };

        // Outer matrix is 1x1 wrapper around inner
        CsrMatrix {
            row_indices: vec![0, 1],
            col_indices: vec![0],
            values: vec![inner],
            shape: (1, 1),
        }
    }

    fn counit<B>(_ctx: &(usize, usize), lrb: CsrMatrix<CsrMatrix<B>>) -> B
    where
        B: Satisfies<deep_causality_haft::NoConstraint>
            + Satisfies<deep_causality_haft::NoConstraint>
            + Clone,
    {
        let flattened = <Self as Monad<Self>>::bind(lrb, |x| x);
        <Self as CoMonad<Self>>::extract(&flattened)
    }

    fn left_adjunct<A, B, F>(ctx: &(usize, usize), a: A, f: F) -> CsrMatrix<B>
    where
        A: Satisfies<deep_causality_haft::NoConstraint>
            + Satisfies<deep_causality_haft::NoConstraint>
            + Clone,
        B: Satisfies<deep_causality_haft::NoConstraint>,
        F: Fn(CsrMatrix<A>) -> B,
    {
        // left_adjunct: a -> f(unit(a))
        let m_m_a = Self::unit(ctx, a);
        <Self as Functor<Self>>::fmap(m_m_a, f)
    }

    fn right_adjunct<A, B, F>(_ctx: &(usize, usize), la: CsrMatrix<A>, f: F) -> B
    where
        A: Satisfies<deep_causality_haft::NoConstraint> + Clone,
        B: Satisfies<deep_causality_haft::NoConstraint>
            + Satisfies<deep_causality_haft::NoConstraint>,
        F: FnMut(A) -> CsrMatrix<B>,
    {
        // right_adjunct: (A -> R<B>) -> (L<A> -> B)
        // Optimized implementation avoids Clone requirement on B by
        // manually extracting the value from the container.
        let mapped: CsrMatrix<CsrMatrix<B>> = <Self as Functor<Self>>::fmap(la, f);

        // Monadic bind to flatten: CsrMatrix<CsrMatrix<B>> -> CsrMatrix<B>
        let flattened: CsrMatrix<B> = <Self as Monad<Self>>::bind(mapped, |x| x);

        // Extract value. Panic if empty (Adjunctions assume total correspondence in valid ctx)
        if let Some(val) = flattened.values.into_iter().next() {
            val
        } else {
            panic!("Adjunction::right_adjunct resulted in empty structure, cannot return B");
        }
    }
}
