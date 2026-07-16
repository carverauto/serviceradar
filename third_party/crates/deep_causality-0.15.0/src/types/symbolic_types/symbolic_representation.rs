/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use std::fmt::Display;

/// SymbolicRepr defines a general-purpose symbolic representation
/// that supports identifiers, logical operations, expressions,
/// and compound terms.
///
/// This type is used to reason over symbolic causality nodes
/// (e.g., rules, logic graphs, theorem-like structures).
/// Box is required for recursive enum definitions.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum SymbolicRepresentation {
    /// A single symbolic identifier (e.g., "A", "TempHigh").
    Atom(String),

    /// A logical AND: A ∧ B
    And(Box<SymbolicRepresentation>, Box<SymbolicRepresentation>),

    /// A logical OR: A ∨ B
    Or(Box<SymbolicRepresentation>, Box<SymbolicRepresentation>),

    /// A logical NOT operation: ¬A
    Not(Box<SymbolicRepresentation>),

    /// A logical implication: A → B
    Implies(Box<SymbolicRepresentation>, Box<SymbolicRepresentation>),

    /// A logical biconditional: A ↔ B
    Iff(Box<SymbolicRepresentation>, Box<SymbolicRepresentation>),

    /// A custom expression: string-based fallback.
    Expr(String),
}

impl SymbolicRepresentation {
    pub fn new_atom(atom: String) -> Self {
        Self::Atom(atom)
    }

    pub fn new_and(lhs: Box<SymbolicRepresentation>, rhs: Box<SymbolicRepresentation>) -> Self {
        Self::And(lhs, rhs)
    }

    pub fn new_or(lhs: Box<SymbolicRepresentation>, rhs: Box<SymbolicRepresentation>) -> Self {
        Self::Or(lhs, rhs)
    }

    pub fn new_not(expr: Box<SymbolicRepresentation>) -> Self {
        Self::Not(expr)
    }

    pub fn new_implies(lhs: Box<SymbolicRepresentation>, rhs: Box<SymbolicRepresentation>) -> Self {
        Self::Implies(lhs, rhs)
    }

    pub fn new_iff(lhs: Box<SymbolicRepresentation>, rhs: Box<SymbolicRepresentation>) -> Self {
        Self::Iff(lhs, rhs)
    }

    pub fn new_expr(expr: String) -> Self {
        Self::Expr(expr)
    }
}

impl Display for SymbolicRepresentation {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
