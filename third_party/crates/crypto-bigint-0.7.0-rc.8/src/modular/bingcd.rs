//! This module implements (a constant variant of) the Optimized Extended Binary GCD algorithm,
//! which is described by Pornin as Algorithm 2 in "Optimized Binary GCD for Modular Inversion".
//! Ref: <https://eprint.iacr.org/2020/972.pdf>

mod compact;
mod div_mod_2k;
mod extension;
mod gcd;
mod matrix;
pub(crate) mod xgcd;
