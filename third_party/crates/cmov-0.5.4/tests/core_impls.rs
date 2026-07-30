//! Tests for `Cmov`/`CmovEq` impls on `core` types.

/// Write the tests for an integer type, given two unequal integers
macro_rules! int_tests {
    ($int:ident, $a:expr, $b:expr) => {
        mod $int {
            use cmov::{Cmov, CmovEq};

            #[test]
            fn cmovz_works() {
                let mut n: $int = $a;

                for cond in 1..0xFF {
                    n.cmovz(&$b, cond);
                    assert_eq!(n, $a);
                }

                n.cmovz(&$b, 0);
                assert_eq!(n, $b);

                n.cmovz(&<$int>::MAX, 0);
                assert_eq!(n, <$int>::MAX);
            }

            #[test]
            fn cmovnz_works() {
                let mut n = $a;
                n.cmovnz(&$b, 0);
                assert_eq!(n, $a);

                for cond in 1..0xFF {
                    let mut n = $a;
                    n.cmovnz(&$b, cond);
                    assert_eq!(n, $b);
                }
            }

            #[test]
            #[allow(
                trivial_numeric_casts,
                clippy::cast_possible_truncation,
                clippy::cast_sign_loss
            )]
            fn cmoveq_works() {
                let mut o = 0u8;

                // compare to zero (a and b should be non-zero)
                $a.cmoveq(&0, 1, &mut o);
                assert_eq!(o, 0);
                0.cmoveq(&$a, 1, &mut o);
                assert_eq!(o, 0);

                for cond in 1..(0x7F as $int) {
                    cond.cmoveq(&cond, cond as u8, &mut o);
                    assert_eq!(o, cond as u8);
                    cond.cmoveq(&0, 0, &mut o);
                    assert_eq!(o, cond as u8);
                }

                // equal so we move
                $a.cmoveq(&$a, 43u8, &mut o);
                assert_eq!(o, 43u8);

                // non-equal so we don't move
                $a.cmoveq(&$b, 55u8, &mut o);
                assert_eq!(o, 43u8);
                <$int>::MAX.cmoveq(&$a, 55u8, &mut o);
                assert_eq!(o, 43u8);

                // equal so we move
                <$int>::MAX.cmoveq(&<$int>::MAX, 55u8, &mut o);
                assert_eq!(o, 55u8);
            }

            #[test]
            #[allow(
                trivial_numeric_casts,
                clippy::cast_possible_truncation,
                clippy::cast_sign_loss
            )]
            fn cmovne_works() {
                let mut o = 0u8;

                // compare to zero (a and b should be non-zero)
                $a.cmovne(&0, 1, &mut o);
                assert_eq!(o, 1);
                o = 0;
                0.cmovne(&$a, 1, &mut o);
                assert_eq!(o, 1);
                o = 0;

                for cond in 1..(0x7F as $int) {
                    cond.cmovne(&0, cond as u8, &mut o);
                    assert_eq!(o, cond as u8);
                    cond.cmovne(&cond, 0, &mut o);
                    assert_eq!(o, cond as u8);
                }

                // non-equal so we move
                o = 0;
                $a.cmovne(&$b, 55u8, &mut o);
                assert_eq!(o, 55u8);

                // equal so we don't move
                $a.cmovne(&$a, 66u8, &mut o);
                assert_eq!(o, 55u8);
                <$int>::MAX.cmovne(&<$int>::MAX, 66u8, &mut o);
                assert_eq!(o, 55u8);

                // non-equal so we move
                <$int>::MAX.cmovne(&$a, 66u8, &mut o);
                assert_eq!(o, 66u8);
            }
        }
    };
}

int_tests!(i8, 0x11i8, -0x22i8);
int_tests!(i16, 0x1111i16, -0x2222i16);
int_tests!(i32, 0x1111_1111i32, -0x2222_2222i32);
int_tests!(i64, 0x1111_1111_1111_1111i64, -0x2222_2222_2222_2222i64);
int_tests!(
    i128,
    0x1111_1111_1111_1111_1111_1111_1111_1111i128,
    -0x2222_2222_2222_2222_2222_2222_2222_2222i128
);
int_tests!(isize, 0x1111isize, -0x2222isize);
int_tests!(u8, 0x11u8, 0x22u8);
int_tests!(u16, 0x1111u16, 0x2222u16);
int_tests!(u32, 0x1111_1111u32, 0x2222_2222u32);
int_tests!(u64, 0x1111_1111_1111_1111u64, 0x2222_2222_2222_2222u64);
int_tests!(
    u128,
    0x1111_1111_1111_1111_2222_2222_2222_2222u128,
    0x2222_2222_2222_2222_3333_3333_3333_3333u128
);
int_tests!(usize, 0x1111usize, 0x2222usize);

mod ordering {
    use cmov::{Cmov, CmovEq};
    use core::cmp::Ordering;

