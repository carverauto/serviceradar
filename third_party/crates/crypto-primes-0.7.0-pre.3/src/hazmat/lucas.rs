//! Lucas primality test.
use core::num::NonZero;
use crypto_bigint::{Limb, Monty, MontyMultiplier, Odd, Square, Unsigned, Word};

use super::{
    Primality,
    gcd::gcd_vartime,
    jacobi::{JacobiSymbol, jacobi_symbol_vartime},
};

/// The maximum number of attempts to find `D` such that `(D/n) == -1`.
// This is widely believed to be impossible.
// So if we exceed it, we will panic reporting the value of `n`.
const MAX_ATTEMPTS: usize = 10_000;

/// The number of attempts to find `D` such that `(D/n) == -1`
/// before checking that `n` is a square (in which case such `D` does not exist).
// This check is relatively expensive compared to calculating the Jacobi symbol
// (~30x for 1024-bit numbers, ~100x for 2048 bit).
// On the other hand, if `n` is a non-square we expect to find a `D`
// in just a few attempts on average (an estimate for the Selfridge method
// can be found in [^Baillie1980], section 7; for the brute force method
// it seems to be about the same).
const ATTEMPTS_BEFORE_SQRT: usize = 30;

/// A method for selecting the base `(P, Q)` for the Lucas primality test.
pub trait LucasBase {
    /// Given an odd integer, returns `Ok((P, abs(Q), is_negative(Q)))` on success,
    /// or `Err(Primality)` if the primality for the given integer was discovered
    /// during the search for a base.
    fn generate<T: Unsigned>(&self, n: &Odd<T>) -> Result<(Word, Word, bool), Primality>;
}

/// "Method A" for selecting the base given in Baillie & Wagstaff[^Baillie1980],
/// attributed to Selfridge.
///
/// Try `D = 1 - 4Q = 5, -7, 9, -11, 13, ...` until `Jacobi(D, n) = -1`.
/// Return `P = 1, Q = (1 - D) / 4)`.
///
/// [^Baillie1980]: R. Baillie, S. S. Wagstaff, "Lucas pseudoprimes",
///   Math. Comp. 35 1391-1417 (1980),
///   DOI: [10.2307/2006406](https://dx.doi.org/10.2307/2006406),
///   <http://mpqs.free.fr/LucasPseudoprimes.pdf>
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub struct SelfridgeBase;

impl LucasBase for SelfridgeBase {
    fn generate<T: Unsigned>(&self, n: &Odd<T>) -> Result<(Word, Word, bool), Primality> {
        let mut abs_d = 5;
        let mut d_is_negative = false;
        let n_is_small = n.bits_vartime() < Word::BITS; // if true, `n` fits into one `Word`
        let small_n = n.as_ref().as_ref()[0].0;
        let mut attempts = 0;
        loop {
            if attempts >= MAX_ATTEMPTS {
                panic!("internal error: cannot find (D/n) = -1 for {:?}", n)
            }

            if attempts >= ATTEMPTS_BEFORE_SQRT {
                let sqrt_n = n.sqrt_vartime();
                if &sqrt_n.wrapping_mul(&sqrt_n) == n.as_ref() {
                    return Err(Primality::Composite);
                }
            }

            let j = jacobi_symbol_vartime(abs_d, d_is_negative, n);

            if j == JacobiSymbol::MinusOne {
                break;
            }
            if j == JacobiSymbol::Zero {
                // Modification of Method A by Baillie, in an example to OEIS:A217120
                // (https://oeis.org/A217120/a217120_1.txt):
                // If `d == (+,-)n`, (e.g., `n` = 5 or 11) try the next `d` instead of quitting;
                // this small modification of Selfridge's method A
                // enables 5 and 11 to be classified as Lucas probable primes.
                // Otherwise GCD(D, n) > 1, and therefore n is not prime.
                if !(n_is_small && small_n == abs_d) {
                    return Err(Primality::Composite);
                }
            }

            attempts += 1;
            d_is_negative = !d_is_negative;
            abs_d += 2;
        }

        // Calculate `q = (1 - d) / 4`.
        // No remainder from division by 4, by construction of `d`.
        let (abs_q, q_is_negative) = if d_is_negative {
            ((abs_d + 1) / 4, false)
        } else {
            ((abs_d - 1) / 4, true)
        };

        Ok((1, abs_q, q_is_negative))
    }
}

/// "Method A*" for selecting the base given in Baillie & Wagstaff[^Baillie1980].
///
/// Same as [`SelfridgeBase`], but returns `(P = 5, Q = 5)` if the Selfridge base set `Q = -1`.
///
/// [^Baillie1980]: R. Baillie, S. S. Wagstaff, "Lucas pseudoprimes",
///   Math. Comp. 35 1391-1417 (1980),
///   DOI: [10.2307/2006406](https://dx.doi.org/10.2307/2006406),
///   <http://mpqs.free.fr/LucasPseudoprimes.pdf>
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub struct AStarBase;

impl LucasBase for AStarBase {
    fn generate<T: Unsigned>(&self, n: &Odd<T>) -> Result<(Word, Word, bool), Primality> {
        SelfridgeBase.generate(n).map(|(p, abs_q, q_is_negative)| {
            if abs_q == 1 && q_is_negative {
                (5, 5, false)
            } else {
                (p, abs_q, q_is_negative)
            }
        })
    }
}

