//! Integration tests.

#![allow(clippy::cast_possible_truncation, clippy::unwrap_used)]

use core::{
    borrow::{Borrow, BorrowMut},
    cmp::Ordering,
    mem::MaybeUninit,
};
use hybrid_array::{Array, ArrayN};
use typenum::{U0, U2, U3, U4, U5, U6, U7};

const EXAMPLE_SLICE: &[u8] = &[1, 2, 3, 4, 5, 6];

/// Ensure `ArrayN` works as expected.
const _FOO: ArrayN<u8, 4> = Array([1, 2, 3, 4]);

#[test]
fn as_flattened() {
    type A = Array<u8, U2>;
    type B = Array<A, U2>;

    let mut array: B = Array([Array([b't', b'e']), Array([b's', b't'])]);
    assert_eq!(array.as_flattened(), b"test");
    assert_eq!(array.as_flattened_mut(), b"test");
}

#[test]
fn as_ref_core_array() {
    type A = Array<u8, U2>;
    let array: A = Array([1, 2]);
    let array_ref: &[u8; 2] = array.as_ref();
    assert_eq!(&array, array_ref);
}

#[test]
fn as_ref_identity() {
    type A = Array<u8, U2>;
    let array: A = Array([1, 2]);
    let array_ref: &A = array.as_ref();
    assert_eq!(&array, array_ref);
}

#[test]
fn as_ref_slice() {
    type A = Array<u8, U2>;
    let array: A = Array([1, 2]);
    let slice: &[u8] = array.as_ref();
    assert_eq!(array.as_slice(), slice);
}

#[test]
fn as_mut_core_array() {
    type A = Array<u8, U2>;
    let mut array: A = Array([1, 2]);
    let array_ref: &mut [u8; 2] = array.as_mut();
    assert_eq!(&[1, 2], array_ref);
}

#[test]
fn as_mut_identity() {
    type A = Array<u8, U2>;
    let mut array: A = Array([1, 2]);
    let array_ref: &mut A = array.as_mut();
    assert_eq!(&[1, 2], array_ref);
}

#[test]
fn as_mut_slice() {
    type A = Array<u8, U2>;
    let mut array: A = Array([1, 2]);
    let slice: &mut [u8] = array.as_mut();
    assert_eq!(&[1, 2], slice);
}

#[test]
fn borrow_core_array() {
    type A = Array<u8, U2>;
    let array: A = Array([1, 2]);
    let array_ref: &[u8; 2] = array.borrow();
    assert_eq!(&array, array_ref);
}

#[test]
fn borrow_identity() {
    type A = Array<u8, U2>;
    let array: A = Array([1, 2]);
    let array_ref: &A = array.borrow();
    assert_eq!(&array, array_ref);
}

#[test]
fn borrow_slice() {
    type A = Array<u8, U2>;
    let array: A = Array([1, 2]);
    let slice: &[u8] = array.borrow();
    assert_eq!(array.as_slice(), slice);
}

#[test]
fn borrow_mut_identity() {
    type A = Array<u8, U2>;
    let mut array: A = Array([1, 2]);
    let array_ref: &mut A = array.borrow_mut();
    assert_eq!(&[1, 2], array_ref);
}

#[test]
fn borrow_mut_core_array() {
    type A = Array<u8, U2>;
    let mut array: A = Array([1, 2]);
    let array_ref: &mut [u8; 2] = array.borrow_mut();
    assert_eq!(&[1, 2], array_ref);
}

#[test]
fn borrow_mut_slice() {
    type A = Array<u8, U2>;
    let mut array: A = Array([1, 2]);
    let slice: &mut [u8] = array.borrow_mut();
    assert_eq!(&[1, 2], slice);
}

#[test]
fn cast_slice_from_core() {
    type A = Array<u8, U2>;
    let slice = A::cast_slice_from_core(&[[1, 2], [3, 4]]);
    assert_eq!(slice[0], Array([1, 2]));
    assert_eq!(slice[1], Array([3, 4]));
}

#[test]
fn cast_slice_from_core_mut() {
    type A = Array<u8, U2>;
    let mut arr = [[1, 2], [3, 4]];
    let slice = A::cast_slice_from_core_mut(&mut arr);
    assert_eq!(slice[0], Array([1, 2]));
    assert_eq!(slice[1], Array([3, 4]));
}

