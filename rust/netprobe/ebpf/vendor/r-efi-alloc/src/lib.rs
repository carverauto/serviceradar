//! UEFI Memory Allocator Integration
//!
//! This crate integrates the memory allocators of the rust standard library
//! with the memory allocators provided by UEFI systems. The `raw` module
//! implements the underlying unsafe allocator to interact with UEFI memory
//! allocations from within rust. The `global` module implements the stable
//! `GlobalAlloc` interface of the rust standard library, thus providing
//! UEFI memory allocators to the rust standard library. Lastly, `alloc`
//! implements the unstable `core::alloc::Allocator` trait which likely
//! will take the role of the main rust memory allocators in the future.

// The `core::alloc::Allocator` trait is still unstable and hidden behind the
// `allocator_api` feature. Make sure to enable it, so we can implement this
// trait. The `alloc_layout_extra` feature provides additional extensions to
// the stable `Layout` object (in particular `dangling()` for ZSTs).
#![cfg_attr(
    feature = "allocator_api",
    feature(alloc_layout_extra, allocator_api)
)]

// We need no features of std, so mark the crate as `no_std` (more importantly,
// `std` might not even be available on UEFI systems). However, pull in `std`
// during tests, so we can run them on the host.
#![cfg_attr(not(test), no_std)]

pub mod alloc;
pub mod global;
pub mod raw;
