use alloc::vec::Vec;
use core::cmp::Ordering;
use core::fmt;
use core::hash::{Hash, Hasher};

use crypto_bigint::modular::{BoxedMontyForm, BoxedMontyParams};
use crypto_bigint::{BoxedUint, Integer, NonZero, Odd, Resize};
use rand_core::CryptoRng;
use zeroize::{Zeroize, ZeroizeOnDrop};
#[cfg(feature = "serde")]
use {
    pkcs8::{DecodePrivateKey, EncodePrivateKey},
    serdect::serde::{de, ser, Deserialize, Serialize},
    spki::{DecodePublicKey, EncodePublicKey},
};

use crate::algorithms::generate::generate_multi_prime_key_with_exp;
use crate::algorithms::rsa::{
    compute_modulus, compute_private_exponent_carmicheal, compute_private_exponent_euler_totient,
    recover_primes,
};

use crate::dummy_rng::DummyRng;
use crate::errors::{Error, Result};
use crate::traits::keys::{CrtValue, PrivateKeyParts, PublicKeyParts};
use crate::traits::{PaddingScheme, SignatureScheme};

/// Represents the public part of an RSA key.
#[derive(Debug, Clone)]
pub struct RsaPublicKey {
    /// Modulus: product of prime numbers `p` and `q`
    n: NonZero<BoxedUint>,
    /// Public exponent: power to which a plaintext message is raised in
    /// order to encrypt it.
    ///
    /// Typically `0x10001` (`65537`)
    e: BoxedUint,

    n_params: BoxedMontyParams,
}

impl Eq for RsaPublicKey {}

impl PartialEq for RsaPublicKey {
    #[inline]
    fn eq(&self, other: &RsaPublicKey) -> bool {
        self.n == other.n && self.e == other.e
    }
}

impl Hash for RsaPublicKey {
    fn hash<H: Hasher>(&self, state: &mut H) {
        // Domain separator for RSA private keys
        state.write(b"RsaPublicKey");
        Hash::hash(&self.n, state);
        Hash::hash(&self.e, state);
    }
}

/// Represents a whole RSA key, public and private parts.
#[derive(Clone)]
pub struct RsaPrivateKey {
    /// Public components of the private key.
    pubkey_components: RsaPublicKey,
    /// Private exponent
    pub(crate) d: BoxedUint,
    /// Prime factors of N, contains >= 2 elements.
    pub(crate) primes: Vec<BoxedUint>,
    /// Precomputed values to speed up private operations
    pub(crate) precomputed: Option<PrecomputedValues>,
}

impl fmt::Debug for RsaPrivateKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let precomputed = if self.precomputed.is_some() {
            "Some(...)"
        } else {
            "None"
        };
        f.debug_struct("RsaPrivateKey")
            .field("pubkey_components", &self.pubkey_components)
            .field("d", &"...")
            .field("primes", &"&[...]")
            .field("precomputed", &precomputed)
            .finish()
    }
}

impl Eq for RsaPrivateKey {}
impl PartialEq for RsaPrivateKey {
    #[inline]
    fn eq(&self, other: &RsaPrivateKey) -> bool {
        self.pubkey_components == other.pubkey_components
            && self.d == other.d
            && self.primes == other.primes
    }
}

impl AsRef<RsaPublicKey> for RsaPrivateKey {
    fn as_ref(&self) -> &RsaPublicKey {
        &self.pubkey_components
    }
}

impl Hash for RsaPrivateKey {
    fn hash<H: Hasher>(&self, state: &mut H) {
        // Domain separator for RSA private keys
        state.write(b"RsaPrivateKey");
        Hash::hash(&self.pubkey_components, state);
    }
}

impl Drop for RsaPrivateKey {
    fn drop(&mut self) {
        self.d.zeroize();
        self.primes.zeroize();
        self.precomputed.zeroize();
    }
}

impl ZeroizeOnDrop for RsaPrivateKey {}

#[derive(Clone)]
pub(crate) struct PrecomputedValues {
    /// D mod (P-1)
    pub(crate) dp: BoxedUint,
    /// D mod (Q-1)
    pub(crate) dq: BoxedUint,
    /// Q^-1 mod P
    pub(crate) qinv: BoxedMontyForm,

    /// Montgomery params for `p`
    pub(crate) p_params: BoxedMontyParams,
    /// Montgomery params for `q`
    pub(crate) q_params: BoxedMontyParams,
}

impl ZeroizeOnDrop for PrecomputedValues {}

impl Zeroize for PrecomputedValues {
    fn zeroize(&mut self) {
        self.dp.zeroize();
        self.dq.zeroize();
        // TODO: once these have landed in crypto-bigint
        // self.p_params.zeroize();
        // self.q_params.zeroize();
    }
}

impl Drop for PrecomputedValues {
    fn drop(&mut self) {
        self.zeroize();
    }
}

impl From<RsaPrivateKey> for RsaPublicKey {
    fn from(private_key: RsaPrivateKey) -> Self {
        (&private_key).into()
    }
}

impl From<&RsaPrivateKey> for RsaPublicKey {
    fn from(private_key: &RsaPrivateKey) -> Self {
        let n = PublicKeyParts::n(private_key);
        let e = PublicKeyParts::e(private_key);
        let n_params = PublicKeyParts::n_params(private_key);
        RsaPublicKey {
            n: n.clone(),
            e: e.clone(),
            n_params: n_params.clone(),
        }
    }
}

impl PublicKeyParts for RsaPublicKey {
    fn n(&self) -> &NonZero<BoxedUint> {
        &self.n
    }

    fn e(&self) -> &BoxedUint {
        &self.e
    }

    fn n_params(&self) -> &BoxedMontyParams {
        &self.n_params
    }
}

impl RsaPublicKey {
    /// Encrypt the given message.
    pub fn encrypt<R: CryptoRng + ?Sized, P: PaddingScheme>(
        &self,
        rng: &mut R,
        padding: P,
        msg: &[u8],
    ) -> Result<Vec<u8>> {
        padding.encrypt(rng, self, msg)
    }

    /// Verify a signed message.
    ///
    /// `hashed` must be the result of hashing the input using the hashing function
    /// passed in through `hash`.
    ///
    /// If the message is valid `Ok(())` is returned, otherwise an `Err` indicating failure.
    pub fn verify<S: SignatureScheme>(&self, scheme: S, hashed: &[u8], sig: &[u8]) -> Result<()> {
        scheme.verify(self, hashed, sig)
    }
}

