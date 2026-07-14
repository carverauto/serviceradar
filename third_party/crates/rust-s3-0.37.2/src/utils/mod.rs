mod time_utils;

pub use time_utils::*;

use std::str::FromStr;

use crate::error::S3Error;
use crate::request::ResponseData;
use crate::{bucket::CHUNK_SIZE, serde_types::HeadObjectResult};

use std::fs::File;

use std::io::Read;
use std::path::Path;

#[cfg(feature = "with-tokio")]
use tokio::io::{AsyncRead, AsyncReadExt};

#[cfg(feature = "with-async-std")]
use async_std::io::Read as AsyncRead;

#[cfg(feature = "with-async-std")]
use async_std::io::ReadExt as AsyncReadExt;

#[derive(Debug)]
pub struct PutStreamResponse {
    status_code: u16,
    uploaded_bytes: usize,
}

impl PutStreamResponse {
    pub fn new(status_code: u16, uploaded_bytes: usize) -> Self {
        Self {
            status_code,
            uploaded_bytes,
        }
    }
    pub fn status_code(&self) -> u16 {
        self.status_code
    }

    pub fn uploaded_bytes(&self) -> usize {
        self.uploaded_bytes
    }
}

/// # Example
/// ```rust,no_run
/// use s3::utils::etag_for_path;
///
/// let path = "test_etag";
/// let etag = etag_for_path(path).unwrap();
/// println!("{}", etag);
/// ```
pub fn etag_for_path(path: impl AsRef<Path>) -> Result<String, S3Error> {
    let mut file = File::open(path)?;
    let mut last_digest: [u8; 16];
    let mut digests = Vec::new();
    let mut chunks = 0;
    loop {
        let chunk = read_chunk(&mut file)?;
        last_digest = md5::compute(&chunk).into();
        digests.extend_from_slice(&last_digest);
        chunks += 1;
        if chunk.len() < CHUNK_SIZE {
            break;
        }
    }
    let etag = if chunks <= 1 {
        format!("{:x}", md5::Digest(last_digest))
    } else {
        let digest = format!("{:x}", md5::compute(digests));
        format!("{}-{}", digest, chunks)
    };
    Ok(etag)
}

pub fn read_chunk<R: Read + ?Sized>(reader: &mut R) -> Result<Vec<u8>, S3Error> {
    let mut chunk = Vec::with_capacity(CHUNK_SIZE);
    let mut take = reader.take(CHUNK_SIZE as u64);
    take.read_to_end(&mut chunk)?;

    Ok(chunk)
}

#[cfg(any(feature = "with-tokio", feature = "with-async-std"))]
pub async fn read_chunk_async<R: AsyncRead + Unpin + ?Sized>(
    reader: &mut R,
) -> Result<Vec<u8>, S3Error> {
    let mut chunk = Vec::with_capacity(CHUNK_SIZE);
    let mut take = reader.take(CHUNK_SIZE as u64);
    take.read_to_end(&mut chunk).await?;

    Ok(chunk)
}

pub trait GetAndConvertHeaders {
    fn get_and_convert<T: FromStr>(&self, header: &str) -> Option<T>;
    fn get_string(&self, header: &str) -> Option<String>;
}

impl GetAndConvertHeaders for http::header::HeaderMap {
    fn get_and_convert<T: FromStr>(&self, header: &str) -> Option<T> {
        self.get(header)?.to_str().ok()?.parse::<T>().ok()
    }
    fn get_string(&self, header: &str) -> Option<String> {
        Some(self.get(header)?.to_str().ok()?.to_owned())
    }
}

