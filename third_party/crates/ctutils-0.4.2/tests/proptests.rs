//! `cmov` property-based tests: randomized with shrinking.

/// Write the proptests for an integer type.
macro_rules! int_proptests {
    ( $($int:ident),+ ) => {
        $(
            mod $int {
                use ctutils::{CtAssign, CtSelect, CtEq, Choice};
                use proptest::prelude::*;

                proptest! {
                    #[test]
                    fn ct_assign(a in any::<$int>(), b in any::<$int>(), byte in any::<u8>()) {
                        let choice = Choice::from_u8_lsb(byte);
                        let mut actual = a;
                        actual.ct_assign(&b, choice);

                        let expected = if byte & 1 == 1 {
                            b
                        } else {
                            a
                        };

                        prop_assert_eq!(expected, actual);
                    }

                    #[test]
                     fn ct_eq(a in any::<$int>(), b in any::<$int>()) {
                        let actual = a.ct_eq(&b);
                        prop_assert_eq!(a == b, actual.to_bool());
                     }

                     #[test]
                     fn ct_ne(a in any::<$int>(), b in any::<$int>()) {
                        let actual = a.ct_ne(&b);
                        prop_assert_eq!(a != b, actual.to_bool());
                     }

                    #[test]
                    fn ct_select(a in any::<$int>(), b in any::<$int>(), byte in any::<u8>()) {
                        let choice = Choice::from_u8_lsb(byte);
                        let actual = a.ct_select(&b, choice);

                        let expected = if byte & 1 == 1 {
                            b
                        } else {
                            a
                        };

                        prop_assert_eq!(expected, actual);
                    }
                }
            }
        )+
    };
}

int_proptests!(i8, i16, i32, i64, i128, u8, u16, u32, u64, u128);
