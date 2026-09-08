//! `Debug` redacts.
//!
//! This is the impl that matters most: `{:?}` reaches secrets through tracing spans, `unwrap`
//! panics and error chains, none of which look like printing a password at the call site.

use crate::types::secret::{Secret, REDACTED};
use std::fmt;

impl fmt::Debug for Secret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Secret({REDACTED})")
    }
}
