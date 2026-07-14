/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::WindowStorage;

const ERROR_EMPTY_ARRAY: &str = "Array is empty";
const ERROR_ARRAY_NOT_FILLED: &str = "Array is not yet filled";

/// A highly optimized fixed-size array-based sliding window implementation
///
/// # Type Parameters
/// * `T` - The type of elements stored in the window
/// * `SIZE` - The size of the sliding window
/// * `CAPACITY` - The total capacity of the underlying array
///
/// # Implementation Note
/// Uses a fixed-size array with constant memory footprint. The window slides through
/// the array using head and tail pointers, with rewind operations when needed.
#[derive(Debug)]
pub struct ArrayStorage<T, const SIZE: usize, const CAPACITY: usize>
where
    T: PartialEq + Copy + Default,
    [T; CAPACITY]: Sized,
{
    arr: [T; CAPACITY],
    size: usize,
    head: usize,
    tail: usize,
}

impl<T, const SIZE: usize, const CAPACITY: usize> ArrayStorage<T, SIZE, CAPACITY>
where
    T: PartialEq + Copy + Default,
    [T; CAPACITY]: Sized,
{
    /// Creates a new ArrayStorage instance
    ///
    /// # Returns
    /// * `Self` - A new ArrayStorage instance with initialized array and pointers
    ///
    /// # Implementation Note
    /// Initializes a fixed-size array with default values and sets up window tracking
    #[inline(always)]
    pub fn new() -> Self {
        assert!(CAPACITY > SIZE, "CAPACITY must be greater than SIZE");
        Self {
            arr: [T::default(); CAPACITY],
            size: SIZE,
            head: 0,
            tail: 0,
        }
    }

    /// Rewinds the window by copying elements to the start of the array
    ///
    /// # Implementation Note
    /// Uses copy_within for efficient memory movement when rewinding
    #[inline(always)]
    fn rewind(&mut self) {
        // Calculate start position efficiently
        let start = self.tail.saturating_sub(self.size);
        let window_size = self.tail - start;

        // Use copy_within for zero-copy slice movement
        self.arr.copy_within(start..self.tail, 0);
        self.head = 0;
        self.tail = window_size;
    }
}

impl<T, const SIZE: usize, const CAPACITY: usize> Default for ArrayStorage<T, SIZE, CAPACITY>
where
    T: PartialEq + Copy + Default,
    [T; SIZE]: Sized,
{
    #[inline(always)]
    fn default() -> Self {
        Self::new()
    }
}

impl<T, const SIZE: usize, const CAPACITY: usize> WindowStorage<T>
    for ArrayStorage<T, SIZE, CAPACITY>
where
    T: PartialEq + Copy + Default,
    [T; SIZE]: Sized,
{
    /// Pushes a new element into the sliding window
    ///
    /// # Args
    /// * `value` - The value to be pushed into the window
    ///
    /// # Implementation Note
    /// Optimized for the common case with minimal branching
    #[inline(always)]
    fn push(&mut self, value: T) {
        if self.tail >= CAPACITY {
            self.rewind();
        }

        // Direct array access is faster than indexing
        self.arr[self.tail] = value;
        self.tail += 1;

        // Use saturating_sub to avoid potential overflow
        if self.tail >= self.size {
            self.head = self.tail - self.size;
        }
    }

    /// Returns the first (oldest) element in the sliding window
    ///
    /// # Returns
    /// * `Ok(T)` - The first element in the window
    /// * `Err(String)` - If the window is empty
    #[inline(always)]
    fn first(&self) -> Result<T, String> {
        if self.tail == 0 {
            return Err(ERROR_EMPTY_ARRAY.to_string());
        }
        Ok(self.arr[self.head])
    }

    /// Returns the last (newest) element in the sliding window
    ///
    /// # Returns
    /// * `Ok(T)` - The last element in the window
    /// * `Err(String)` - If the window is not yet filled
    #[inline(always)]
    fn last(&self) -> Result<T, String> {
        if !self.filled() {
            return Err(ERROR_ARRAY_NOT_FILLED.to_string());
        }
        Ok(self.arr[self.tail - 1])
    }

    /// Returns the current tail position of the window
    #[inline(always)]
    fn tail(&self) -> usize {
        self.tail
    }

    /// Returns the size of the sliding window
    #[inline(always)]
    fn size(&self) -> usize {
        self.size
    }

    /// Returns a slice of the current window contents
    ///
    /// # Returns
    /// * `&[T]` - A slice containing the current window elements
    #[inline(always)]
    fn get_slice(&self) -> &[T] {
        // Use array slicing for zero-copy access
        &self.arr[self.head..self.tail]
    }

    /// Checks if the sliding window is filled to its maximum size
    #[inline(always)]
    fn filled(&self) -> bool {
        // Use saturating_sub to avoid potential overflow
        self.tail.saturating_sub(self.head) >= self.size
    }
}
