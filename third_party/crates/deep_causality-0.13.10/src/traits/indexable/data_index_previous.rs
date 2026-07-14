/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::DataIndexable;

const PREVIOUS_DATA_INDEX_KEY: usize = 0;

pub trait PreviousDataIndex: DataIndexable {
    /// Get the previous data index.
    ///
    /// # Parameters
    ///
    /// * `key` - The key to look up in the index map
    ///
    /// # Returns
    ///
    /// The previous data index as a `usize`.
    ///
    fn get_previous_data_index(&self) -> Option<&usize> {
        self.get_data_index(&PREVIOUS_DATA_INDEX_KEY, false)
    }

    /// Set the current previous index.
    ///
    /// # Parameters
    ///
    /// * `key` - The key of the previous data index to place in the index map
    /// * `index` - The previous data index to set as a `usize`
    ///
    fn set_previous_data_index(&mut self, index: usize) {
        self.set_data_index(PREVIOUS_DATA_INDEX_KEY, index, false)
    }
}