/// "Method C" for selecting the base given by Baillie[^Baillie].
///
/// Try `P = 3, 4, 5, ...` until `Jacobi(D, n) = -1`, where `D = P^2 - 4Q`.
/// Returns the found `P`, and `Q = 1`.
///
/// [^Baillie]: R. Baillie, Mathematica code for extra strong Lucas pseudoprimes,
///   <https://oeis.org/A217719/a217719.txt>
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub struct BruteForceBase;

impl LucasBase for BruteForceBase {
    fn generate<T: Unsigned>(&self, n: &Odd<T>) -> Result<(Word, Word, bool), Primality> {
        let mut p = 3;
        let mut attempts = 0;

        loop {
            if attempts >= MAX_ATTEMPTS {
                panic!("internal error: cannot find (D/n) = -1 for {:?}", n)
            }

            if attempts >= ATTEMPTS_BEFORE_SQRT {
                let sqrt_n = n.sqrt_vartime();
                if &sqrt_n.wrapping_mul(&sqrt_n) == n.as_ref() {
                    return Err(Primality::Composite);
                }
            }

            // Can unwrap here since `p` is always small (see the condition above).
            let j = jacobi_symbol_vartime(p * p - 4, false, n);

            if j == JacobiSymbol::MinusOne {
                break;
            }
            if j == JacobiSymbol::Zero {
                // D = P^2 - 4 = (P - 2)(P + 2).
                // If (D/n) == 0 then D shares a prime factor with n.
                // Since the loop proceeds in increasing P and starts with P - 2 == 1,
                // the shared prime factor must be P + 2.
                // If P + 2 == n, then n is prime; otherwise P + 2 is a proper factor of n.
                let primality = if n.as_ref() == &T::from_limb_like(Limb::from(p + 2), n.as_ref()) {
                    Primality::Prime
                } else {
                    Primality::Composite
                };
                return Err(primality);
            }

            attempts += 1;
            p += 1;
        }

        Ok((p, 1, false))
    }
}

/// For the given odd `n`, finds `s` and odd `d` such that `n + 1 == 2^s * d`.
fn decompose<T>(n: &Odd<T>) -> (u32, Odd<T>)
where
    T: Unsigned,
{
    // Need to be careful here since `n + 1` can overflow.
    // Instead of adding 1 and counting trailing 0s, we count trailing ones on the original `n`.

    let one = T::one_like(n);
    let s = n.trailing_ones_vartime();
    let d = if s < n.bits_precision() {
        // The shift won't overflow because of the check above.
        // The addition won't overflow since the original `n` was odd,
        // so we right-shifted at least once.
        n.as_ref()
            .overflowing_shr_vartime(s)
            .expect("shift should be within range by construction")
            .checked_add(&one)
            .expect("addition should not overflow by construction")
    } else {
        one
    };

    (s, Odd::new(d).expect("`d` should be odd by construction"))
}