#[cfg(feature = "with-async-std")]
impl From<&http::HeaderMap> for HeadObjectResult {
    fn from(headers: &http::HeaderMap) -> Self {
        let mut result = HeadObjectResult {
            accept_ranges: headers.get_string("accept-ranges"),
            cache_control: headers.get_string("Cache-Control"),
            content_disposition: headers.get_string("Content-Disposition"),
            content_encoding: headers.get_string("Content-Encoding"),
            content_language: headers.get_string("Content-Language"),
            content_length: headers.get_and_convert("Content-Length"),
            content_type: headers.get_string("Content-Type"),
            delete_marker: headers.get_and_convert("x-amz-delete-marker"),
            e_tag: headers.get_string("ETag"),
            expiration: headers.get_string("x-amz-expiration"),
            expires: headers.get_string("Expires"),
            last_modified: headers.get_string("Last-Modified"),
            ..Default::default()
        };
        let mut values = ::std::collections::HashMap::new();
        for (key, value) in headers.iter() {
            if key.as_str().starts_with("x-amz-meta-")
                && let Ok(value) = value.to_str()
            {
                values.insert(
                    key.as_str()["x-amz-meta-".len()..].to_owned(),
                    value.to_owned(),
                );
            }
        }
        result.metadata = Some(values);
        result.missing_meta = headers.get_and_convert("x-amz-missing-meta");
        result.object_lock_legal_hold_status = headers.get_string("x-amz-object-lock-legal-hold");
        result.object_lock_mode = headers.get_string("x-amz-object-lock-mode");
        result.object_lock_retain_until_date =
            headers.get_string("x-amz-object-lock-retain-until-date");
        result.parts_count = headers.get_and_convert("x-amz-mp-parts-count");
        result.replication_status = headers.get_string("x-amz-replication-status");
        result.request_charged = headers.get_string("x-amz-request-charged");
        result.restore = headers.get_string("x-amz-restore");
        result.sse_customer_algorithm =
            headers.get_string("x-amz-server-side-encryption-customer-algorithm");
        result.sse_customer_key_md5 =
            headers.get_string("x-amz-server-side-encryption-customer-key-MD5");
        result.ssekms_key_id = headers.get_string("x-amz-server-side-encryption-aws-kms-key-id");
        result.server_side_encryption = headers.get_string("x-amz-server-side-encryption");
        result.storage_class = headers.get_string("x-amz-storage-class");
        result.version_id = headers.get_string("x-amz-version-id");
        result.website_redirect_location = headers.get_string("x-amz-website-redirect-location");
        result
    }
}

