`core_affinity_rs` is a Rust crate for managing CPU affinities. It currently supports Linux, Mac OSX, and Windows.

[Documentation](https://docs.rs/core_affinity)

[![Linux Status](https://travis-ci.org/Elzair/core_affinity_rs.svg?branch=master)](https://travis-ci.org/Elzair/core_affinity_rs)
[![Build status](https://ci.appveyor.com/api/projects/status/065hefrnkxg5dllt?svg=true)](https://ci.appveyor.com/project/Elzair/core-affinity-rs)

# Example

This example shows how create a thread for each available processor and pin each thread to its corresponding processor. 

```rust
extern crate core_affinity;

use std::thread;

// Retrieve the IDs of all active CPU cores.
let core_ids = core_affinity::get_core_ids().unwrap();

// Create a thread for each active CPU core.
let handles = core_ids.into_iter().map(|id| {
    thread::spawn(move || {
        // Pin this thread to a single CPU core.
        core_affinity::set_for_current(id);
        // Do more work after this.
    })
}).collect::<Vec<_>>();

for handle in handles.into_iter() {
    handle.join().unwrap();
}
```

# Platforms

`core_affinity_rs` should work on Linux, Windows, Mac OSX, and Android.

`core_affinity_rs` is continuously tested on:
  * `x86_64-unknown-linux-gnu` (Linux)
  * `i686-unknown-linux-gnu`
  * `x86_64-unknown-linux-musl` (Linux w/ [MUSL](https://www.musl-libc.org/))
  * `i686-unknown-linux-musl`
  * `x86_64-apple-darwin` (Mac OSX)
  * `i686-apple-darwin`
  * `x86_64-pc-windows-msvc` (Windows)
  * `i686-pc-windows-msvc`
  * `x86_64-pc-windows-gnu`
  * `i686-pc-windows-gnu`

`core_affinity_rs` is continuously cross-compiled for:
  * `arm-unknown-linux-gnueabihf`
  * `aarch64-unknown-linux-gnu`
  * `mips-unknown-linux-gnu`
  * `aarch64-unknown-linux-musl`
  * `i686-linux-android`
  * `x86_64-linux-android`
  * `arm-linux-androideabi`
  * `aarch64-linux-android`
