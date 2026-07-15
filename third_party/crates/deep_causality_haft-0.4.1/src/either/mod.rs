/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! A two-variant sum type, `Either<L, R>`.
//!
//! `Either` is the carrier for choice in the arrow algebra: a value is `Left` or `Right`, and a
//! combinator routes each side to its own arm. It is deliberately distinct from `Result<L, R>`,
//! which already means success-or-error; routing a branch on `Result` would conflate a branch with
//! a failure. The type lives here, in `deep_causality_haft`, so the pure-arrow choice combinator and
//! the Causal Discovery Language can reuse the one sum.

/// A value of one of two types, `Left(L)` or `Right(R)`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Either<L, R> {
    /// The left variant.
    Left(L),
    /// The right variant.
    Right(R),
}

impl<L, R> Either<L, R> {
    /// Returns `true` if this is a `Left` value.
    #[inline]
    pub const fn is_left(&self) -> bool {
        matches!(self, Either::Left(_))
    }

    /// Returns `true` if this is a `Right` value.
    #[inline]
    pub const fn is_right(&self) -> bool {
        matches!(self, Either::Right(_))
    }

    /// Returns the left value if present, consuming `self`.
    #[inline]
    pub fn left(self) -> Option<L> {
        match self {
            Either::Left(l) => Some(l),
            Either::Right(_) => None,
        }
    }

    /// Returns the right value if present, consuming `self`.
    #[inline]
    pub fn right(self) -> Option<R> {
        match self {
            Either::Left(_) => None,
            Either::Right(r) => Some(r),
        }
    }

    /// Borrows the inner value, returning an `Either<&L, &R>` without consuming `self`. This is the
    /// non-consuming counterpart to [`left`](Self::left) / [`right`](Self::right), letting a caller
    /// holding `&Either<L, R>` reach the inner value of a non-`Copy` type by reference.
    #[inline]
    pub const fn as_ref(&self) -> Either<&L, &R> {
        match self {
            Either::Left(l) => Either::Left(l),
            Either::Right(r) => Either::Right(r),
        }
    }

    /// Mutably borrows the inner value, returning an `Either<&mut L, &mut R>` without consuming
    /// `self`, so a caller holding `&mut Either<L, R>` can edit the inner value in place.
    #[inline]
    pub fn as_mut(&mut self) -> Either<&mut L, &mut R> {
        match self {
            Either::Left(l) => Either::Left(l),
            Either::Right(r) => Either::Right(r),
        }
    }
}
