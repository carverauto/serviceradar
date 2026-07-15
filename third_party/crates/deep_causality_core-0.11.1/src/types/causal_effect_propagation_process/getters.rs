/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{CausalEffect, CausalEffectPropagationProcess};

impl<Value, State, Context, Error, Log>
    CausalEffectPropagationProcess<Value, State, Context, Error, Log>
{
    /// The effect-XOR-error channel: a [`CausalEffect`] (value or command), or the error that ended
    /// the computation.
    pub const fn outcome(&self) -> &Result<CausalEffect<Value>, Error> {
        &self.outcome
    }

    /// The carried scalar, if the process holds a value effect.
    ///
    /// This is the everyday accessor: it lends `Some(&v)` only when the process carries an ordinary
    /// value, and `None` for an errored process, a `None` effect, or a command effect. Reach for
    /// [`value_cloned`](Self::value_cloned) / [`into_value`](Self::into_value) for the value by
    /// value, and [`effect`](Self::effect) / [`command_target`](Self::command_target) to discriminate.
    pub fn value(&self) -> Option<&Value> {
        self.outcome.as_ref().ok()?.as_value()
    }

    /// The carried scalar cloned out, if the process holds a value effect.
    ///
    /// The borrowing, owned-result counterpart to [`value`](Self::value); the non-consuming
    /// counterpart to [`into_value`](Self::into_value).
    pub fn value_cloned(&self) -> Option<Value>
    where
        Value: Clone,
    {
        self.value().cloned()
    }

    /// The carried [`CausalEffect`] (value or command), or `None` if the process holds an error.
    ///
    /// Yields the whole effect so callers can discriminate value / none / command (via
    /// [`CausalEffect::is_command`] etc.). Most callers want the plain scalar instead: use
    /// [`value`](Self::value). An errored process has no effect to lend — effect and error are one
    /// channel (the W-invariant, by construction).
    pub fn effect(&self) -> Option<&CausalEffect<Value>> {
        self.outcome.as_ref().ok()
    }

    /// The target causaloid index if this process carries a `RelayTo` command effect, else `None`.
    pub fn command_target(&self) -> Option<usize> {
        self.outcome.as_ref().ok()?.command_target()
    }

    pub const fn state(&self) -> &State {
        &self.state
    }

    pub const fn context(&self) -> &Option<Context> {
        &self.context
    }

    /// The error that ended the computation, or `None` if the process carries a value.
    pub fn error(&self) -> Option<&Error> {
        self.outcome.as_ref().err()
    }

    pub const fn logs(&self) -> &Log {
        &self.logs
    }
}