/// The checks to perform in the Lucas test.
///
/// Given the Lucas sequence built from some base `(P, Q)` (see [`LucasBase`])
/// up to the elements `V(d)`, `U(d)`, where `d * 2^s == n - (D/n)`, `d` odd, and `D = P^2 - 4Q`,
/// the checks are defined as follows:
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub enum LucasCheck {
    /// Introduced by Baillie & Wagstaff[^Baillie1980].
    /// If `U(n - (D/n)) == 0`, report the number as prime.
    ///
    /// This is the Lucas test prescribed by the FIPS-186.5[^FIPS] standard (Section B.3.3).
    ///
    /// If the base is [`SelfridgeBase`], known false positives constitute OEIS:A217120[^A217120].
    ///
    /// [^Baillie1980]: R. Baillie, S. S. Wagstaff, "Lucas pseudoprimes",
    ///   Math. Comp. 35 1391-1417 (1980),
    ///   DOI: [10.2307/2006406](https://dx.doi.org/10.2307/2006406),
    ///   <http://mpqs.free.fr/LucasPseudoprimes.pdf>
    ///
    /// [^FIPS]: <https://nvlpubs.nist.gov/nistpubs/FIPS/NIST.FIPS.186-5.pdf>
    ///
    /// [^A217120]: <https://oeis.org/A217120>
    Regular,

    /// Introduced by Baillie & Wagstaff[^Baillie1980].
    /// If either of the following is true:
    /// - any of `V(d*2^r) == 0` for `0 <= r < s`,
    /// - `U(d) == 0`,
    ///
    /// report the number as prime.
    ///
    /// If the base is [`SelfridgeBase`], known false positives constitute OEIS:A217255[^A217255].
    ///
    /// [^Baillie1980]: R. Baillie, S. S. Wagstaff, "Lucas pseudoprimes",
    ///   Math. Comp. 35 1391-1417 (1980),
    ///   DOI: [10.2307/2006406](https://dx.doi.org/10.2307/2006406),
    ///   <http://mpqs.free.fr/LucasPseudoprimes.pdf>
    ///
    /// [^A217255]: <https://oeis.org/A217255>
    Strong,

    /// A [`LucasCheck::ExtraStrong`] without checking for `U(d)`.
    /// That is, if either of the following is true:
    /// - any of `V(d*2^r) == 0` for `0 <= r < s`,
    /// - `V(d) == ±2`,
    ///
    /// report the number as prime.
    ///
    /// Note: the second condition is only checked if `Q == 1`,
    /// otherwise it is considered to be true.
    ///
    /// If the base is [`BruteForceBase`], some known false positives
    /// are listed by Jacobsen[^Jacobsen].
    ///
    /// Note: this option is intended for testing against known pseudoprimes;
    /// do not use unless you know what you are doing.
    ///
    /// [^Jacobsen]: D. Jacobsen, "Pseudoprime Statistics, Tables, and Data",
    ///   <http://ntheory.org/pseudoprimes.html>
    AlmostExtraStrong,

    /// Introduced by Mo[^Mo1993], and also described by Grantham[^Grantham2001].
    /// If either of the following is true:
    /// - any of `V(d*2^r) == 0` for `0 <= r < s`,
    /// - `U(d) == 0` and `V(d) == ±2`,
    ///
    /// report the number as prime.
    ///
    /// Note that this check only differs from [`LucasCheck::Strong`] if `Q == 1`.
    ///
    /// If the base is [`BruteForceBase`], known false positives constitute OEIS:A217719[^A217719].
    ///
    /// [^Mo1993]: Zhaiyu Mo, "Diophantine equations, Lucas sequences and pseudoprimes",
    ///   graduate thesis, University of Calgary, Calgary, AB (1993)
    ///   DOI: [10.11575/PRISM/10820](https://dx.doi.org/10.11575/PRISM/10820)
    ///
    /// [^Grantham2001]: J. Grantham, "Frobenius pseudoprimes",
    ///   Math. Comp. 70 873-891 (2001),
    ///   DOI: [10.1090/S0025-5718-00-01197-2](https://dx.doi.org/10.1090/S0025-5718-00-01197-2)
    ///
    /// [^A217719]: <https://oeis.org/A217719>
    ExtraStrong,

    /// Introduced by Baillie et al[^Baillie2021].
    /// If `V(n+1) == 2 Q`, report the number as prime.
    ///
    /// If the base is [`AStarBase`], some known false positives
    /// are provided by Baillie et al[^Baillie2021].
    ///
    /// [^Baillie2021]: R. Baillie, A. Fiori, S. S. Wagstaff,
    ///   "Strengthening the Baillie-PSW primality test",
    ///   Math. Comp. 90 1931-1955 (2021),
    ///   DOI: [10.1090/mcom/3616](https://doi.org/10.1090/mcom/3616)
    LucasV,

    /// The Lucas part of the improved BPSW test proposed by Baillie et al[^Baillie2021].
    ///
    /// Performs [`LucasCheck::Strong`] and [`LucasCheck::LucasV`] checks, and applies the Euler criterion,
    /// checking if `Q^((n+1)/2) == Q * (Q/n) mod n`. If either of those fail,
    /// the candidate is considered composite.
    ///
    /// [^Baillie2021]: R. Baillie, A. Fiori, S. S. Wagstaff,
    ///   "Strengthening the Baillie-PSW primality test",
    ///   Math. Comp. 90 1931-1955 (2021),
    ///   DOI: [10.1090/mcom/3616](https://doi.org/10.1090/mcom/3616)
    Bpsw21,
}

