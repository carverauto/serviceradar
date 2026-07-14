/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! `Uncertain<Float106>`: the double-double precision instantiation of the uncertain engine.
//!
//! It needs no `Float106`-specific code. Construction (`point` / `normal` / `uniform`) is the
//! shared generic surface in `uncertain_real`, and sampling (`sample`, `sample_with_index`,
//! `take_samples`) is the precision-generic `impl<T: ProbabilisticType> Uncertain<T>` in
//! `uncertain_sampling`. The f64→double-double widening that the `Float106` draw relies on
//! lives in `Float106::from_sampled_value`, so the generic sampler reproduces it with no
//! narrowing through `f64`.
