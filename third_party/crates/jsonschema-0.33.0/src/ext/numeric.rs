use fraction::{BigFraction, Zero};
use serde_json::Number;

macro_rules! define_num_cmp {
    ($($trait_fn:ident => $fn_name:ident),* $(,)?) => {
        $(
            pub(crate) fn $fn_name<T>(value: &Number, limit: T) -> bool
            where
                T: Copy,
                u64: num_cmp::NumCmp<T>,
                i64: num_cmp::NumCmp<T>,
                f64: num_cmp::NumCmp<T>,
            {
                if let Some(v) = value.as_u64() {
                    num_cmp::NumCmp::$trait_fn(v, limit)
                } else if let Some(v) = value.as_i64() {
                    num_cmp::NumCmp::$trait_fn(v, limit)
                } else {
                    let v = value.as_f64().expect("Always valid");
                    num_cmp::NumCmp::$trait_fn(v, limit)
                }
            }
        )*
    };
}

define_num_cmp!(
    num_ge => ge,
    num_le => le,
    num_gt => gt,
    num_lt => lt,
);

pub(crate) fn is_multiple_of_float(value: &Number, multiple: f64) -> bool {
    let value = value.as_f64().expect("Always valid");
    if value.is_zero() {
        // Zero is a multiple of anything
        return true;
    }
    if value < multiple {
        return false;
    }
    // From the JSON Schema spec
    //
    // > A numeric instance is valid only if division by this keyword's value results in an integer.
    //
    // For fractions, integers have denominator equal to one.
    //
    // Ref: https://json-schema.org/draft/2020-12/json-schema-validation#section-6.2.1
    (BigFraction::from(value) / BigFraction::from(multiple))
        .denom()
        .map_or(true, fraction::One::is_one)
}

pub(crate) fn is_multiple_of_integer(value: &Number, multiple: f64) -> bool {
    let value = value.as_f64().expect("Always valid");
    // As the divisor has its fractional part as zero, then any value with a non-zero
    // fractional part can't be a multiple of this divisor, therefore it is short-circuited
    value.fract() == 0. && (value % multiple) == 0.
}
