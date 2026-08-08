/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::traits::tensor_train::TensorTrain;
use crate::types::causal_tensor_network::canonical_form::CanonicalForm;
use crate::types::causal_tensor_network::causal_tensor_train::construct::MAX_DENSE_ELEMS;
use crate::types::causal_tensor_network::causal_tensor_train::linalg::{matmul, transpose};
use crate::types::causal_tensor_network::causal_tensor_train::{CausalTensorTrain, Identity};
use crate::types::causal_tensor_network::cross_config::CrossConfig;
use crate::types::causal_tensor_network::truncation::{RoundStrategy, Truncation};
use crate::{CausalTensor, CausalTensorError, Tensor};
use deep_causality_algebra::{ConjugateScalar, Real, Scalar};
use deep_causality_num::Zero;

/// The real magnitude type of a conjugate scalar.
type Re<T> = <T as ConjugateScalar>::Real;

/// `(r_left, n, r_right)` of a rank-3 core.
fn dims<T>(core: &CausalTensor<T>) -> (usize, usize, usize) {
    let s = core.shape();
    (s[0], s[1], s[2])
}

/// `k × k` identity buffer (row-major).
fn identity<T: ConjugateScalar>(k: usize) -> Vec<T> {
    let mut m = vec![T::zero(); k * k];
    for i in 0..k {
        m[i * k + i] = T::one();
    }
    m
}

/// In-place left-orthonormalize core `k` via QR, absorbing `R` into core `k+1`.
fn qr_step<T: ConjugateScalar>(
    cores: &mut [CausalTensor<T>],
    k: usize,
) -> Result<(), CausalTensorError> {
    let (rl, n, rr) = dims(&cores[k]);
    let m = cores[k].reshape(&[rl * n, rr])?;
    let (q, r) = m.qr()?;
    let qd = q.shape()[1];
    cores[k] = q.reshape(&[rl, n, qd])?;

    let (rl2, n2, rr2) = dims(&cores[k + 1]);
    let next = cores[k + 1].reshape(&[rl2, n2 * rr2])?;
    let data = matmul(r.as_slice(), qd, rr, next.as_slice(), n2 * rr2);
    cores[k + 1] = CausalTensor::new(data, vec![qd, n2, rr2])?;
    Ok(())
}

/// In-place right-orthonormalize core `k` via LQ, absorbing `L` into core `k-1`.
fn lq_step<T: ConjugateScalar>(
    cores: &mut [CausalTensor<T>],
    k: usize,
) -> Result<(), CausalTensorError> {
    let (rl, n, rr) = dims(&cores[k]);
    let m = cores[k].reshape(&[rl, n * rr])?;
    // LQ via QR of the transpose: Mᵀ = Q R ⇒ M = Rᵀ Qᵀ.
    let mt = CausalTensor::new(transpose(m.as_slice(), rl, n * rr), vec![n * rr, rl])?;
    let (q, r) = mt.qr()?;
    let qd = q.shape()[1];
    // core k ← Qᵀ, shape [qd, n, rr].
    let qt = transpose(q.as_slice(), n * rr, qd);
    cores[k] = CausalTensor::new(qt, vec![qd, n, rr])?;
    // Absorb Rᵀ ([rl, qd]) into core k-1's right bond.
    let rt = transpose(r.as_slice(), qd, rl);
    let (rl0, n0, rr0) = dims(&cores[k - 1]);
    let prev = cores[k - 1].reshape(&[rl0 * n0, rr0])?;
    let data = matmul(prev.as_slice(), rl0 * n0, rr0, &rt, qd);
    cores[k - 1] = CausalTensor::new(data, vec![rl0, n0, qd])?;
    Ok(())
}

impl<T> CausalTensorTrain<T>
where
    T: ConjugateScalar,
{
    /// Scales the represented tensor by a scalar (exact, rank-preserving).
    ///
    /// Inherent (not on the `TensorTrain` trait) so `.scale(..)` never collides with the
    /// `Module::scale` provided method once `CausalTensorTrain` is a `Module`.
    pub fn scale(&self, s: T) -> Self {
        // 0·s = 0; the bare multiplicative identity is left unchanged (degenerate, unused).
        if self.cores().is_empty() {
            return self.clone();
        }
        let mut cores = self.cores().to_vec();
        let (rl, n, rr) = dims(&cores[0]);
        let data: Vec<T> = cores[0].as_slice().iter().map(|&x| x * s).collect();
        cores[0] = CausalTensor::new(data, vec![rl, n, rr]).unwrap();
        Self::from_cores_unchecked(cores, CanonicalForm::None)
    }
}

