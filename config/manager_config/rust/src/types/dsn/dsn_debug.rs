//! `Debug` redacts, because `{:?}` reaches a DSN through tracing spans and connection errors --
//! exactly the places a failing database connection gets logged.

use crate::types::dsn::{Dsn, REDACTED};
use std::fmt;

impl fmt::Debug for Dsn {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Dsn({REDACTED})")
    }
}
