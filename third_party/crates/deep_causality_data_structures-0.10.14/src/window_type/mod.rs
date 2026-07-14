/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use std::marker::PhantomData;

use crate::{ArrayStorage, VectorStorage, WindowStorage};

pub(crate) mod storage;
pub(crate) mod storage_safe;

/// Returns a new sliding window with a vector storage and the size and capacity given as parameters.
///
/// # Arguments
///
/// * `size: usize` - Maximum number of elements held in the sliding window.
/// * `multiple: usize` - Multiplier to calculate capacity as size * multiple
///
/// Capacity refers to the maximum number of elements before a rewind occurs.
///
/// # Example
///
/// ```
/// use deep_causality_data_structures::{VectorStorage,window_type, SlidingWindow};
///
/// // Size refers to the maximum number of elements the sliding window can store.
/// const SIZE: usize = 4;
/// // Multiplier to calculate capacity as size * multiple.
/// const MULT: usize = 300; // Capacity: 4 * 300 = 1200
///
/// // SlidingWindow requires PartialEq + Copy + Default
/// #[derive(Default, Debug, Copy, Clone, Hash, Eq, PartialEq)]
/// pub struct Data {
///    dats: i32,
/// }
///
/// let mut window: SlidingWindow<VectorStorage<Data>, Data>=window_type::new_with_vector_storage(SIZE, MULT);
///
/// assert!(window.empty());
/// assert_eq!(window.size(), SIZE);
/// ```
pub fn new_with_vector_storage<T>(
    size: usize,
    multiple: usize,
) -> SlidingWindow<VectorStorage<T>, T>
where
    T: PartialEq + Copy + Default,
{
    let storage = VectorStorage::new(size, multiple);
    SlidingWindow::with_storage(storage)
}

/// Returns a new sliding window with an const generic array storage and
/// the size and capacity given as generic parameters.
///
/// # Const Generic Arguments
/// *  SIZE: usize - Maximum number of elements held in the sliding window
/// * `CAPACITY: usize` - Maximum number of elements before a rewind occurs
///
/// Note, CAPACITY > SIZE and capacity should be a multiple of size.
/// For example, size 4 should be stored 300 times before rewind;
/// 4 * 300 = 1200
///
/// # Example
/// ```
/// use deep_causality_data_structures::{ArrayStorage, SlidingWindow,window_type};
///
/// // Size refers to the maximum number of elements the sliding window can store.
/// const SIZE: usize = 4;
/// // Capacity refers to the maximum number of elements before a rewind occurs.
/// // Note, CAPACITY > SIZE and capacity should be a multiple of size.
/// // For example, size 4 should be stored 300 times before rewind;
/// // 4 * 300 = 1200
/// const CAPACITY: usize = 1200;
///
/// // SlidingWindow requires PartialEq + Copy + Default
/// #[derive(Default, Debug, Copy, Clone, Hash, Eq, PartialEq)]
/// pub struct Data {
///    dats: i32,
/// }
///
/// // Util function that helps with type inference.
/// fn get_sliding_window() -> SlidingWindow<ArrayStorage<Data, SIZE, CAPACITY>, Data> {
///     window_type::new_with_array_storage()
/// }
///
///   let mut window = get_sliding_window();
///   assert_eq!(window.size(), SIZE);
///
/// ```
///
pub fn new_with_array_storage<T, const SIZE: usize, const CAPACITY: usize>()
-> SlidingWindow<ArrayStorage<T, SIZE, CAPACITY>, T>
where
    T: PartialEq + Copy + Default,
    [T; SIZE]: Sized,
    [T; CAPACITY]: Sized,
{
    let storage = ArrayStorage::new();
    SlidingWindow::with_storage(storage)
}

pub fn default_array_storage<
    T: PartialEq + Copy + Default,
    const SIZE: usize,
    const CAPACITY: usize,
>() -> SlidingWindow<ArrayStorage<T, SIZE, CAPACITY>, T> {
    assert!(CAPACITY > SIZE);

    SlidingWindow::with_storage(ArrayStorage::default())
}

pub struct SlidingWindow<S, T>
where
    T: PartialEq + Copy + Default,
    S: WindowStorage<T>,
{
    storage: S,
    ty: PhantomData<T>,
}

impl<S, T> SlidingWindow<S, T>
where
    T: PartialEq + Copy + Default,
    S: WindowStorage<T>,
{
    pub(crate) fn with_storage(storage: S) -> Self {
        Self {
            storage,
            ty: Default::default(),
        }
    }
}

impl<S, T> SlidingWindow<S, T>
where
    T: PartialEq + Copy + Default,
    S: WindowStorage<T>,
{
    /// Pushes a new element to the beginning of the sliding window.
    /// If the window is filled, the last element will be dropped.
    pub fn push(&mut self, value: T) {
        self.storage.push(value)
    }
    /// Returns the first element in the sliding window
    pub fn first(&self) -> Result<T, String> {
        self.storage.first()
    }
    /// Returns the last element in the sliding window
    pub fn last(&self) -> Result<T, String> {
        self.storage.last()
    }
    /// Returns true if the window is empty.
    pub fn empty(&self) -> bool {
        self.storage.empty()
    }
    /// Returns true if the window is filled.
    pub fn filled(&self) -> bool {
        self.storage.filled()
    }
    /// Returns the window size
    pub fn size(&self) -> usize {
        self.storage.size()
    }
    /// Returns the sliding window as a fixed size static array.
    pub fn arr<const SIZE: usize>(&self) -> Result<[T; SIZE], String> {
        self.storage.arr()
    }
    /// Returns sliding window as slice
    pub fn slice(&self) -> Result<&[T], String> {
        self.storage.slice()
    }
    /// Returns the sliding window as a vector.
    pub fn vec(&self) -> Result<Vec<T>, String> {
        self.storage.vec()
    }
}
