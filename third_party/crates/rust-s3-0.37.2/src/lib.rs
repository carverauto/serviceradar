//! Simple access to Amazon Web Service's (AWS) Simple Storage Service (S3)
#![forbid(unsafe_code)]

#[macro_use]
extern crate serde_derive;

use std::sync::atomic::AtomicU8;

pub use awscreds as creds;
pub use awsregion as region;

pub use bucket::Bucket;
pub use bucket::Tag;
pub use bucket_ops::BucketConfiguration;
pub use post_policy::{PostPolicy, PostPolicyChecksum, PostPolicyField, PostPolicyValue};
pub use put_object_request::PutObjectRequest;
#[cfg(any(feature = "with-tokio", feature = "with-async-std"))]
pub use put_object_request::PutObjectStreamRequest;
pub use region::Region;

pub mod bucket;
pub mod bucket_ops;
pub mod command;
pub mod deserializer;
pub mod post_policy;
pub mod put_object_request;
pub mod serde_types;
pub mod signing;

pub mod error;
pub mod request;
pub mod utils;

const LONG_DATETIME: &[time::format_description::FormatItem<'static>] =
    time::macros::format_description!("[year][month][day]T[hour][minute][second]Z");
const EMPTY_PAYLOAD_SHA: &str = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

static RETRIES: AtomicU8 = AtomicU8::new(1);

/// Sets the number of retries for operations that may fail and need to be retried.
///
/// This function stores the specified number of retries in an atomic variable,
/// which can be safely shared across threads. This is used by the retry! macro to automatically retry all requests.
///
/// # Arguments
///
/// * `retries` - The number of retries to set.
///
/// # Example
///
/// ```rust
/// s3::set_retries(3);
/// ```
pub fn set_retries(retries: u8) {
    RETRIES.store(retries, std::sync::atomic::Ordering::SeqCst);
}

/// Retrieves the current number of retries set for operations.
///
/// This function loads the value of the atomic variable storing the number of retries,
/// which can be safely accessed across threads.
///
/// # Returns
///
/// The number of retries currently set, as a `u64`.
///
/// # Example
///
/// ```rust
/// let retries = s3::get_retries();
/// ```
pub fn get_retries() -> u8 {
    RETRIES.load(std::sync::atomic::Ordering::Relaxed)
}
