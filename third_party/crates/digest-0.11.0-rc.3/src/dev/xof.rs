use crate::{ExtendableOutputReset, dev::TestVector};
use core::fmt::Debug;

/// Resettable XOF test
pub fn xof_reset_test<D: ExtendableOutputReset + Default + Debug + Clone>(
    &TestVector { input, output }: &TestVector,
) -> Result<(), &'static str> {
    let mut hasher = D::default();
    let mut buf = [0u8; 1024];
    let buf = &mut buf[..output.len()];
    // Test that it works when accepting the message all at once
    hasher.update(input);
    let mut hasher2 = hasher.clone();
    hasher.finalize_xof_into(buf);
    if buf != output {
        return Err("whole message");
    }
    buf.iter_mut().for_each(|b| *b = 0);

    // Test if reset works correctly
    hasher2.reset();
    hasher2.update(input);
    hasher2.finalize_xof_reset_into(buf);
    if buf != output {
        return Err("whole message after reset");
    }
    buf.iter_mut().for_each(|b| *b = 0);

    // Test that it works when accepting the message in chunks
    for n in 1..core::cmp::min(17, input.len()) {
        let mut hasher = D::default();
        for chunk in input.chunks(n) {
            hasher.update(chunk);
            hasher2.update(chunk);
        }
        hasher.finalize_xof_into(buf);
        if buf != output {
            return Err("message in chunks");
        }
        buf.iter_mut().for_each(|b| *b = 0);

        hasher2.finalize_xof_reset_into(buf);
        if buf != output {
            return Err("message in chunks");
        }
        buf.iter_mut().for_each(|b| *b = 0);
    }

    Ok(())
}
