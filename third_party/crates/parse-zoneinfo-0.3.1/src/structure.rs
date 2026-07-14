//! Determining the structure of a set of ruleset names.
//!
//! The names of time zones in the zoneinfo database are of the form
//! `Area/Location`, or more rarely, `Area/Location/Sublocation`. This means
//! they form a hierarchy, with each level either serving as a time zone
//! itself (usually a location) or as a parent of multiple other entries
//! (usually an area).
//!
//! When generating Rust code containing the timezone data, we need to
//! generate the entire tree structure, not just the leaves of actual timezone
//! data. This module determines that structure, allowing it to be created
//! before any actual timezone data is written.
//!
//! For example, say we have the following subset of time zone entries:
//!
//! - America/Antigua
//! - America/Araguaina
//! - America/Argentina/Buenos_Aires
//! - America/Argentina/Catamarca
//! - America/Argentina/Cordoba
//! - America/Aruba
//!
//! On top of the six actual time zone files, we would need to create the following:
//!
//! - An America module that has three private submodules (Antigua, Araguaína,
//!   and Aruba) and one public submodule (Argentina);
//! - An America/Argentina submodule that has there private submodules (Buenos
//!   Aires, Catamarca, Cordoba).
//!
//! This module contains an iterator that finds all parent zonesets, and
//! sorts them so they’re output in a correct order.

use std::collections::{BTreeMap, BTreeSet};

use crate::table::Table;

/// Trait to put the `structure` method on Tables.
pub trait Structure {
    /// Returns an iterator over the structure of this table.
    fn structure(&self) -> TableStructure;
}

impl Structure for Table {
    fn structure(&self) -> TableStructure {
        let mut mappings = BTreeMap::new();

        for key in self.zonesets.keys().chain(self.links.keys()) {
            // Extract the name from the *last* slash. So
            // `America/Kentucky/Louisville` is split into
            // `America/Kentucky` and `Louisville` components.
            let last_slash = match key.rfind('/') {
                Some(pos) => pos,
                None => continue,
            };

            // Split the string around the slash, which gets removed.
            let parent = &key[..last_slash];
            {
                let set = mappings.entry(parent).or_insert_with(BTreeSet::new);
                set.insert(Child::TimeZone(&key[last_slash + 1..]));
            }

            // If the *parent* name still has a slash in it, then this is
            // a time zone of the form `America/Kentucky/Louisville`. We
            // need to make sure that `America` now has a `Kentucky`
            // child, too.
            if let Some(first_slash) = parent.find('/') {
                let grandparent = &parent[..first_slash];
                let set = mappings.entry(grandparent).or_insert_with(BTreeSet::new);
                set.insert(Child::Submodule(&parent[first_slash + 1..]));
            }
        }

        TableStructure { mappings }
    }
}

/// The structure of a set of time zone names.
#[derive(PartialEq, Debug)]
pub struct TableStructure<'table> {
    mappings: BTreeMap<&'table str, BTreeSet<Child<'table>>>,
}

impl<'table> IntoIterator for TableStructure<'table> {
    type Item = TableStructureEntry<'table>;
    type IntoIter = Iter<'table>;

    fn into_iter(self) -> Self::IntoIter {
        // It’s necessary to sort the keys before producing them, to
        // ensure that (for example) `America` is produced before
        // `America/Kentucky`.
        let mut keys: Vec<_> = self.mappings.keys().cloned().collect();
        keys.sort_by(|a, b| b.cmp(a));

        Iter {
            structure: self,
            keys,
        }
    }
}

/// Iterator over sorted entries in a `TableStructure`.
#[derive(PartialEq, Debug)]
pub struct Iter<'table> {
    structure: TableStructure<'table>,
    keys: Vec<&'table str>,
}

impl<'table> Iterator for Iter<'table> {
    type Item = TableStructureEntry<'table>;

    fn next(&mut self) -> Option<Self::Item> {
        let key = self.keys.pop()?;

        // Move the strings out into an (automatically-sorted) vector.
        let values = self.structure.mappings[key].iter().cloned().collect();

        Some(TableStructureEntry {
            name: key,
            children: values,
        })
    }
}

/// An entry returned from a `TableStructure` iterator.
#[derive(PartialEq, Debug)]
pub struct TableStructureEntry<'table> {
    /// This entry’s name, which *can* still include slashes.
    pub name: &'table str,

    /// A vector of sorted child names, which should have no slashes in.
    pub children: Vec<Child<'table>>,
}

/// A child module that needs to be created.
///
/// The order here is important for `PartialOrd`: submodules need to be
/// created before actual time zones, as directories need to be created
/// before the files in them can be written.
#[derive(PartialEq, Eq, PartialOrd, Ord, Debug, Copy, Clone)]
pub enum Child<'table> {
    /// A module containing **only** submodules, no time zones.
    Submodule(&'table str),

    /// A module containing **only** the details of a time zone.
    TimeZone(&'table str),
}

#[cfg(test)]
#[allow(unused_results)]
mod test {
    use super::*;
    use crate::table::Table;

    #[test]
    fn empty() {
        let table = Table::default();
        let mut structure = table.structure().into_iter();
        assert_eq!(structure.next(), None);
    }

    #[test]
    fn separate() {
        let mut table = Table::default();
        table.zonesets.insert("a".to_owned(), Vec::new());
        table.zonesets.insert("b".to_owned(), Vec::new());
        table.zonesets.insert("c".to_owned(), Vec::new());

        let mut structure = table.structure().into_iter();
        assert_eq!(structure.next(), None);
    }

    #[test]
    fn child() {
        let mut table = Table::default();
        table.zonesets.insert("a/b".to_owned(), Vec::new());

        let mut structure = table.structure().into_iter();
        assert_eq!(
            structure.next(),
            Some(TableStructureEntry {
                name: "a",
                children: vec![Child::TimeZone("b")]
            })
        );
        assert_eq!(structure.next(), None);
    }

    #[test]
    fn hierarchy() {
        let mut table = Table::default();
        table.zonesets.insert("a/b/c".to_owned(), Vec::new());
        table.zonesets.insert("a/b/d".to_owned(), Vec::new());
        table.zonesets.insert("a/e".to_owned(), Vec::new());

        let mut structure = table.structure().into_iter();
        assert_eq!(
            structure.next(),
            Some(TableStructureEntry {
                name: "a",
                children: vec![Child::Submodule("b"), Child::TimeZone("e")]
            })
        );
        assert_eq!(
            structure.next(),
            Some(TableStructureEntry {
                name: "a/b",
                children: vec![Child::TimeZone("c"), Child::TimeZone("d")]
            })
        );
        assert_eq!(structure.next(), None);
    }
}
