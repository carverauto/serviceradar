use crate::{from_iter, from_iter_radix, ProcResult};
#[cfg(feature = "serde1")]
use serde::{Deserialize, Serialize};

use std::io::Read;

/// Syscall information about the process, based on the `/proc/<pid>/syscall` file.
///
/// New variants to this enum may be added at any time (even without a major or minor semver bump).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "serde1", derive(Serialize, Deserialize))]
#[non_exhaustive]
pub enum Syscall {
    /// The process is running, and so the values are not present
    Running,
    Blocked {
        /// The syscall this process is blocked on.
        /// If the syscall_number is -1, then not blocked on a syscall (blocked for another reason).
        /// Note that the rest of the values are still filled in.
        syscall_number: i64,
        /// The argument registers
        argument_registers: [u64; 6],
        /// e.g. rsp
        stack_pointer: u64,
        /// e.g. rip
        program_counter: u64,
    },
}

impl crate::FromRead for Syscall {
    fn from_read<R: Read>(mut r: R) -> ProcResult<Self> {
        // read in entire thing, this is only going to be 1 line
        let mut buf = Vec::with_capacity(512);
        r.read_to_end(&mut buf)?;

        let line = String::from_utf8_lossy(&buf);
        let buf = line.trim();

        if buf == "running" {
            Ok(Self::Running)
        } else {
            let mut values = buf.split(' ');

            let syscall_number: i64 = expect!(from_iter(&mut values), "failed to read syscall number");

            let mut argument_registers: [u64; 6] = [0; 6];
            for arg_reg in argument_registers.iter_mut() {
                *arg_reg = expect!(from_iter_radix(&mut values, 16), "failed to read argument register");
            }

            let stack_pointer: u64 = expect!(from_iter_radix(&mut values, 16), "failed to read stack pointer");
            let program_counter: u64 = expect!(from_iter_radix(&mut values, 16), "failed to read program counter");

            Ok(Self::Blocked {
                syscall_number,
                argument_registers,
                stack_pointer,
                program_counter,
            })
        }
    }
}