#[cfg(feature = "with-tokio")]
impl From<&reqwest::header::HeaderMap> for HeadObjectResult {
    fn from(headers: &reqwest::header::HeaderMap) -> Self {
        let mut result = HeadObjectResult {
            accept_ranges: headers
                .get("accept-ranges")
                .map(|v| v.to_str().unwrap_or_default().to_string()),
            cache_control: headers
                .get("Cache-Control")
                .map(|v| v.to_str().unwrap_or_default().to_string()),
            content_disposition: headers
                .get("Content-Disposition")
                .map(|v| v.to_str().unwrap_or_default().to_string()),
            content_encoding: headers
                .get("Content-Encoding")
                .map(|v| v.to_str().unwrap_or_default().to_string()),
            content_language: headers
                .get("Content-Language")
                .map(|v| v.to_str().unwrap_or_default().to_string()),
            content_length: headers
                .get("Content-Length")
                .map(|v| v.to_str().unwrap_or_default().parse().unwrap_or_default()),
            content_type: headers
                .get("Content-Type")
                .map(|v| v.to_str().unwrap_or_default().to_string()),
            delete_marker: headers
                .get("x-amz-delete-marker")
                .map(|v| v.to_str().unwrap_or_default().parse().unwrap_or_default()),
            e_tag: headers
                .get("ETag")
                .map(|v| v.to_str().unwrap_or_default().to_string()),
            expiration: headers
                .get("x-amz-expiration")
                .map(|v| v.to_str().unwrap_or_default().to_string()),
            expires: headers
                .get("Expires")
                .map(|v| v.to_str().unwrap_or_default().to_string()),
            last_modified: headers
                .get("Last-Modified")
                .map(|v| v.to_str().unwrap_or_default().to_string()),
            ..Default::default()
        };
        let mut values = ::std::collections::HashMap::new();
        for (key, value) in headers.iter() {
            if key.as_str().starts_with("x-amz-meta-")
                && let Ok(value) = value.to_str()
            {
                values.insert(
                    key.as_str()["x-amz-meta-".len()..].to_owned(),
                    value.to_owned(),
                );
            }
        }
        result.metadata = Some(values);
        result.missing_meta = headers
            .get("x-amz-missing-meta")
            .map(|v| v.to_str().unwrap_or_default().parse().unwrap_or_default());
        result.object_lock_legal_hold_status = headers
            .get("x-amz-object-lock-legal-hold")
            .map(|v| v.to_str().unwrap_or_default().to_string());
        result.object_lock_mode = headers
            .get("x-amz-object-lock-mode")
            .map(|v| v.to_str().unwrap_or_default().to_string());
        result.object_lock_retain_until_date = headers
            .get("x-amz-object-lock-retain-until-date")
            .map(|v| v.to_str().unwrap_or_default().to_string());
        result.parts_count = headers
            .get("x-amz-mp-parts-count")
            .map(|v| v.to_str().unwrap_or_default().parse().unwrap_or_default());
        result.replication_status = headers
            .get("x-amz-replication-status")
            .map(|v| v.to_str().unwrap_or_default().to_string());
        result.request_charged = headers
            .get("x-amz-request-charged")
            .map(|v| v.to_str().unwrap_or_default().to_string());
        result.restore = headers
            .get("x-amz-restore")
            .map(|v| v.to_str().unwrap_or_default().to_string());
        result.sse_customer_algorithm = headers
            .get("x-amz-server-side-encryption-customer-algorithm")
            .map(|v| v.to_str().unwrap_or_default().to_string());
        result.sse_customer_key_md5 = headers
            .get("x-amz-server-side-encryption-customer-key-MD5")
            .map(|v| v.to_str().unwrap_or_default().to_string());
        result.ssekms_key_id = headers
            .get("x-amz-server-side-encryption-aws-kms-key-id")
            .map(|v| v.to_str().unwrap_or_default().to_string());
        result.server_side_encryption = headers
            .get("x-amz-server-side-encryption")
            .map(|v| v.to_str().unwrap_or_default().to_string());
        result.storage_class = headers
            .get("x-amz-storage-class")
            .map(|v| v.to_str().unwrap_or_default().to_string());
        result.version_id = headers
            .get("x-amz-version-id")
            .map(|v| v.to_str().unwrap_or_default().to_string());
        result.website_redirect_location = headers
            .get("x-amz-website-redirect-location")
            .map(|v| v.to_str().unwrap_or_default().to_string());
        result
    }
}

