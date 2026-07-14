//! Secret `Vec` types

use super::{CloneableSecret, DebugSecret, Secret};
use alloc::vec::Vec;
use zeroize::Zeroize;

/// `Vec` types containing secret value
#[cfg_attr(docsrs, doc(cfg(feature = "alloc")))]
pub type SecretVec<S> = Secret<Vec<S>>;

impl<S: CloneableSecret + Zeroize> CloneableSecret for Vec<S> {}
impl<S: DebugSecret + Zeroize> DebugSecret for Vec<S> {}
