# dlmalloc-rs

A port of [dlmalloc] to Rust.

[Documentation](https://docs.rs/dlmalloc)

[dlmalloc]: https://gee.cs.oswego.edu/dl/html/malloc.html

## Why dlmalloc?

This crate is a port of [dlmalloc] to Rust, and doesn't rely on C. The primary
purpose of this crate is to serve as the default allocator for Rust on the
`wasm32-unknown-unknown` target. At the time this was written the wasm target
didn't support C code, so it was required to have a Rust-only solution.

This allocator is not the most performant by a longshot. It is primarily, I
think, intended for being easy to port and easy to learn. I didn't dive too deep
into the implementation when writing it, it's just a straight port of the C
version.

It's unlikely that Rust code needs to worry/interact with this allocator in
general. Most of the time you'll be manually switching to a different allocator
:)

# License

This project is licensed under either of

 * Apache License, Version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
   http://www.apache.org/licenses/LICENSE-2.0)
 * MIT license ([LICENSE-MIT](LICENSE-MIT) or
   http://opensource.org/licenses/MIT)

at your option.

### Contribution

Unless you explicitly state otherwise, any contribution intentionally submitted
for inclusion in this project by you, as defined in the Apache-2.0 license,
shall be dual licensed as above, without any additional terms or conditions.
