use super::{FieldElement, field_impl::*};
use core::ops::Mul;

/// "Loose" field element: unreduced and intended to be followed by an
/// additional operation which will perform a reduction.
pub struct LooseFieldElement(pub(super) fiat_p521_loose_field_element);

impl LooseFieldElement {
    /// Reduce field element.
    #[inline]
    pub const fn carry(&self) -> FieldElement {
        let mut out = fiat_p521_tight_field_element([0; 9]);
        fiat_p521_carry(&mut out, &self.0);
        FieldElement(out)
    }

    /// Multiplies two field elements and reduces the result.
    #[inline]
    pub const fn multiply(&self, rhs: &Self) -> FieldElement {
        let mut out = fiat_p521_tight_field_element([0; 9]);
        fiat_p521_carry_mul(&mut out, &self.0, &rhs.0);
        FieldElement(out)
    }

    /// Squares a field element and reduces the result.
    #[inline]
    pub const fn square(&self) -> FieldElement {
        let mut out = fiat_p521_tight_field_element([0; 9]);
        fiat_p521_carry_square(&mut out, &self.0);
        FieldElement(out)
    }
}

impl From<FieldElement> for LooseFieldElement {
    #[inline]
    fn from(tight: FieldElement) -> LooseFieldElement {
        LooseFieldElement::from(&tight)
    }
}

impl From<&FieldElement> for LooseFieldElement {
    #[inline]
    fn from(tight: &FieldElement) -> LooseFieldElement {
        tight.relax()
    }
}

impl From<LooseFieldElement> for FieldElement {
    #[inline]
    fn from(loose: LooseFieldElement) -> FieldElement {
        FieldElement::from(&loose)
    }
}

impl From<&LooseFieldElement> for FieldElement {
    #[inline]
    fn from(loose: &LooseFieldElement) -> FieldElement {
        loose.carry()
    }
}

impl Mul for LooseFieldElement {
    type Output = FieldElement;

    #[inline]
    fn mul(self, rhs: LooseFieldElement) -> FieldElement {
        Self::multiply(&self, &rhs)
    }
}

impl Mul<&LooseFieldElement> for LooseFieldElement {
    type Output = FieldElement;

    #[inline]
    fn mul(self, rhs: &LooseFieldElement) -> FieldElement {
        Self::multiply(&self, rhs)
    }
}

impl Mul<&LooseFieldElement> for &LooseFieldElement {
    type Output = FieldElement;

    #[inline]
    fn mul(self, rhs: &LooseFieldElement) -> FieldElement {
        LooseFieldElement::multiply(self, rhs)
    }
}
