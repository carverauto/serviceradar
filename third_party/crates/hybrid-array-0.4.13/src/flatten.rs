use crate::{
    Array, ArraySize,
    typenum::{Prod, Quot, U0, Unsigned},
};
use core::{
    mem::ManuallyDrop,
    ops::{Div, Mul, Rem},
    ptr,
};

/// Defines a sequence of sequences that can be merged into a bigger overall sequence.
pub trait Flatten<T, M: ArraySize> {
    /// Size of the output array.
    type OutputSize: ArraySize;

    /// Flatten array.
    fn flatten(self) -> Array<T, Self::OutputSize>;
}

impl<T, N, M> Flatten<T, Prod<M, N>> for Array<Array<T, M>, N>
where
    N: ArraySize,
    M: ArraySize + Mul<N>,
    Prod<M, N>: ArraySize,
{
    type OutputSize = Prod<M, N>;

    // SAFETY: this is the reverse transmute between [T; K*N] and [[T; K], M], which is guaranteed
    // to be safe by the Rust memory layout of these types.
    fn flatten(self) -> Array<T, Self::OutputSize> {
        let whole = ManuallyDrop::new(self);
        unsafe { ptr::read(whole.as_ptr().cast()) }
    }
}

/// Defines a sequence that can be split into a sequence of smaller sequences of uniform size.
pub trait Unflatten<M>
where
    M: ArraySize,
{
    /// Part of the array we're decomposing into.
    type Part;

    /// Unflatten array into `Self::Part` chunks.
    fn unflatten(self) -> Array<Self::Part, M>;
}

impl<T, N, M> Unflatten<M> for Array<T, N>
where
    N: ArraySize + Div<M> + Rem<M, Output = U0>,
    M: ArraySize,
    Quot<N, M>: ArraySize,
{
    type Part = Array<T, Quot<N, M>>;

    // SAFETY: this is doing the same thing as what is done in `Array::split`.
    // Basically, this is doing transmute between [T; K*N] and [[T; K], M], which is guaranteed to
    // be safe by the Rust memory layout of these types.
    fn unflatten(self) -> Array<Self::Part, M> {
        let part_size = Quot::<N, M>::USIZE;
        let whole = ManuallyDrop::new(self);
        Array::from_fn(|i| unsafe {
            let offset = i.checked_mul(part_size).expect("overflow");
            ptr::read(whole.as_ptr().add(offset).cast())
        })
    }
}

impl<'a, T, N, M> Unflatten<M> for &'a Array<T, N>
where
    N: ArraySize + Div<M> + Rem<M, Output = U0>,
    M: ArraySize,
    Quot<N, M>: ArraySize,
{
    type Part = &'a Array<T, Quot<N, M>>;

    // SAFETY: this is doing the same thing as what is done in `Array::split`.
    // Basically, this is doing transmute between [T; K*N] and [[T; K], M], which is guaranteed to
    // be safe by the Rust memory layout of these types.
    fn unflatten(self) -> Array<Self::Part, M> {
        let part_size = Quot::<N, M>::USIZE;
        let mut ptr: *const T = self.as_ptr();
        Array::from_fn(|_i| unsafe {
            let part = &*(ptr.cast());
            ptr = ptr.add(part_size);
            part
        })
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use crate::{
        Array,
        sizes::{U2, U5},
    };

    #[test]
    fn flatten() {
        let flat: Array<u8, _> = Array([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
        let unflat2: Array<Array<u8, _>, _> = Array([
            Array([1, 2]),
            Array([3, 4]),
            Array([5, 6]),
            Array([7, 8]),
            Array([9, 10]),
        ]);
        let unflat5: Array<Array<u8, _>, _> =
            Array([Array([1, 2, 3, 4, 5]), Array([6, 7, 8, 9, 10])]);

        // Flatten
        let actual = unflat2.flatten();
        assert_eq!(flat, actual);

        let actual = unflat5.flatten();
        assert_eq!(flat, actual);

        // Unflatten
        let actual: Array<Array<u8, U2>, U5> = flat.unflatten();
        assert_eq!(unflat2, actual);

        let actual: Array<Array<u8, U5>, U2> = flat.unflatten();
        assert_eq!(unflat5, actual);

        // Unflatten on references
        let actual: Array<&Array<u8, U2>, U5> = (&flat).unflatten();
        for (i, part) in actual.iter().enumerate() {
            assert_eq!(&unflat2[i], *part);
        }

        let actual: Array<&Array<u8, U5>, U2> = (&flat).unflatten();
        for (i, part) in actual.iter().enumerate() {
            assert_eq!(&unflat5[i], *part);
        }
    }
}