#[test]
fn cast_slice_to_core() {
    type A = Array<u8, U2>;
    let arr = [Array([1, 2]), Array([3, 4])];
    let slice = A::cast_slice_to_core(&arr);
    assert_eq!(slice[0], [1, 2]);
    assert_eq!(slice[1], [3, 4]);
}

#[test]
fn cast_slice_to_core_mut() {
    type A = Array<u8, U2>;
    let mut arr = [Array([1, 2]), Array([3, 4])];
    let slice = A::cast_slice_to_core_mut(&mut arr);
    assert_eq!(slice[0], [1, 2]);
    assert_eq!(slice[1], [3, 4]);
}

#[test]
fn cmp() {
    type A = Array<u8, U2>;
    let a1: A = Array([0, 0]);
    let a2: A = Array([0, 1]);
    let a3: A = Array([1, 0]);

    assert_eq!(a1.cmp(&a1), Ordering::Equal);
    assert_eq!(a1.cmp(&a2), Ordering::Less);
    assert_eq!(a2.cmp(&a1), Ordering::Greater);
    assert_eq!(a2.cmp(&a2), Ordering::Equal);
    assert_eq!(a2.cmp(&a3), Ordering::Less);
    assert_eq!(a3.cmp(&a2), Ordering::Greater);
    assert_eq!(a3.cmp(&a3), Ordering::Equal);

    assert_eq!(a1.partial_cmp(&a1), Some(Ordering::Equal));
    assert_eq!(a1.partial_cmp(&a2), Some(Ordering::Less));
    assert_eq!(a2.partial_cmp(&a1), Some(Ordering::Greater));
    assert_eq!(a2.partial_cmp(&a2), Some(Ordering::Equal));
    assert_eq!(a2.partial_cmp(&a3), Some(Ordering::Less));
    assert_eq!(a3.partial_cmp(&a2), Some(Ordering::Greater));
    assert_eq!(a3.partial_cmp(&a3), Some(Ordering::Equal));
}

#[test]
fn debug() {
    let arr: Array<u8, U3> = Array([1, 2, 3]);
    assert_eq!(format!("{arr:?}"), "Array([1, 2, 3])");
}

#[test]
fn from_hybrid_array_for_core_array() {
    let hybrid_arr: Array<u8, U2> = Array([1, 2]);
    let core_arr = <[u8; 2]>::from(hybrid_arr);
    assert_eq!(core_arr, [1, 2]);
}

#[test]
fn from_hybrid_ref_for_core_ref() {
    let hybrid_arr: &Array<u8, U2> = &Array([1, 2]);
    let core_arr = <&[u8; 2]>::from(hybrid_arr);
    assert_eq!(core_arr, &[1, 2]);
}

#[test]
fn from_hybrid_mut_for_core_mut() {
    let hybrid_arr: &mut Array<u8, U2> = &mut Array([1, 2]);
    let core_arr = <&mut [u8; 2]>::from(hybrid_arr);
    assert_eq!(core_arr, &[1, 2]);
}

#[test]
fn from_ref() {
    let n = 42u64;
    let array = Array::from_ref(&n);
    assert_eq!(array[0], n);
}

#[test]
#[allow(deprecated)]
fn from_slice_deprecated() {
    let slice = &[1, 2];
    assert_eq!(Array::<u8, U2>::from_slice(slice), slice);
}

#[test]
#[allow(deprecated)]
#[should_panic]
fn from_slice_deprecated_length_mismatch() {
    let slice = &[1, 2, 3];
    Array::<u8, U2>::from_slice(slice);
}

#[test]
#[allow(deprecated)]
fn from_mut_slice_deprecated() {
    let slice = &mut [1, 2];
    assert_eq!(Array::<u8, U2>::from_mut_slice(slice), &[1, 2]);
}

#[test]
#[allow(deprecated)]
#[should_panic]
fn from_mut_slice_deprecated_length_mismatch() {
    let slice = &mut [1, 2, 3];
    Array::<u8, U2>::from_mut_slice(slice);
}

#[test]
fn from_mut() {
    let mut n = 42u64;
    let array = Array::from_mut(&mut n);
    array[0] = 43;
    assert_eq!(n, 43);
}

#[test]
fn from_fn() {
    let array = Array::<u8, U6>::from_fn(|n| (n + 1) as u8);
    assert_eq!(array.as_slice(), EXAMPLE_SLICE);
}

