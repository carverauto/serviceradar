/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

use core::str::FromStr;

use super::ConnectionString;
use crate::errors::connection_string_error::ConnectionStringError;

impl FromStr for ConnectionString {
    type Err = ConnectionStringError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Self::parse(s)
    }
}
