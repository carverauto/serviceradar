/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{Functor, HKT, Satisfies};

/// The `CoMonad` trait represents a comonadic context, which is the dual of a `Monad`.
///
/// While a `Monad` allows for chaining computations that produce values *within* a context
/// (e.g., `bind` for `M<A>` to `M<B>`), a `CoMonad` focuses on computations that consume
/// values *from* a context and produce new contexts based on observations.
///
/// Think of a `CoMonad` as a context that can be "inspected" or "observed" to yield a value,
/// and then "extended" to produce new contexts by applying a function that observes the original context.
///
/// # Unified Design
///
/// This trait unifies the previous `CoMonad` and `BoundedComonad` traits into a single
/// hierarchy using the constraint system. Types that need algebraic bounds (like
/// `CausalTensor` needing `TensorData`) specify their constraint via the HKT's
/// `Constraint` associated type.
///
/// # Intuition & Analogy
///
/// A common analogy is a spreadsheet cell:
/// - `extract` gets the value of the current cell.
/// - `extend` allows you to fill a new spreadsheet with the results of formulas applied
///   to the original spreadsheet. Each cell in the new spreadsheet is derived by observing
///   the context of the old spreadsheet (e.g., the cell itself and its neighbors).
///
/// # Laws (Informal)
///
/// 1.  **Left Identity**: `extend(w, extract) = w`
///     (Extending a context with its own `extract` function should yield the original context).
/// 2.  **Right Identity**: `extract(extend(w, f)) = f(w)`
///     (Extracting from an extended context should be the same as directly applying the function `f` to the context).
/// 3.  **Associativity**: `extend(extend(w, f), g) = extend(w, |w_prime| g(extend(w_prime, f)))`
///     (Extending twice is equivalent to extending once with a composed function).
///
/// # Type Parameters
///
/// *   `F`: A Higher-Kinded Type (HKT) witness that represents the type constructor
///     (e.g., `BoxWitness`, `CausalTensorWitness`). This `F` must also be a `Functor`.
pub trait CoMonad<F: HKT>: Functor<F> {
    /// Extracts the value at the current focus of the comonadic context.
    ///
    /// This operation allows you to "peek inside" the context and obtain its current value
    /// without transforming the context itself.
    ///
    /// # Arguments
    ///
    /// *   `fa`: A reference to the comonadic context (`F::Type<A>`).
    ///
    /// # Returns
    ///
    /// The value `A` contained within the context `fa`.
    ///
    /// # Type Parameters
    ///
    /// *   `A`: The type of the value to extract.
    ///
    /// # Requirements
    ///
    /// *   `A: Clone`: The extracted value must be clonable, as `extract` takes a reference
    ///     and returns an owned value, implying a copy.
    /// *   `A: Satisfies<F::Constraint>`: The type must satisfy the HKT's constraint.
    ///
    /// # Examples
    ///
    /// ```rust
    /// use deep_causality_haft::{BoxWitness, CoMonad};
    ///
    /// let box_val = Box::new(42);
    /// let extracted = BoxWitness::extract(&box_val);
    /// assert_eq!(extracted, 42);
    /// ```
    fn extract<A>(fa: &F::Type<A>) -> A
    where
        A: Satisfies<F::Constraint> + Clone;

    /// Extends the comonadic context by applying a function to its observed state.
    ///
    /// This creates a new comonadic context `F::Type<B>`, where each element `B` is the
    /// result of applying the function `f` to the *original* context `fa`.
    /// The function `f` receives a reference to the `fa` (the original context)
    /// and should produce a value `B`.
    ///
    /// # Arguments
    ///
    /// *   `fa`: A reference to the original comonadic context (`F::Type<A>`).
    /// *   `f`: A function (`Func`) that takes a reference to the context `F::Type<A>`
    ///     and returns a new value `B`. This function represents an "observation"
    ///     or "computation" based on the current context.
    ///
    /// # Returns
    ///
    /// A new comonadic context (`F::Type<B>`) where each element is the result
    /// of applying `f` to the original context.
    ///
    /// # Type Parameters
    ///
    /// *   `A`: The type of the values in the original context.
    /// *   `B`: The type of the values in the new context.
    /// *   `Func`: The type of the extension function, which must be `FnMut(&F::Type<A>) -> B`.
    ///
    /// # Examples
    ///
    /// ```rust
    /// use deep_causality_haft::{BoxWitness, CoMonad, HKT};
    ///
    /// let box_val = Box::new(5);
    ///
    /// // Extend to create a new Box containing the square of the original value
    /// let f_square = |b: &<BoxWitness as HKT>::Type<i32>| (**b) * (**b);
    /// let extended_square = BoxWitness::extend(&box_val, f_square);
    /// assert_eq!(extended_square, Box::new(25));
    ///
    /// // Extend to create a new Box containing a string representation
    /// let f_to_string = |b: &<BoxWitness as HKT>::Type<i32>| format!("Value: {}", **b);
    /// let extended_string = BoxWitness::extend(&box_val, f_to_string);
    /// assert_eq!(extended_string, Box::new("Value: 5".to_string()));
    /// ```
    fn extend<A, B, Func>(fa: &F::Type<A>, f: Func) -> F::Type<B>
    where
        A: Satisfies<F::Constraint> + Clone,
        B: Satisfies<F::Constraint>,
        Func: FnMut(&F::Type<A>) -> B;

    /// Duplicates the comonadic context.
    ///
    /// This creates a nested structure where each position contains the context
    /// focused at that position.
    ///
    /// # Arguments
    ///
    /// *   `fa`: A reference to the comonadic context to duplicate.
    ///
    /// # Returns
    ///
    /// A nested comonadic context (`F::Type<F::Type<A>>`).
    ///
    /// # Default Implementation
    ///
    /// Uses `extend` with clone: `extend(fa, |x| x.clone())`
    fn duplicate<A>(fa: &F::Type<A>) -> F::Type<F::Type<A>>
    where
        A: Satisfies<F::Constraint> + Clone,
        F::Type<A>: Satisfies<F::Constraint> + Clone,
    {
        Self::extend(fa, |x| x.clone())
    }
}
