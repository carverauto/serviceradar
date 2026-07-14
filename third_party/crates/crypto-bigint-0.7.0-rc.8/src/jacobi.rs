use crate::ConstChoice;
use core::ops::Neg;
use subtle::{Choice, ConstantTimeEq};

/// Possible return values for Jacobi symbol calculations.
#[derive(Debug, Copy, Clone)]
#[repr(i8)]
pub enum JacobiSymbol {
    /// The two arguments are not coprime, they have a common divisor apart from 1.
    Zero = 0,

    /// The two arguments are coprime. If the lower argument is prime, then the upper argument
    /// is quadratic residue modulo the lower argument. Otherwise, the upper argument is known to
    /// be quadratic nonresidue for an even number of prime factors of the lower argument.
    One = 1,

    /// The two terms are coprime, and the upper argument is a quadratic nonresidue modulo the
    /// lower argument.
    MinusOne = -1,
}

impl JacobiSymbol {
    /// Determine if the symbol is zero.
    pub const fn is_zero(&self) -> ConstChoice {
        ConstChoice::from_i64_eq(*self as i8 as i64, 0)
    }

    /// Determine if the symbol is one.
    pub const fn is_one(&self) -> ConstChoice {
        ConstChoice::from_i64_eq(*self as i8 as i64, 1)
    }

    /// Determine if the symbol is minus one.
    pub const fn is_minus_one(&self) -> ConstChoice {
        ConstChoice::from_i64_eq(*self as i8 as i64, -1)
    }

    /// Negate the symbol.
    pub const fn neg(self) -> Self {
        match self {
            Self::Zero => Self::Zero,
            Self::One => Self::MinusOne,
            Self::MinusOne => Self::One,
        }
    }

    pub(crate) const fn from_i8(value: i8) -> Self {
        match value {
            0 => Self::Zero,
            1 => Self::One,
            -1 => Self::MinusOne,
            _ => panic!("invalid value for Jacobi symbol"),
        }
    }
}

impl ConstantTimeEq for JacobiSymbol {
    fn ct_eq(&self, other: &Self) -> Choice {
        (*self as i8).ct_eq(&(*other as i8))
    }
}

impl Eq for JacobiSymbol {}

impl PartialEq for JacobiSymbol {
    fn eq(&self, other: &Self) -> bool {
        bool::from(self.ct_eq(other))
    }
}

impl From<JacobiSymbol> for i8 {
    fn from(symbol: JacobiSymbol) -> i8 {
        symbol as i8
    }
}

impl Neg for JacobiSymbol {
    type Output = Self;

    fn neg(self) -> Self {
        match self {
            Self::Zero => Self::Zero,
            Self::One => Self::MinusOne,
            Self::MinusOne => Self::One,
        }
    }
}
