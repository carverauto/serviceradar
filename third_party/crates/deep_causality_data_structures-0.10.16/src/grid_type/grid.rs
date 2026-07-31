/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use std::cell::RefCell;
use std::fmt::Debug;

use crate::{PointIndex, Storage};

// A Grid API, with four different implementations backed by const generic arrays.
// https://github.com/adamchalmers/const_generic_grid

/// A generic multi-dimensional grid abstraction backed by a user-provided storage type.
///
/// `Grid` provides safe, convenient, and dimension-aware access to array-based
/// data structures of up to 4D using [`PointIndex`] coordinates. Internally,
/// it uses a `RefCell` to allow interior mutability while avoiding external
/// `&mut` borrowing for convenience in controlled environments.
///
/// # Type Parameters
///
/// - `S`: The underlying storage type implementing the [`Storage<T>`] trait.
/// - `T`: The element type stored in the grid. Must be `Copy`.
///
/// # Features
///
/// - Supports reading and writing elements via [`PointIndex`].
/// - Preserves dimensional metadata (width, height, depth, time).
/// - Enables grid interaction without exposing internal storage representation.
///
/// # Example
///
/// ```rust
/// use deep_causality_data_structures::*;
///
/// let array: [[f64; 4]; 4] = [[0.0; 4]; 4];
/// let grid = Grid::new(array);
/// let index = PointIndex::new2d(1, 2);
/// grid.set(index, 42.0);
/// assert_eq!(grid.get(index), 42.0);
/// ```
#[derive(Debug)]
pub struct Grid<S, T>
where
    T: Copy,
    S: Storage<T>,
{
    /// Internal storage wrapped in `RefCell` to allow interior mutability.
    storage: RefCell<S>,
    // Type marker to retain generic parameter `T` even though it's not stored directly.
    _marker: std::marker::PhantomData<T>,
}

impl<S, T> Grid<S, T>
where
    T: Copy + Default,
    S: Storage<T>,
{
    /// Creates a new [`Grid`] instance from the provided storage implementation.
    ///
    /// # Arguments
    ///
    /// * `storage` - A structure implementing the [`Storage<T>`] trait.
    ///
    /// # Returns
    ///
    /// A new `Grid` ready for indexed access.
    #[inline(always)]
    pub fn new(storage: S) -> Self {
        Self {
            storage: RefCell::new(storage),
            _marker: std::marker::PhantomData,
        }
    }

    /// Retrieves a copy of the element at the given point index.
    ///
    /// # Arguments
    ///
    /// * `p` - A [`PointIndex`] indicating the position to access.
    ///
    /// # Panics
    ///
    /// May panic if the index is out of bounds based on the underlying storage.
    #[inline(always)]
    pub fn get(&self, p: PointIndex) -> T {
        *self.storage.borrow().get(p)
    }

    /// Sets the element at the given point index to the specified value.
    ///
    /// # Arguments
    ///
    /// * `p` - A [`PointIndex`] indicating where to write the value.
    /// * `value` - The value to assign at the given location.
    ///
    /// # Panics
    ///
    /// May panic if the index is out of bounds based on the underlying storage.
    #[inline(always)]
    pub fn set(&self, p: PointIndex, value: T) {
        self.storage.borrow_mut().set(p, value);
    }

    /// Returns the depth (Z-axis size) of the grid if available.
    ///
    /// # Returns
    ///
    /// * `Some(depth)` if the underlying storage supports depth information.
    /// * `None` if not applicable (e.g., 1D or 2D storage).
    #[inline(always)]
    pub fn depth(&self) -> Option<usize> {
        self.storage.borrow().depth().copied()
    }

    /// Returns the height (Y-axis size) of the grid if available.
    #[inline(always)]
    pub fn height(&self) -> Option<usize> {
        self.storage.borrow().height().copied()
    }

    /// Returns the time (T-axis) dimension size of the grid if applicable.
    #[inline(always)]
    pub fn time(&self) -> Option<usize> {
        self.storage.borrow().time().copied()
    }

    /// Returns the width (X-axis size) of the grid if available.
    #[inline(always)]
    pub fn width(&self) -> Option<usize> {
        self.storage.borrow().width().copied()
    }
}
