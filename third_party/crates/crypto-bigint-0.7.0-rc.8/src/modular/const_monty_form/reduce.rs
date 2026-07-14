use super::ConstMontyParams;
use crate::{Reduce, Uint, modular::ConstMontyForm};

impl<const LIMBS: usize, MOD> Reduce<Uint<LIMBS>> for ConstMontyForm<MOD, LIMBS>
where
    MOD: ConstMontyParams<LIMBS>,
{
    fn reduce(value: &Uint<LIMBS>) -> Self {
        Self::new(value)
    }
}
