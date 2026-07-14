//! Test to ensure that `impl_modulus!` works from outside this crate.

use crypto_bigint::{U64, const_monty_params};

const_monty_params!(TestMod, U64, "30e4b8f030ab42f3");
