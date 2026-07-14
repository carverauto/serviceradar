/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::TangentSpacetime;
use crate::traits::contextuable::metric_tensor::MetricTensor4D;

impl MetricTensor4D for TangentSpacetime {
    fn metric_tensor(&self) -> [[f64; 4]; 4] {
        self.metric
    }

    fn update_metric_tensor(&mut self, new_metric: [[f64; 4]; 4]) {
        self.metric = new_metric;
    }
}
