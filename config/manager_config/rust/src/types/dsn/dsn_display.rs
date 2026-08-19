//! `Display` redacts, so interpolating a DSN into a connection error cannot leak the password.

use crate::types::dsn::{Dsn, REDACTED};
use std::fmt;

impl fmt::Display for Dsn {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(REDACTED)
    }
}
