//! `proptest`-powered property-based tests.

use const_oid::{Error, ObjectIdentifier};
use proptest::prelude::*;
use regex::Regex;

prop_compose! {
    /// Produce a string of digits and dots, i.e. the component parts of OIDs.
    ///
    /// Note that this can be any permutation of digits-and-dots and does not necessarily
    /// represent a valid OID.
    fn oid_like_string()(bytes in any::<Vec<u8>>()) -> String {
        // Create a digit or dot from a byte input
        fn byte_to_char(byte: u8) -> char {
            match byte % 11 {
                n @ 0..=9  => (b'0' + n) as char,
                10 => '.',
                _ => unreachable!()
            }
        }


        let mut ret = String::with_capacity(bytes.len());
        for byte in bytes {
            ret.push(byte_to_char(byte));
        }
        ret
    }
}

proptest! {
    #[test]
    fn round_trip(s in oid_like_string()) {
        match ObjectIdentifier::new(&s) {
            Ok(oid) => {
                // Leading zeros won't round trip, so ignore that case
                // TODO(tarcieri): disallow leading zeros?
                if !s.starts_with("0") && !s.contains(".0") {
                    let oid_string = oid.to_string();
                    prop_assert_eq!(s, oid_string);
                }
            },
            Err(Error::ArcInvalid { .. }) | Err(Error::ArcTooBig) => (),
            Err(e) => {
                let re = Regex::new("^([0-2])\\.([0-3]?[0-9])((\\.0)|(\\.[1-9][0-9]*))+$").unwrap();

                prop_assert!(
                    re.find(&s).is_none(),
                    "regex asserts OID `{}` is valid, but `const-oid`failed: {}",
                    &s,
                    &e
                );
            }
        }
    }
}