    #[test]
    fn cmovz_works() {
        let mut n: Ordering = Ordering::Less;

        n.cmovz(&Ordering::Equal, 0);
        assert_eq!(n, Ordering::Equal);

        for cond in 1..0xFF {
            n.cmovz(&Ordering::Greater, cond);
            assert_eq!(n, Ordering::Equal);
        }
    }

    #[test]
    fn cmovnz_works() {
        let mut n = Ordering::Less;
        n.cmovnz(&Ordering::Equal, 0);
        assert_eq!(n, Ordering::Less);

        for cond in 1..0xFF {
            let mut n = Ordering::Less;
            n.cmovnz(&Ordering::Greater, cond);
            assert_eq!(n, Ordering::Greater);
        }
    }

    #[test]
    fn cmoveq_works() {
        let mut o = 0u8;

        // equal so we move
        Ordering::Equal.cmoveq(&Ordering::Equal, 43u8, &mut o);
        assert_eq!(o, 43u8);

        // non-equal so we don't move
        Ordering::Less.cmoveq(&Ordering::Equal, 1, &mut o);
        assert_eq!(o, 43u8);
        Ordering::Less.cmoveq(&Ordering::Greater, 1, &mut o);
        assert_eq!(o, 43u8);
    }
}

mod arrays {
    use cmov::{Cmov, CmovEq};

    // 127-elements: large enough to test the chunk loop, odd-sized to test remainder handling,
    // and with each element different to ensure the operations actually work
    const EXAMPLE_A: [u8; 127] = [
        0x1, 0x2, 0x3, 0x4, 0x5, 0x6, 0x7, 0x8, 0x9, 0xa, 0xb, 0xc, 0xd, 0xe, 0xf, 0x10, 0x11,
        0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x20,
        0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f,
        0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e,
        0x3f, 0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x4b, 0x4c, 0x4d,
        0x4e, 0x4f, 0x50, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x5b, 0x5c,
        0x5d, 0x5e, 0x5f, 0x60, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x6b,
        0x6c, 0x6d, 0x6e, 0x6f, 0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a,
        0x7b, 0x7c, 0x7d, 0x7e, 0x7f,
    ];

    // Completely different
    const EXAMPLE_B: [u8; 127] = [
        0xff, 0xfe, 0xfd, 0xfc, 0xfb, 0xfa, 0xf9, 0xf8, 0xf7, 0xf6, 0xf5, 0xf4, 0xf3, 0xf2, 0xf1,
        0xf0, 0xef, 0xee, 0xed, 0xec, 0xeb, 0xea, 0xe9, 0xe8, 0xe7, 0xe6, 0xe5, 0xe4, 0xe3, 0xe2,
        0xe1, 0xe0, 0xdf, 0xde, 0xdd, 0xdc, 0xdb, 0xda, 0xd9, 0xd8, 0xd7, 0xd6, 0xd5, 0xd4, 0xd3,
        0xd2, 0xd1, 0xd0, 0xcf, 0xce, 0xcd, 0xcc, 0xcb, 0xca, 0xc9, 0xc8, 0xc7, 0xc6, 0xc5, 0xc4,
        0xc3, 0xc2, 0xc1, 0xc0, 0xbf, 0xbe, 0xbd, 0xbc, 0xbb, 0xba, 0xb9, 0xb8, 0xb7, 0xb6, 0xb5,
        0xb4, 0xb3, 0xb2, 0xb1, 0xb0, 0xaf, 0xae, 0xad, 0xac, 0xab, 0xaa, 0xa9, 0xa8, 0xa7, 0xa6,
        0xa5, 0xa4, 0xa3, 0xa2, 0xa1, 0xa0, 0x9f, 0x9e, 0x9d, 0x9c, 0x9b, 0x9a, 0x99, 0x98, 0x97,
        0x96, 0x95, 0x94, 0x93, 0x92, 0x91, 0x90, 0x8f, 0x8e, 0x8d, 0x8c, 0x8b, 0x8a, 0x89, 0x88,
        0x87, 0x86, 0x85, 0x84, 0x83, 0x82, 0x81,
    ];

    // Same as `EXAMPLE_A` except for the last byte
    const EXAMPLE_C: [u8; 127] = [
        0x1, 0x2, 0x3, 0x4, 0x5, 0x6, 0x7, 0x8, 0x9, 0xa, 0xb, 0xc, 0xd, 0xe, 0xf, 0x10, 0x11,
        0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x20,
        0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f,
        0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e,
        0x3f, 0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x4b, 0x4c, 0x4d,
        0x4e, 0x4f, 0x50, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x5b, 0x5c,
        0x5d, 0x5e, 0x5f, 0x60, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x6b,
        0x6c, 0x6d, 0x6e, 0x6f, 0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a,
        0x7b, 0x7c, 0x7d, 0x7e, 0x7e,
    ];

    /// Note: we only provide this impl for `[u8; N]` so we have some optimized way of operating
    /// over byte arrays. Unfortunately without specialization we can't also provide a generalized
    /// impl, but having good codegen for byte arrays is important.
    #[test]
    fn u8_cmovnz_works() {
        let mut x = EXAMPLE_A;
        x.cmovnz(&EXAMPLE_B, 0);
        assert_eq!(x, EXAMPLE_A);

        for cond in 1..u8::MAX {
            let mut x = EXAMPLE_A;
            x.cmovnz(&EXAMPLE_B, cond);
            assert_eq!(x, EXAMPLE_B);
        }
    }