#[cfg(feature = "sync")]
impl From<&attohttpc::header::HeaderMap> for HeadObjectResult {
    fn from(headers: &attohttpc::header::HeaderMap) -> Self {
        let mut result = HeadObjectResult {
            accept_ranges: headers
                .get("accept-ranges")
                .map(|v| v.to_str().unwrap_or_default().to_string()),
            cache_control: headers
                .get("Cache-Control")
                .map(|v| v.to_str().unwrap_or_default().to_string()),
            content_disposition: headers
                .get("Content-Disposition")
                .map(|v| v.to_str().unwrap_or_default().to_string()),
            content_encoding: headers
                .get("Content-Encoding")
                .map(|v| v.to_str().unwrap_or_default().to_string()),
            content_language: headers
                .get("Content-Language")
                .map(|v| v.to_str().unwrap_or_default().to_string()),
            content_length: headers
                .get("Content-Length")
                .map(|v| v.to_str().unwrap_or_default().parse().unwrap_or_default()),
            content_type: headers
                .get("get-Type")
                .map(|v| v.to_str().unwrap_or_default().to_string()),
            delete_marker: headers
                .get("x-amz-delete-marker")
                .map(|v| v.to_str().unwrap_or_default().parse().unwrap_or_default()),
            e_tag: headers
                .get("ETag")
                .map(|v| v.to_str().unwrap_or_default().to_string()),
            expiration: headers
                .get("x-amz-expiration")
                .map(|v| v.to_str().unwrap_or_default().to_string()),
            expires: headers
                .get("Expires")
                .map(|v| v.to_str().unwrap_or_default().to_string()),
            last_modified: headers
                .get("Last-Modified")
                .map(|v| v.to_str().unwrap_or_default().to_string()),
            ..Default::default()
        };
        let mut values = ::std::collections::HashMap::new();
        for (key, value) in headers.iter() {
            if key.as_str().starts_with("x-amz-meta-")
                && let Ok(value) = value.to_str()
            {
                values.insert(
                    key.as_str()["x-amz-meta-".len()..].to_owned(),
                    value.to_owned(),
                );
            }
        }
        result.metadata = Some(values);
        result.missing_meta = headers
            .get("x-amz-missing-meta")
            .map(|v| v.to_str().unwrap_or_default().parse().unwrap_or_default());
        result.object_lock_legal_hold_status = headers
            .get("x-amz-object-lock-legal-hold")
            .map(|v| v.to_str().unwrap_or_default().to_string());
        result.object_lock_mode = headers
            .get("x-amz-object-lock-mode")
            .map(|v| v.to_str().unwrap_or_default().to_string());
        result.object_lock_retain_until_date = headers
            .get("x-amz-object-lock-retain-until-date")
            .map(|v| v.to_str().unwrap_or_default().to_string());
        result.parts_count = headers
            .get("x-amz-mp-parts-count")
            .map(|v| v.to_str().unwrap_or_default().parse().unwrap_or_default());
        result.replication_status = headers
            .get("x-amz-replication-status")
            .map(|v| v.to_str().unwrap_or_default().to_string());
        result.request_charged = headers
            .get("x-amz-request-charged")
            .map(|v| v.to_str().unwrap_or_default().to_string());
        result.restore = headers
            .get("x-amz-restore")
            .map(|v| v.to_str().unwrap_or_default().to_string());
        result.sse_customer_algorithm = headers
            .get("x-amz-server-side-encryption-customer-algorithm")
            .map(|v| v.to_str().unwrap_or_default().to_string());
        result.sse_customer_key_md5 = headers
            .get("x-amz-server-side-encryption-customer-key-MD5")
            .map(|v| v.to_str().unwrap_or_default().to_string());
        result.ssekms_key_id = headers
            .get("x-amz-server-side-encryption-aws-kms-key-id")
            .map(|v| v.to_str().unwrap_or_default().to_string());
        result.server_side_encryption = headers
            .get("x-amz-server-side-encryption")
            .map(|v| v.to_str().unwrap_or_default().to_string());
        result.storage_class = headers
            .get("x-amz-storage-class")
            .map(|v| v.to_str().unwrap_or_default().to_string());
        result.version_id = headers
            .get("x-amz-version-id")
            .map(|v| v.to_str().unwrap_or_default().to_string());
        result.website_redirect_location = headers
            .get("x-amz-website-redirect-location")
            .map(|v| v.to_str().unwrap_or_default().to_string());
        result
    }
}

pub(crate) fn error_from_response_data(response_data: ResponseData) -> Result<S3Error, S3Error> {
    let utf8_content = String::from_utf8(response_data.as_slice().to_vec())?;
    Err(S3Error::HttpFailWithBody(
        response_data.status_code(),
        utf8_content,
    ))
}

