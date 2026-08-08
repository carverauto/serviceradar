/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

use core::fmt::{Debug, Formatter};

use super::Secret;

// Hand-written rather than derived: a derived Debug would print the credential, which is
// exactly the leak this type exists to prevent.
impl Debug for Secret {
    fn fmt(&self, f: &mut Formatter<'_>) -> core::fmt::Result {
        f.write_str("Secret(<redacted>)")
    }
}
