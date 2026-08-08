// Licensed to the Apache Software Foundation (ASF) under one
// or more contributor license agreements.  See the NOTICE file
// distributed with this work for additional information
// regarding copyright ownership.  The ASF licenses this file
// to you under the Apache License, Version 2.0 (the
// "License"); you may not use this file except in compliance
// with the License.  You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

//! Utility functions and types.

use std::fmt::Debug;

/// Redacts a string by replacing all but the first and last three characters with asterisks.
///
/// - If the input string has fewer than 12 characters, it should be entirely redacted.
/// - If the input string has 12 or more characters, only the first three and the last three.
///
/// This design is to allow users to distinguish between different redacted strings but avoid
/// leaking sensitive information.
pub struct Redact<'a>(&'a str);

impl<'a> From<&'a str> for Redact<'a> {
    fn from(value: &'a str) -> Self {
        Redact(value)
    }
}

impl<'a> From<&'a String> for Redact<'a> {
    fn from(value: &'a String) -> Self {
        Redact(value.as_str())
    }
}

impl<'a> From<&'a Option<String>> for Redact<'a> {
    fn from(value: &'a Option<String>) -> Self {
        match value {
            None => Redact(""),
            Some(v) => Redact(v),
        }
    }
}

impl Debug for Redact<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let length = self.0.len();
        if length == 0 {
            f.write_str("EMPTY")
        } else if length < 12 {
            f.write_str("***")
        } else {
            f.write_str(&self.0[..3])?;
            f.write_str("***")?;
            f.write_str(&self.0[length - 3..])
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_redact() {
        let cases = vec![
            ("Short", "***"),
            ("Hello World!", "Hel***ld!"),
            ("This is a longer string", "Thi***ing"),
            ("", "EMPTY"),
            ("HelloWorld", "***"),
        ];

        for (input, expected) in cases {
            assert_eq!(
                format!("{:?}", Redact(input)),
                expected,
                "Failed on input: {}",
                input
            );
        }
    }
}
