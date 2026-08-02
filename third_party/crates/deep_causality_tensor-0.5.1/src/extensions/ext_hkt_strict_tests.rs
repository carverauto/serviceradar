/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::CausalTensor;
use crate::extensions::ext_hkt_strict::StrictCausalTensorWitness;
use deep_causality_haft::{Foldable, Functor, Pure};

//  **Strict GAT HKTs are Solved in the Next-Generation Trait Solver**
//
// As of **January 2026**, we have confirmed that the inability to implement strict `Monad` and `CoMonad`
// (due to `E0276`/ `E0277` GAT normalization errors) is a **temporary limitation** of the current stable Rust trait solver.
//

#[test]
fn test_strict_pure() {
    let tensor: CausalTensor<f64> = StrictCausalTensorWitness::pure(42.0);
    assert_eq!(tensor.shape(), &[1]);
    assert_eq!(tensor.as_slice(), &[42.0]);
}

#[test]
fn test_strict_functor() {
    let tensor = CausalTensor::from_vec(vec![1.0, 2.0, 3.0], &[3]);
    let result = StrictCausalTensorWitness::fmap(tensor, |x| x * 2.0);
    assert_eq!(result.as_slice(), &[2.0, 4.0, 6.0]);
}

#[test]
fn test_strict_foldable() {
    let tensor = CausalTensor::from_vec(vec![1.0, 2.0, 3.0], &[3]);
    let result = StrictCausalTensorWitness::fold(tensor, 0.0, |acc, x| acc + x);
    assert_eq!(result, 6.0);
}

/*
#[test]
fn test_strict_monad_bind() {
    let tensor = CausalTensor::from_vec(vec![1.0, 2.0, 3.0], &[3]);
    let result = StrictCausalTensorWitness::bind(tensor, |x| {
        StrictCausalTensorWitness::pure(x * 2.0)
    });
    // Expected result: [2.0, 4.0, 6.0] (List Monad behavior)
    assert_eq!(result.shape(), &[3]);
    assert_eq!(result.as_slice(), &[2.0, 4.0, 6.0]);
}

#[test]
fn test_strict_comonad_extend() {
    let tensor = CausalTensor::from_vec(vec![1.0, 2.0, 3.0], &[3]);
    // Extend with sum
    let result = StrictCausalTensorWitness::extend(&tensor, |t: &CausalTensor<_>| {
        StrictCausalTensorWitness::fold(t.clone(), 0.0, |acc, x| acc + x)
    });
    // For list comonad (shifted view), extend(sum) usually gives suffix sums or similar depending on implementation
    // Implementation uses shifted_view(i), so for [1, 2, 3]:
    // i=0: view=[1, 2, 3], sum=6
    // i=1: view=[2, 3], sum=5
    // i=2: view=[3], sum=3
    assert_eq!(result.as_slice(), &[6.0, 5.0, 3.0]);
}
*/
