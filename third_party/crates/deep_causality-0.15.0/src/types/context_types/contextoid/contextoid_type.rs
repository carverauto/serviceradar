/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use std::fmt::{Display, Formatter};
use std::hash::Hash;
use std::marker::PhantomData;

use crate::*;

/// Enum of monoidal context node types (each a composable unit of structure).
/// Each variant name ends in `-oid` to emphasize its monoid role as a single identity-bearing unit.
#[derive(Debug, Copy, Clone, Eq, PartialEq, Hash)]
pub enum ContextKind {
    Datoid,
    Tempoid,
    Root,
    Spaceoid,
    SpaceTempoid,
    Symboid,
}

#[derive(Debug, Copy, Clone, Hash, Eq, PartialEq)]
pub enum ContextoidType<D, S, T, ST, SYM, VS, VT>
where
    D: Datable + Clone,
    S: Spatial<VS> + Clone,
    T: Temporal<VT> + Clone,
    ST: SpaceTemporal<VS, VT> + Clone,
    SYM: Symbolic + Clone,
    VS: Clone,
    VT: Clone,
{
    Datoid(D),
    Tempoid(T),
    Root(Root),
    Spaceoid(S),
    SpaceTempoid(ST),
    Symboid(SYM),
    #[doc(hidden)]
    _Marker(PhantomData<(VS, VT)>),
}

impl<D, S, T, ST, SYM, VS, VT> ContextoidType<D, S, T, ST, SYM, VS, VT>
where
    D: Datable + Clone,
    S: Spatial<VS> + Clone,
    T: Temporal<VT> + Clone,
    ST: SpaceTemporal<VS, VT> + Clone,
    SYM: Symbolic + Clone,
    VS: Clone,
    VT: Clone,
{
    pub fn kind(&self) -> ContextKind {
        match self {
            ContextoidType::Datoid(_) => ContextKind::Datoid,
            ContextoidType::Tempoid(_) => ContextKind::Tempoid,
            ContextoidType::Root(_) => ContextKind::Root,
            ContextoidType::Spaceoid(_) => ContextKind::Spaceoid,
            ContextoidType::SpaceTempoid(_) => ContextKind::SpaceTempoid,
            ContextoidType::Symboid(_) => ContextKind::Symboid,
            _ => unreachable!(), // phantom variant
        }
    }
}

impl<D, S, T, ST, SYM, VS, VT> ContextoidType<D, S, T, ST, SYM, VS, VT>
where
    D: Datable + Clone,
    S: Spatial<VS> + Clone,
    T: Temporal<VT> + Clone,
    ST: SpaceTemporal<VS, VT> + Clone,
    SYM: Symbolic + Clone,
    VS: Clone,
    VT: Clone,
{
    pub fn root(&self) -> Option<&Root> {
        if let ContextoidType::Root(b) = self {
            Some(b)
        } else {
            None
        }
    }

    pub fn dataoid(&self) -> Option<&D> {
        if let ContextoidType::Datoid(b) = self {
            Some(b)
        } else {
            None
        }
    }
    pub fn tempoid(&self) -> Option<&T> {
        if let ContextoidType::Tempoid(b) = self {
            Some(b)
        } else {
            None
        }
    }
    pub fn spaceoid(&self) -> Option<&S> {
        if let ContextoidType::Spaceoid(b) = self {
            Some(b)
        } else {
            None
        }
    }
    pub fn space_tempoid(&self) -> Option<&ST> {
        if let ContextoidType::SpaceTempoid(b) = self {
            Some(b)
        } else {
            None
        }
    }

    pub fn symboid(&self) -> Option<&SYM> {
        if let ContextoidType::Symboid(b) = self {
            Some(b)
        } else {
            None
        }
    }
}

impl<D, S, T, ST, SYM, VS, VT> Display for ContextoidType<D, S, T, ST, SYM, VS, VT>
where
    D: Display + Datable + Clone,
    S: Display + Spatial<VS> + Clone,
    T: Display + Temporal<VT> + Clone,
    ST: Display + SpaceTemporal<VS, VT> + Clone,
    SYM: Display + Symbolic + Clone,
    VS: Display + Clone,
    VT: Display + Clone,
{
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            ContextoidType::Datoid(b) => write!(f, "Datoid: {b}"),
            ContextoidType::Tempoid(b) => write!(f, "Tempoid: {b}"),
            ContextoidType::Root(b) => write!(f, "Root: {b}"),
            ContextoidType::Spaceoid(b) => write!(f, "Spaceoid: {b}"),
            ContextoidType::SpaceTempoid(b) => write!(f, "SpaceTempoid: {b}"),
            ContextoidType::Symboid(b) => write!(f, "Symboid: {b}"),
            ContextoidType::_Marker(_) => {
                unreachable!("_Marker variant should never be accessed directly")
            }
        }
    }
}
