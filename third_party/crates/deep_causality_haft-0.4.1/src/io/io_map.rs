/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::io::IoAction;

/// The functor map of the IO monad: run the inner action, then apply `f` to its successful output.
///
/// Built by [`IoAction::map`]. Implements [`IoAction`], so mapped actions compose further. Nothing
/// runs until [`run`](IoAction::run).
pub struct IoMap<P, F>(P, F);

impl<P, F> IoMap<P, F> {
    /// Builds the mapped action. Prefer [`IoAction::map`].
    #[inline]
    pub const fn new(action: P, f: F) -> Self {
        IoMap(action, f)
    }
}

impl<P, B, F> IoAction for IoMap<P, F>
where
    P: IoAction,
    F: FnOnce(P::Output) -> B,
{
    type Output = B;
    type Error = P::Error;

    #[inline]
    fn run(self) -> Result<B, P::Error> {
        self.0.run().map(self.1)
    }
}
