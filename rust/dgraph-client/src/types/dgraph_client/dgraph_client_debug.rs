/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

use core::fmt::{Debug, Formatter};

use super::DgraphClient;

// Renders the configuration (which redacts its own credentials) and never the token cache.
impl Debug for DgraphClient {
    fn fmt(&self, f: &mut Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("DgraphClient")
            .field("endpoints", &self.config().endpoints())
            .field("tls", &self.config().tls_mode())
            .finish_non_exhaustive()
    }
}