/// Performs the primality test based on Lucas sequence.
///
/// See [`LucasCheck`] for possible checks, and the implementors of [`LucasBase`]
/// for the corresponding bases.
///
/// When used with [`SelfridgeBase`] and [`LucasCheck::Regular`], implements the algorithm
/// prescribed by the FIPS.186-5 standard[^FIPS].
///
/// [^FIPS]: FIPS-186.5 standard, <https://nvlpubs.nist.gov/nistpubs/FIPS/NIST.FIPS.186-5.pdf>
pub fn lucas_test<T>(candidate: Odd<T>, base: impl LucasBase, check: LucasCheck) -> Primality
where
    T: Unsigned,
{
    // The comments in this function use references in `LucasCheck`, plus this one:
    //
    // [^Crandall2005]:
    //   R. Crandall, C. Pomerance, "Prime numbers: a computational perspective",
    //   2nd ed., Springer (2005) (ISBN: 0-387-25282-7, 978-0387-25282-7)

    // A word-to-big integer conversion helper
    let to_integer = |x: Word| T::from_limb_like(Limb::from(x), candidate.as_ref());

    // Find the base for the Lucas sequence.
    let (p, abs_q, q_is_negative) = match base.generate(&candidate) {
        Ok(pq) => pq,
        Err(primality) => return primality,
    };

    // Discriminant `d = p^2 - 4q`
    let (abs_d, d_is_negative) = if q_is_negative {
        (p * p + 4 * abs_q, false)
    } else {
        let t1 = p * p;
        let t2 = 4 * abs_q;
        if t2 > t1 { (t2 - t1, true) } else { (t1 - t2, false) }
    };

    // If either is true, it allows us to optimize certain parts of the calculations.
    let p_is_one = p == 1;
    let q_is_one = abs_q == 1 && !q_is_negative;

    // See the references for the specific checks in the docstrings for [`LucasCheck`].

    // All of the definitions require gcd(n, 2QD) == 1.
    // We know gcd(n, D) = 1 by construction of the base (D is chosen such that (D/n) != 0).
    // We know gcd(n, 2) = 1 (we checked for it earlier).
    // In practice, gcd(n, Q) = 1 is always true, because the Lucas test is preceded by a sieve,
    // and since `Q` is always small, division by it would have been already checked.
    // But in order to avoid an implicit assumption that a sieve has been run,
    // we check that gcd(n, Q) = 1 anyway - again, since `Q` is small,
    // it does not noticeably affect the performance.
    if abs_q != 1
        && gcd_vartime(
            candidate.as_ref(),
            NonZero::new(abs_q).expect("q is not zero by construction"),
        ) != 1
        && candidate.as_ref() > &to_integer(abs_q)
    {
        return Primality::Composite;
    }

    // Find `d` and `s`, such that `d` is odd and `d * 2^s = n - (D/n)`.
    // Since `(D/n) == -1` by construction, we're looking for `d * 2^s = n + 1`.
    let (s, d) = decompose(&candidate);

    // Some constants in Montgomery form
    let params = <T as Unsigned>::Monty::new_params_vartime(candidate.clone());

    let zero = <T as Unsigned>::Monty::zero(params.clone());
    let one = <T as Unsigned>::Monty::one(params.clone());
    let two = one.clone() + &one;
    let minus_two = -two.clone();

    // Convert Q to Montgomery form

    let q = if q_is_one {
        one.clone()
    } else {
        let abs_q = <T as Unsigned>::Monty::new(to_integer(abs_q), params.clone());
        if q_is_negative { -abs_q } else { abs_q }
    };

    // Convert P to Montgomery form

    let p = if p_is_one {
        one.clone()
    } else {
        <T as Unsigned>::Monty::new(to_integer(p), params.clone())
    };

    // Compute d-th element of Lucas sequence (U_d(P, Q), V_d(P, Q)), where:
    //
    // V_0 = 2
    // U_0 = 0
    //
    // U_{2k} = U_k V_k
    // V_{2k} = V_k^2 - 2 Q^k
    //
    // U_{k+1} = (P U_k + V_k) / 2
    // V_{k+1} = (D U_k + P V_k) / 2
    //
    // (The propagation method is due to [^Baillie2021], Eqs. 13, 14, 16, 17)
    // We can therefore start with k=0 and build up to k=d in log2(d) steps.

    // Starting with k = 0
    let mut vk = two.clone(); // keeps V_k
    let mut uk = <T as Unsigned>::Monty::zero(params.clone()); // keeps U_k
    let mut qk = one.clone(); // keeps Q^k

    let mut temp = <T as Unsigned>::Monty::zero(params.clone());

    let mut mm = <<T as Unsigned>::Monty as Monty>::Multiplier::from(&params);

    // D in Montgomery representation - note that it can be negative.
    let abs_d = <T as Unsigned>::Monty::new(to_integer(abs_d), params.clone());
    let d_m = if d_is_negative { -abs_d } else { abs_d };

    for i in (0..d.bits_vartime()).rev() {
        // k' = 2k
        // U_{k'} = U_k V_k;
        // V_{k'} = V_k^2 - 2 Q_k
        // Q^{k'} = (Q^k)^2

        mm.mul_assign(&mut uk, &vk);

        mm.square_assign(&mut vk);
        vk -= &qk;
        vk -= &qk;

        mm.square_assign(&mut qk);

        if d.bit_vartime(i) {
            // k' = k + 1
            // U_{k'} = (P U_k + V_k) / 2
            // V_{k'} = (D U_k + P V_k) / 2
            // Q^{k'} = Q Q^k

            temp.copy_montgomery_from(&uk);
            if !p_is_one {
                mm.mul_assign(&mut uk, &p);
            }
            uk += &vk;
            uk.div_by_2_assign();

            mm.mul_assign(&mut temp, &d_m);
            if !p_is_one {
                mm.mul_assign(&mut vk, &p);
            };
            vk += &temp;
            vk.div_by_2_assign();

            mm.mul_assign(&mut qk, &q);
        }
    }

    // Now k=d, so vk = V_d and uk = U_d.

    // The `U_d == 0` criterion.
    let ud_equals_zero = uk == zero;

    // The `V_d == ±2 mod n` criterion.
    //
    // Note that the first identity only applies if `Q = 1`, since it is a consequence
    // of a property of Lucas series: `V_k^2 - 4 Q^k = D U_k^2 mod n`.
    // If `Q = 1` we can easily decompose the left side of the equation
    // leading to the check above.
    //
    // If `Q != 1` we just consider it passed (we don't have a corresponding
    // pseudoprime list anyway).
    let vk_equals_two = !q_is_one || (vk == two || vk == minus_two);

    // Early exit for some of the checks.
    if check == LucasCheck::Strong && ud_equals_zero {
        return Primality::ProbablyPrime;
    }

    if check == LucasCheck::ExtraStrong && ud_equals_zero && vk_equals_two {
        return Primality::ProbablyPrime;
    }

    // "Almost extra strong" check skips the `U_d` check.
    // Since we have `U_d` anyway, it does not improve performance,
    // so it is only here for testing purposes, since we have a corresponding pseudoprime list.
    if check == LucasCheck::AlmostExtraStrong && vk_equals_two {
        return Primality::ProbablyPrime;
    }

    // Propagate `V_k` up to `V_{n+1}`.
    // For the checks which require it, check if V_{2^t d} == 0 mod n for some 0 <= t < s.

    let mut one_of_vk_equals_zero = vk == zero;

    if (check == LucasCheck::Strong || check == LucasCheck::ExtraStrong || check == LucasCheck::AlmostExtraStrong)
        && one_of_vk_equals_zero
    {
        return Primality::ProbablyPrime;
    }

    for _ in 1..s {
        // Optimization: V_k = ±2 is a fixed point for V_k' = V_k^2 - 2 Q^k with Q = 1,
        // so if V_k = ±2, we can stop: we will never find a future V_k == 0.
        if (check == LucasCheck::Strong
            || check == LucasCheck::ExtraStrong
            || check == LucasCheck::AlmostExtraStrong
            || check == LucasCheck::Bpsw21)
            && q_is_one
            && (vk == two || vk == minus_two)
        {
            return Primality::Composite;
        }

        if check == LucasCheck::Regular {
            uk *= &vk;
        }

        // k' = 2k
        // V_{k'} = V_k^2 - 2 Q^k
        vk = vk.square() - &qk.double();

        one_of_vk_equals_zero |= vk == zero;

        if (check == LucasCheck::Strong || check == LucasCheck::ExtraStrong || check == LucasCheck::AlmostExtraStrong)
            && one_of_vk_equals_zero
        {
            return Primality::ProbablyPrime;
        }

        if !q_is_one {
            qk = qk.square();
        }
    }

    if check == LucasCheck::Strong || check == LucasCheck::ExtraStrong || check == LucasCheck::AlmostExtraStrong {
        return Primality::Composite;
    }

    if check == LucasCheck::Bpsw21 && !ud_equals_zero && !one_of_vk_equals_zero {
        return Primality::Composite;
    }

    // At this point:
    //   vk = V_{d * 2^(s-1)} == V_{(n + 1) / 2}.
    //   qk = Q^{(n + 1) / 2}
    // In case of `check == Regular`, also
    //   uk = U_{(n + 1) / 2}

    if check == LucasCheck::Regular {
        // Double the index again:
        uk *= &vk; // now `uk = U_{d * 2^s} = U_{n+1}`
        if uk == zero {
            return Primality::ProbablyPrime;
        } else {
            return Primality::Composite;
        }
    }

    // Double the index again:
    vk = vk.square() - &qk - &qk; // now `vk = V_{d * 2^s} = V_{n+1}`

    // Lucas-V check[^Baillie2021]: if `V_{n+1} != 2 Q`, report `n` as composite.
    let lucas_v = vk == q.double();
    if check == LucasCheck::LucasV {
        if !lucas_v {
            return Primality::Composite;
        } else {
            return Primality::ProbablyPrime;
        }
    }

    // The only remaining variant at this point.
    debug_assert!(check == LucasCheck::Bpsw21);

    // In case of BPSW'21, even if the Lucas-V check is passed we have another check to apply
    if !lucas_v {
        return Primality::Composite;
    }

    // Euler criterion: if `Q^((n+1)/2) != Q * (Q/n) mod n`, report `n` as composite.
    let q_jacobi = jacobi_symbol_vartime(abs_q, q_is_negative, &candidate);
    let t = match q_jacobi {
        JacobiSymbol::Zero => unreachable!("we previously checked that either `Q = 1` or `gcd(Q, n) != 1"),
        JacobiSymbol::One => q,
        JacobiSymbol::MinusOne => -q,
    };

    if qk == t {
        Primality::ProbablyPrime
    } else {
        Primality::Composite
    }
}

