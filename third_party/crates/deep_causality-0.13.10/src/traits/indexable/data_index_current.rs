/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::DataIndexable;

const CURRENT_DATA_INDEX_KEY: usize = 1;

pub trait CurrentDataIndex: DataIndexable {
    /// Get the current data index.
    ///
    /// # Parameters
    ///
    /// * `key` - The key to look up in the index map
    ///
    /// # Returns
    ///
    /// The current data index as a `usize`.
    ///
    fn get_current_data_index(&self) -> Option<&usize> {
        self.get_data_index(&CURRENT_DATA_INDEX_KEY, true)
    }

    /// Set the current data index.
    ///
    /// # Parameters
    ///
    /// * `key` - The key of the index to place in the index map
    /// * `index` - The data index to set as a `usize`
    ///
    fn set_current_data_index(&mut self, index: usize) {
        self.set_data_index(CURRENT_DATA_INDEX_KEY, index, true)
    }
}
