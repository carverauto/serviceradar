//! Generic RSA implementation

use core::cmp::Ordering;

use crypto_bigint::modular::{BoxedMontyForm, BoxedMontyParams};
use crypto_bigint::{BoxedUint, Gcd, NonZero, Odd, RandomMod, Resize};
use rand_core::TryCryptoRng;
use zeroize::Zeroize;

use crate::errors::{Error, Result};
use crate::traits::keys::{PrivateKeyParts, PublicKeyParts};

/// ⚠️ Raw RSA encryption of m with the public key. No padding is performed.
///
/// # ☢️️ WARNING: HAZARDOUS API ☢️
///
/// Use this function with great care! Raw RSA should never be used without an appropriate padding
/// or signature scheme. See the [module-level documentation][crate::hazmat] for more information.
#[inline]
pub fn rsa_encrypt<K: PublicKeyParts>(key: &K, m: &BoxedUint) -> Result<BoxedUint> {
    let res = pow_mod_params(m, key.e(), key.n_params());
    Ok(res)
}

/// ⚠️ Performs raw RSA decryption with no padding or error checking.
///
/// Returns a plaintext `BoxedUint`. Performs RSA blinding if an `Rng` is passed.
///
/// # ☢️️ WARNING: HAZARDOUS API ☢️
///
/// Use this function with great care! Raw RSA should never be used without an appropriate padding
/// or signature scheme. See the [module-level documentation][crate::hazmat] for more information.
#[inline]
pub fn rsa_decrypt<R: TryCryptoRng + ?Sized>(
    rng: Option<&mut R>,
    priv_key: &impl PrivateKeyParts,
    c: &BoxedUint,
) -> Result<BoxedUint> {
    let n = priv_key.n();
    let d = priv_key.d();

    if c.bits_precision() != n.as_ref().bits_precision() {
        return Err(Error::Decryption);
    }

    if c >= n.as_ref() {
        return Err(Error::Decryption);
    }

    let mut ir = None;

    let n_params = priv_key.n_params();
    let bits = d.bits_precision();

    let c = if let Some(rng) = rng {
        let (blinded, unblinder) = blind(rng, priv_key, c, n_params)?;
        ir = Some(unblinder);
        blinded.try_resize(bits).ok_or(Error::Internal)?
    } else {
        c.try_resize(bits).ok_or(Error::Internal)?
    };

    let is_multiprime = priv_key.primes().len() > 2;

    let m = match (
        priv_key.dp(),
        priv_key.dq(),
        priv_key.qinv(),
        priv_key.p_params(),
        priv_key.q_params(),
    ) {
        (Some(dp), Some(dq), Some(qinv), Some(p_params), Some(q_params)) if !is_multiprime => {
            // We have the precalculated values needed for the CRT.

            let p = &priv_key.primes()[0];
            let q = &priv_key.primes()[1];

            // precomputed: dP = (1/e) mod (p-1) = d mod (p-1)
            // precomputed: dQ = (1/e) mod (q-1) = d mod (q-1)

            // TODO: it may be faster to convert to and from Montgomery with prepared parameters
            // (modulo `p` and `q`) rather than calculating the remainder directly.

            // m1 = c^dP mod p
            let p_wide = p_params.modulus().resize_unchecked(c.bits_precision());
            let c_mod_dp = (&c % p_wide.as_nz_ref()).resize_unchecked(dp.bits_precision());
            let cp = BoxedMontyForm::new(c_mod_dp, p_params.clone());
            let mut m1 = cp.pow(dp);
            // m2 = c^dQ mod q
            let q_wide = q_params.modulus().resize_unchecked(c.bits_precision());
            let c_mod_dq = (&c % q_wide.as_nz_ref()).resize_unchecked(dq.bits_precision());
            let cq = BoxedMontyForm::new(c_mod_dq, q_params.clone());
            let m2 = cq.pow(dq).retrieve();

            // Note that since `p` and `q` may have different `bits_precision`,
            // it may be different for `m1` and `m2` as well.

            // (m1 - m2) mod p = (m1 mod p) - (m2 mod p) mod p
            let m2_mod_p = match p_params.bits_precision().cmp(&q_params.bits_precision()) {
                Ordering::Less => {
                    let p_wide = NonZero::new(p.clone())
                        .expect("`p` is non-zero")
                        .resize_unchecked(q_params.bits_precision());
                    (&m2 % p_wide).resize_unchecked(p_params.bits_precision())
                }
                Ordering::Greater => (&m2).resize_unchecked(p_params.bits_precision()),
                Ordering::Equal => m2.clone(),
            };
            let m2r = BoxedMontyForm::new(m2_mod_p, p_params.clone());
            m1 -= &m2r;

            // precomputed: qInv = (1/q) mod p

            // h = qInv.(m1 - m2) mod p
            let h = (qinv * m1).retrieve();

            // m = m2 + h.q
            let m2 = m2.try_resize(n.bits_precision()).ok_or(Error::Internal)?;
            let hq = (h * q)
                .try_resize(n.bits_precision())
                .ok_or(Error::Internal)?;
            m2.wrapping_add(&hq)
        }
        _ => {
            // c^d (mod n)
            pow_mod_params(&c, d, n_params)
        }
    };

    match ir {
        Some(ref ir) => {
            // unblind
            let res = unblind(&m, ir, n_params);
            Ok(res)
        }
        None => Ok(m),
    }
}