impl RsaPublicKey {
    /// Minimum value of the public exponent `e`.
    pub const MIN_PUB_EXPONENT: u64 = 2;

    /// Maximum value of the public exponent `e`.
    pub const MAX_PUB_EXPONENT: u64 = (1 << 33) - 1;

    /// Maximum size of the modulus `n` in bits.
    pub const MAX_SIZE: usize = 4096;

    /// Create a new public key from its components.
    ///
    /// This function accepts public keys with a modulus size up to 4096-bits,
    /// i.e. [`RsaPublicKey::MAX_SIZE`].
    pub fn new(n: BoxedUint, e: BoxedUint) -> Result<Self> {
        Self::new_with_max_size(n, e, Self::MAX_SIZE)
    }

    /// Create a new public key from its components.
    pub fn new_with_max_size(n: BoxedUint, e: BoxedUint, max_size: usize) -> Result<Self> {
        check_public_with_max_size(&n, &e, max_size)?;

        let n_odd = Odd::new(n.clone())
            .into_option()
            .ok_or(Error::InvalidModulus)?;
        let n_params = BoxedMontyParams::new(n_odd);
        let n = NonZero::new(n).expect("checked above");

        Ok(Self { n, e, n_params })
    }

    /// Create a new public key, bypassing checks around the modulus and public
    /// exponent size.
    ///
    /// This method is not recommended, and only intended for unusual use cases.
    /// Most applications should use [`RsaPublicKey::new`] or
    /// [`RsaPublicKey::new_with_max_size`] instead.
    pub fn new_unchecked(n: BoxedUint, e: BoxedUint) -> Self {
        let n_odd = Odd::new(n.clone()).expect("n must be odd");
        let n_params = BoxedMontyParams::new(n_odd);
        let n = NonZero::new(n).expect("odd numbers are non zero");

        Self { n, e, n_params }
    }
}

impl PublicKeyParts for RsaPrivateKey {
    fn n(&self) -> &NonZero<BoxedUint> {
        &self.pubkey_components.n
    }

    fn e(&self) -> &BoxedUint {
        &self.pubkey_components.e
    }

    fn n_params(&self) -> &BoxedMontyParams {
        &self.pubkey_components.n_params
    }
}

impl RsaPrivateKey {
    /// Default exponent for RSA keys.
    const EXP: u64 = 65537;

    /// Minimum size of the modulus `n` in bits. Currently only applies to keygen.
    const MIN_SIZE: u32 = 1024;

    /// Generate a new RSA key pair with a modulus of the given bit size using the passed in `rng`.
    ///
    /// # Errors
    /// - If `bit_size` is lower than the minimum 1024-bits.
    pub fn new<R: CryptoRng + ?Sized>(rng: &mut R, bit_size: usize) -> Result<Self> {
        Self::new_with_exp(rng, bit_size, Self::EXP.into())
    }

    /// Generate a new RSA key pair of the given bit size.
    ///
    /// #⚠️Warning: Hazmat!
    /// This version does not apply minimum key size checks, and as such may generate keys
    /// which are insecure!
    #[cfg(feature = "hazmat")]
    pub fn new_unchecked<R: CryptoRng + ?Sized>(rng: &mut R, bit_size: usize) -> Result<Self> {
        Self::new_with_exp_unchecked(rng, bit_size, Self::EXP.into())
    }

    /// Generate a new RSA key pair of the given bit size and the public exponent
    /// using the passed in `rng`.
    ///
    /// Unless you have specific needs, you should use [`RsaPrivateKey::new`] instead.
    pub fn new_with_exp<R: CryptoRng + ?Sized>(
        rng: &mut R,
        bit_size: usize,
        exp: BoxedUint,
    ) -> Result<RsaPrivateKey> {
        if bit_size < Self::MIN_SIZE as usize {
            return Err(Error::ModulusTooSmall);
        }

        let components = generate_multi_prime_key_with_exp(rng, 2, bit_size, exp)?;
        RsaPrivateKey::from_components(
            components.n.get(),
            components.e,
            components.d,
            components.primes,
        )
    }

    /// Generate a new RSA key pair of the given bit size and the public exponent
    /// using the passed in `rng`.
    ///
    /// Unless you have specific needs, you should use [`RsaPrivateKey::new`] instead.
    ///
    /// #⚠️Warning: Hazmat!
    /// This version does not apply minimum key size checks, and as such may generate keys
    /// which are insecure!
    #[cfg(feature = "hazmat")]
    pub fn new_with_exp_unchecked<R: CryptoRng + ?Sized>(
        rng: &mut R,
        bit_size: usize,
        exp: BoxedUint,
    ) -> Result<RsaPrivateKey> {
        let components = generate_multi_prime_key_with_exp(rng, 2, bit_size, exp)?;
        RsaPrivateKey::from_components(
            components.n.get(),
            components.e,
            components.d,
            components.primes,
        )
    }