impl<T> TensorTrain<T> for CausalTensorTrain<T>
where
    T: ConjugateScalar,
{
    fn to_dense(&self) -> Result<CausalTensor<T>, CausalTensorError> {
        // An algebraic identity is shape-polymorphic; densify it to the corresponding scalar,
        // mirroring `CausalTensor::zero().to_dense()` (a shape-`[]` scalar).
        if self.cores().is_empty() {
            let val = match self.identity_kind() {
                Identity::MultiplicativeOne => T::one(),
                _ => T::zero(),
            };
            return CausalTensor::new(vec![val], vec![]);
        }
        let total: usize = self.phys_dims().iter().product();
        if total > MAX_DENSE_ELEMS {
            return Err(CausalTensorError::RankExceeded);
        }
        let cores = self.cores();
        let d = cores.len();

        let (_, n0, r1) = dims(&cores[0]);
        let mut acc = cores[0].as_slice().to_vec(); // [n0, r1]
        let mut rows = n0;
        let mut rk = r1;
        for core in cores.iter().take(d).skip(1) {
            let (_, n, rr) = dims(core);
            acc = matmul(&acc, rows, rk, core.as_slice(), n * rr);
            rows *= n;
            rk = rr;
        }
        // rk == 1 here, so acc has `total` entries.
        CausalTensor::new(acc, self.phys_dims().to_vec())
    }

    fn eval(&self, index: &[usize]) -> Result<T, CausalTensorError> {
        let cores = self.cores();
        if index.len() != cores.len() {
            return Err(CausalTensorError::DimensionMismatch);
        }
        // Order-0 identity: the empty index evaluates to the identity scalar.
        if cores.is_empty() {
            return Ok(match self.identity_kind() {
                Identity::MultiplicativeOne => T::one(),
                _ => T::zero(),
            });
        }
        let mut v = vec![T::one()]; // r_0 == 1
        let mut rk = 1usize;
        for (core, &i) in cores.iter().zip(index.iter()) {
            let (_, n, rr) = dims(core);
            if i >= n {
                return Err(CausalTensorError::IndexOutOfBounds);
            }
            let data = core.as_slice();
            let mut nv = vec![T::zero(); rr];
            for (a, &va) in v.iter().enumerate().take(rk) {
                if va == T::zero() {
                    continue;
                }
                let base = a * (n * rr) + i * rr;
                for (b, nvb) in nv.iter_mut().enumerate() {
                    *nvb += va * data[base + b];
                }
            }
            v = nv;
            rk = rr;
        }
        Ok(v[0])
    }

    fn left_canonicalize(&self) -> Result<Self, CausalTensorError> {
        let d = self.order();
        let mut cores = self.cores().to_vec();
        for k in 0..d.saturating_sub(1) {
            qr_step(&mut cores, k)?;
        }
        Ok(Self::from_cores_unchecked(
            cores,
            CanonicalForm::LeftAt(d - 1),
        ))
    }

    fn right_canonicalize(&self) -> Result<Self, CausalTensorError> {
        let d = self.order();
        let mut cores = self.cores().to_vec();
        for k in (1..d).rev() {
            lq_step(&mut cores, k)?;
        }
        Ok(Self::from_cores_unchecked(cores, CanonicalForm::RightAt(0)))
    }

    fn canonicalize_at(&self, center: usize) -> Result<Self, CausalTensorError> {
        let d = self.order();
        if center >= d {
            return Err(CausalTensorError::IndexOutOfBounds);
        }
        let mut cores = self.cores().to_vec();
        for k in 0..center {
            qr_step(&mut cores, k)?;
        }
        for k in (center + 1..d).rev() {
            lq_step(&mut cores, k)?;
        }
        Ok(Self::from_cores_unchecked(
            cores,
            CanonicalForm::Mixed(center),
        ))
    }

    fn round(&self, trunc: &Truncation<Re<T>>) -> Result<Self, CausalTensorError> {
        // The randomized strategy uses randomize-then-orthogonalize, which sketches the train first and
        // never canonicalizes the full high-bond cores (the deterministic sweep below would). The inner
        // trim it performs uses a deterministic policy, so there is no recursion.
        if let RoundStrategy::Randomized { oversample, seed } = trunc.strategy() {
            return self.round_randomized(trunc, oversample, seed);
        }
        let d = self.order();
        let mut cores = self.cores().to_vec();
        // Left-canonicalize, then a right-to-left truncated-SVD sweep.
        for k in 0..d.saturating_sub(1) {
            qr_step(&mut cores, k)?;
        }
        for k in (1..d).rev() {
            let (rl, n, rr) = dims(&cores[k]);
            let m = cores[k].reshape(&[rl, n * rr])?;
            let (u, s, vt) = m.svd_truncated(trunc)?;
            let q = s.len();
            cores[k] = vt.reshape(&[q, n, rr])?;

            // US = U · diag(S), shape [rl, q] (singular values are real).
            let mut us = u.as_slice().to_vec();
            let s_slice = s.as_slice();
            for a in 0..rl {
                for (j, sj) in s_slice.iter().enumerate() {
                    us[a * q + j] *= T::from_real(*sj);
                }
            }
            let (rl0, n0, rr0) = dims(&cores[k - 1]);
            let prev = cores[k - 1].reshape(&[rl0 * n0, rr0])?;
            let data = matmul(prev.as_slice(), rl0 * n0, rr0, &us, q);
            cores[k - 1] = CausalTensor::new(data, vec![rl0, n0, q])?;
        }
        Ok(Self::from_cores_unchecked(cores, CanonicalForm::Mixed(0)))
    }

    fn norm(&self) -> Result<T, CausalTensorError> {
        // ‖x‖² = ⟨x|x⟩ is a non-negative real (its imaginary part is zero up to rounding); take the
        // real part and clamp before the square root, so the norm is always real and never `NaN`
        // (a tiny negative from catastrophic cancellation on a near-zero train would otherwise
        // produce `NaN`). The result is returned as `T` (real-valued for a complex train).
        let sq = self.inner(self)?.real_part();
        let sq = if sq < Re::<T>::zero() {
            Re::<T>::zero()
        } else {
            sq
        };
        Ok(T::from_real(sq.sqrt()))
    }

    fn inner(&self, other: &Self) -> Result<T, CausalTensorError> {
        if self.phys_dims() != other.phys_dims() {
            return Err(CausalTensorError::ShapeMismatch);
        }
        let a = self.cores();
        let b = other.cores();
        let mut l = vec![T::one()]; // [ra=1, rb=1]
        let mut ra = 1usize;
        let mut rb = 1usize;
        // Scratch buffers reused across sites (cleared/resized in place) to avoid a per-site
        // allocation; the arithmetic and its order are unchanged, so the result is bit-identical.
        let mut m: Vec<T> = Vec::new();
        let mut nl: Vec<T> = Vec::new();
        for (ac, bc) in a.iter().zip(b.iter()) {
            let (_, n, ar) = dims(ac);
            let (_, _, br) = dims(bc);
            let ad = ac.as_slice();
            let bd = bc.as_slice();

            // Hermitian inner product ⟨self|other⟩ = Σ conj(self)·other: the `self` (a) factors are
            // conjugated. For a real scalar the conjugation is the identity.
            // Step 1: M[bb, i, ga] = Σ_aa L[aa,bb] · conj(a[aa,i,ga]).
            m.clear();
            m.resize(rb * n * ar, T::zero());
            for aa in 0..ra {
                for bb in 0..rb {
                    let lval = l[aa * rb + bb];
                    if lval == T::zero() {
                        continue;
                    }
                    for i in 0..n {
                        let abase = aa * (n * ar) + i * ar;
                        let mbase = (bb * n + i) * ar;
                        for ga in 0..ar {
                            m[mbase + ga] += lval * ad[abase + ga].conjugate();
                        }
                    }
                }
            }
            // Step 2: L'[ga, gb] = Σ_{bb,i} M[bb,i,ga] · b[bb,i,gb].
            nl.clear();
            nl.resize(ar * br, T::zero());
            for bb in 0..rb {
                for i in 0..n {
                    let mbase = (bb * n + i) * ar;
                    let bbase = bb * (n * br) + i * br;
                    for ga in 0..ar {
                        let mval = m[mbase + ga];
                        if mval == T::zero() {
                            continue;
                        }
                        let nlbase = ga * br;
                        for gb in 0..br {
                            nl[nlbase + gb] += mval * bd[bbase + gb];
                        }
                    }
                }
            }
            // Swap the new carry into `l`, keeping `nl`'s freed buffer for the next site.
            core::mem::swap(&mut l, &mut nl);
            ra = ar;
            rb = br;
        }
        Ok(l[0])
    }

    fn add(&self, other: &Self) -> Result<Self, CausalTensorError> {
        if self.phys_dims() != other.phys_dims() {
            return Err(CausalTensorError::ShapeMismatch);
        }
        let a = self.cores();
        let b = other.cores();
        let d = a.len();
        let mut cores = Vec::with_capacity(d);

        for k in 0..d {
            let (al, n, ar) = dims(&a[k]);
            let (bl, _, br) = dims(&b[k]);
            let ad = a[k].as_slice();
            let bd = b[k].as_slice();
            let af = |x: usize, i: usize, g: usize| ad[x * (n * ar) + i * ar + g];
            let bf = |x: usize, i: usize, g: usize| bd[x * (n * br) + i * br + g];

            if d == 1 {
                // Order-1: elementwise sum of the two vectors.
                let mut data = vec![T::zero(); n];
                for (i, slot) in data.iter_mut().enumerate() {
                    *slot = af(0, i, 0) + bf(0, i, 0);
                }
                cores.push(CausalTensor::new(data, vec![1, n, 1])?);
            } else if k == 0 {
                let nrr = ar + br;
                let mut data = vec![T::zero(); n * nrr];
                for i in 0..n {
                    for g in 0..ar {
                        data[i * nrr + g] = af(0, i, g);
                    }
                    for g in 0..br {
                        data[i * nrr + ar + g] = bf(0, i, g);
                    }
                }
                cores.push(CausalTensor::new(data, vec![1, n, nrr])?);
            } else if k == d - 1 {
                let nrl = al + bl;
                let mut data = vec![T::zero(); nrl * n];
                for x in 0..al {
                    for i in 0..n {
                        data[x * n + i] = af(x, i, 0);
                    }
                }
                for x in 0..bl {
                    for i in 0..n {
                        data[(al + x) * n + i] = bf(x, i, 0);
                    }
                }
                cores.push(CausalTensor::new(data, vec![nrl, n, 1])?);
            } else {
                let nrl = al + bl;
                let nrr = ar + br;
                let mut data = vec![T::zero(); nrl * n * nrr];
                for x in 0..al {
                    for i in 0..n {
                        for g in 0..ar {
                            data[x * (n * nrr) + i * nrr + g] = af(x, i, g);
                        }
                    }
                }
                for x in 0..bl {
                    for i in 0..n {
                        for g in 0..br {
                            data[(al + x) * (n * nrr) + i * nrr + (ar + g)] = bf(x, i, g);
                        }
                    }
                }
                cores.push(CausalTensor::new(data, vec![nrl, n, nrr])?);
            }
        }
        Ok(Self::from_cores_unchecked(cores, CanonicalForm::None))
    }

    fn add_rounded(
        &self,
        other: &Self,
        trunc: &Truncation<Re<T>>,
    ) -> Result<Self, CausalTensorError> {
        self.add(other)?.round(trunc)
    }

    fn add_scalar(&self, c: T) -> Result<Self, CausalTensorError> {
        let ones = Self::ones(self.phys_dims());
        self.add(&ones.scale(c))
    }

    fn hadamard(&self, other: &Self) -> Result<Self, CausalTensorError> {
        if self.phys_dims() != other.phys_dims() {
            return Err(CausalTensorError::ShapeMismatch);
        }
        let a = self.cores();
        let b = other.cores();
        let mut cores = Vec::with_capacity(a.len());
        for (ac, bc) in a.iter().zip(b.iter()) {
            let (al, n, ar) = dims(ac);
            let (bl, _, br) = dims(bc);
            let ad = ac.as_slice();
            let bd = bc.as_slice();
            let nrl = al * bl;
            let nrr = ar * br;
            let mut data = vec![T::zero(); nrl * n * nrr];
            for x in 0..al {
                for y in 0..bl {
                    for i in 0..n {
                        for g in 0..ar {
                            let aval = ad[x * (n * ar) + i * ar + g];
                            if aval == T::zero() {
                                continue;
                            }
                            for h in 0..br {
                                let bval = bd[y * (n * br) + i * br + h];
                                let row = x * bl + y;
                                let col = g * br + h;
                                data[row * (n * nrr) + i * nrr + col] = aval * bval;
                            }
                        }
                    }
                }
            }
            cores.push(CausalTensor::new(data, vec![nrl, n, nrr])?);
        }
        Ok(Self::from_cores_unchecked(cores, CanonicalForm::None))
    }

    fn hadamard_rounded(
        &self,
        other: &Self,
        trunc: &Truncation<Re<T>>,
    ) -> Result<Self, CausalTensorError> {
        if self.phys_dims() != other.phys_dims() {
            return Err(CausalTensorError::ShapeMismatch);
        }
        let a = self.cores();
        let b = other.cores();
        let d = a.len();

        // Fused build-and-left-canonicalize: form the squared-bond Hadamard core for *one* site at a
        // time, fold in the carried `R`, and immediately QR-reduce its left unfolding before moving
        // on. Only a single bond-`r²` core is ever materialized (not the whole squared train), and
        // the stored cores come out left-orthonormal — so the trailing `round` is just the cheap
        // right-to-left truncation sweep. The represented tensor equals `hadamard(other).round(trunc)`.
        let mut cores: Vec<CausalTensor<T>> = Vec::with_capacity(d);
        let mut carry: Vec<T> = vec![T::one()]; // [carry_rows, nrl_0] = [1, 1]
        let mut carry_rows = 1usize;

        for k in 0..d {
            let (al, n, ar) = dims(&a[k]);
            let (bl, _, br) = dims(&b[k]);
            let ad = a[k].as_slice();
            let bd = b[k].as_slice();
            let nrl = al * bl;
            let nrr = ar * br;

            // Squared-bond core H_k[(x·bl+y), i, (g·br+h)] = a[x,i,g]·b[y,i,h] (transient).
            let mut hk = vec![T::zero(); nrl * n * nrr];
            for x in 0..al {
                for y in 0..bl {
                    let row = x * bl + y;
                    for i in 0..n {
                        for g in 0..ar {
                            let aval = ad[x * (n * ar) + i * ar + g];
                            if aval == T::zero() {
                                continue;
                            }
                            for h in 0..br {
                                let bval = bd[y * (n * br) + i * br + h];
                                let col = g * br + h;
                                hk[row * (n * nrr) + i * nrr + col] = aval * bval;
                            }
                        }
                    }
                }
            }

            // Absorb the carry into the left bond: M = carry · H_k, shape [carry_rows, n·nrr].
            let m = matmul(&carry, carry_rows, nrl, &hk, n * nrr);

            if k < d - 1 {
                // Left-orthonormalize: QR of [carry_rows·n, nrr]; R is carried into the next site.
                let mt = CausalTensor::new(m, vec![carry_rows * n, nrr])?;
                let (q, r) = mt.qr()?;
                let qd = q.shape()[1];
                cores.push(q.reshape(&[carry_rows, n, qd])?);
                carry = r.as_slice().to_vec(); // [qd, nrr] → next core's left bond
                carry_rows = qd;
            } else {
                // Last site: nrr == 1, so M is already the final core [carry_rows, n, 1].
                cores.push(CausalTensor::new(m, vec![carry_rows, n, 1])?);
            }
        }

        let train = Self::from_cores_unchecked(cores, CanonicalForm::LeftAt(d - 1));
        train.round(trunc)
    }

    fn marginalize(&self, sites: &[usize]) -> Result<Self, CausalTensorError> {
        let cores = self.cores();
        let d = cores.len();
        let mut summed = vec![false; d];
        for &s in sites {
            if s >= d {
                return Err(CausalTensorError::IndexOutOfBounds);
            }
            summed[s] = true;
        }
        if summed.iter().all(|&x| x) {
            return Err(CausalTensorError::InvalidParameter(
                "marginalize cannot sum out every site".to_string(),
            ));
        }

        // Carry matrix C (crows × ccols), starting as the 1×1 identity on the left boundary.
        let mut carry = vec![T::one()];
        let mut crows = 1usize;
        let mut out: Vec<CausalTensor<T>> = Vec::new();
        let mut last_kept = false;

        for (k, core) in cores.iter().enumerate() {
            let (rl, n, rr) = dims(core);
            let data = core.as_slice();
            if summed[k] {
                // M_k = Σ_i core[:, i, :], shape [rl, rr].
                let mut mk = vec![T::zero(); rl * rr];
                for x in 0..rl {
                    for i in 0..n {
                        for g in 0..rr {
                            mk[x * rr + g] += data[x * (n * rr) + i * rr + g];
                        }
                    }
                }
                carry = matmul(&carry, crows, rl, &mk, rr);
                last_kept = false;
            } else {
                // Absorb the carry into the left bond of this kept core.
                let cmat = core.reshape(&[rl, n * rr])?;
                let data = matmul(&carry, crows, rl, cmat.as_slice(), n * rr);
                out.push(CausalTensor::new(data, vec![crows, n, rr])?);
                carry = identity(rr);
                crows = rr;
                last_kept = true;
            }
        }

        // Trailing summed sites: fold the residual carry into the last kept core's right bond.
        if !last_kept {
            let last = out.pop().expect("at least one kept site");
            let (rl0, n0, rr0) = dims(&last);
            let ccols = carry.len() / crows; // crows == rr0
            let prev = last.reshape(&[rl0 * n0, rr0])?;
            let folded = matmul(prev.as_slice(), rl0 * n0, rr0, &carry, ccols);
            out.push(CausalTensor::new(folded, vec![rl0, n0, ccols])?);
        }

        Self::from_cores(out)
    }

    fn integrate(&self, weights: &[CausalTensor<T>]) -> Result<T, CausalTensorError> {
        let cores = self.cores();
        if weights.len() != cores.len() {
            return Err(CausalTensorError::DimensionMismatch);
        }
        if cores.is_empty() {
            return Ok(match self.identity_kind() {
                Identity::MultiplicativeOne => T::one(),
                _ => T::zero(),
            });
        }
        let mut vrow = vec![T::one()]; // [r_0 == 1]
        let mut rk = 1usize;
        for (core, w) in cores.iter().zip(weights.iter()) {
            let (_, n, rr) = dims(core);
            if w.len() != n {
                return Err(CausalTensorError::ShapeMismatch);
            }
            let cd = core.as_slice();
            let wd = w.as_slice();
            // M[a,b] = Σ_i core[a,i,b]·w[i]; vrow ← vrow · M.
            let mut nv = vec![T::zero(); rr];
            for (a, &va) in vrow.iter().enumerate().take(rk) {
                if va == T::zero() {
                    continue;
                }
                for (i, &wi) in wd.iter().enumerate() {
                    let base = a * (n * rr) + i * rr;
                    for (b, nvb) in nv.iter_mut().enumerate() {
                        *nvb += va * cd[base + b] * wi;
                    }
                }
            }
            vrow = nv;
            rk = rr;
        }
        Ok(vrow[0])
    }
}