/// Retries a given expression a specified number of times with exponential backoff.
///
/// This macro attempts to execute the provided expression up to `N` times, where `N`
/// is the value set by `set_retries`. If the expression returns `Ok`, it returns the value.
/// If the expression returns `Err`, it logs a warning and retries after a delay that increases
/// exponentially with each retry.
///
/// The delay between retries is calculated as `1 * retry_cnt.pow(2)` seconds, where `retry_cnt`
/// is the current retry attempt.
///
/// This macro supports both asynchronous and synchronous contexts:
/// - For `tokio` users, it uses `tokio::time::sleep`.
/// - For `async-std` users, it uses `async_std::task::sleep`.
/// - For synchronous contexts, it uses `std::thread::sleep`.
///
/// # Features
///
/// - `with-tokio`: Uses `tokio::time::sleep` for async retries.
/// - `with-async-std`: Uses `async_std::task::sleep` for async retries.
/// - `sync`: Uses `std::thread::sleep` for sync retries.
///
/// # Errors
///
/// If all retry attempts fail, the last error is returned.
#[macro_export]
macro_rules! retry {
    ($e:expr) => {{
        let mut retry_cnt: u64 = 0;
        let max_retries = $crate::get_retries() as u64;

        loop {
            match $e {
                Ok(v) => break Ok(v),
                Err(e) => {
                    log::warn!("Retrying {e}");
                    if retry_cnt >= max_retries {
                        break Err(e);
                    }
                    retry_cnt += 1;
                    let delay = std::time::Duration::from_secs(1 * retry_cnt.pow(2));
                    #[cfg(feature = "with-tokio")]
                    tokio::time::sleep(delay).await;
                    #[cfg(feature = "with-async-std")]
                    async_std::task::sleep(delay).await;
                    #[cfg(feature = "sync")]
                    std::thread::sleep(delay);
                    continue;
                }
            }
        }
    }};
}

#[cfg(test)]
mod test {
    use crate::utils::etag_for_path;
    use std::fs::File;
    use std::io::Cursor;
    use std::io::prelude::*;
    use std::path::PathBuf;

    fn object(size: u32) -> Vec<u8> {
        (0..size).map(|_| 33).collect()
    }

    fn etag_test_path(test_name: &str) -> PathBuf {
        let mut path = std::env::temp_dir();
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();

        path.push(format!(
            "rust-s3-{test_name}-{}-{unique}",
            std::process::id()
        ));
        path
    }

    #[test]
    fn test_etag_large_file() {
        let path = etag_test_path("etag-large-file");
        std::fs::remove_file(&path).unwrap_or(());
        let test: Vec<u8> = object(10_000_000);

        let mut file = File::create(&path).unwrap();
        file.write_all(&test).unwrap();

        let etag = etag_for_path(&path).unwrap();

        std::fs::remove_file(&path).unwrap_or(());

        assert_eq!(etag, "e438487f09f09c042b2de097765e5ac2-2");
    }

    #[test]
    fn test_etag_small_file() {
        let path = etag_test_path("etag-small-file");
        std::fs::remove_file(&path).unwrap_or(());
        let test: Vec<u8> = object(1000);

        let mut file = File::create(&path).unwrap();
        file.write_all(&test).unwrap();

        let etag = etag_for_path(&path).unwrap();

        std::fs::remove_file(&path).unwrap_or(());

        assert_eq!(etag, "8122ef1c2b2331f7986349560248cf56");
    }

    #[test]
    fn test_read_chunk_all_zero() {
        let blob = vec![0u8; 10_000_000];
        let mut blob = Cursor::new(blob);

        let result = super::read_chunk(&mut blob).unwrap();

        assert_eq!(result.len(), crate::bucket::CHUNK_SIZE);
    }

    #[test]
    fn test_read_chunk_multi_chunk() {
        let blob = vec![1u8; 10_000_000];
        let mut blob = Cursor::new(blob);

        let result = super::read_chunk(&mut blob).unwrap();
        assert_eq!(result.len(), crate::bucket::CHUNK_SIZE);

        let result = super::read_chunk(&mut blob).unwrap();
        assert_eq!(result.len(), 1_611_392);
    }
}