/// ⚠️ Performs raw RSA decryption with no padding.
///
/// Returns a plaintext `BoxedUint`. Performs RSA blinding if an `Rng` is passed.  This will also
/// check for errors in the CRT computation.
///
/// `c` must have the same `bits_precision` as the RSA key modulus.
///
/// # ☢️️ WARNING: HAZARDOUS API ☢️
///
/// Use this function with great care! Raw RSA should never be used without an appropriate padding
/// or signature scheme. See the [module-level documentation][crate::hazmat] for more information.
#[inline]
pub fn rsa_decrypt_and_check<R: TryCryptoRng + ?Sized>(
    priv_key: &impl PrivateKeyParts,
    rng: Option<&mut R>,
    c: &BoxedUint,
) -> Result<BoxedUint> {
    let m = rsa_decrypt(rng, priv_key, c)?;

    // In order to defend against errors in the CRT computation, m^e is
    // calculated, which should match the original ciphertext.
    let check = rsa_encrypt(priv_key, &m)?;

    if c != &check {
        return Err(Error::Internal);
    }

    Ok(m)
}

/// Returns the blinded c, along with the unblinding factor.
fn blind<R: TryCryptoRng + ?Sized, K: PublicKeyParts>(
    rng: &mut R,
    key: &K,
    c: &BoxedUint,
    n_params: &BoxedMontyParams,
) -> Result<(BoxedUint, BoxedUint)> {
    // Blinding involves multiplying c by r^e.
    // Then the decryption operation performs (m^e * r^e)^d mod n
    // which equals mr mod n. The factor of r can then be removed
    // by multiplying by the multiplicative inverse of r.
    debug_assert_eq!(&key.n().clone().get(), n_params.modulus());
    let bits = key.n_bits_precision();

    let mut r: BoxedUint = BoxedUint::one_with_precision(bits);
    let mut ir: Option<BoxedUint> = None;
    while ir.is_none() {
        r = BoxedUint::try_random_mod(rng, key.n()).map_err(|_| Error::Rng)?;
        if r.is_zero().into() {
            r = BoxedUint::one_with_precision(bits);
        }

        // r^-1 (mod n)
        ir = r.invert_mod(key.n()).into();
    }

    let blinded = {
        // r^e (mod n)
        let mut rpowe = pow_mod_params(&r, key.e(), n_params);
        // c * r^e (mod n)
        let c = mul_mod_params(c, &rpowe, n_params);
        rpowe.zeroize();

        c
    };

    let ir = ir.expect("loop exited");
    debug_assert_eq!(blinded.bits_precision(), bits);
    debug_assert_eq!(ir.bits_precision(), bits);

    Ok((blinded, ir))
}

/// Given an m and unblinding factor, unblind the m.
fn unblind(m: &BoxedUint, unblinder: &BoxedUint, n_params: &BoxedMontyParams) -> BoxedUint {
    // m * r^-1 (mod n)
    debug_assert_eq!(
        m.bits_precision(),
        unblinder.bits_precision(),
        "invalid unblinder"
    );

    debug_assert_eq!(
        m.bits_precision(),
        n_params.bits_precision(),
        "invalid n_params"
    );

    mul_mod_params(m, unblinder, n_params)
}

/// Computes `base.pow_mod(exp, n)` with precomputed `n_params`.
fn pow_mod_params(base: &BoxedUint, exp: &BoxedUint, n_params: &BoxedMontyParams) -> BoxedUint {
    let base = reduce_vartime(base, n_params);
    base.pow(exp).retrieve()
}

fn reduce_vartime(n: &BoxedUint, p: &BoxedMontyParams) -> BoxedMontyForm {
    let modulus = p.modulus().as_nz_ref().clone();
    let n_reduced = n.rem_vartime(&modulus).resize_unchecked(p.bits_precision());
    BoxedMontyForm::new(n_reduced, p.clone())
}