#[cfg(test)]
mod tests {

    use alloc::format;

    use crypto_bigint::{Odd, U64, U128, Uint, Unsigned, Word};

    #[cfg(feature = "tests-exhaustive")]
    use num_prime::nt_funcs::is_prime64;

    use super::{AStarBase, BruteForceBase, LucasBase, LucasCheck, SelfridgeBase, decompose, lucas_test};
    use crate::hazmat::{Primality, primes, pseudoprimes};

    #[test]
    fn bases_derived_traits() {
        assert_eq!(format!("{SelfridgeBase:?}"), "SelfridgeBase");
        assert_eq!(SelfridgeBase.clone(), SelfridgeBase);
        assert_eq!(format!("{AStarBase:?}"), "AStarBase");
        assert_eq!(AStarBase.clone(), AStarBase);
        assert_eq!(format!("{BruteForceBase:?}"), "BruteForceBase");
        assert_eq!(BruteForceBase.clone(), BruteForceBase);

        assert_eq!(format!("{:?}", LucasCheck::Strong), "Strong");
        assert_eq!(LucasCheck::Strong.clone(), LucasCheck::Strong);
    }

    #[test]
    fn base_for_square() {
        // We can't find a base with Jacobi symbol = -1 for a square,
        // check that it is handled properly.
        let num = Odd::new(U64::from(131u32).square()).unwrap();
        assert_eq!(SelfridgeBase.generate(&num), Err(Primality::Composite));
        assert_eq!(AStarBase.generate(&num), Err(Primality::Composite));
        assert_eq!(BruteForceBase.generate(&num), Err(Primality::Composite));
    }

    #[test]
    fn base_early_quit() {
        // 5 is flagged as prime at the base generation stage
        assert_eq!(
            BruteForceBase.generate(&Odd::new(U64::from(5u32)).unwrap()),
            Err(Primality::Prime)
        )
    }

