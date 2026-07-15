/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::io::IoAction;

/// The monadic bind of the IO monad: run the inner action, feed its output to `f`, then run the
/// action `f` returns. Short-circuits on the first error (the second action does not run).
///
/// Built by [`IoAction::and_then`]. Implements [`IoAction`], so chains compose further. Nothing runs
/// until [`run`](IoAction::run).
pub struct IoAndThen<P, F>(P, F);

impl<P, F> IoAndThen<P, F> {
    /// Builds the chained action. Prefer [`IoAction::and_then`].
    #[inline]
    pub const fn new(action: P, f: F) -> Self {
        IoAndThen(action, f)
    }
}

impl<P, Q, F> IoAction for IoAndThen<P, F>
where
    P: IoAction,
    Q: IoAction<Error = P::Error>,
    F: FnOnce(P::Output) -> Q,
{
    type Output = Q::Output;
    type Error = P::Error;

    #[inline]
    fn run(self) -> Result<Q::Output, P::Error> {
        self.0.run().and_then(|out| (self.1)(out).run())
    }
}
