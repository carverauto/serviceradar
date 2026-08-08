//! `cmov` property-based tests: randomized with shrinking.

#![cfg(any(unix, windows))]

/// Write the proptests for an integer type.
macro_rules! int_proptests {
    ( $($int:ident),+ ) => {
        $(
            mod $int {
                use cmov::{Cmov, CmovEq};
                use proptest::prelude::*;

                proptest! {
                    #[test]
                    fn cmovz_works(mut a in any::<$int>(), b in any::<$int>(), cond in any::<u8>()) {
                        let expected = if cond == 0 {
                            b
                        } else {
                            a
                        };

                        a.cmovz(&b, cond);
                        prop_assert_eq!(expected, a);
                    }

                    #[test]
                    fn cmovnz_works(mut a in any::<$int>(), b in any::<$int>(), cond in any::<u8>()) {
                        let expected = if cond != 0 {
                            b
                        } else {
                            a
                        };

                        a.cmovnz(&b, cond);
                        prop_assert_eq!(expected, a);
                    }

                    #[test]
                     fn cmoveq_works(a in any::<$int>(), b in any::<$int>(), cond in any::<u8>()) {
                        let expected = if a == b {
                            cond
                        } else {
                            0
                        };

                        let mut actual = 0;
                        a.cmoveq(&b, cond, &mut actual);
                        prop_assert_eq!(expected, actual);
                     }

                    #[test]
                     fn cmovne_works(a in any::<$int>(), b in any::<$int>(), cond in any::<u8>()) {
                        let expected = if a != b {
                            cond
                        } else {
                            0
                        };

                        let mut actual = 0;
                        a.cmovne(&b, cond, &mut actual);
                        prop_assert_eq!(expected, actual);
                     }
                }
            }
        )+
    };
}

/// Write the proptests for a byte array of the given size.
macro_rules! byte_array_proptests {
    ( $($name:ident: $size:expr),+ ) => {
        $(
            mod $name {
                use cmov::Cmov;
                use proptest::prelude::*;

                proptest! {
                    #[test]
                    fn cmovnz_works(
                        mut a in any::<[u8; $size]>(),
                        b in any::<[u8; $size]>(),
                        cond in any::<u8>()
                    ) {
                        let expected = if cond == 0 {
                            a
                        } else {
                            b
                        };

                        a.cmovnz(&b, cond);
                        prop_assert_eq!(expected, a);
                    }
                }
            }
        )+
    };
}

int_proptests!(
    i8, i16, i32, i64, i128, isize, u8, u16, u32, u64, u128, usize
);
byte_array_proptests!(
    array0: 0,
    array1: 1,
    array2: 2,
    array3: 3,
    array4: 4,
    array5: 5,
    array6: 6,
    array7: 7,
    array8: 8,
    array9: 9,
    array10: 10,
    array11: 11,
    array12: 12,
    array13: 13,
    array14: 14,
    array15: 15,
    array16: 16,
    array17: 17,
    array18: 18,
    array19: 19,
    array20: 20,
    array21: 21,
    array22: 22,
    array23: 23,
    array24: 24
);
