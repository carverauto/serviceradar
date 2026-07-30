/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The DeepCausality Authors and Contributors. All Rights Reserved.
 */
mod get_ref;
#[cfg(test)]
mod get_ref_tests;

use crate::CausalTensor;

impl<T> CausalTensor<T> {
    /// Returns a reference to the underlying `Vec<T>` that stores the tensor's data.
    ///
    /// The data is stored in row-major order.
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_tensor::CausalTensor;
    ///
    /// let tensor = CausalTensor::new(vec![1, 2, 3, 4, 5, 6], vec![2, 3]).unwrap();
    /// assert_eq!(tensor.data(), &vec![1, 2, 3, 4, 5, 6]);
    ///
    /// let empty_tensor: CausalTensor<f64> = CausalTensor::new(vec![], vec![0]).unwrap();
    /// assert!(empty_tensor.data().is_empty());
    /// ```
    pub fn data(&self) -> &Vec<T> {
        &self.data
    }

    /// Returns a slice representing the shape (dimensions) of the tensor.
    ///
    /// The elements of the slice indicate the size of each dimension.
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_tensor::CausalTensor;
    ///
    /// let tensor = CausalTensor::new(vec![1, 2, 3, 4, 5, 6], vec![2, 3]).unwrap();
    /// assert_eq!(tensor.shape(), &[2, 3]);
    /// ```
    pub fn shape(&self) -> &[usize] {
        &self.shape
    }

    // --- Inspectors ---

    /// Returns `true` if the tensor contains no elements.
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_tensor::CausalTensor;
    ///
    /// let empty_tensor: CausalTensor<i32> = CausalTensor::new(vec![], vec![0]).unwrap();
    /// assert!(empty_tensor.is_empty());
    ///
    /// let non_empty_tensor: CausalTensor<f64> = CausalTensor::new(vec![1.0], vec![1]).unwrap();
    /// assert!(!non_empty_tensor.is_empty());
    /// ```
    pub fn is_empty(&self) -> bool {
        self.data.is_empty()
    }

    /// Returns the number of dimensions (rank) of the tensor.
    ///
    /// This is equivalent to `self.shape().len()`.
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_tensor::CausalTensor;
    ///
    /// let tensor = CausalTensor::new(vec![1, 2, 3, 4, 5, 6], vec![2, 3]).unwrap();
    /// assert_eq!(tensor.num_dim(), 2);
    ///
    /// let scalar = CausalTensor::new(vec![42], vec![]).   unwrap();
    /// assert_eq!(scalar.num_dim(), 0); // A scalar has 0 dimensions
    /// ```
    pub fn num_dim(&self) -> usize {
        self.shape.len()
    }

    /// Returns the total number of elements in the tensor.
    ///
    /// This is equivalent to `self.as_slice().len()`.
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_tensor::CausalTensor;
    ///
    /// let tensor = CausalTensor::new(vec![1, 2, 3, 4, 5, 6], vec![2, 3]).unwrap();
    /// assert_eq!(tensor.len(), 6);
    ///
    /// let empty_tensor: CausalTensor<f64> = CausalTensor::new(vec![], vec![0]).unwrap();
    /// assert_eq!(empty_tensor.len(), 0);
    /// ```
    pub fn len(&self) -> usize {
        self.data.len()
    }

    /// Returns a slice to the underlying contiguous data storage of the tensor.
    ///
    /// The data is stored in row-major order.
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_tensor::CausalTensor;
    ///
    /// let tensor = CausalTensor::new(vec![1, 2, 3, 4, 5, 6], vec![2, 3]).unwrap();
    /// assert_eq!(tensor.as_slice(), &[1, 2, 3, 4, 5, 6]);
    /// ```
    pub fn as_slice(&self) -> &[T] {
        &self.data
    }

    /// Returns an optional reference to the element at the specified multi-dimensional index.
    ///
    /// Returns `None` if the provided `index` is out of bounds or has an incorrect number of dimensions.
    ///
    /// # Arguments
    ///
    /// * `index` - A slice representing the multi-dimensional coordinates (e.g., `&[row, col]`).
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_tensor::CausalTensor;
    ///
    /// let tensor = CausalTensor::new(vec![1, 2, 3, 4, 5, 6], vec![2, 3]).unwrap();
    ///
    /// assert_eq!(tensor.get(&[0, 0]), Some(&1));
    /// assert_eq!(tensor.get(&[0, 1]), Some(&2));
    /// assert_eq!(tensor.get(&[1, 2]), Some(&6));
    ///
    /// // Out of bounds
    /// assert_eq!(tensor.get(&[2, 0]), None);
    /// assert_eq!(tensor.get(&[0, 3]), None);
    ///
    /// // Incorrect number of dimensions
    /// assert_eq!(tensor.get(&[0]), None);
    /// assert_eq!(tensor.get(&[0, 0, 0]), None);
    /// ```
    pub fn get(&self, index: &[usize]) -> Option<&T> {
        let flat_index = self.get_flat_index(index)?;
        self.data.get(flat_index)
    }

    /// Returns an optional mutable reference to the element at the specified multi-dimensional index.
    ///
    /// Returns `None` if the provided `index` is out of bounds or has an incorrect number of dimensions.
    ///
    /// # Arguments
    ///
    /// * `index` - A slice representing the multi-dimensional coordinates (e.g., `&[row, col]`).
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_tensor::CausalTensor;
    ///
    /// let mut tensor = CausalTensor::new(vec![1, 2, 3, 4, 5, 6], vec![2, 3]).unwrap();
    ///
    /// if let Some(val) = tensor.get_mut(&[0, 0]) {
    ///     *val = 10;
    /// }
    /// assert_eq!(tensor.as_slice(), &[10, 2, 3, 4, 5, 6]);
    ///
    /// if let Some(val) = tensor.get_mut(&[1, 2]) {
    ///     *val = 60;
    /// }
    /// assert_eq!(tensor.as_slice(), &[10, 2, 3, 4, 5, 60]);
    ///
    /// // Out of bounds
    /// assert_eq!(tensor.get_mut(&[2, 0]), None);
    /// ```
    pub fn get_mut(&mut self, index: &[usize]) -> Option<&mut T> {
        let flat_index = self.get_flat_index(index)?;
        self.data.get_mut(flat_index)
    }

    /// Calculates the flat index into the `data` vector from a multi-dimensional index.
    /// This is the core of the stride-based memory layout.
    pub(crate) fn get_flat_index(&self, index: &[usize]) -> Option<usize> {
        if index.len() != self.num_dim() {
            return None;
        }

        let mut flat_index = 0;
        for (i, &dim_index) in index.iter().enumerate() {
            if dim_index >= self.shape[i] {
                return None; // Index is out of bounds for this dimension
            }
            flat_index += dim_index * self.strides[i];
        }
        Some(flat_index)
    }
}
