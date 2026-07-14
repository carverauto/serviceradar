//! Selection of [`Int`] types.
//! todo: replace with macro implementation once serde is set up.

use crate::Int;

#[cfg(target_pointer_width = "64")]
/// Signed bit integer.
pub type I64 = Int<1>;

#[cfg(target_pointer_width = "64")]
/// Signed bit integer.
pub type I128 = Int<2>;

#[cfg(target_pointer_width = "64")]
/// Signed bit integer.
pub type I256 = Int<4>;

#[cfg(target_pointer_width = "64")]
/// Signed bit integer.
pub type I512 = Int<8>;

#[cfg(target_pointer_width = "64")]
/// Signed bit integer.
pub type I1024 = Int<16>;

#[cfg(target_pointer_width = "64")]
/// Signed bit integer.
pub type I2048 = Int<32>;

#[cfg(target_pointer_width = "64")]
/// Signed bit integer.
pub type I4096 = Int<64>;

#[cfg(target_pointer_width = "32")]
/// Signed bit integer.
pub type I64 = Int<2>;

#[cfg(target_pointer_width = "32")]
/// Signed bit integer.
pub type I128 = Int<4>;

#[cfg(target_pointer_width = "32")]
/// Signed bit integer.
pub type I256 = Int<8>;

#[cfg(target_pointer_width = "32")]
/// Signed bit integer.
pub type I512 = Int<16>;

#[cfg(target_pointer_width = "32")]
/// Signed bit integer.
pub type I1024 = Int<32>;

#[cfg(target_pointer_width = "32")]
/// Signed bit integer.
pub type I2048 = Int<64>;

#[cfg(target_pointer_width = "32")]
/// Signed bit integer.
pub type I4096 = Int<128>;
