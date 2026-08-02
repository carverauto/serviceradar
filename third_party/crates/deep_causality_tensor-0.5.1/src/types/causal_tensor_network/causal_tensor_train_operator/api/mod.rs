/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::traits::tensor_train::TensorTrain;
use crate::traits::tensor_train_operator::TensorTrainOperator;
use crate::types::causal_tensor_network::canonical_form::CanonicalForm;
use crate::types::causal_tensor_network::causal_tensor_train::CausalTensorTrain;
use crate::types::causal_tensor_network::causal_tensor_train_operator::CausalTensorTrainOperator;
use crate::types::causal_tensor_network::truncation::Truncation;
use crate::{CausalTensor, CausalTensorError, Tensor};
use deep_causality_algebra::ConjugateScalar;

impl<T> TensorTrainOperator<T> for CausalTensorTrainOperator<T>
where
    T: ConjugateScalar,
{
    fn apply(
        &self,
        state: &CausalTensorTrain<T>,
        trunc: &Truncation<<T as ConjugateScalar>::Real>,
    ) -> Result<CausalTensorTrain<T>, CausalTensorError> {
        if state.phys_dims() != self.in_dims.as_slice() {
            return Err(CausalTensorError::ShapeMismatch);
        }
        let d = self.cores.len();
        let mut out_cores = Vec::with_capacity(d);

        for (w, g) in self.cores.iter().zip(state.cores().iter()) {
            let ws = w.shape();
            let (rb, nout, nin, rbp) = (ws[0], ws[1], ws[2], ws[3]);
            let gs = g.shape();
            let (ra, _, rap) = (gs[0], gs[1], gs[2]);
            let nl = rb * ra;
            let nr = rbp * rap;
            let wd = w.as_slice();
            let gd = g.as_slice();

            // H[(b·ra+a), o, (b'·rap+a')] = Σ_in W[b,o,in,b'] · G[a,in,a'].
            let mut data = vec![T::zero(); nl * nout * nr];
            for b in 0..rb {
                for a in 0..ra {
                    let row = b * ra + a;
                    for o in 0..nout {
                        for inx in 0..nin {
                            let w_base = (((b * nout) + o) * nin + inx) * rbp;
                            let g_base = ((a * nin) + inx) * rap;
                            for bp in 0..rbp {
                                let wv = wd[w_base + bp];
                                if wv == T::zero() {
                                    continue;
                                }
                                for ap in 0..rap {
                                    let col = bp * rap + ap;
                                    data[(row * nout + o) * nr + col] += wv * gd[g_base + ap];
                                }
                            }
                        }
                    }
                }
            }
            out_cores.push(CausalTensor::new(data, vec![nl, nout, nr])?);
        }

        CausalTensorTrain::from_cores_raw(out_cores, CanonicalForm::None).round(trunc)
    }

    fn compose(
        &self,
        other: &Self,
        trunc: &Truncation<<T as ConjugateScalar>::Real>,
    ) -> Result<Self, CausalTensorError> {
        // self: out ← mid ; other: mid ← in ; result: out ← in.
        if self.in_dims != other.out_dims {
            return Err(CausalTensorError::ShapeMismatch);
        }
        let d = self.cores.len();
        let mut cores = Vec::with_capacity(d);

        for (m, n) in self.cores.iter().zip(other.cores.iter()) {
            let ms = m.shape();
            let (bm, nout, nmid, bmp) = (ms[0], ms[1], ms[2], ms[3]);
            let ns = n.shape();
            let (bn, _, nin, bnp) = (ns[0], ns[1], ns[2], ns[3]);
            let nl = bm * bn;
            let nr = bmp * bnp;
            let md = m.as_slice();
            let nd = n.as_slice();

            // R[(bm·bn+...), o, in, (bm'·bn'+...)] = Σ_mid M[bm,o,mid,bm'] · N[bn,mid,in,bn'].
            let mut data = vec![T::zero(); nl * nout * nin * nr];
            for bmi in 0..bm {
                for bni in 0..bn {
                    let row = bmi * bn + bni;
                    for o in 0..nout {
                        for mid in 0..nmid {
                            let m_base = (((bmi * nout) + o) * nmid + mid) * bmp;
                            for inx in 0..nin {
                                let n_base = (((bni * nmid) + mid) * nin + inx) * bnp;
                                for bmp_i in 0..bmp {
                                    let mv = md[m_base + bmp_i];
                                    if mv == T::zero() {
                                        continue;
                                    }
                                    for bnp_i in 0..bnp {
                                        let col = bmp_i * bnp + bnp_i;
                                        let idx = ((row * nout + o) * nin + inx) * nr + col;
                                        data[idx] += mv * nd[n_base + bnp_i];
                                    }
                                }
                            }
                        }
                    }
                }
            }
            cores.push(CausalTensor::new(data, vec![nl, nout, nin, nr])?);
        }

        Self::from_cores_raw(cores, self.round_policy).round(trunc)
    }

    fn round(
        &self,
        trunc: &Truncation<<T as ConjugateScalar>::Real>,
    ) -> Result<Self, CausalTensorError> {
        let rounded = self.as_combined_train().round(trunc)?;
        Self::from_combined_train(&rounded, &self.out_dims, &self.in_dims, self.round_policy)
    }

    fn transpose(&self) -> Self {
        // Physically swap the (out, in) legs of every core: new[r, i, o, r'] = old[r, o, i, r'].
        // (A strided `permute_axes` view would leave `as_slice` in the un-permuted order.)
        let cores = self
            .cores
            .iter()
            .map(|c| {
                let s = c.shape();
                let (r, nout, nin, rp) = (s[0], s[1], s[2], s[3]);
                let d = c.as_slice();
                let mut data = vec![T::zero(); r * nin * nout * rp];
                for ri in 0..r {
                    for o in 0..nout {
                        for i in 0..nin {
                            let old_base = (((ri * nout) + o) * nin + i) * rp;
                            let new_base = (((ri * nin) + i) * nout + o) * rp;
                            data[new_base..new_base + rp]
                                .copy_from_slice(&d[old_base..old_base + rp]);
                        }
                    }
                }
                CausalTensor::new(data, vec![r, nin, nout, rp]).unwrap()
            })
            .collect();
        Self::from_cores_raw(cores, self.round_policy)
    }

    fn to_dense(&self) -> Result<CausalTensor<T>, CausalTensorError> {
        // Contract over the combined index, then split each site back into interleaved (out, in).
        let combined = self.as_combined_train().to_dense()?;
        let mut interleaved = Vec::with_capacity(self.out_dims.len() * 2);
        for (o, i) in self.out_dims.iter().zip(self.in_dims.iter()) {
            interleaved.push(*o);
            interleaved.push(*i);
        }
        combined.reshape(&interleaved)
    }
}
