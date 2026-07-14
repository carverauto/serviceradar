/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::Open01;
use crate::utils::{ziggurat_sampler, ziggurat_tables};
use crate::{Distribution, Rng};

#[derive(Clone, Copy, Debug)]
pub struct StandardNormal;

impl Distribution<f32> for StandardNormal {
    #[inline]
    fn sample<R: Rng + ?Sized>(&self, rng: &mut R) -> f32 {
        let x: f64 = self.sample(rng);
        x as f32
    }
}

impl Distribution<f64> for StandardNormal {
    fn sample<R: Rng + ?Sized>(&self, rng: &mut R) -> f64 {
        #[inline]
        fn pdf(x: f64) -> f64 {
            (-x * x / 2.0).exp()
        }
        #[inline]
        fn zero_case<R: Rng + ?Sized>(rng: &mut R, u: f64) -> f64 {
            // compute a random number in the tail by hand

            // strange initial conditions, because the loop is not
            // do-while, so the condition should be true on the first
            // run, they get overwritten anyway (0 < 1, so these are
            // good).
            let mut x = 1.0f64;
            let mut y = 0.0f64;

            while -2.0 * y < x * x {
                let x_: f64 = rng.sample(Open01);
                let y_: f64 = rng.sample(Open01);

                x = x_.ln() / ziggurat_tables::ZIG_NORM_R;
                y = y_.ln();
            }

            if u < 0.0 {
                x - ziggurat_tables::ZIG_NORM_R
            } else {
                ziggurat_tables::ZIG_NORM_R - x
            }
        }

        ziggurat_sampler::ziggurat(
            rng,
            true, // this is symmetric
            &ziggurat_tables::ZIG_NORM_X,
            &ziggurat_tables::ZIG_NORM_F,
            pdf,
            zero_case,
        )
    }
}
