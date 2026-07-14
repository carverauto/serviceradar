use crate::{Digest, FixedOutput, FixedOutputReset, HashMarker, dev::TestVector};

/// Fixed-output resettable digest test via the `Digest` trait
pub fn fixed_reset_test<D: FixedOutputReset + Clone + Default + HashMarker>(
    &TestVector { input, output }: &TestVector,
) -> Result<(), &'static str> {
    let mut hasher = D::new();
    // Test that it works when accepting the message all at once
    hasher.update(input);
    let mut hasher2 = hasher.clone();
    if hasher.finalize()[..] != output[..] {
        return Err("whole message");
    }

    // Test if reset works correctly
    hasher2.reset();
    hasher2.update(input);
    if hasher2.finalize_reset()[..] != output[..] {
        return Err("whole message after reset");
    }

    // Test that it works when accepting the message in chunks
    for n in 1..core::cmp::min(17, input.len()) {
        let mut hasher = D::new();
        for chunk in input.chunks(n) {
            hasher.update(chunk);
            hasher2.update(chunk);
        }
        if hasher.finalize()[..] != output[..] {
            return Err("message in chunks");
        }
        if hasher2.finalize_reset()[..] != output[..] {
            return Err("message in chunks");
        }
    }

    Ok(())
}

/// Variable-output resettable digest test
pub fn fixed_test<D: FixedOutput + Default + HashMarker>(
    &TestVector { input, output }: &TestVector,
) -> Result<(), &'static str> {
    let mut hasher = D::default();
    // Test that it works when accepting the message all at once
    hasher.update(input);
    if hasher.finalize_fixed()[..] != output[..] {
        return Err("whole message");
    }

    // Test that it works when accepting the message in chunks
    for n in 1..core::cmp::min(17, input.len()) {
        let mut hasher = D::default();
        for chunk in input.chunks(n) {
            hasher.update(chunk);
        }
        if hasher.finalize_fixed()[..] != output[..] {
            return Err("message in chunks");
        }
    }
    Ok(())
}
