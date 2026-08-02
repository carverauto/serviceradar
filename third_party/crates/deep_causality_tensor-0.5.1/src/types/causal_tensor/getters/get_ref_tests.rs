/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The DeepCausality Authors and Contributors. All Rights Reserved.
 */

// `get_ref` and `set` are crate-private helpers (used by `inverse_impl`), so
// their error branches can only be exercised from within the crate.

#[cfg(test)]
mod tests {
    use crate::{CausalTensor, CausalTensorError};

    #[test]
    fn test_get_ref_success() {
        let tensor = CausalTensor::new(vec![1, 2, 3, 4], vec![2, 2]).unwrap();
        assert_eq!(*tensor.get_ref(0, 0).unwrap(), 1);
        assert_eq!(*tensor.get_ref(0, 1).unwrap(), 2);
        assert_eq!(*tensor.get_ref(1, 0).unwrap(), 3);
        assert_eq!(*tensor.get_ref(1, 1).unwrap(), 4);
    }

    #[test]
    fn test_get_ref_row_out_of_bounds() {
        let tensor = CausalTensor::new(vec![1, 2, 3, 4], vec![2, 2]).unwrap();
        let err = tensor.get_ref(2, 0).unwrap_err();
        assert_eq!(err, CausalTensorError::IndexOutOfBounds);
    }

    #[test]
    fn test_get_ref_col_out_of_bounds() {
        let tensor = CausalTensor::new(vec![1, 2, 3, 4], vec![2, 2]).unwrap();
        let err = tensor.get_ref(0, 2).unwrap_err();
        assert_eq!(err, CausalTensorError::IndexOutOfBounds);
    }

    #[test]
    fn test_get_ref_non_2d_error() {
        // A 1-D tensor is not 2-dimensional, so any access is rejected.
        let tensor = CausalTensor::new(vec![1, 2, 3], vec![3]).unwrap();
        let err = tensor.get_ref(0, 0).unwrap_err();
        assert_eq!(err, CausalTensorError::IndexOutOfBounds);
    }

    #[test]
    fn test_set_success() {
        let mut tensor = CausalTensor::new(vec![1, 2, 3, 4], vec![2, 2]).unwrap();
        tensor.set(1, 1, 40).unwrap();
        assert_eq!(*tensor.get_ref(1, 1).unwrap(), 40);
    }

    #[test]
    fn test_set_row_out_of_bounds() {
        let mut tensor = CausalTensor::new(vec![1, 2, 3, 4], vec![2, 2]).unwrap();
        let err = tensor.set(2, 0, 99).unwrap_err();
        assert_eq!(err, CausalTensorError::IndexOutOfBounds);
    }

    #[test]
    fn test_set_col_out_of_bounds() {
        let mut tensor = CausalTensor::new(vec![1, 2, 3, 4], vec![2, 2]).unwrap();
        let err = tensor.set(0, 2, 99).unwrap_err();
        assert_eq!(err, CausalTensorError::IndexOutOfBounds);
    }

    #[test]
    fn test_set_non_2d_error() {
        let mut tensor = CausalTensor::new(vec![1, 2, 3], vec![3]).unwrap();
        let err = tensor.set(0, 0, 99).unwrap_err();
        assert_eq!(err, CausalTensorError::IndexOutOfBounds);
    }
}
