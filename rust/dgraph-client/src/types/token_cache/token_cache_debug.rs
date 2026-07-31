/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

use core::fmt::{Debug, Formatter};

use super::{TokenCache, Tokens};

// Never renders token material, and never blocks: reporting whether a lock is held would
// require awaiting it, so Debug reports only the type.
impl Debug for TokenCache {
    fn fmt(&self, f: &mut Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("TokenCache").finish_non_exhaustive()
    }
}

impl Debug for Tokens {
    fn fmt(&self, f: &mut Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("Tokens")
            .field("access", &"<redacted>")
            .field("refresh", &"<redacted>")
            .finish()
    }
}
