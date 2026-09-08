//! `<kind>[":" <instance>]` -- the exact spelling `SERVICERADAR_ENV` accepts, so an error can
//! quote back something a reader can paste into a manifest.

use crate::types::Identity;
use std::fmt;

impl fmt::Display for Identity {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.instance() {
            Some(i) => write!(f, "{}:{}", self.kind(), i),
            None => write!(f, "{}", self.kind()),
        }
    }
}
