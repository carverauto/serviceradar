/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

pub mod grid;
pub mod point;
pub mod storage;
pub mod storage_array_1d;
pub mod storage_array_2d;
pub mod storage_array_3d;
pub mod storage_array_4d;

use std::fmt::{Debug, Display, Formatter};

pub use point::PointIndexType;

use crate::{Grid, PointIndex};

/// Enum representing the dimensionality of the array-backed grid.
#[derive(Debug, Copy, Clone)]
pub enum ArrayType {
    /// 1-dimensional array: `[T; H]`
    Array1D,
    /// 2-dimensional array: `[[T; W]; H]`
    Array2D,
    /// 3-dimensional array: `[[[T; W]; H]; D]`
    Array3D,
    /// 4-dimensional array: `[[[[T; W]; H]; D]; C]`
    Array4D,
}

/// Type alias for 4D grid configuration using fixed-size array storage.
type GridType<T, const W: usize, const H: usize, const D: usize, const C: usize> =
    Grid<[[[[T; W]; H]; D]; C], T>;

/// A wrapper around [`Grid`] that simplifies usage of fixed-size array-based grids
/// across 1D to 4D space (optionally including time).
///
/// `ArrayGrid` provides a uniform API for accessing multi-dimensional array data
/// through a single enum. Each variant corresponds to a concrete instantiation of a
/// `Grid` with a particular dimensionality. This design enables type-safe access
/// while allowing ergonomic dynamic dispatch on dimensionality.
///
/// # Type Parameters
///
/// - `T`: The type of the stored element. Must implement `Copy + Default`.
/// - `W`: Width (X-axis).
/// - `H`: Height (Y-axis).
/// - `D`: Depth (Z-axis).
/// - `C`: Time/Chronos (T-axis).
///
/// # Example
///
/// ```rust
/// use deep_causality_data_structures::*;
///
/// let grid: ArrayGrid<f64, 4, 4, 4, 4> = ArrayGrid::new(ArrayType::Array2D);
/// let index = PointIndex::new2d(1, 1);
/// grid.set(index, 1.618);
/// assert_eq!(grid.get(index), 1.618);
/// ```
#[derive(Debug)]
pub enum ArrayGrid<T, const W: usize, const H: usize, const D: usize, const C: usize>
where
    T: Copy + Default,
{
    /// A 1D array-backed grid: `[T; H]`.
    ArrayGrid1D(Grid<[T; H], T>),

    /// A 2D array-backed grid: `[[T; W]; H]`.
    ArrayGrid2D(Grid<[[T; W]; H], T>),

    /// A 3D array-backed grid: `[[[T; W]; H]; D]`.
    ArrayGrid3D(Grid<[[[T; W]; H]; D], T>),

    /// A 4D array-backed grid: `[[[[T; W]; H]; D]; C]`.
    ArrayGrid4D(GridType<T, W, H, D, C>),
}

impl<T, const W: usize, const H: usize, const D: usize, const C: usize> ArrayGrid<T, W, H, D, C>
where
    T: Copy + Default,
{
    /// Creates a new [`ArrayGrid`] of the specified dimensionality with all elements set to `T::default()`.
    ///
    /// # Arguments
    ///
    /// * `array_type` - One of [`ArrayType::Array1D`] through [`ArrayType::Array4D`].
    ///
    /// # Returns
    ///
    /// A new `ArrayGrid` instance corresponding to the selected type.
    #[inline(always)]
    pub fn new(array_type: ArrayType) -> ArrayGrid<T, W, H, D, C> {
        match array_type {
            ArrayType::Array1D => ArrayGrid::ArrayGrid1D(Grid::new([T::default(); H])),
            ArrayType::Array2D => ArrayGrid::ArrayGrid2D(Grid::new([[T::default(); W]; H])),
            ArrayType::Array3D => ArrayGrid::ArrayGrid3D(Grid::new([[[T::default(); W]; H]; D])),
            ArrayType::Array4D => ArrayGrid::ArrayGrid4D(GridType::<T, W, H, D, C>::new(
                [[[[T::default(); W]; H]; D]; C],
            )),
        }
    }

    /// Returns a reference to the internal 1D grid, if this variant is `ArrayGrid1D`.
    #[inline(always)]
    pub fn array_grid_1d(&self) -> Option<&Grid<[T; H], T>> {
        if let ArrayGrid::ArrayGrid1D(grid) = self {
            Some(grid)
        } else {
            None
        }
    }

    /// Returns a reference to the internal 2D grid, if this variant is `ArrayGrid2D`.
    #[inline(always)]
    pub fn array_grid_2d(&self) -> Option<&Grid<[[T; W]; H], T>> {
        if let ArrayGrid::ArrayGrid2D(grid) = self {
            Some(grid)
        } else {
            None
        }
    }

    /// Returns a reference to the internal 3D grid, if this variant is `ArrayGrid3D`.
    #[inline(always)]
    pub fn array_grid_3d(&self) -> Option<&Grid<[[[T; W]; H]; D], T>> {
        if let ArrayGrid::ArrayGrid3D(grid) = self {
            Some(grid)
        } else {
            None
        }
    }

    /// Returns a reference to the internal 4D grid, if this variant is `ArrayGrid4D`.
    #[inline(always)]
    pub fn array_grid_4d(&self) -> Option<&GridType<T, W, H, D, C>> {
        if let ArrayGrid::ArrayGrid4D(grid) = self {
            Some(grid)
        } else {
            None
        }
    }

    /// Retrieves the value at the specified [`PointIndex`] from the active grid.
    ///
    /// # Panics
    ///
    /// Will panic if the index is out of bounds for the internal array structure.
    #[inline(always)]
    pub fn get(&self, p: PointIndex) -> T {
        match self {
            ArrayGrid::ArrayGrid1D(grid) => grid.get(p),
            ArrayGrid::ArrayGrid2D(grid) => grid.get(p),
            ArrayGrid::ArrayGrid3D(grid) => grid.get(p),
            ArrayGrid::ArrayGrid4D(grid) => grid.get(p),
        }
    }

    /// Sets the value at the specified [`PointIndex`] in the active grid.
    ///
    /// # Panics
    ///
    /// Will panic if the index is out of bounds for the internal array structure.
    #[inline(always)]
    pub fn set(&self, p: PointIndex, value: T) {
        match self {
            ArrayGrid::ArrayGrid1D(grid) => grid.set(p, value),
            ArrayGrid::ArrayGrid2D(grid) => grid.set(p, value),
            ArrayGrid::ArrayGrid3D(grid) => grid.set(p, value),
            ArrayGrid::ArrayGrid4D(grid) => grid.set(p, value),
        }
    }
}

impl<T, const W: usize, const H: usize, const D: usize, const C: usize> Display
    for ArrayGrid<T, W, H, D, C>
where
    T: Copy + Default + Debug,
{
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            ArrayGrid::ArrayGrid1D(_) => write!(f, "ArrayGrid1D"),
            ArrayGrid::ArrayGrid2D(_) => write!(f, "ArrayGrid2D"),
            ArrayGrid::ArrayGrid3D(_) => write!(f, "ArrayGrid3D"),
            ArrayGrid::ArrayGrid4D(_) => write!(f, "ArrayGrid4D"),
        }
    }
}