    #[test]
    fn gcd_check() {
        // Test that `gcd(2QD, n) == 1` is checked after the base is found.
        // All the bases already produce D such that `gcd(D, n) == 1`.
        // We need a special test base generator to test the situation where
        // `gcd(n, Q) != 1` and `n > Q`, because it just doesn't seem to happen normally
        // for "production" bases.

        struct TestBase;

        impl LucasBase for TestBase {
            fn generate<T: Unsigned>(&self, _n: &Odd<T>) -> Result<(Word, Word, bool), Primality> {
                Ok((5, 5, false))
            }
        }

        assert_eq!(
            lucas_test(Odd::new(U64::from(15u32)).unwrap(), TestBase, LucasCheck::Strong),
            Primality::Composite
        );
    }

    #[test]
    fn decomposition() {
        assert_eq!(
            decompose(&Odd::new(U128::MAX).unwrap()),
            (128, Odd::new(U128::ONE).unwrap())
        );
        assert_eq!(
            decompose(&Odd::new(U128::ONE).unwrap()),
            (1, Odd::new(U128::ONE).unwrap())
        );
        assert_eq!(
            decompose(&Odd::new(U128::from(7766015u32)).unwrap()),
            (15, Odd::new(U128::from(237u32)).unwrap())
        );
    }

    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    enum BaseType {
        Selfridge,
        BruteForce,
        AStar,
    }

    trait HasBaseType: LucasBase + Copy {
        const BASE_TYPE: BaseType;
    }

    impl HasBaseType for SelfridgeBase {
        const BASE_TYPE: BaseType = BaseType::Selfridge;
    }

    impl HasBaseType for BruteForceBase {
        const BASE_TYPE: BaseType = BaseType::BruteForce;
    }

    impl HasBaseType for AStarBase {
        const BASE_TYPE: BaseType = BaseType::AStar;
    }

    // Returns `true` if `num` is a composite that is known to be reported as a prime
    // by a Lucas test with the given base `T` and check type `check`.
    // Returns `false` is `num` is not in the list of such composites for the given base and check type.
    //
    // Panics if there is no data for the given base and check type.
    fn is_pseudoprime<T: HasBaseType>(num: u32, check: LucasCheck) -> bool {
        let pseudoprimes = match (T::BASE_TYPE, check) {
            (BaseType::Selfridge, LucasCheck::Regular) => pseudoprimes::LUCAS,
            (BaseType::Selfridge, LucasCheck::Strong) => pseudoprimes::STRONG_LUCAS,
            (BaseType::BruteForce, LucasCheck::AlmostExtraStrong) => pseudoprimes::ALMOST_EXTRA_STRONG_LUCAS,
            (BaseType::BruteForce, LucasCheck::ExtraStrong) => pseudoprimes::EXTRA_STRONG_LUCAS,
            (BaseType::AStar, LucasCheck::LucasV) => pseudoprimes::LUCAS_V,
            (BaseType::AStar, LucasCheck::Bpsw21) => &[],
            _ => panic!("We do not have pseudoprimes listed for this combination of base and check"),
        };

        pseudoprimes.contains(&num)
    }

    fn test_pseudoprimes<T: HasBaseType>(numbers: &[u32], base: T, check: LucasCheck, expected_result: bool) {
        for num in numbers.iter() {
            let false_positive = is_pseudoprime::<T>(*num, check);
            let actual_expected_result = if false_positive { true } else { expected_result };

            // Test both single-limb and multi-limb, just in case.

            let is_prime = lucas_test(Odd::new(Uint::<1>::from(*num)).unwrap(), base, check).is_probably_prime();
            assert_eq!(
                is_prime, actual_expected_result,
                "{num} reported as prime={is_prime}, expected prime={actual_expected_result}"
            );

            let is_prime = lucas_test(Odd::new(Uint::<2>::from(*num)).unwrap(), base, check).is_probably_prime();
            assert_eq!(
                is_prime, actual_expected_result,
                "{num} reported as prime={is_prime}, expected prime={actual_expected_result}"
            );
        }
    }

    #[test]
    fn strong_fibonacci_pseudoprimes() {
        // Can't use `test_pseudoprimes()` since `STRONG_FIBONACCI` is `U64`.
        for num in pseudoprimes::STRONG_FIBONACCI.iter() {
            assert!(!lucas_test(Odd::new(*num).unwrap(), SelfridgeBase, LucasCheck::Regular).is_probably_prime());
            assert!(!lucas_test(Odd::new(*num).unwrap(), SelfridgeBase, LucasCheck::Strong).is_probably_prime());
            assert!(!lucas_test(Odd::new(*num).unwrap(), AStarBase, LucasCheck::LucasV).is_probably_prime());
            assert!(
                !lucas_test(Odd::new(*num).unwrap(), BruteForceBase, LucasCheck::AlmostExtraStrong).is_probably_prime()
            );
            assert!(!lucas_test(Odd::new(*num).unwrap(), BruteForceBase, LucasCheck::ExtraStrong).is_probably_prime());
            assert!(!lucas_test(Odd::new(*num).unwrap(), AStarBase, LucasCheck::Bpsw21).is_probably_prime());
        }
    }

    #[test]
    fn fibonacci_pseudoprimes() {
        let nums = pseudoprimes::FIBONACCI;
        test_pseudoprimes(nums, SelfridgeBase, LucasCheck::Regular, false);
        test_pseudoprimes(nums, SelfridgeBase, LucasCheck::Strong, false);
        test_pseudoprimes(nums, AStarBase, LucasCheck::LucasV, false);
        test_pseudoprimes(nums, BruteForceBase, LucasCheck::AlmostExtraStrong, false);
        test_pseudoprimes(nums, BruteForceBase, LucasCheck::ExtraStrong, false);
        test_pseudoprimes(nums, AStarBase, LucasCheck::Bpsw21, false);
    }

