/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::CausalTensor;

// Helper function to create a simple scalar tensor for testing
pub fn scalar_tensor(value: f64) -> CausalTensor<f64> {
    CausalTensor::new(vec![value], vec![]).unwrap()
}

// Helper function to create a simple vector tensor for testing
pub fn vector_tensor(data: Vec<f64>) -> CausalTensor<f64> {
    let len = data.len();
    CausalTensor::new(data, vec![len]).unwrap()
}

// Helper function to create a simple matrix tensor for testing
pub fn matrix_tensor(data: Vec<f64>, rows: usize, cols: usize) -> CausalTensor<f64> {
    CausalTensor::new(data, vec![rows, cols]).unwrap()
}

pub fn tensor_3d(data: Vec<f64>, dim0: usize, dim1: usize, dim2: usize) -> CausalTensor<f64> {
    CausalTensor::new(data, vec![dim0, dim1, dim2]).unwrap()
}
