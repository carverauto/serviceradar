/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::PointCloud;
use crate::traits::base_topology::BaseTopology;

impl<C, D> BaseTopology for PointCloud<C, D> {
    fn dimension(&self) -> usize {
        0
    }

    fn len(&self) -> usize {
        self.len()
    }

    fn is_empty(&self) -> bool {
        self.is_empty()
    }

    fn num_elements_at_grade(&self, grade: usize) -> Option<usize> {
        if grade == 0 { Some(self.len()) } else { None }
    }
}