#[test]
#[allow(clippy::std_instead_of_core)]
fn hash() {
    use std::hash::{DefaultHasher, Hash, Hasher};

    type A = Array<u8, U2>;
    let array1: A = Array([1, 2]);
    let array2: A = Array([1, 3]);

    let mut hasher1 = DefaultHasher::new();
    array1.hash(&mut hasher1);

    let mut hasher2 = DefaultHasher::new();
    array2.hash(&mut hasher2);

    assert_ne!(hasher1.finish(), hasher2.finish());
}

#[test]
fn tryfrom_slice_for_clonable_array() {
    assert!(Array::<u8, U0>::try_from(EXAMPLE_SLICE).is_err());
    assert!(Array::<u8, U3>::try_from(EXAMPLE_SLICE).is_err());

    let array_ref = Array::<u8, U6>::try_from(EXAMPLE_SLICE).expect("slice contains 6 bytes");
    assert_eq!(&*array_ref, EXAMPLE_SLICE);

    assert!(Array::<u8, U7>::try_from(EXAMPLE_SLICE).is_err());
}

#[test]
fn tryfrom_slice_for_array_ref() {
    assert!(<&Array<u8, U0>>::try_from(EXAMPLE_SLICE).is_err());
    assert!(<&Array::<u8, U3>>::try_from(EXAMPLE_SLICE).is_err());

    let array_ref = <&Array<u8, U6>>::try_from(EXAMPLE_SLICE).expect("slice contains 6 bytes");
    assert_eq!(array_ref.as_slice(), EXAMPLE_SLICE);

    assert!(<&Array::<u8, U7>>::try_from(EXAMPLE_SLICE).is_err());
}

#[test]
fn tryfrom_mut_slice_for_array_mut() {
    let mut example_arr = [1, 2, 3, 4, 5, 6];

    assert!(<&mut Array<u8, U0>>::try_from(example_arr.as_mut()).is_err());
    assert!(<&mut Array::<u8, U3>>::try_from(example_arr.as_mut()).is_err());

    let array_ref =
        <&mut Array<u8, U6>>::try_from(example_arr.as_mut()).expect("slice contains 6 bytes");
    assert_eq!(array_ref.as_slice(), EXAMPLE_SLICE);

    assert!(<&mut Array::<u8, U7>>::try_from(example_arr.as_mut()).is_err());
}

#[test]
fn slice_as_array() {
    type A = Array<u8, U2>;
    assert_eq!(A::slice_as_array(&[]), None);
    assert_eq!(A::slice_as_array(&[1]), None);
    assert_eq!(A::slice_as_array(&[1, 2]), Some(&Array([1, 2])));
    assert_eq!(A::slice_as_array(&[1, 2, 3]), None);
}

#[test]
fn slice_as_mut_array() {
    type A = Array<u8, U2>;
    assert_eq!(A::slice_as_mut_array(&mut []), None);
    assert_eq!(A::slice_as_mut_array(&mut [1]), None);
    assert_eq!(A::slice_as_mut_array(&mut [1, 2]), Some(&mut Array([1, 2])));
    assert_eq!(A::slice_as_mut_array(&mut [1, 2, 3]), None);
}

#[test]
fn slice_as_chunks() {
    type A = Array<u8, U2>;

    let (slice_empty, rem_empty) = A::slice_as_chunks(&[]);
    assert!(slice_empty.is_empty());
    assert!(rem_empty.is_empty());

    let (slice_one, rem_one) = A::slice_as_chunks(&[1]);
    assert!(slice_one.is_empty());
    assert_eq!(rem_one, &[1]);

    let (slice_aligned, rem_aligned) = A::slice_as_chunks(&[1u8, 2]);
    assert_eq!(slice_aligned, &[Array([1u8, 2])]);
    assert_eq!(rem_aligned, &[]);

    let (slice_unaligned, rem_unaligned) = A::slice_as_chunks(&[1u8, 2, 3]);
    assert_eq!(slice_unaligned, &[Array([1u8, 2])]);
    assert_eq!(rem_unaligned, &[3]);
}

