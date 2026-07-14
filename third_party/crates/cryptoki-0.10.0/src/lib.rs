// Copyright 2021 Contributors to the Parsec project.
// SPDX-License-Identifier: Apache-2.0
#![doc = include_str!("../README.md")]
// This list comes from
// https://github.com/rust-unofficial/patterns/blob/master/anti_patterns/deny-warnings.md
#![allow(renamed_and_removed_lints, unknown_lints)]
#![deny(bad_style,
       dead_code,
       improper_ctypes,
       non_shorthand_field_patterns,
       no_mangle_generic_items,
       overflowing_literals,
       path_statements ,
       patterns_in_fns_without_body,
       private_bounds,
       private_in_public,
       private_interfaces,
       renamed_and_removed_lints,
       unconditional_recursion,
       unnameable_types,
       unused,
       unused_allocation,
       unused_comparisons,
       unused_parens,
       while_true,
       missing_debug_implementations,
       missing_copy_implementations,
       missing_docs,
       // Useful to cast to raw pointers
       //trivial_casts,
       trivial_numeric_casts,
       unused_extern_crates,
       unused_import_braces,
       unused_qualifications,
       unused_results)]

// Warning: The context module defines the
// get_pkcs11() macro, which must be defined before
// any modules that use it are declared.
#[macro_use]
pub mod context;

pub mod error;
pub mod mechanism;
pub mod object;
pub mod session;
pub mod slot;
pub mod types;

use cryptoki_sys::CK_UTF8CHAR;

fn string_from_blank_padded(field: &[CK_UTF8CHAR]) -> String {
    let decoded_str = String::from_utf8_lossy(field);
    decoded_str.trim_end_matches(' ').to_string()
}

fn label_from_str(label: &str) -> [CK_UTF8CHAR; 32] {
    let mut lab: [CK_UTF8CHAR; 32] = [32; 32];
    let mut i = 0;
    for c in label.chars() {
        if i + c.len_utf8() <= 32 {
            let mut buf = [0; 4];
            let bytes = c.encode_utf8(&mut buf).as_bytes();
            for b in bytes {
                lab[i] = *b;
                i += 1;
            }
        } else {
            break;
        }
    }
    lab
}
