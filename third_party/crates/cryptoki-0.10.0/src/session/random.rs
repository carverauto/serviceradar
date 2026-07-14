// Copyright 2021 Contributors to the Parsec project.
// SPDX-License-Identifier: Apache-2.0
//! Functions used to generate random numbers

use crate::context::Function;
use crate::error::{Result, Rv};
use crate::session::Session;
use std::convert::TryInto;

impl Session {
    /// Generates a random number and sticks it in a slice
    ///
    /// # Arguments
    ///
    /// * `random_slice` - The slice to stick the random data into.  The length of the slice represents
    ///   the number of bytes to obtain from the RBG
    pub fn generate_random_slice(&self, random_data: &mut [u8]) -> Result<()> {
        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_GenerateRandom)(
                self.handle(),
                random_data.as_ptr() as *mut u8,
                random_data.len().try_into()?,
            ))
            .into_result(Function::GenerateRandom)?;
        }
        Ok(())
    }

    /// Generates random data and returns it as a `Vec<u8>`.  The length of the returned Vector will
    /// be the amount of random requested, which is `random_len`.
    pub fn generate_random_vec(&self, random_len: u32) -> Result<Vec<u8>> {
        let mut result: Vec<u8> = vec![0; random_len as usize];
        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_GenerateRandom)(
                self.handle(),
                result.as_mut_ptr(),
                random_len.into(),
            ))
            .into_result(Function::GenerateRandom)?;
        }
        Ok(result)
    }

    /// Seeds the RNG
    pub fn seed_random(&self, seed: &[u8]) -> Result<()> {
        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_SeedRandom)(
                self.handle(),
                seed.as_ptr() as *mut u8,
                seed.len().try_into()?,
            ))
            .into_result(Function::SeedRandom)?;
        }
        Ok(())
    }
}