    /// Constructs an RSA key pair from individual components:
    ///
    /// - `n`: RSA modulus
    /// - `e`: public exponent (i.e. encrypting exponent)
    /// - `d`: private exponent (i.e. decrypting exponent)
    /// - `primes`: prime factors of `n`: typically two primes `p` and `q`. More than two primes can
    ///   be provided for multiprime RSA, however this is generally not recommended. If no `primes`
    ///   are provided, a prime factor recovery algorithm will be employed to attempt to recover the
    ///   factors (as described in [NIST SP 800-56B Revision 2] Appendix C.2). This algorithm only
    ///   works if there are just two prime factors `p` and `q` (as opposed to multiprime), and `e`
    ///   is between 2^16 and 2^256.
    ///
    ///  [NIST SP 800-56B Revision 2]: https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-56Br2.pdf
    pub fn from_components(
        n: BoxedUint,
        e: BoxedUint,
        d: BoxedUint,
        mut primes: Vec<BoxedUint>,
    ) -> Result<RsaPrivateKey> {
        let n = Odd::new(n).into_option().ok_or(Error::InvalidModulus)?;

        // The modulus may come in padded with zeros, shorten it
        // to ensure optimal performance of arithmetic operations.
        let n_bits = n.bits_vartime();
        let n = n.resize_unchecked(n_bits);

        let n_params = BoxedMontyParams::new(n.clone());
        let n_c = NonZero::new(n.get())
            .into_option()
            .ok_or(Error::InvalidModulus)?;

        match primes.len() {
            0 => {
                // Recover `p` and `q` from `d`.
                // See method in Appendix C.2: https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-56Br2.pdf
                let (p, q) = recover_primes(&n_c, &e, &d)?;
                primes.push(p);
                primes.push(q);
            }
            1 => return Err(Error::NprimesTooSmall),
            _ => {
                // Check that the product of primes matches the modulus.
                // This also ensures that `bit_precision` of each prime is <= that of the modulus,
                // and `bit_precision` of their product is >= that of the modulus.
                if &primes.iter().fold(BoxedUint::one(), |acc, p| acc * p) != n_c.as_ref() {
                    return Err(Error::InvalidModulus);
                }
            }
        }

        // The primes may come in padded with zeros too, so we need to shorten them as well.
        let primes = primes
            .into_iter()
            .map(|p| {
                let p_bits = p.bits();
                p.resize_unchecked(p_bits)
            })
            .collect();

        let mut k = RsaPrivateKey {
            pubkey_components: RsaPublicKey {
                n: n_c,
                e,
                n_params,
            },
            d,
            primes,
            precomputed: None,
        };

        // Always validate the key, to ensure precompute can't fail
        k.validate()?;

        // Precompute when possible, ignore error otherwise.
        k.precompute().ok();

        Ok(k)
    }

    /// Constructs an RSA key pair from its two primes p and q.
    ///
    /// This will rebuild the private exponent and the modulus.
    ///
    /// Private exponent will be rebuilt using the method defined in
    /// [NIST 800-56B Section 6.2.1](https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-56Br2.pdf#page=47).
    pub fn from_p_q(
        p: BoxedUint,
        q: BoxedUint,
        public_exponent: BoxedUint,
    ) -> Result<RsaPrivateKey> {
        if p == q {
            return Err(Error::InvalidPrime);
        }

        let d = compute_private_exponent_carmicheal(&p, &q, &public_exponent)?;
        let primes = vec![p, q];
        let n = compute_modulus(&primes);

        Self::from_components(n.get(), public_exponent, d, primes)
    }

    /// Constructs an RSA key pair from its primes.
    ///
    /// This will rebuild the private exponent and the modulus.
    pub fn from_primes(
        primes: Vec<BoxedUint>,
        public_exponent: BoxedUint,
    ) -> Result<RsaPrivateKey> {
        if primes.len() < 2 {
            return Err(Error::NprimesTooSmall);
        }

        // Makes sure that the primes are pairwise unequal.
        for (i, prime1) in primes.iter().enumerate() {
            for prime2 in primes.iter().take(i) {
                if prime1 == prime2 {
                    return Err(Error::InvalidPrime);
                }
            }
        }

        let n = compute_modulus(&primes);
        let d = compute_private_exponent_euler_totient(&primes, &public_exponent)?;

        Self::from_components(n.get(), public_exponent, d, primes)
    }

    /// Get the public key from the private key, cloning `n` and `e`.
    ///
    /// Generally this is not needed since `RsaPrivateKey` implements the `PublicKey` trait,
    /// but it can occasionally be useful to discard the private information entirely.
    pub fn to_public_key(&self) -> RsaPublicKey {
        self.pubkey_components.clone()
    }

    /// Performs some calculations to speed up private key operations.
    pub fn precompute(&mut self) -> Result<()> {
        if self.precomputed.is_some() {
            return Ok(());
        }

        let d = &self.d;
        let p = self.primes[0].clone();
        let q = self.primes[1].clone();

        let p_odd = Odd::new(p.clone())
            .into_option()
            .ok_or(Error::InvalidPrime)?;
        let p_params = BoxedMontyParams::new(p_odd);
        let q_odd = Odd::new(q.clone())
            .into_option()
            .ok_or(Error::InvalidPrime)?;
        let q_params = BoxedMontyParams::new(q_odd);

        let x = NonZero::new(p.wrapping_sub(&BoxedUint::one()))
            .into_option()
            .ok_or(Error::InvalidPrime)?;
        let dp = d.rem_vartime(&x);

        let x = NonZero::new(q.wrapping_sub(&BoxedUint::one()))
            .into_option()
            .ok_or(Error::InvalidPrime)?;
        let dq = d.rem_vartime(&x);

        // Note that since `p` and `q` may have different `bits_precision`,
        // so we have to equalize them to calculate the remainder.
        let q_mod_p = match p.bits_precision().cmp(&q.bits_precision()) {
            Ordering::Less => (&q
                % NonZero::new(p.clone())
                    .expect("`p` is non-zero")
                    .resize_unchecked(q.bits_precision()))
            .resize_unchecked(p.bits_precision()),
            Ordering::Greater => {
                (&q).resize_unchecked(p.bits_precision())
                    % &NonZero::new(p.clone()).expect("`p` is non-zero")
            }
            Ordering::Equal => &q % NonZero::new(p.clone()).expect("`p` is non-zero"),
        };

        let q_mod_p = BoxedMontyForm::new(q_mod_p, p_params.clone());
        let qinv = q_mod_p.invert().into_option().ok_or(Error::InvalidPrime)?;

        debug_assert_eq!(dp.bits_precision(), p.bits_precision());
        debug_assert_eq!(dq.bits_precision(), q.bits_precision());
        debug_assert_eq!(qinv.bits_precision(), p.bits_precision());
        debug_assert_eq!(p_params.bits_precision(), p.bits_precision());
        debug_assert_eq!(q_params.bits_precision(), q.bits_precision());

        self.precomputed = Some(PrecomputedValues {
            dp,
            dq,
            qinv,
            p_params,
            q_params,
        });

        Ok(())
    }

    /// Clears precomputed values by setting to None
    pub fn clear_precomputed(&mut self) {
        self.precomputed = None;
    }

    /// Compute CRT coefficient: `(1/q) mod p`.
    pub fn crt_coefficient(&self) -> Option<BoxedUint> {
        let p = &self.primes[0];
        let q = &self.primes[1];
        // TODO: maybe store primes as `NonZero`?
        Option::from(q.invert_mod(&NonZero::new(p.clone()).expect("prime")))
    }