/// Computes `lhs.mul_mod(rhs, n)` with precomputed `n_params`.
fn mul_mod_params(lhs: &BoxedUint, rhs: &BoxedUint, n_params: &BoxedMontyParams) -> BoxedUint {
    // TODO: nicer api in crypto-bigint?
    let lhs = BoxedMontyForm::new(lhs.clone(), n_params.clone());
    let rhs = BoxedMontyForm::new(rhs.clone(), n_params.clone());
    (lhs * rhs).retrieve()
}

/// The following (deterministic) algorithm also recovers the prime factors `p` and `q` of a modulus `n`, given the
/// public exponent `e` and private exponent `d` using the method described in
/// [NIST 800-56B Appendix C.2](https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-56Br2.pdf).
pub fn recover_primes(
    n: &NonZero<BoxedUint>,
    e: &BoxedUint,
    d: &BoxedUint,
) -> Result<(BoxedUint, BoxedUint)> {
    // Check precondition

    // Note: because e is at most u64::MAX, it is already
    // known to be < 2**256
    if e <= &BoxedUint::from(2u64.pow(16)) {
        return Err(Error::InvalidArguments);
    }

    // 1. Let a = (de – 1) × GCD(n – 1, de – 1).
    let bits = d.bits_precision() * 2;
    let one = BoxedUint::one_with_precision(bits);
    let e = e.resize_unchecked(d.bits_precision());
    let d = d.resize_unchecked(d.bits_precision());
    let n = n.resize_unchecked(bits);

    let a1 = d * e - &one;
    let a2 = (n.as_ref() - &one).gcd(&a1);
    let a = a1 * a2;
    let n = n.resize_unchecked(a.bits_precision());

    // 2. Let m = floor(a /n) and r = a – m n, so that a = m n + r and 0 ≤ r < n.
    let m = &a / &n;
    let r = a - &m * n.as_ref();
    let n = n.get();

    // 3. Let b = ( (n – r)/(m + 1) ) + 1; if b is not an integer or b^2 ≤ 4n, then output an error indicator,
    //    and exit without further processing.
    let modulus_check = (&n - &r) % NonZero::new(&m + &one).expect("adding 1");
    if (!modulus_check.is_zero()).into() {
        return Err(Error::InvalidArguments);
    }
    let b = ((&n - &r) / NonZero::new(&m + &one).expect("adding one")) + one;

    let four = BoxedUint::from(4u32);
    let four_n = &n * four;
    let b_squared = b.square();

    if b_squared <= four_n {
        return Err(Error::InvalidArguments);
    }
    let b_squared_minus_four_n = b_squared - four_n;

    // 4. Let ϒ be the positive square root of b^2 – 4n; if ϒ is not an integer,
    //    then output an error indicator, and exit without further processing.
    let y = b_squared_minus_four_n.sqrt();

    let y_squared = y.square();
    let sqrt_is_whole_number = y_squared == b_squared_minus_four_n;
    if !sqrt_is_whole_number {
        return Err(Error::InvalidArguments);
    }

    let bits = core::cmp::max(b.bits_precision(), y.bits_precision());
    let two = NonZero::new(BoxedUint::from(2u64))
        .expect("2 is non zero")
        .resize_unchecked(bits);
    let p = (&b + &y) / &two;
    let q = (b - y) / two;

    Ok((p, q))
}

/// Compute the modulus of a key from its primes.
pub(crate) fn compute_modulus(primes: &[BoxedUint]) -> Odd<BoxedUint> {
    let mut primes = primes.iter();
    let mut out = primes.next().expect("must at least be one prime").clone();
    for p in primes {
        out *= p;
    }
    Odd::new(out).expect("modulus must be odd")
}

/// Compute the private exponent from its primes (p and q) and public exponent
/// This uses Euler's totient function
#[inline]
pub(crate) fn compute_private_exponent_euler_totient(
    primes: &[BoxedUint],
    exp: &BoxedUint,
) -> Result<BoxedUint> {
    if primes.len() < 2 {
        return Err(Error::InvalidPrime);
    }
    let bits = primes[0].bits_precision();
    let mut totient = BoxedUint::one_with_precision(bits);

    for prime in primes {
        totient *= prime - &BoxedUint::one();
    }
    let exp = exp.resize_unchecked(totient.bits_precision());

    // NOTE: `mod_inverse` checks if `exp` evenly divides `totient` and returns `None` if so.
    // This ensures that `exp` is not a factor of any `(prime - 1)`.
    let totient = NonZero::new(totient).expect("known");
    match exp.invert_mod(&totient).into_option() {
        Some(res) => Ok(res),
        None => Err(Error::InvalidPrime),
    }
}

