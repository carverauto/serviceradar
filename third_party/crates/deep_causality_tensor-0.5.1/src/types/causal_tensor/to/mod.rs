/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::CausalTensor;

impl<T> CausalTensor<T> {
    pub fn from_vec(data: Vec<T>, shape: &[usize]) -> Self {
        Self::new(data, shape.to_vec()).unwrap()
    }

    /// Consumes the tensor and returns the underlying data.
    pub fn into_vec(self) -> Vec<T> {
        self.data
    }

    pub fn to_vec(self) -> Vec<T> {
        self.data
    }
}
