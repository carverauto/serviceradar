/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

/// Trait defining the interface for a sliding window data structure
///
/// # Type Parameters
/// * `T` - The type of elements stored in the window, must implement PartialEq + Copy + Default
///
/// # Implementation Note
/// This trait provides both required methods that must be implemented by all window types
/// and default implementations for common window operations.
pub trait WindowStorage<T>
where
    T: PartialEq + Copy + Default,
{
    /// Pushes a new element to the beginning of the sliding window
    ///
    /// # Args
    /// * `value` - The value to be pushed into the window
    ///
    /// # Implementation Note
    /// When the window is filled, the oldest element will be dropped to maintain the window size
    fn push(&mut self, value: T);

    /// Returns the first (oldest) element in the sliding window
    ///
    /// # Returns
    /// * `Ok(T)` - The first element in the window
    /// * `Err(String)` - If the window is empty
    fn first(&self) -> Result<T, String>;

    /// Returns the last (newest) element in the sliding window
    ///
    /// # Returns
    /// * `Ok(T)` - The last element in the window
    /// * `Err(String)` - If the window is not yet filled
    fn last(&self) -> Result<T, String>;

    /// Returns the current tail position of the window
    ///
    /// # Returns
    /// * `usize` - The current tail position
    fn tail(&self) -> usize;

    /// Returns the size of the sliding window
    ///
    /// # Returns
    /// * `usize` - The configured size of the window
    fn size(&self) -> usize;

    /// Returns a slice of the current window contents
    ///
    /// # Returns
    /// * `&[T]` - A slice containing the current window elements
    fn get_slice(&self) -> &[T];

    //
    // Default implementations. Override as required.
    //

    /// Returns true if the window is empty
    ///
    /// # Returns
    /// * `bool` - True if the window is empty, false otherwise
    ///
    /// # Implementation Note
    /// Default implementation checks if tail position is 0
    fn empty(&self) -> bool {
        self.tail() == 0
    }

    /// Returns true if the window is filled
    ///
    /// # Returns
    /// * `bool` - True if the window is filled, false otherwise
    ///
    /// # Implementation Note
    /// Default implementation checks if tail position is at least the window size
    fn filled(&self) -> bool {
        self.tail() >= self.size()
    }

    /// Returns the sliding window as a fixed size static array
    ///
    /// # Type Parameters
    /// * `S` - The size of the returned array
    ///
    /// # Returns
    /// * `Ok([T; S])` - The window contents as a fixed-size array
    /// * `Err(String)` - If the window is not yet filled
    ///
    /// # Implementation Note
    /// Default implementation copies window contents into a new fixed-size array
    fn arr<const S: usize>(&self) -> Result<[T; S], String> {
        if !self.filled() {
            return Err(
                "Sliding window is not yet filled. Add some elements to the array first"
                    .to_string(),
            );
        }

        let mut arr: [T; S] = [T::default(); S];
        let slice = self.get_slice();
        arr[..self.size()].copy_from_slice(&slice[..self.size()]);

        Ok(arr)
    }

    /// Returns the sliding window as a slice
    ///
    /// # Returns
    /// * `Ok(&[T])` - A slice of the window contents
    /// * `Err(String)` - If the window is not yet filled
    ///
    /// # Implementation Note
    /// Default implementation returns the slice only if the window is filled
    fn slice(&self) -> Result<&[T], String> {
        if !self.filled() {
            Err(
                "Sliding window is not yet filled. Add some elements to the array first"
                    .to_string(),
            )
        } else {
            Ok(self.get_slice())
        }
    }

    /// Returns the sliding window as a vector
    ///
    /// # Returns
    /// * `Ok(Vec<T>)` - A vector containing the window contents
    /// * `Err(String)` - If the window is not yet filled
    ///
    /// # Implementation Note
    /// Default implementation converts the window slice to a vector
    fn vec(&self) -> Result<Vec<T>, String> {
        if !self.filled() {
            Err(
                "Sliding window is not yet filled. Add some elements to the array first"
                    .to_string(),
            )
        } else {
            Ok(self.get_slice().to_vec())
        }
    }
}