    #[test]
    fn bruckman_lucas_pseudoprimes() {
        let nums = pseudoprimes::BRUCKMAN_LUCAS;
        test_pseudoprimes(nums, SelfridgeBase, LucasCheck::Regular, false);
        test_pseudoprimes(nums, SelfridgeBase, LucasCheck::Strong, false);
        test_pseudoprimes(nums, AStarBase, LucasCheck::LucasV, false);
        test_pseudoprimes(nums, BruteForceBase, LucasCheck::AlmostExtraStrong, false);
        test_pseudoprimes(nums, BruteForceBase, LucasCheck::ExtraStrong, false);
        test_pseudoprimes(nums, AStarBase, LucasCheck::Bpsw21, false);
    }

    #[test]
    fn almost_extra_strong_lucas_pseudoprimes() {
        let nums = pseudoprimes::ALMOST_EXTRA_STRONG_LUCAS;

        test_pseudoprimes(nums, SelfridgeBase, LucasCheck::Regular, false);
        test_pseudoprimes(nums, SelfridgeBase, LucasCheck::Strong, false);
        test_pseudoprimes(nums, AStarBase, LucasCheck::LucasV, false);

        // Check for the difference between the almost extra strong and extra strong tests.
        test_pseudoprimes(nums, BruteForceBase, LucasCheck::AlmostExtraStrong, true);
        test_pseudoprimes(nums, BruteForceBase, LucasCheck::ExtraStrong, false);

        test_pseudoprimes(nums, AStarBase, LucasCheck::Bpsw21, false);
    }

    #[test]
    fn extra_strong_lucas_pseudoprimes() {
        let nums = pseudoprimes::EXTRA_STRONG_LUCAS;
        test_pseudoprimes(nums, SelfridgeBase, LucasCheck::Regular, false);
        test_pseudoprimes(nums, SelfridgeBase, LucasCheck::Strong, false);
        test_pseudoprimes(nums, AStarBase, LucasCheck::LucasV, false);

        // These are the known false positives for the extra strong test
        // with brute force base selection.
        test_pseudoprimes(nums, BruteForceBase, LucasCheck::ExtraStrong, true);

        test_pseudoprimes(nums, AStarBase, LucasCheck::Bpsw21, false);
    }

    #[test]
    fn lucas_pseudoprimes() {
        let nums = pseudoprimes::LUCAS;
        test_pseudoprimes(nums, SelfridgeBase, LucasCheck::Regular, true);
        test_pseudoprimes(nums, SelfridgeBase, LucasCheck::Strong, false);
        test_pseudoprimes(nums, AStarBase, LucasCheck::LucasV, false);
        test_pseudoprimes(nums, BruteForceBase, LucasCheck::AlmostExtraStrong, false);
        test_pseudoprimes(nums, BruteForceBase, LucasCheck::ExtraStrong, false);
        test_pseudoprimes(nums, AStarBase, LucasCheck::Bpsw21, false);
    }

    #[test]
    fn strong_lucas_pseudoprimes() {
        let nums = pseudoprimes::STRONG_LUCAS;

        // These are the known false positives for the strong test
        // with Selfridge base selection.
        test_pseudoprimes(nums, SelfridgeBase, LucasCheck::Strong, true);

        test_pseudoprimes(nums, SelfridgeBase, LucasCheck::Regular, false);
        test_pseudoprimes(nums, AStarBase, LucasCheck::LucasV, false);
        test_pseudoprimes(nums, BruteForceBase, LucasCheck::AlmostExtraStrong, false);
        test_pseudoprimes(nums, BruteForceBase, LucasCheck::ExtraStrong, false);
        test_pseudoprimes(nums, AStarBase, LucasCheck::Bpsw21, false);
    }

    #[test]
    fn strong_pseudoprimes_base_2() {
        // Cross-test against the pseudoprimes that circumvent the MR test base 2.
        // We expect the Lucas test to correctly classify them as composites.

        let nums = pseudoprimes::STRONG_BASE_2;
        test_pseudoprimes(nums, SelfridgeBase, LucasCheck::Regular, false);
        test_pseudoprimes(nums, SelfridgeBase, LucasCheck::Strong, false);
        test_pseudoprimes(nums, AStarBase, LucasCheck::LucasV, false);
        test_pseudoprimes(nums, BruteForceBase, LucasCheck::AlmostExtraStrong, false);
        test_pseudoprimes(nums, BruteForceBase, LucasCheck::ExtraStrong, false);
        test_pseudoprimes(nums, AStarBase, LucasCheck::Bpsw21, false);
    }

    #[test]
    fn large_carmichael_number() {
        let p = Odd::new(pseudoprimes::LARGE_CARMICHAEL_NUMBER).unwrap();
        assert!(!lucas_test(p, SelfridgeBase, LucasCheck::Regular).is_probably_prime());
        assert!(!lucas_test(p, SelfridgeBase, LucasCheck::Strong).is_probably_prime());
        assert!(!lucas_test(p, AStarBase, LucasCheck::LucasV).is_probably_prime());
        assert!(!lucas_test(p, BruteForceBase, LucasCheck::AlmostExtraStrong).is_probably_prime());
        assert!(!lucas_test(p, BruteForceBase, LucasCheck::ExtraStrong).is_probably_prime());
        assert!(!lucas_test(p, AStarBase, LucasCheck::Bpsw21).is_probably_prime());
    }