    /// Performs basic sanity checks on the key.
    /// Returns `Ok(())` if everything is good, otherwise an appropriate error.
    pub fn validate(&self) -> Result<()> {
        check_public(self)?;

        // Check that Πprimes == n.
        let mut m = BoxedUint::one_with_precision(self.pubkey_components.n.bits_precision());
        let one = BoxedUint::one();
        for prime in &self.primes {
            // Any primes ≤ 1 will cause divide-by-zero panics later.
            if prime < &one {
                return Err(Error::InvalidPrime);
            }
            m = m.wrapping_mul(prime);
        }
        if m != *self.pubkey_components.n {
            return Err(Error::InvalidModulus);
        }

        // Check that de ≡ 1 mod p-1, for each prime.
        // This implies that e is coprime to each p-1 as e has a multiplicative
        // inverse. Therefore e is coprime to lcm(p-1,q-1,r-1,...) =
        // exponent(ℤ/nℤ). It also implies that a^de ≡ a mod p as a^(p-1) ≡ 1
        // mod p. Thus a^de ≡ a mod n for all a coprime to n, as required.
        let de = self.d.mul(&self.pubkey_components.e);

        for prime in &self.primes {
            let x = NonZero::new(prime.wrapping_sub(&BoxedUint::one())).unwrap();
            let congruence = de.rem_vartime(&x);
            if !bool::from(congruence.is_one()) {
                return Err(Error::InvalidExponent);
            }
        }

        Ok(())
    }

    /// Decrypt the given message.
    pub fn decrypt<P: PaddingScheme>(&self, padding: P, ciphertext: &[u8]) -> Result<Vec<u8>> {
        padding.decrypt(Option::<&mut DummyRng>::None, self, ciphertext)
    }

    /// Decrypt the given message.
    ///
    /// Uses `rng` to blind the decryption process.
    pub fn decrypt_blinded<R: CryptoRng + ?Sized, P: PaddingScheme>(
        &self,
        rng: &mut R,
        padding: P,
        ciphertext: &[u8],
    ) -> Result<Vec<u8>> {
        padding.decrypt(Some(rng), self, ciphertext)
    }

    /// Sign the given digest.
    pub fn sign<S: SignatureScheme>(&self, padding: S, digest_in: &[u8]) -> Result<Vec<u8>> {
        padding.sign(Option::<&mut DummyRng>::None, self, digest_in)
    }

    /// Sign the given digest using the provided `rng`, which is used in the
    /// following ways depending on the [`SignatureScheme`]:
    ///
    /// - [`Pkcs1v15Sign`][`crate::Pkcs1v15Sign`] padding: uses the RNG
    ///   to mask the private key operation with random blinding, which helps
    ///   mitigate sidechannel attacks.
    /// - [`Pss`][`crate::Pss`] always requires randomness. Use
    ///   [`Pss::new`][`crate::Pss::new`] for a standard RSASSA-PSS signature, or
    ///   [`Pss::new_blinded`][`crate::Pss::new_blinded`] for RSA-BSSA blind
    ///   signatures.
    pub fn sign_with_rng<R: CryptoRng + ?Sized, S: SignatureScheme>(
        &self,
        rng: &mut R,
        padding: S,
        digest_in: &[u8],
    ) -> Result<Vec<u8>> {
        padding.sign(Some(rng), self, digest_in)
    }
}

impl PrivateKeyParts for RsaPrivateKey {
    fn d(&self) -> &BoxedUint {
        &self.d
    }

    fn primes(&self) -> &[BoxedUint] {
        &self.primes
    }

    fn dp(&self) -> Option<&BoxedUint> {
        self.precomputed.as_ref().map(|p| &p.dp)
    }

    fn dq(&self) -> Option<&BoxedUint> {
        self.precomputed.as_ref().map(|p| &p.dq)
    }

    fn qinv(&self) -> Option<&BoxedMontyForm> {
        self.precomputed.as_ref().map(|p| &p.qinv)
    }

    fn crt_values(&self) -> Option<&[CrtValue]> {
        None
    }

    fn p_params(&self) -> Option<&BoxedMontyParams> {
        self.precomputed.as_ref().map(|p| &p.p_params)
    }

    fn q_params(&self) -> Option<&BoxedMontyParams> {
        self.precomputed.as_ref().map(|p| &p.q_params)
    }
}

/// Check that the public key is well formed and has an exponent within acceptable bounds.
#[inline]
pub fn check_public(public_key: &impl PublicKeyParts) -> Result<()> {
    check_public_with_max_size(public_key.n(), public_key.e(), RsaPublicKey::MAX_SIZE)
}

/// Check that the public key is well formed and has an exponent within acceptable bounds.
#[inline]
fn check_public_with_max_size(n: &BoxedUint, e: &BoxedUint, max_size: usize) -> Result<()> {
    if n.bits_vartime() as usize > max_size {
        return Err(Error::ModulusTooLarge);
    }

    if e >= n || n.is_even().into() || n.is_zero().into() {
        return Err(Error::InvalidModulus);
    }

    if e.is_even().into() {
        return Err(Error::InvalidExponent);
    }

    if e < &BoxedUint::from(RsaPublicKey::MIN_PUB_EXPONENT) {
        return Err(Error::PublicExponentTooSmall);
    }

    if e > &BoxedUint::from(RsaPublicKey::MAX_PUB_EXPONENT) {
        return Err(Error::PublicExponentTooLarge);
    }

    Ok(())
}

#[cfg(feature = "serde")]
impl Serialize for RsaPublicKey {
    fn serialize<S>(&self, serializer: S) -> core::prelude::v1::Result<S::Ok, S::Error>
    where
        S: serdect::serde::Serializer,
    {
        let der = self.to_public_key_der().map_err(ser::Error::custom)?;
        serdect::slice::serialize_hex_lower_or_bin(&der, serializer)
    }
}

#[cfg(feature = "serde")]
impl<'de> Deserialize<'de> for RsaPublicKey {
    fn deserialize<D>(deserializer: D) -> core::prelude::v1::Result<Self, D::Error>
    where
        D: serdect::serde::Deserializer<'de>,
    {
        let der_bytes = serdect::slice::deserialize_hex_or_bin_vec(deserializer)?;
        Self::from_public_key_der(&der_bytes).map_err(de::Error::custom)
    }
}

