// This test requires the `global` feature, and then also require a 32-bit
// platform as otherwise exhausting the address space on 64-bit platforms is
// unreasonable.
#![cfg(all(feature = "global", target_pointer_width = "32"))]

use std::mem;

#[global_allocator]
static A: dlmalloc::GlobalDlmalloc = dlmalloc::GlobalDlmalloc;

fn get_vec_allocated_near_end_of_address_space() -> Vec<u8> {
    // Reserve a 1.5 GiB outer vector, to OOM faster
    let mut test_vector: Vec<Vec<u8>> = Vec::with_capacity(2usize.pow(27));

    // Allocate 1KiB vectors until we run out of memory
    loop {
        let mut inner_vector = vec![];
        if inner_vector.try_reserve_exact(1024).is_err() {
            return mem::take(test_vector.last_mut().unwrap());
        };
        test_vector.push(inner_vector);
    }
}

#[test]
fn eat_memory() {
    get_vec_allocated_near_end_of_address_space();
}
