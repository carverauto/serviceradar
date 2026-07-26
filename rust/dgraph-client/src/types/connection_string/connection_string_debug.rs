/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

use core::fmt::{Debug, Formatter};

use super::ConnectionString;

// Hand-written rather than derived. A derived Debug would still be safe today because
// every credential field is a `Secret` with a redacting Debug, but writing it out means a
// future plain-String credential field cannot silently start leaking.
impl Debug for ConnectionString {
    fn fmt(&self, f: &mut Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("ConnectionString")
            .field("host", &self.host())
            .field("port", &self.port())
            .field("tls", &self.tls_mode())
            .field("username", &self.username())
            .field("password", &self.password().map(|_| "<redacted>"))
            .field("api_key", &self.api_key().map(|_| "<redacted>"))
            .field("bearer_token", &self.bearer_token().map(|_| "<redacted>"))
            .field("namespace", &self.namespace())
            .finish()
    }
}
