/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::CausalTensor;
use crate::CausalTensorError;
use deep_causality_algebra::RealField;

pub trait CausalTensorMathExt<T> {
    /// Computes the element-wise natural logarithm of the tensor.
    ///
    /// # Arguments
    ///
    /// * `self` - A reference to the CausalTensor.
    ///
    /// # Returns
    ///
    /// A `Result` containing a new `CausalTensor` with the natural logarithm of each element,
    /// or a `CausalTensorError` if the operation fails.
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_tensor::{CausalTensor, CausalTensorMathExt};
    ///
    /// let tensor = CausalTensor::new(vec![1.0, std::f32::consts::E, 10.0], vec![3, 1]).unwrap();
    /// let result = tensor.log_nat().unwrap();
    ///
    /// assert_eq!(result.as_slice(), &[0.0, 0.99999994, std::f32::consts::LN_10]); // Approx. ln(10)
    /// ```
    fn log_nat(&self) -> Result<CausalTensor<T>, CausalTensorError>;

    /// Computes the element-wise base-2 logarithm of the tensor.
    ///
    /// # Arguments
    ///
    /// * `self` - A reference to the CausalTensor.
    ///
    /// # Returns
    ///
    /// A `Result` containing a new `CausalTensor` with the base-2 logarithm of each element,
    /// or a `CausalTensorError` if the operation fails.
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_tensor::{CausalTensor, CausalTensorMathExt};
    ///
    /// let tensor = CausalTensor::new(vec![1.0, 2.0, 4.0, 8.0], vec![4, 1]).unwrap();
    /// let result = tensor.log2().unwrap();
    ///
    /// assert_eq!(result.as_slice(), &[0.0, 1.0, 2.0, 3.0]);
    /// ```
    fn log2(&self) -> Result<CausalTensor<T>, CausalTensorError>;

    /// Computes the element-wise base-10 logarithm of the tensor.
    ///
    /// # Arguments
    ///
    /// * `self` - A reference to the CausalTensor.
    ///
    /// # Returns
    ///
    /// A `Result` containing a new `CausalTensor` with the base-10 logarithm of each element,
    /// or a `CausalTensorError` if the operation fails.
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_tensor::{CausalTensor, CausalTensorMathExt};
    ///
    /// let tensor = CausalTensor::new(vec![1.0, 10.0, 100.0], vec![3, 1]).unwrap();
    /// let result = tensor.log10().unwrap();
    ///
    /// assert_eq!(result.as_slice(), &[0.0, 1.0, 2.0]);
    /// ```
    fn log10(&self) -> Result<CausalTensor<T>, CausalTensorError>;

    /// Computes the element-wise base-2 logarithm of the tensor, handling 0.0 inputs as 0.0.
    /// This replicates the behavior of Python's `mylog` function for information theory calculations.
    ///
    /// # Arguments
    ///
    /// * `self` - A reference to the CausalTensor.
    ///
    /// # Returns
    ///
    /// A `Result` containing a new `CausalTensor` with the base-2 logarithm of each element,
    /// or a `CausalTensorError` if the operation fails.
    fn surd_log2(&self) -> Result<CausalTensor<T>, CausalTensorError>;

    /// Performs element-wise division that is safe for probabilistic calculations.
    ///
    /// This method handles the `0.0 / 0.0` case by returning `0.0`, which is the
    /// correct interpretation in an information-theoretic context where an impossible
    /// event provides zero information. It will still panic on other divisions by zero
    /// (e.g., `x / 0` where `x > 0`), as this represents a malformed probability.
    fn safe_div(&self, rhs: &CausalTensor<T>) -> Result<CausalTensor<T>, CausalTensorError>;
}

/// Single generic implementation over any real field `T: RealField`.
///
/// This replaces the previous per-type `f32`/`f64` implementations, so the math
/// extension now composes with every precision in the numerical stack
/// (`f32`, `f64`, `Float106`, and future real types) without code change.
impl<T> CausalTensorMathExt<T> for CausalTensor<T>
where
    T: RealField,
{
    fn log_nat(&self) -> Result<CausalTensor<T>, CausalTensorError> {
        if self.is_empty() {
            return Ok(CausalTensor::from_slice(&[], self.shape()));
        }
        let new_data: Vec<T> = self.as_slice().iter().map(|&val| val.ln()).collect();
        Ok(CausalTensor::from_slice(&new_data, self.shape()))
    }

    fn log2(&self) -> Result<CausalTensor<T>, CausalTensorError> {
        if self.is_empty() {
            return Ok(CausalTensor::from_slice(&[], self.shape()));
        }
        let new_data: Vec<T> = self.as_slice().iter().map(|&val| val.log2()).collect();
        Ok(CausalTensor::from_slice(&new_data, self.shape()))
    }

    fn log10(&self) -> Result<CausalTensor<T>, CausalTensorError> {
        if self.is_empty() {
            return Ok(CausalTensor::from_slice(&[], self.shape()));
        }
        let new_data: Vec<T> = self.as_slice().iter().map(|&val| val.log10()).collect();
        Ok(CausalTensor::from_slice(&new_data, self.shape()))
    }

    fn surd_log2(&self) -> Result<CausalTensor<T>, CausalTensorError> {
        if self.is_empty() {
            return Ok(CausalTensor::from_slice(&[], self.shape()));
        }
        let zero = T::zero();
        let new_data: Vec<T> = self
            .as_slice()
            .iter()
            .map(|&val| if val == zero { zero } else { val.log2() })
            .collect();
        Ok(CausalTensor::from_slice(&new_data, self.shape()))
    }

    fn safe_div(&self, rhs: &CausalTensor<T>) -> Result<CausalTensor<T>, CausalTensorError> {
        // Type-scaled near-zero tolerance, infallible for any real field (matches `safe_div_cdl`).
        let eps = T::epsilon();
        let zero = T::zero();
        self.broadcast_op(rhs, move |numerator: T, denominator: T| {
            if denominator.abs() < eps {
                if numerator.abs() < eps {
                    Ok(zero)
                } else {
                    Err(CausalTensorError::DivisionByZero)
                }
            } else {
                Ok(numerator / denominator)
            }
        })
    }
}