#[cfg(feature = "serde")]
impl Serialize for RsaPrivateKey {
    fn serialize<S>(&self, serializer: S) -> core::prelude::v1::Result<S::Ok, S::Error>
    where
        S: ser::Serializer,
    {
        let der = self.to_pkcs8_der().map_err(ser::Error::custom)?;
        serdect::slice::serialize_hex_lower_or_bin(&der.as_bytes(), serializer)
    }
}

#[cfg(feature = "serde")]
impl<'de> Deserialize<'de> for RsaPrivateKey {
    fn deserialize<D>(deserializer: D) -> core::prelude::v1::Result<Self, D::Error>
    where
        D: de::Deserializer<'de>,
    {
        let der_bytes = serdect::slice::deserialize_hex_or_bin_vec(deserializer)?;
        Self::from_pkcs8_der(&der_bytes).map_err(de::Error::custom)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::algorithms::rsa::{rsa_decrypt_and_check, rsa_encrypt};
    use crate::traits::{PrivateKeyParts, PublicKeyParts};

    use hex_literal::hex;
    use rand_chacha::{rand_core::SeedableRng, ChaCha8Rng};

    #[cfg(feature = "encoding")]
    use pkcs8::DecodePrivateKey;

    #[test]
    fn test_from_into() {
        let raw_n = BoxedUint::from(101u64);
        let n_odd = Odd::new(raw_n.clone()).unwrap();
        let private_key = RsaPrivateKey {
            pubkey_components: RsaPublicKey {
                n: NonZero::new(raw_n.clone()).unwrap(),
                e: BoxedUint::from(200u64),
                n_params: BoxedMontyParams::new(n_odd),
            },
            d: BoxedUint::from(123u64),
            primes: vec![],
            precomputed: None,
        };
        let public_key: RsaPublicKey = private_key.into();

        let n_limbs: &[u64] = PublicKeyParts::n(&public_key).as_ref().as_ref();
        assert_eq!(n_limbs, &[101u64]);
        assert_eq!(PublicKeyParts::e(&public_key), &BoxedUint::from(200u64));
        assert_eq!(PublicKeyParts::e_bytes(&public_key), [200].into());
        assert_eq!(PublicKeyParts::n_bytes(&public_key), [101].into());
    }

    fn test_key_basics(private_key: &RsaPrivateKey) {
        private_key.validate().expect("invalid private key");

        assert!(
            PrivateKeyParts::d(private_key) < PublicKeyParts::n(private_key).as_ref(),
            "private exponent too large"
        );

        let pub_key: RsaPublicKey = private_key.clone().into();
        let m = BoxedUint::from(42u64);
        let c = rsa_encrypt(&pub_key, &m).expect("encryption successful");

        let m2 = rsa_decrypt_and_check::<ChaCha8Rng>(private_key, None, &c)
            .expect("unable to decrypt without blinding");
        assert_eq!(m, m2);
        let mut rng = ChaCha8Rng::from_seed([42; 32]);
        let m3 = rsa_decrypt_and_check(private_key, Some(&mut rng), &c)
            .expect("unable to decrypt with blinding");
        assert_eq!(m, m3);
    }

    macro_rules! key_generation {
        ($name:ident, $multi:expr, $size:expr) => {
            #[test]
            fn $name() {
                let mut rng = ChaCha8Rng::from_seed([42; 32]);
                let exp = BoxedUint::from(RsaPrivateKey::EXP);

                for _ in 0..10 {
                    let components =
                        generate_multi_prime_key_with_exp(&mut rng, $multi, $size, exp.clone())
                            .unwrap();
                    let private_key = RsaPrivateKey::from_components(
                        components.n.get(),
                        components.e,
                        components.d,
                        components.primes,
                    )
                    .unwrap();
                    assert_eq!(PublicKeyParts::n(&private_key).bits(), $size);

                    test_key_basics(&private_key);
                }
            }
        };
    }

    key_generation!(key_generation_128, 2, 128);
    key_generation!(key_generation_1024, 2, 1024);

    key_generation!(key_generation_multi_3_256, 3, 256);

    key_generation!(key_generation_multi_4_64, 4, 64);

    key_generation!(key_generation_multi_5_64, 5, 64);
    key_generation!(key_generation_multi_8_576, 8, 576);
    key_generation!(key_generation_multi_16_1024, 16, 1024);

    #[test]
    fn test_negative_decryption_value() {
        let bits = 128;
        let private_key = RsaPrivateKey::from_components(
            BoxedUint::from_le_slice(
                &[
                    99, 192, 208, 179, 0, 220, 7, 29, 49, 151, 75, 107, 75, 73, 200, 180,
                ],
                bits,
            )
            .unwrap(),
            BoxedUint::from_le_slice(&[1, 0, 1, 0, 0, 0, 0, 0], 64).unwrap(),
            BoxedUint::from_le_slice(
                &[
                    81, 163, 254, 144, 171, 159, 144, 42, 244, 133, 51, 249, 28, 12, 63, 65,
                ],
                bits,
            )
            .unwrap(),
            vec![
                BoxedUint::from_le_slice(&[105, 101, 60, 173, 19, 153, 3, 192], bits / 2).unwrap(),
                BoxedUint::from_le_slice(&[235, 65, 160, 134, 32, 136, 6, 241], bits / 2).unwrap(),
            ],
        )
        .unwrap();

        for _ in 0..1000 {
            test_key_basics(&private_key);
        }
    }

    #[test]
    #[cfg(all(feature = "hazmat", feature = "serde"))]
    fn test_serde() {
        use rand_chacha::{rand_core::SeedableRng, ChaCha8Rng};
        use serde_test::{assert_tokens, Configure, Token};

        let mut rng = ChaCha8Rng::from_seed([42; 32]);
        let priv_key = RsaPrivateKey::new_unchecked(&mut rng, 64).expect("failed to generate key");

        let priv_tokens = [Token::Str(concat!(
            "3056020100300d06092a864886f70d010101050004423040020100020900a",
            "b240c3361d02e370203010001020811e54a15259d22f9020500ceff5cf302",
            "0500d3a7aaad020500ccaddf17020500cb529d3d020500bb526d6f"
        ))];
        assert_tokens(&priv_key.clone().readable(), &priv_tokens);

        let priv_tokens = [Token::Str(
            "3024300d06092a864886f70d01010105000313003010020900ab240c3361d02e370203010001",
        )];
        assert_tokens(
            &RsaPublicKey::from(priv_key.clone()).readable(),
            &priv_tokens,
        );
    }

    #[test]
    fn invalid_coeff_private_key_regression() {
        use base64ct::{Base64, Encoding};

        let n = Base64::decode_vec(
            "wC8GyQvTCZOK+iiBR5fGQCmzRCTWX9TQ3aRG5gGFk0wB6EFoLMAyEEqeG3gS8xhA\
             m2rSWYx9kKufvNat3iWlbSRVqkcbpVAYlj2vTrpqDpJl+6u+zxFYoUEBevlJJkAh\
             l8EuCccOA30fVpcfRvXPTtvRd3yFT9E9EwZljtgSI02w7gZwg7VIxaGeajh5Euz6\
             ZVQZ+qNRKgXrRC7gPRqVyI6Dt0Jc+Su5KBGNn0QcPDzOahWha1ieaeMkFisZ9mdp\
             sJoZ4tw5eicLaUomKzALHXQVt+/rcZSrCd6/7uUo11B/CYBM4UfSpwXaL88J9AE6\
             A5++no9hmJzaF2LLp+Qwx4yY3j9TDutxSAjsraxxJOGZ3XyA9nG++Ybt3cxZ5fP7\
             ROjxCfROBmVv5dYn0O9OBIqYeCH6QraNpZMadlLNIhyMv8Y+P3r5l/PaK4VJaEi5\
             pPosnEPawp0W0yZDzmjk2z1LthaRx0aZVrAjlH0Rb/6goLUQ9qu1xsDtQVVpN4A8\
             9ZUmtTWORnnJr0+595eHHxssd2gpzqf4bPjNITdAEuOCCtpvyi4ls23zwuzryUYj\
             cUOEnsXNQ+DrZpLKxdtsD/qNV/j1hfeyBoPllC3cV+6bcGOFcVGbjYqb+Kw1b0+j\
             L69RSKQqgmS+qYqr8c48nDRxyq3QXhR8qtzUwBFSLVk=",
        )
        .unwrap();
        let e = Base64::decode_vec("AQAB").unwrap();
        let d = Base64::decode_vec(
            "qQazSQ+FRN7nVK1bRsROMRB8AmsDwLVEHivlz1V3Td2Dr+oW3YUMgxedhztML1Id\
             QJPq/ad6qErJ6yRFNySVIjDaxzBTOEoB1eHa1btOnBJWb8rVvvjaorixvJ6Tn3i4\
             EuhsvVy9DoR1k4rGj3qSIiFjUVvLRDAbLyhpGgEfsr0Z577yJmTC5E8JLRMOKX8T\
             mxsk3jPVpsgd65Hu1s8S/ZmabwuHCf9SkdMeY/1bd/9i7BqqJeeDLE4B5x1xcC3z\
             3scqDUTzqGO+vZPhjgprPDRlBamVwgenhr7KwCn8iaLamFinRVwOAag8BeBqOJj7\
             lURiOsKQa9FIX1kdFUS1QMQxgtPycLjkbvCJjriqT7zWKsmJ7l8YLs6Wmm9/+QJR\
             wNCEVdMTXKfCP1cJjudaiskEQThfUldtgu8gUDNYbQ/Filb2eKfiX4h1TiMxZqUZ\
             HVZyb9nShbQoXJ3vj/MGVF0QM8TxhXM8r2Lv9gDYU5t9nQlUMLhs0jVjai48jHAB\
             bFNyH3sEcOmJOIwJrCXw1dzG7AotwyaEVUHOmL04TffmwCFfnyrLjbFgnyOeoyII\
             BYjcY7QFRm/9nupXMTH5hZ2qrHfCJIp0KK4tNBdQqmnHapFl5l6Le1s4qBS5bEIz\
             jitobLvAFm9abPlDGfxmY6mlrMK4+nytwF9Ct7wc1AE=",
        )
        .unwrap();
        let primes = [
            Base64::decode_vec(
                "9kQWEAzsbzOcdPa+s5wFfw4XDd7bB1q9foZ31b1+TNjGNxbSBCFlDF1q98vwpV6n\
                 M8bWDh/wtbNoETSQDgpEnYOQ26LWEw6YY1+q1Q2GGEFceYUf+Myk8/vTc8TN6Zw0\
                 bKZBWy10Qo8h7xk4JpzuI7NcxvjJYTkS9aErFxi3vVH0aiZC0tmfaCqr8a2rJxyV\
                 wqreRpOjwAWrotMsf2wGsF4ofx5ScoFy5GB5fJkkdOrW1LyTvZAUCX3cstPr19+T\
                 NC5zZOk7WzZatnCkN5H5WzalWtZuu0oVL205KPOa3R8V2yv5e6fm0v5fTmqSuvjm\
                 aMJLXCN4QJkmIzojO99ckQ==",
            )
            .unwrap(),
            Base64::decode_vec(
                "x8exdMjVA2CiI+Thx7loHtVcevoeE2sZ7btRVAvmBqo+lkHwxb7FHRnWvuj6eJSl\
                 D2f0T50EewIhhiW3R9BmktCk7hXjbSCnC1u9Oxc1IAUm/7azRqyfCMx43XhLxpD+\
                 xkBCpWkKDLxGczsRwTuaP3lKS3bSdBrNlGmdblubvVBIq4YZ2vXVlnYtza0cS+dg\
                 CK7BGTqUsrCUd/ZbIvwcwZkZtpkhj1KQfto9X/0OMurBzAqbkeq1cyRHXHkOfN/q\
                 bUIIRqr9Ii7Eswf9Vk8xp2O1Nt8nzcYS9PFD12M5eyaeFEkEYfpNMNGuTzp/31oq\
                 VjbpoCxS6vuWAZyADxhISQ==",
            )
            .unwrap(),
            Base64::decode_vec(
                "is7d0LY4HoXszlC2NO7gejkq7XqL4p1W6hZJPYTNx+r37t1CC2n3Vvzg6kNdpRix\
                 DhIpXVTLjN9O7UO/XuqSumYKJIKoP52eb4Tg+a3hw5Iz2Zsb5lUTNSLgkQSBPAf7\
                 1LHxbL82JL4g1nBUog8ae60BwnVArThKY4EwlJguGNw09BAU4lwf6csDl/nX2vfV\
                 wiAloYpeZkHL+L8m+bueGZM5KE2jEz+7ztZCI+T+E5i69rZEYDjx0lfLKlEhQlCW\
                 3HbCPELqXgNJJkRfi6MP9kXa9lSfnZmoT081RMvqonB/FUa4HOcKyCrw9XZEtnbN\
                 CIdbitfDVEX+pSSD7596wQ==",
            )
            .unwrap(),
            Base64::decode_vec(
                "GPs0injugfycacaeIP5jMa/WX55VEnKLDHom4k6WlfDF4L4gIGoJdekcPEUfxOI5\
                 faKvHyFwRP1wObkPoRBDM0qZxRfBl4zEtpvjHrd5MibSyJkM8+J0BIKk/nSjbRIG\
                 eb3hV5O56PvGB3S0dKhCUnuVObiC+ne7izplsD4OTG70l1Yud33UFntyoMxrxGYL\
                 USqhBMmZfHquJg4NOWOzKNY/K+EcHDLj1Kjvkcgv9Vf7ocsVxvpFdD9uGPceQ6kw\
                 RDdEl6mb+6FDgWuXVyqR9+904oanEIkbJ7vfkthagLbEf57dyG6nJlqh5FBZWxGI\
                 R72YGypPuAh7qnnqXXjY2Q==",
            )
            .unwrap(),
            Base64::decode_vec(
                "CUWC+hRWOT421kwRllgVjy6FYv6jQUcgDNHeAiYZnf5HjS9iK2ki7v8G5dL/0f+Y\
                 f+NhE/4q8w4m8go51hACrVpP1p8GJDjiT09+RsOzITsHwl+ceEKoe56ZW6iDHBLl\
                 rNw5/MtcYhKpjNU9KJ2udm5J/c9iislcjgckrZG2IB8ADgXHMEByZ5DgaMl4AKZ1\
                 Gx8/q6KftTvmOT5rNTMLi76VN5KWQcDWK/DqXiOiZHM7Nr4dX4me3XeRgABJyNR8\
                 Fqxj3N1+HrYLe/zs7LOaK0++F9Ul3tLelhrhsvLxei3oCZkF9A/foD3on3luYA+1\
                 cRcxWpSY3h2J4/22+yo4+Q==",
            )
            .unwrap(),
        ];

        let e = BoxedUint::from_be_slice(&e, 64).unwrap();

        let bits = 4096;
        let n = BoxedUint::from_be_slice(&n, bits).unwrap();
        let d = BoxedUint::from_be_slice(&d, bits).unwrap();
        let primes = primes
            .iter()
            .map(|p| BoxedUint::from_be_slice(p, bits / 2).unwrap())
            .collect();
        let res = RsaPrivateKey::from_components(n, e, d, primes);
        assert_eq!(res, Err(Error::InvalidModulus));
    }

    #[test]
    fn reject_oversized_private_key() {
        // -----BEGIN PUBLIC KEY-----
        // MIIEIjANBgkqhkiG9w0BAQEFAAOCBA8AMIIECgKCBAEAkMBiB8qsNVXAsJR6Xoto
        // H1r2rtZl/xzUK2tIfy99aPE489u+5tLxCQhQf+a89158vSDpr2/xwgK8w9u0Xpu2
        // m7XRKjVMS0Y6UIINFoeTc87rVXT92Scr47kNVcGmSFXez4BSDpS+LKpWwXN+0AQu
        // +cmcfdtsx2862iEbqQvq4PwKGQJOdOR0yldH8O4yeJK/buvIOXRHjb++vtQND/xi
        // bFGAcd9WJqvaOG7tclhbZ277mbO6ER+y9Lj7AyO8ywybWqNeHaVPHMysPhT7HUWI
        // 17m59i1OpuVwwEnvzDQQEUf9d5hUmkLYb5qQzuf6Ddnx/04QJCKAgkhyr9CXgnV6
        // vEZ3PKtpicCHRxk7eqTEmgBlgwqH5vflRFV1iywQMXJnuRhzWOQaXl/vb8v4HIvF
        // 4TatEZKqfzpbyScLIiYbPEAhHXKdZMd2zY8hkSbicifePApAZmuNpAxxJDZzphh7
        // r4lD6t8MPT/RUAdtrZfihqaBhduFI6YeVIy6emg05M6YWvlUyer7nYGaPRS1JqD4
        // 0v7xOtme5I8Qw6APiFPXhTqBK3occr7TgGb3V3lpC8Eq+esNHrji98R1fITkFXJW
        // KdFcTWjBghPxiobUzMCFUrPIDJcWXeBzrARAryU+hXjEiFfzluXrps0B7RJQ/rLD
        // LXeTn4vovUeHQVHa7YfoyWMy9pfqeVC+56LBK7SEIAvL0I3lrq5vIv+ZIuOAdbVg
        // JiRy8DneCOk2LP3RnA8M0HSevYW93DiC+4h/l4ntjjiOfi6yRVOZ8WbVyXZ/83j4
        // 6+pGWgvi0uMyb+btgOXjBQv7bGqdyHMc5Lqk5bF7ExETx51vKQMYCV4351caS6aX
        // q16lYZATHgbTADEAZHdroDMJB+HMQaze9O6qU5ZO8wxxAjw89xry0dnoOQD/yA4H
        // 7CRCo9vVDpV2hqIvHY9RI2T7cek28kmQpKvNvvK+ovmM138dHKViWULHk0fBRt7m
        // 4wQ+tiL2PmJ/Tr8g1gVhM6S9D1XdE9z0KeDnODCWn1Q8sx2G2ah4ynnYQURDWcwO
        // McAoP6bdJ7cCt+4F2tEsMPf4S/EwlnjvuNoQjvztxCPahYe9EnyggtQXyHJveIn7
        // gDJsP6b93VB6x4QbLy5ch4DUhqDWginuKVeo7CTgDkq03j/IEaS1BHwreSDQceny
        // +bYWONwV+4TMpGytKOHvU5288kmHbyZHdXuaXk8LLqbnqr30fa6Cbp4llCi9sH5a
        // Kmi5jxQfVTe+elkMs7oVsLsVgkZS6NqPcOuEckAFijNqG223+IJoqvifCzO5Bdcs
        // JTOLE+YaUYc8LUJwIaPykgcXmtMvQjeT8MCQ3aAlzkHfDpSvvICrXtqbGiaKolU6
        // mQIDAQAB
        // -----END PUBLIC KEY-----

        let n = BoxedUint::from_be_slice(
            &hex!(
                "
            90c06207caac3555c0b0947a5e8b681f5af6aed665ff1cd42b6b487f2f7d68f1
            38f3dbbee6d2f10908507fe6bcf75e7cbd20e9af6ff1c202bcc3dbb45e9bb69b
            b5d12a354c4b463a50820d16879373ceeb5574fdd9272be3b90d55c1a64855de
            cf80520e94be2caa56c1737ed0042ef9c99c7ddb6cc76f3ada211ba90beae0fc
            0a19024e74e474ca5747f0ee327892bf6eebc83974478dbfbebed40d0ffc626c
            518071df5626abda386eed72585b676efb99b3ba111fb2f4b8fb0323bccb0c9b
            5aa35e1da54f1cccac3e14fb1d4588d7b9b9f62d4ea6e570c049efcc34101147
            fd7798549a42d86f9a90cee7fa0dd9f1ff4e10242280824872afd09782757abc
            46773cab6989c08747193b7aa4c49a0065830a87e6f7e54455758b2c10317267
            b9187358e41a5e5fef6fcbf81c8bc5e136ad1192aa7f3a5bc9270b22261b3c40
            211d729d64c776cd8f219126e27227de3c0a40666b8da40c71243673a6187baf
            8943eadf0c3d3fd150076dad97e286a68185db8523a61e548cba7a6834e4ce98
            5af954c9eafb9d819a3d14b526a0f8d2fef13ad99ee48f10c3a00f8853d7853a
            812b7a1c72bed38066f75779690bc12af9eb0d1eb8e2f7c4757c84e415725629
            d15c4d68c18213f18a86d4ccc08552b3c80c97165de073ac0440af253e8578c4
            8857f396e5eba6cd01ed1250feb2c32d77939f8be8bd47874151daed87e8c963
            32f697ea7950bee7a2c12bb484200bcbd08de5aeae6f22ff9922e38075b56026
            2472f039de08e9362cfdd19c0f0cd0749ebd85bddc3882fb887f9789ed8e388e
            7e2eb2455399f166d5c9767ff378f8ebea465a0be2d2e3326fe6ed80e5e3050b
            fb6c6a9dc8731ce4baa4e5b17b131113c79d6f290318095e37e7571a4ba697ab
            5ea56190131e06d300310064776ba0330907e1cc41acdef4eeaa53964ef30c71
            023c3cf71af2d1d9e83900ffc80e07ec2442a3dbd50e957686a22f1d8f512364
            fb71e936f24990a4abcdbef2bea2f98cd77f1d1ca5625942c79347c146dee6e3
            043eb622f63e627f4ebf20d6056133a4bd0f55dd13dcf429e0e73830969f543c
            b31d86d9a878ca79d841444359cc0e31c0283fa6dd27b702b7ee05dad12c30f7
            f84bf1309678efb8da108efcedc423da8587bd127ca082d417c8726f7889fb80
            326c3fa6fddd507ac7841b2f2e5c8780d486a0d68229ee2957a8ec24e00e4ab4
            de3fc811a4b5047c2b7920d071e9f2f9b61638dc15fb84cca46cad28e1ef539d
            bcf249876f2647757b9a5e4f0b2ea6e7aabdf47dae826e9e259428bdb07e5a2a
            68b98f141f5537be7a590cb3ba15b0bb15824652e8da8f70eb847240058a336a
            1b6db7f88268aaf89f0b33b905d72c25338b13e61a51873c2d427021a3f29207
            179ad32f423793f0c090dda025ce41df0e94afbc80ab5eda9b1a268aa2553a99"
            ),
            8192,
        )
        .unwrap();

        let e = BoxedUint::from(65_537u64);

        assert_eq!(
            RsaPublicKey::new(n, e).err().unwrap(),
            Error::ModulusTooLarge
        );
    }

    #[test]
    #[cfg(feature = "encoding")]
    fn build_key_from_primes() {
        const RSA_2048_PRIV_DER: &[u8] = include_bytes!("../tests/examples/pkcs8/rsa2048-priv.der");
        let ref_key = RsaPrivateKey::from_pkcs8_der(RSA_2048_PRIV_DER).unwrap();
        assert_eq!(ref_key.validate(), Ok(()));

        let primes = PrivateKeyParts::primes(&ref_key).to_vec();

        let exp = PublicKeyParts::e(&ref_key);
        let key = RsaPrivateKey::from_primes(primes, exp.clone())
            .expect("failed to import key from primes");
        assert_eq!(key.validate(), Ok(()));

        assert_eq!(PublicKeyParts::n(&key), PublicKeyParts::n(&ref_key));

        assert_eq!(PrivateKeyParts::dp(&key), PrivateKeyParts::dp(&ref_key));
        assert_eq!(PrivateKeyParts::dq(&key), PrivateKeyParts::dq(&ref_key));

        assert_eq!(PrivateKeyParts::d(&key), PrivateKeyParts::d(&ref_key));
    }

    #[test]
    #[cfg(feature = "encoding")]
    fn build_key_from_p_q() {
        const RSA_2048_SP800_PRIV_DER: &[u8] =
            include_bytes!("../tests/examples/pkcs8/rsa2048-sp800-56b-priv.der");
        let ref_key = RsaPrivateKey::from_pkcs8_der(RSA_2048_SP800_PRIV_DER).unwrap();
        assert_eq!(ref_key.validate(), Ok(()));

        let primes = PrivateKeyParts::primes(&ref_key).to_vec();
        let exp = PublicKeyParts::e(&ref_key);

        let key = RsaPrivateKey::from_p_q(primes[0].clone(), primes[1].clone(), exp.clone())
            .expect("failed to import key from primes");
        assert_eq!(key.validate(), Ok(()));

        assert_eq!(PublicKeyParts::n(&key), PublicKeyParts::n(&ref_key));

        assert_eq!(PrivateKeyParts::dp(&key), PrivateKeyParts::dp(&ref_key));
        assert_eq!(PrivateKeyParts::dq(&key), PrivateKeyParts::dq(&ref_key));

        assert_eq!(PrivateKeyParts::d(&key), PrivateKeyParts::d(&ref_key));
    }
}
