/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{BaseSymbol, Identifiable, Symbolic, SymbolicRepresentation};
use std::fmt::{Display, Formatter};

#[derive(Debug, Clone, PartialEq)]
pub enum SymbolKind {
    BaseSymbol(BaseSymbol),
}

impl Identifiable for SymbolKind {
    fn id(&self) -> u64 {
        match self {
            SymbolKind::BaseSymbol(base_symbol) => base_symbol.id(),
        }
    }
}

impl Symbolic for SymbolKind {
    type Repr = SymbolicRepresentation;

    fn symbol(&self) -> &Self::Repr {
        match self {
            SymbolKind::BaseSymbol(base_symbol) => base_symbol.symbol(),
        }
    }
}

impl Display for SymbolKind {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            SymbolKind::BaseSymbol(base_symbol) => base_symbol.fmt(f),
        }
    }
}
