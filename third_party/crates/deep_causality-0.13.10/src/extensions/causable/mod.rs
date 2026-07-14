/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

// Extension trait http://xion.io/post/code/rust-extension-traits.html
use std::collections::{BTreeMap, HashMap, VecDeque};
use std::fmt::Debug;
use std::hash::Hash;

use crate::IdentificationValue;
use crate::{
    Causable, CausableCollectionAccessor, Identifiable, MonadicCausable, MonadicCausableCollection,
    StatefulMonadicCausable, StatefulMonadicCausableCollection,
};

//
// [T]
//
impl<I, O, T> MonadicCausableCollection<I, O, T> for [T]
where
    T: MonadicCausable<I, O> + Clone + Causable,
    O: crate::utils::monadic_collection_utils::Aggregatable
        + Clone
        + Default
        + Send
        + Sync
        + 'static
        + Debug,
{
}

impl<I, O, S, C, T> StatefulMonadicCausableCollection<I, O, S, C, T> for [T]
where
    T: MonadicCausable<I, O> + StatefulMonadicCausable<I, O, S, C> + Clone + Causable,
    I: Clone,
    O: crate::utils::monadic_collection_utils::Aggregatable
        + Clone
        + Default
        + Send
        + Sync
        + 'static
        + Debug,
    S: Clone + Default,
    C: Clone,
{
}

impl<I, O, T> CausableCollectionAccessor<I, O, T> for [T]
where
    T: MonadicCausable<I, O> + Clone + Identifiable,
{
    fn get_all_items(&self) -> Vec<&T> {
        self.iter().collect()
    }

    fn len(&self) -> usize {
        <[T]>::len(self)
    }

    fn is_empty(&self) -> bool {
        self.len() == 0
    }

    fn to_vec(&self) -> Vec<T> {
        self.to_vec()
    }

    fn get_item_by_id(&self, id: IdentificationValue) -> Option<&T> {
        self.iter().find(|&item| item.id() == id)
    }
}

//
//  VecDeque
//
impl<I, O, T> MonadicCausableCollection<I, O, T> for VecDeque<T>
where
    T: MonadicCausable<I, O> + Causable + Clone,
    O: crate::utils::monadic_collection_utils::Aggregatable
        + Clone
        + Default
        + Send
        + Sync
        + 'static
        + Debug,
{
}

impl<I, O, S, C, T> StatefulMonadicCausableCollection<I, O, S, C, T> for VecDeque<T>
where
    T: MonadicCausable<I, O> + StatefulMonadicCausable<I, O, S, C> + Causable + Clone,
    I: Clone,
    O: crate::utils::monadic_collection_utils::Aggregatable
        + Clone
        + Default
        + Send
        + Sync
        + 'static
        + Debug,
    S: Clone + Default,
    C: Clone,
{
}

impl<I, O, T> CausableCollectionAccessor<I, O, T> for VecDeque<T>
where
    T: MonadicCausable<I, O> + Clone + Identifiable,
{
    fn get_all_items(&self) -> Vec<&T> {
        self.iter().collect()
    }

    fn len(&self) -> usize {
        VecDeque::len(self)
    }

    fn is_empty(&self) -> bool {
        VecDeque::is_empty(self)
    }

    fn to_vec(&self) -> Vec<T> {
        self.iter().cloned().collect()
    }

    fn get_item_by_id(&self, id: IdentificationValue) -> Option<&T> {
        self.iter().find(|&item| item.id() == id)
    }
}

//
// HashMap<K, V>
//
impl<I, O, K, V> MonadicCausableCollection<I, O, V> for HashMap<K, V>
where
    K: Eq + Hash,
    V: MonadicCausable<I, O> + Causable + Clone,
    O: crate::utils::monadic_collection_utils::Aggregatable
        + Clone
        + Default
        + Send
        + Sync
        + 'static
        + Debug,
{
}

impl<I, O, S, C, K, V> StatefulMonadicCausableCollection<I, O, S, C, V> for HashMap<K, V>
where
    K: Eq + Hash,
    V: MonadicCausable<I, O> + StatefulMonadicCausable<I, O, S, C> + Causable + Clone,
    I: Clone,
    O: crate::utils::monadic_collection_utils::Aggregatable
        + Clone
        + Default
        + Send
        + Sync
        + 'static
        + Debug,
    S: Clone + Default,
    C: Clone,
{
}

impl<I, O, K, V> CausableCollectionAccessor<I, O, V> for HashMap<K, V>
where
    K: Eq + Hash,
    V: MonadicCausable<I, O> + Clone + Identifiable,
{
    fn get_all_items(&self) -> Vec<&V> {
        self.values().collect::<Vec<&V>>()
    }

    fn len(&self) -> usize {
        HashMap::len(self)
    }

    fn is_empty(&self) -> bool {
        HashMap::is_empty(self)
    }

    fn to_vec(&self) -> Vec<V> {
        self.values().cloned().collect()
    }

    fn get_item_by_id(&self, id: IdentificationValue) -> Option<&V> {
        self.values().find(|&item| item.id() == id)
    }
}

//
// BTreeMap<K, V>
//
impl<I, O, K, V> MonadicCausableCollection<I, O, V> for BTreeMap<K, V>
where
    K: Ord,
    V: MonadicCausable<I, O> + Causable + Clone,
    O: crate::utils::monadic_collection_utils::Aggregatable
        + Clone
        + Default
        + Send
        + Sync
        + 'static
        + Debug,
{
}

impl<I, O, S, C, K, V> StatefulMonadicCausableCollection<I, O, S, C, V> for BTreeMap<K, V>
where
    K: Ord,
    V: MonadicCausable<I, O> + StatefulMonadicCausable<I, O, S, C> + Causable + Clone,
    I: Clone,
    O: crate::utils::monadic_collection_utils::Aggregatable
        + Clone
        + Default
        + Send
        + Sync
        + 'static
        + Debug,
    S: Clone + Default,
    C: Clone,
{
}

impl<I, O, K, V> CausableCollectionAccessor<I, O, V> for BTreeMap<K, V>
where
    K: Ord,
    V: MonadicCausable<I, O> + Causable + Clone + Identifiable,
{
    fn get_all_items(&self) -> Vec<&V> {
        self.values().collect::<Vec<&V>>()
    }

    fn len(&self) -> usize {
        BTreeMap::len(self)
    }

    fn is_empty(&self) -> bool {
        BTreeMap::is_empty(self)
    }

    fn to_vec(&self) -> Vec<V> {
        self.values().cloned().collect()
    }

    fn get_item_by_id(&self, id: IdentificationValue) -> Option<&V> {
        self.values().find(|&item| item.id() == id)
    }
}