#[test]
fn slice_as_chunks_mut() {
    type A = Array<u8, U2>;
    let mut input = [1u8, 2, 3];

    let (slice_empty, rem_empty) = A::slice_as_chunks_mut(&mut []);
    assert!(slice_empty.is_empty());
    assert!(rem_empty.is_empty());

    let (slice_one, rem_one) = A::slice_as_chunks_mut(&mut input[..1]);
    assert!(slice_one.is_empty());
    assert_eq!(rem_one, &[1]);

    let (slice_aligned, rem_aligned) = A::slice_as_chunks_mut(&mut input[..2]);
    assert_eq!(slice_aligned, &[Array([1u8, 2])]);
    assert_eq!(rem_aligned, &[]);

    let (slice_unaligned, rem_unaligned) = A::slice_as_chunks_mut(&mut input);
    assert_eq!(slice_unaligned, &[Array([1u8, 2])]);
    assert_eq!(rem_unaligned, &[3]);
}

#[test]
fn concat() {
    let prefix = Array::<u8, U2>::try_from(&EXAMPLE_SLICE[..2]).unwrap();
    let suffix = Array::<u8, U4>::try_from(&EXAMPLE_SLICE[2..]).unwrap();

    let array = prefix.concat(suffix);
    assert_eq!(array.as_slice(), EXAMPLE_SLICE);
}

#[test]
fn split() {
    let array = Array::<u8, U6>::try_from(EXAMPLE_SLICE).unwrap();
    let (prefix, suffix) = array.split::<U2>();

    assert_eq!(prefix.as_slice(), &EXAMPLE_SLICE[..2]);
    assert_eq!(suffix.as_slice(), &EXAMPLE_SLICE[2..]);
}

#[test]
fn split_ref() {
    let array = Array::<u8, U6>::try_from(EXAMPLE_SLICE).unwrap();
    let (prefix, suffix) = array.split_ref::<U3>();

    assert_eq!(prefix.as_slice(), &EXAMPLE_SLICE[..3]);
    assert_eq!(suffix.as_slice(), &EXAMPLE_SLICE[3..]);
}

#[test]
fn split_ref_mut() {
    let array = &mut Array::<u8, U6>::try_from(EXAMPLE_SLICE).unwrap();
    let (prefix, suffix) = array.split_ref_mut::<U4>();

    assert_eq!(prefix.as_slice(), &EXAMPLE_SLICE[..4]);
    assert_eq!(suffix.as_slice(), &EXAMPLE_SLICE[4..]);
}

#[test]
fn try_from_fn() {
    let array = Array::<u8, U6>::try_from_fn::<()>(|n| Ok((n + 1) as u8)).unwrap();
    assert_eq!(array.as_slice(), EXAMPLE_SLICE);

    let err = Array::<u8, U6>::try_from_fn::<&'static str>(|_| Err("err"))
        .err()
        .unwrap();

    assert_eq!(err, "err");
}

#[test]
fn from_iterator_correct_size() {
    let array: Array<u8, U6> = EXAMPLE_SLICE.iter().copied().collect();
    assert_eq!(array.as_slice(), EXAMPLE_SLICE);
}

#[test]
#[should_panic]
fn from_iterator_too_short() {
    let _array: Array<u8, U7> = EXAMPLE_SLICE.iter().copied().collect();
}

#[test]
#[should_panic]
fn from_iterator_too_long() {
    let _array: Array<u8, U5> = EXAMPLE_SLICE.iter().copied().collect();
}

#[test]
fn try_from_iterator_correct_size() {
    let array = Array::<u8, U6>::try_from_iter(EXAMPLE_SLICE.iter().copied()).unwrap();
    assert_eq!(array.as_slice(), EXAMPLE_SLICE);
}

#[test]
fn try_from_iterator_too_short() {
    let result = Array::<u8, U7>::try_from_iter(EXAMPLE_SLICE.iter().copied());
    assert!(result.is_err());
}

#[test]
fn try_from_iterator_too_long() {
    let result = Array::<u8, U5>::try_from_iter(EXAMPLE_SLICE.iter().copied());
    assert!(result.is_err());
}

#[test]
fn maybe_uninit() {
    let mut uninit_array = Array::<MaybeUninit<u8>, U6>::uninit();

    for i in 0..6 {
        uninit_array[i].write(EXAMPLE_SLICE[i]);
    }

    let array = unsafe { uninit_array.assume_init() };
    assert_eq!(array.as_slice(), EXAMPLE_SLICE);
}

