/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

use core::fmt::{Debug, Formatter};

use super::ClientConfig;

// Hand-written so that a future plain-String credential field cannot start leaking just
// because someone added it without a Secret wrapper.
impl Debug for ClientConfig {
    fn fmt(&self, f: &mut Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("ClientConfig")
            .field("endpoints", &self.endpoints())
            .field("tls", &self.tls_mode())
            .field("username", &self.username())
            .field("password", &self.password().map(|_| "<redacted>"))
            .field("api_key", &self.api_key().map(|_| "<redacted>"))
            .field("bearer_token", &self.bearer_token().map(|_| "<redacted>"))
            .field("namespace", &self.namespace())
            .finish()
    }
}
