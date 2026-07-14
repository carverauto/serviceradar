`core_affinity_rs` is a Rust crate for managing CPU affinities. It currently supports Linux, Mac OSX, and Windows.

[Documentation](https://docs.rs/core_affinity)

# Example

This example shows how create a thread for each available processor and pin each thread to its corresponding processor. 

```rust
extern crate core_affinity;

use std::thread;

// Retrieve the IDs of all cores on which the current
// thread is allowed to run.
// NOTE: If you want ALL the possible cores, you should
// use num_cpus.
let core_ids = core_affinity::get_core_ids().unwrap();

// Create a thread for each active CPU core.
let handles = core_ids.into_iter().map(|id| {
    thread::spawn(move || {
        // Pin this thread to a single CPU core.
        let res = core_affinity::set_for_current(id);
        if (res) {
          // Do more work after this.
        }
    })
}).collect::<Vec<_>>();

for handle in handles.into_iter() {
    handle.join().unwrap();
}
```

# Platforms

`core_affinity_rs` should work on Linux, Windows, Mac OSX, FreeBSD, NetBSD, and Android.
