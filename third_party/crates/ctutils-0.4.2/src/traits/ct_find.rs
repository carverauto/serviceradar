use crate::{Choice, CtAssign, CtOption};

#[cfg(doc)]
use core::iter::Iterator;

/// Constant-time equivalent of [`Iterator::find`], which can search a collection by iterating over
/// every element and applying the given predicate to each item, then selecting the first matching
/// entry.
pub trait CtFind<T: CtAssign> {
    /// Iterate through every `T` item in `&self`, applying the given `predicate` which can select
    /// a specific item by returning [`Choice::TRUE`].
    ///
    /// The first item where `predicate` returns [`Choice::TRUE`] is selected, or the [`CtOption`]
    /// equivalent of `None` is returned if the `predicate` returns [`Choice::FALSE`] for all items.
    #[must_use]
    fn ct_find<P>(&self, predicate: P) -> CtOption<T>
    where
        P: Fn(&T) -> Choice;
}

impl<T> CtFind<T> for [T]
where
    T: CtAssign + Default,
{
    #[inline]
    fn ct_find<P>(&self, predicate: P) -> CtOption<T>
    where
        P: Fn(&T) -> Choice,
    {
        let mut ret = CtOption::none();

        for item in self {
            ret.insert_if(item, predicate(item) & ret.is_none());
        }

        ret
    }
}

impl<T, const N: usize> CtFind<T> for [T; N]
where
    T: CtAssign + Default,
{
    #[inline]
    fn ct_find<P>(&self, predicate: P) -> CtOption<T>
    where
        P: Fn(&T) -> Choice,
    {
        self.as_slice().ct_find(predicate)
    }
}

#[cfg(feature = "alloc")]
mod alloc {
    use super::{Choice, CtAssign, CtFind, CtOption};
    use ::alloc::{boxed::Box, vec::Vec};

    impl<T> CtFind<T> for Box<[T]>
    where
        T: CtAssign + Default,
    {
        #[inline]
        fn ct_find<P>(&self, predicate: P) -> CtOption<T>
        where
            P: Fn(&T) -> Choice,
        {
            (**self).ct_find(predicate)
        }
    }

    #[cfg(feature = "alloc")]
    impl<T> CtFind<T> for Vec<T>
    where
        T: CtAssign + Default,
    {
        #[inline]
        fn ct_find<P>(&self, predicate: P) -> CtOption<T>
        where
            P: Fn(&T) -> Choice,
        {
            self.as_slice().ct_find(predicate)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::CtFind;

    mod array {
        use super::*;
        use crate::{CtEq, CtGt};

        const ARRAY: [u8; 6] = [0, 0, 0, 1, 2, 3];

        #[test]
        fn ct_find() {
            // Find the first nonzero even number
            assert_eq!(
                ARRAY.ct_find(|n| n.ct_ne(&0) & (n & 1).ct_eq(&0)).unwrap(),
                2
            );

            // Predicate where nothing matches
            assert!(ARRAY.ct_find(|n| n.ct_gt(&3)).is_none().to_bool());
        }
    }

    mod slice {
        use super::*;
        use crate::{CtEq, CtGt};

        const SLICE: &[u8] = &[0, 0, 0, 1, 2, 3];

        #[test]
        fn ct_find() {
            // Find the first nonzero even number
            assert_eq!(
                SLICE.ct_find(|n| n.ct_ne(&0) & (n & 1).ct_eq(&0)).unwrap(),
                2
            );

            // Predicate where nothing matches
            assert!(SLICE.ct_find(|n| n.ct_gt(&3)).is_none().to_bool());
        }
    }
}
