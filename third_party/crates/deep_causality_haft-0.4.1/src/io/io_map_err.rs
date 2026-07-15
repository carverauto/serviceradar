/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::io::IoAction;

/// Transforms the error channel of an IO action, leaving the success path untouched.
///
/// Built by [`IoAction::map_err`]. Implements [`IoAction`]. Nothing runs until
/// [`run`](IoAction::run).
pub struct IoMapErr<P, F>(P, F);

impl<P, F> IoMapErr<P, F> {
    /// Builds the error-mapped action. Prefer [`IoAction::map_err`].
    #[inline]
    pub const fn new(action: P, f: F) -> Self {
        IoMapErr(action, f)
    }
}

impl<P, E2, F> IoAction for IoMapErr<P, F>
where
    P: IoAction,
    F: FnOnce(P::Error) -> E2,
{
    type Output = P::Output;
    type Error = E2;

    #[inline]
    fn run(self) -> Result<P::Output, E2> {
        self.0.run().map_err(self.1)
    }
}
