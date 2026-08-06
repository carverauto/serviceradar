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

use reqsign_core::SigningCredential;
use reqsign_core::time::Timestamp;
use reqsign_core::utils::Redact;
use std::fmt::{Debug, Formatter};
use std::time::Duration;

/// Credential that holds the access_key and secret_key.
#[derive(Default, Clone)]
pub struct Credential {
    /// Access key id for aws services.
    pub access_key_id: String,
    /// Secret access key for aws services.
    pub secret_access_key: String,
    /// Session token for aws services.
    pub session_token: Option<String>,
    /// Expiration time for this credential.
    pub expires_in: Option<Timestamp>,
}

impl Debug for Credential {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Credential")
            .field("access_key_id", &Redact::from(&self.access_key_id))
            .field("secret_access_key", &Redact::from(&self.secret_access_key))
            .field("session_token", &Redact::from(&self.session_token))
            .field("expires_in", &self.expires_in)
            .finish()
    }
}

impl SigningCredential for Credential {
    fn is_valid(&self) -> bool {
        self.is_valid_at(Timestamp::now() + Duration::from_secs(120))
    }

    fn is_valid_at(&self, timestamp: Timestamp) -> bool {
        if self.access_key_id.is_empty() || self.secret_access_key.is_empty() {
            return false;
        }

        self.expires_in.is_none_or(|expires| expires > timestamp)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn separates_cache_freshness_from_exact_validity() {
        let now = Timestamp::now();
        let credential = Credential {
            access_key_id: "access-key".to_string(),
            secret_access_key: "secret-key".to_string(),
            session_token: Some("token".to_string()),
            expires_in: Some(now + Duration::from_secs(30)),
        };

        assert!(!credential.is_valid());
        assert!(credential.is_valid_at(now + Duration::from_secs(10)));
        assert!(!credential.is_valid_at(now + Duration::from_secs(30)));
    }

    #[test]
    fn session_token_does_not_replace_signing_keys() {
        let credential = Credential {
            session_token: Some("token".to_string()),
            ..Default::default()
        };

        assert!(!credential.is_valid_at(Timestamp::now()));
    }
}