    fn test_large_primes<const L: usize>(nums: &[Uint<L>]) {
        for num in nums {
            let num = Odd::new(*num).unwrap();
            assert!(lucas_test(num, SelfridgeBase, LucasCheck::Regular).is_probably_prime());
            assert!(lucas_test(num, SelfridgeBase, LucasCheck::Strong).is_probably_prime());
            assert!(lucas_test(num, AStarBase, LucasCheck::LucasV).is_probably_prime());
            assert!(lucas_test(num, BruteForceBase, LucasCheck::AlmostExtraStrong).is_probably_prime());
            assert!(lucas_test(num, BruteForceBase, LucasCheck::ExtraStrong).is_probably_prime());
            assert!(lucas_test(num, AStarBase, LucasCheck::Bpsw21).is_probably_prime());
        }
    }

    #[test]
    fn large_primes() {
        test_large_primes(primes::PRIMES_128);
        test_large_primes(primes::PRIMES_256);
        test_large_primes(primes::PRIMES_384);
        test_large_primes(primes::PRIMES_512);
        test_large_primes(primes::PRIMES_1024);
    }

    #[test]
    fn test_lucas_v_pseudoprimes() {
        for num in pseudoprimes::LARGE_LUCAS_V {
            let num = Odd::new(*num).unwrap();
            // These are false positives for Lucas-V test
            assert!(lucas_test(num, AStarBase, LucasCheck::LucasV).is_probably_prime());

            // These tests should work correctly
            assert!(!lucas_test(num, SelfridgeBase, LucasCheck::Strong).is_probably_prime());
            assert!(!lucas_test(num, BruteForceBase, LucasCheck::AlmostExtraStrong).is_probably_prime());
            assert!(!lucas_test(num, BruteForceBase, LucasCheck::ExtraStrong).is_probably_prime());
            assert!(!lucas_test(num, AStarBase, LucasCheck::Bpsw21).is_probably_prime());
        }
    }

    #[test]
    fn corner_cases() {
        // By convention, 1 is composite. That's what `num-prime` returns.
        let res = lucas_test(
            Odd::new(U64::ONE).unwrap(),
            BruteForceBase,
            LucasCheck::AlmostExtraStrong,
        );
        assert_eq!(res, Primality::Composite);
    }

    #[cfg(feature = "tests-exhaustive")]
    #[test]
    fn exhaustive() {
        // Test all the odd numbers up to the limit where we know the false positives,
        // and compare the results with the reference.
        for num in (3..pseudoprimes::EXHAUSTIVE_TEST_LIMIT).step_by(2) {
            let res_ref = is_prime64(num.into());

            let odd_num = Odd::new(Uint::<1>::from(num)).unwrap();

            let lpsp = is_pseudoprime::<SelfridgeBase>(num, LucasCheck::Regular);
            let res = lucas_test(odd_num, SelfridgeBase, LucasCheck::Regular).is_probably_prime();
            let expected = lpsp || res_ref;
            assert_eq!(
                res, expected,
                "Selfridge base, regular: n={num}, expected={expected}, actual={res}",
            );

            let aeslpsp = is_pseudoprime::<BruteForceBase>(num, LucasCheck::AlmostExtraStrong);
            let res = lucas_test(odd_num, BruteForceBase, LucasCheck::AlmostExtraStrong).is_probably_prime();
            let expected = aeslpsp || res_ref;
            assert_eq!(
                res, expected,
                "Brute force base, almost extra strong: n={num}, expected={expected}, actual={res}",
            );

            let eslpsp = is_pseudoprime::<BruteForceBase>(num, LucasCheck::ExtraStrong);
            let res = lucas_test(odd_num, BruteForceBase, LucasCheck::ExtraStrong).is_probably_prime();
            let expected = eslpsp || res_ref;
            assert_eq!(
                res, expected,
                "Brute force base: n={num}, expected={expected}, actual={res}",
            );

            let slpsp = is_pseudoprime::<SelfridgeBase>(num, LucasCheck::Strong);
            let res = lucas_test(odd_num, SelfridgeBase, LucasCheck::Strong).is_probably_prime();
            let expected = slpsp || res_ref;
            assert_eq!(
                res, expected,
                "Selfridge base: n={num}, expected={expected}, actual={res}",
            );

            let vpsp = is_pseudoprime::<AStarBase>(num, LucasCheck::LucasV);
            let res = lucas_test(odd_num, AStarBase, LucasCheck::LucasV).is_probably_prime();
            let expected = vpsp || res_ref;
            assert_eq!(
                res, expected,
                "A* base, Lucas-V: n={num}, expected={expected}, actual={res}",
            );

            let bpsw21psp = is_pseudoprime::<AStarBase>(num, LucasCheck::Bpsw21);
            let res = lucas_test(odd_num, AStarBase, LucasCheck::Bpsw21).is_probably_prime();
            let expected = bpsw21psp || res_ref;
            assert_eq!(
                res, expected,
                "A* base, BPSW'21: n={num}, expected={expected}, actual={res}",
            );
        }
    }
}