#[test]
fn map() {
    let base = Array::<u8, U4>::from([1, 2, 3, 4]);
    let expected = Array::<u16, U4>::from([2, 3, 4, 5]);
    assert_eq!(base.map(|item| u16::from(item) + 1), expected);
}

#[test]
#[allow(deprecated)]
fn clone_from_slice() {
    let array = Array::<u8, U6>::clone_from_slice(EXAMPLE_SLICE);
    assert_eq!(array.as_slice(), EXAMPLE_SLICE);
}

#[test]
fn slice_as_flattened() {
    let slice: &mut [Array<u8, U4>] = &mut [Array([1, 2, 3, 4]), Array([5, 6, 7, 8])];
    assert_eq!(
        Array::slice_as_flattened_mut(slice),
        &mut [1, 2, 3, 4, 5, 6, 7, 8]
    );
    assert_eq!(Array::slice_as_flattened(slice), &[1, 2, 3, 4, 5, 6, 7, 8]);
}

#[cfg(feature = "alloc")]
mod allocating {
    use super::*;
    use typenum::U4;

    #[test]
    fn array_try_from_boxed_slice() {
        type A = Array<u8, U2>;
        assert!(A::try_from(vec![1].into_boxed_slice()).is_err());
        assert_eq!(
            &A::try_from(vec![1, 2].into_boxed_slice()).unwrap(),
            &[1, 2]
        );
    }

    #[test]
    fn array_try_from_boxed_slice_ref() {
        type A = Array<u8, U2>;
        assert!(A::try_from(&vec![1].into_boxed_slice()).is_err());
        assert_eq!(
            &A::try_from(&vec![1, 2].into_boxed_slice()).unwrap(),
            &[1, 2]
        );
    }

    #[test]
    fn array_try_from_vec() {
        type A = Array<u8, U2>;
        assert!(A::try_from(vec![1]).is_err());
        assert_eq!(&A::try_from(vec![1, 2]).unwrap(), &[1, 2]);
    }

    #[test]
    fn array_try_from_vec_ref() {
        type A = Array<u8, U2>;
        assert!(A::try_from(&vec![1]).is_err());
        assert_eq!(&A::try_from(&vec![1, 2]).unwrap(), &[1, 2]);
    }

    #[test]
    fn boxed_slice_from_array() {
        let array: Array<u8, U4> = Array([1, 2, 3, 4]);
        let boxed_slice1: Box<[u8]> = Box::from(array);
        assert_eq!(&*boxed_slice1, &[1, 2, 3, 4]);

        let boxed_slice2: Box<[u8]> = Box::from(&array);
        assert_eq!(&*boxed_slice2, &[1, 2, 3, 4]);
    }

    #[test]
    fn vec_from_array() {
        let array: Array<u8, U4> = Array([1, 2, 3, 4]);
        let vec1: Vec<u8> = Vec::from(array);
        assert_eq!(&vec1, &[1, 2, 3, 4]);

        let vec2: Vec<u8> = Vec::from(&array);
        assert_eq!(&*vec2, &[1, 2, 3, 4]);
    }
}

#[cfg(feature = "arbitrary")]
#[test]
fn arbitrary() {
    use arbitrary::{Arbitrary, Unstructured};
    let mut unstructured = Unstructured::new(EXAMPLE_SLICE);
    let array = Array::<u8, U4>::arbitrary(&mut unstructured).unwrap();
    assert_eq!(array.as_slice(), &[1, 2, 3, 4]);
}

#[cfg(feature = "zerocopy")]
#[test]
#[allow(unused)]
fn zerocopy_traits() {
    use zerocopy::{FromBytes, Immutable, IntoBytes, KnownLayout, Unaligned};
    struct Check<T: IntoBytes + FromBytes + Unaligned + Immutable + KnownLayout>(T);
    let ok: Check<Array<u8, U5>> = Check(Array([1, 2, 3, 4, 5]));
    // let not_unaligned:  Check::<Array<u16, U5>> = Check(Array([1, 2, 3, 4, 5]));
}

#[cfg(feature = "zeroize")]
#[test]
fn zeroize_array() {
    use zeroize::Zeroize;

    let mut array: Array<u8, U3> = Array([1, 2, 3]);
    array.zeroize();
    assert_eq!(&array, &[0, 0, 0]);
}
