/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use std::collections::{BTreeMap, HashMap, VecDeque};
use std::hash::Hash;

// Extension trait http://xion.io/post/code/rust-extension-traits.html
use crate::{Observable, ObservableReasoning};

//
// [T]
//
impl<T> ObservableReasoning<T> for [T]
where
    T: Observable,
{
    fn len(&self) -> usize {
        <[T]>::len(self)
    }

    fn is_empty(&self) -> bool {
        self.len() == 0
    }
    fn get_all_items(&self) -> Vec<&T> {
        self.iter().collect()
    }
}

//
//  Vec<T>
//
impl<T> ObservableReasoning<T> for Vec<T>
where
    T: Observable,
{
    fn len(&self) -> usize {
        Vec::len(self)
    }

    fn is_empty(&self) -> bool {
        Vec::is_empty(self)
    }
    fn get_all_items(&self) -> Vec<&T> {
        self.iter().collect()
    }
}

//
//  VecDeque
//
impl<T> ObservableReasoning<T> for VecDeque<T>
where
    T: Observable,
{
    fn len(&self) -> usize {
        VecDeque::len(self)
    }
    fn is_empty(&self) -> bool {
        VecDeque::is_empty(self)
    }
    fn get_all_items(&self) -> Vec<&T> {
        self.iter().collect()
    }
}

//
// HashMap<K, V>
//
impl<K, V> ObservableReasoning<V> for HashMap<K, V>
where
    K: Eq + Hash,
    V: Observable,
{
    fn len(&self) -> usize {
        HashMap::len(self)
    }
    fn is_empty(&self) -> bool {
        HashMap::is_empty(self)
    }
    fn get_all_items(&self) -> Vec<&V> {
        self.values().collect::<Vec<&V>>()
    }
}

//
// BTreeMap<K, V>
//
impl<K, V> ObservableReasoning<V> for BTreeMap<K, V>
where
    K: Ord,
    V: Observable,
{
    fn len(&self) -> usize {
        BTreeMap::len(self)
    }
    fn is_empty(&self) -> bool {
        BTreeMap::is_empty(self)
    }
    fn get_all_items(&self) -> Vec<&V> {
        self.values().collect::<Vec<&V>>()
    }
}