    #[test]
    fn u8_cmovz_works() {
        let mut x = EXAMPLE_A;
        x.cmovz(&EXAMPLE_B, 0);
        assert_eq!(x, EXAMPLE_B);

        for cond in 1..u8::MAX {
            let mut x = EXAMPLE_A;
            x.cmovz(&EXAMPLE_B, cond);
            assert_eq!(x, EXAMPLE_A);
        }
    }

    #[test]
    fn u8_cmoveq_works() {
        let mut o = 0u8;

        // Same contents.
        EXAMPLE_A.cmoveq(&EXAMPLE_A, 43, &mut o);
        assert_eq!(o, 43);

        // Different contents.
        EXAMPLE_A.cmoveq(&EXAMPLE_B, 45, &mut o);
        EXAMPLE_A.cmoveq(&EXAMPLE_C, 45, &mut o);
        assert_ne!(o, 45);
    }

    #[test]
    fn u8_cmovne_works() {
        let mut o = 0u8;

        // Same contents.
        EXAMPLE_A.cmovne(&EXAMPLE_A, 43, &mut o);
        assert_ne!(o, 43);

        // Different contents.
        EXAMPLE_A.cmovne(&EXAMPLE_B, 45, &mut o);
        assert_eq!(o, 45);

        EXAMPLE_A.cmovne(&EXAMPLE_C, 47, &mut o);
        assert_eq!(o, 47);
    }
}

mod slices {
    macro_rules! int_slice_test {
        ($int:ident, $a:expr, $b:expr) => {
            mod $int {
                use cmov::{Cmov, CmovEq};

                const EXAMPLE_A: &[$int] = &[$a, $a, $b];
                const EXAMPLE_B: &[$int] = &[$b, $a, $a]; // different contents
                const EXAMPLE_C: &[$int] = &[$a, $a]; // different length

                #[test]
                fn cmovnz_works() {
                    let mut x: [$int; 3] = [0; 3];
                    x.as_mut_slice().cmovnz(EXAMPLE_A, 0);
                    assert_eq!(x, [0; 3]);

                    for cond in 1..u8::MAX {
                        let mut x: [$int; 3] = [0; 3];
                        x.as_mut_slice().cmovnz(EXAMPLE_A, cond);
                        assert_eq!(x, EXAMPLE_A);
                    }
                }

                #[test]
                fn cmovz_works() {
                    let mut x: [$int; 3] = [0; 3];
                    x.as_mut_slice().cmovz(EXAMPLE_A, 0);
                    assert_eq!(x, EXAMPLE_A);

                    for cond in 1..u8::MAX {
                        let mut x: [$int; 3] = [0; 3];
                        x.as_mut_slice().cmovz(EXAMPLE_A, cond);
                        assert_eq!(x, [0; 3]);
                    }
                }

                #[test]
                #[should_panic]
                fn cmovnz_length_mismatch_panics() {
                    let mut x: [$int; 3] = [0; 3];
                    x.as_mut_slice().cmovnz(EXAMPLE_C, 1);
                }

                #[test]
                fn cmoveq_works() {
                    let mut o = 0u8;

                    // Same slices.
                    EXAMPLE_A.cmoveq(EXAMPLE_A, 43, &mut o);
                    assert_eq!(o, 43);

                    // Different contents.
                    EXAMPLE_A.cmoveq(EXAMPLE_B, 45, &mut o);
                    assert_ne!(o, 45);

                    // Different lengths.
                    EXAMPLE_A.cmoveq(EXAMPLE_C, 44, &mut o);
                    assert_ne!(o, 44);
                }

                #[test]
                fn cmovne_works() {
                    let mut o = 0u8;

                    // Same slices.
                    EXAMPLE_A.cmovne(EXAMPLE_A, 43, &mut o);
                    assert_ne!(o, 43);

                    // Different contents.
                    EXAMPLE_A.cmovne(EXAMPLE_B, 45, &mut o);
                    assert_eq!(o, 45);

                    // Different lengths.
                    EXAMPLE_A.cmovne(EXAMPLE_C, 44, &mut o);
                    assert_eq!(o, 44);
                }
            }
        };
    }

    int_slice_test!(i8, i8::MIN, i8::MAX);
    int_slice_test!(i16, i16::MIN, i16::MAX);
    int_slice_test!(i32, i32::MIN, i32::MAX);
    int_slice_test!(i64, i64::MIN, i64::MAX);
    int_slice_test!(i128, i128::MIN, i128::MAX);

    int_slice_test!(u8, 7, u8::MAX);
    int_slice_test!(u16, 11, u16::MAX);
    int_slice_test!(u32, 13, u32::MAX);
    int_slice_test!(u64, 17, u64::MAX);
    int_slice_test!(u128, 23, u128::MAX);
}
