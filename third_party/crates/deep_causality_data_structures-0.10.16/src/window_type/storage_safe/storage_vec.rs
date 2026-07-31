/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::WindowStorage;

/// A highly optimized vector-based sliding window implementation using only safe Rust.
///
/// # Type Parameters
/// * `T` - The type of elements stored in the window. Must implement `PartialEq` and `Copy`.
///
/// # Performance Optimizations
/// - Cache line alignment for better CPU cache utilization
/// - Pre-allocated capacity with default values
/// - Fast path for common operations
/// - Efficient memory reuse during rewind
/// - Branchless arithmetic where possible
#[repr(align(64))]
#[derive(Debug)]
pub struct VectorStorage<T>
where
    T: PartialEq + Copy,
{
    vec: Vec<T>,
    size: usize,
    head: usize,
    tail: usize,
    capacity: usize,
}

impl<T> VectorStorage<T>
where
    T: PartialEq + Copy + Default,
{
    /// Creates a new VectorStorage with pre-allocated capacity.
    ///
    /// # Arguments
    /// * `size` - The maximum number of elements that can be viewed in the sliding window at once
    /// * `multiple` - The capacity multiplier. Total capacity will be size * multiple
    ///
    /// # Returns
    /// A new instance of VectorStorage
    ///
    /// # Implementation Notes
    /// - Pre-allocates memory for the entire capacity upfront
    /// - Initializes with default values to avoid reallocation
    /// - Aligns the structure to cache line boundaries
    #[inline(always)]
    pub fn new(size: usize, multiple: usize) -> Self {
        let capacity = size * multiple;
        let mut vec = Vec::with_capacity(capacity);
        vec.resize(capacity, T::default());
        Self {
            vec,
            size,
            head: 0,
            tail: 0,
            capacity,
        }
    }
}

impl<T> WindowStorage<T> for VectorStorage<T>
where
    T: PartialEq + Copy + Default,
{
    /// Pushes a new value into the sliding window.
    ///
    /// # Arguments
    /// * `value` - The value to push into the window
    ///
    /// # Implementation Notes
    /// - Uses a fast path for the common case
    /// - Employs branchless arithmetic for head updates
    /// - Efficiently rewinds using copy_within when needed
    #[inline(always)]
    fn push(&mut self, value: T) {
        // Fast path: just append if there's space
        if self.tail < self.capacity {
            self.vec[self.tail] = value;
            self.tail += 1;
            if self.tail - self.head > self.size {
                self.head += 1;
            }
            return;
        }

        // Slow path: rewind needed
        self.vec.copy_within(self.head..self.head + self.size, 0);
        self.head = 0;
        self.tail = self.size;
        self.vec[self.tail] = value;
        self.tail += 1;
    }

    /// Returns the first element in the sliding window.
    ///
    /// # Returns
    /// * `Ok(T)` - The first element if the window is not empty
    /// * `Err(String)` - An error message if the window is empty
    ///
    /// # Implementation Notes
    /// - Uses direct indexing for performance
    /// - Maintains safety through explicit empty check
    #[inline(always)]
    fn first(&self) -> Result<T, String> {
        if self.tail == 0 {
            return Err("Vector is empty. Add some elements to the array first".to_string());
        }
        Ok(self.vec[self.head])
    }

    /// Returns the last element in the sliding window.
    ///
    /// # Returns
    /// * `Ok(T)` - The last element if the window is filled
    /// * `Err(String)` - An error message if the window is not yet filled
    ///
    /// # Implementation Notes
    /// - Uses direct indexing for performance
    /// - Maintains safety through explicit filled check
    #[inline(always)]
    fn last(&self) -> Result<T, String> {
        if !self.filled() {
            return Err(
                "Vector is not yet filled. Add some elements to the array first".to_string(),
            );
        }
        Ok(self.vec[self.tail - 1])
    }

    /// Returns the current tail position of the sliding window.
    ///
    /// # Returns
    /// The current tail index
    #[inline(always)]
    fn tail(&self) -> usize {
        self.tail
    }

    /// Returns the size of the sliding window.
    ///
    /// # Returns
    /// The maximum number of elements that can be viewed in the window at once
    #[inline(always)]
    fn size(&self) -> usize {
        self.size
    }

    /// Returns a slice containing all current elements in the sliding window.
    ///
    /// # Returns
    /// A slice containing the current elements from head to tail
    ///
    /// # Implementation Notes
    /// - Uses direct slice indexing for performance
    /// - Maintains safety through proper bounds management
    #[inline(always)]
    fn get_slice(&self) -> &[T] {
        &self.vec[self.head..self.tail]
    }

    /// Checks if the sliding window is filled to its maximum size.
    ///
    /// # Returns
    /// * `true` - If the window contains the maximum number of elements
    /// * `false` - If the window is not yet filled to capacity
    #[inline(always)]
    fn filled(&self) -> bool {
        self.tail >= self.size
    }
}