impl<T> CausalTensorTrain<T>
where
    T: Scalar + ConjugateScalar<Real = T>,
{
    /// Applies a general nonlinear scalar map `f` to every logical entry, returning a *new*
    /// approximate train and a sampled residual.
    ///
    /// A nonlinear map of a tensor train has no exact local form (and can inflate rank), so this
    /// re-approximates `f∘self` by TT-cross over the oracle `i ↦ f(self.eval(i))`. The returned
    /// residual makes the approximation explicit. For exact linear/affine maps use `scale` /
    /// `add_scalar` instead.
    ///
    /// Inherent (not on the `TensorTrain` trait) and bound on [`Scalar`]: TT-cross relies on ordered
    /// pivoting, so it is real/dual only — complex trains do not get this method.
    ///
    /// # Errors
    /// Propagates [`CausalTensorError::CrossSampleFailure`] if `f` or evaluation produces a
    /// non-finite value, and other cross errors.
    pub fn apply_nonlinear<F>(
        &self,
        mut f: F,
        config: &CrossConfig<T>,
    ) -> Result<(Self, T), CausalTensorError>
    where
        F: FnMut(T) -> T,
    {
        let shape = self.phys_dims().to_vec();
        CausalTensorTrain::cross(
            &shape,
            |idx| match self.eval(idx) {
                Ok(x) => f(x),
                Err(_) => T::nan(),
            },
            config,
        )
    }
}