/// Compute the private exponent from its primes (p and q) and public exponent
///
/// This is using the method defined by
/// [NIST 800-56B Section 6.2.1](https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-56Br2.pdf#page=47).
/// (Carmichael function)
///
/// FIPS 186-4 **requires** the private exponent to be less than λ(n), which would
/// make Euler's totiem unreliable.
#[inline]
pub(crate) fn compute_private_exponent_carmicheal(
    p: &BoxedUint,
    q: &BoxedUint,
    exp: &BoxedUint,
) -> Result<BoxedUint> {
    let one = BoxedUint::one();
    let p1 = p - &one;
    let q1 = q - &one;

    // LCM inlined
    let gcd = p1.gcd(&q1);
    let lcm = p1 / NonZero::new(gcd).expect("gcd is non zero") * &q1;
    let exp = exp.resize_unchecked(lcm.bits_precision());
    if let Some(d) = exp.invert_mod(&NonZero::new(lcm).expect("non zero")).into() {
        Ok(d)
    } else {
        // `exp` evenly divides `lcm`
        Err(Error::InvalidPrime)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recover_primes_works() {
        let bits = 2048;

        let n = BoxedUint::from_be_hex(
            concat!(
                "d397b84d98a4c26138ed1b695a8106ead91d553bf06041b62d3fdc50a041e222",
                "b8f4529689c1b82c5e71554f5dd69fa2f4b6158cf0dbeb57811a0fc327e1f28e",
                "74fe74d3bc166c1eabdc1b8b57b934ca8be5b00b4f29975bcc99acaf415b59bb",
                "28a6782bb41a2c3c2976b3c18dbadef62f00c6bb226640095096c0cc60d22fe7",
                "ef987d75c6a81b10d96bf292028af110dc7cc1bbc43d22adab379a0cd5d8078c",
                "c780ff5cd6209dea34c922cf784f7717e428d75b5aec8ff30e5f0141510766e2",
                "e0ab8d473c84e8710b2b98227c3db095337ad3452f19e2b9bfbccdd8148abf67",
                "76fa552775e6e75956e45229ae5a9c46949bab1e622f0e48f56524a84ed3483b"
            ),
            bits,
        )
        .unwrap();
        let e = BoxedUint::from(65_537u64);
        let d = BoxedUint::from_be_hex(
            concat!(
                "c4e70c689162c94c660828191b52b4d8392115df486a9adbe831e458d7395832",
                "0dc1b755456e93701e9702d76fb0b92f90e01d1fe248153281fe79aa9763a92f",
                "ae69d8d7ecd144de29fa135bd14f9573e349e45031e3b76982f583003826c552",
                "e89a397c1a06bd2163488630d92e8c2bb643d7abef700da95d685c941489a46f",
                "54b5316f62b5d2c3a7f1bbd134cb37353a44683fdc9d95d36458de22f6c44057",
                "fe74a0a436c4308f73f4da42f35c47ac16a7138d483afc91e41dc3a1127382e0",
                "c0f5119b0221b4fc639d6b9c38177a6de9b526ebd88c38d7982c07f98a0efd87",
                "7d508aae275b946915c02e2e1106d175d74ec6777f5e80d12c053d9c7be1e341"
            ),
            bits,
        )
        .unwrap();
        let p = BoxedUint::from_be_hex(
            concat!(
                "f827bbf3a41877c7cc59aebf42ed4b29c32defcb8ed96863d5b090a05a8930dd",
                "624a21c9dcf9838568fdfa0df65b8462a5f2ac913d6c56f975532bd8e78fb07b",
                "d405ca99a484bcf59f019bbddcb3933f2bce706300b4f7b110120c5df9018159",
                "067c35da3061a56c8635a52b54273b31271b4311f0795df6021e6355e1a42e61"
            ),
            bits / 2,
        )
        .unwrap();
        let q = BoxedUint::from_be_hex(
            concat!(
                "da4817ce0089dd36f2ade6a3ff410c73ec34bf1b4f6bda38431bfede11cef1f7",
                "f6efa70e5f8063a3b1f6e17296ffb15feefa0912a0325b8d1fd65a559e717b5b",
                "961ec345072e0ec5203d03441d29af4d64054a04507410cf1da78e7b6119d909",
                "ec66e6ad625bf995b279a4b3c5be7d895cd7c5b9c4c497fde730916fcdb4e41b"
            ),
            bits / 2,
        )
        .unwrap();

        let (mut p1, mut q1) = recover_primes(&NonZero::new(n).unwrap(), &e, &d).unwrap();

        if p1 < q1 {
            std::mem::swap(&mut p1, &mut q1);
        }
        assert_eq!(p, p1);
        assert_eq!(q, q1);
    }
}
