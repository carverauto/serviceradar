//! Common implementation utilities shared among backends.

/// Compute the first N powers of h, in reverse order.
#[inline]
pub(super) fn powers_of_h<T, MUL, const N: usize>(h: T, mul: MUL) -> [T; N]
where
    T: Clone + Copy,
    MUL: Fn(T, T) -> T,
{
    // (We could use MaybeUninit here, but the compiler should be smart enough to
    // see that everything is replaced.)
    let mut pow: [T; N] = [h; N];

    // TODO: We could _maybe_ improve the pipelining here by using more
    // square operations, but it might not help.
    let mut prev = h;
    for (i, v) in pow.iter_mut().rev().enumerate() {
        *v = h;
        if i > 0 {
            *v = mul(*v, prev);
        }
        prev = *v
    }
    pow
}
