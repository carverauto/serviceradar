//! Builder pattern for S3 PUT operations with customizable options
//!
//! This module provides a builder pattern for constructing PUT requests with
//! various options including custom headers, content type, and other metadata.

use crate::error::S3Error;
use crate::request::{Request as _, ResponseData};
use crate::{Bucket, command::Command};
use http::{HeaderMap, HeaderName, HeaderValue};

#[cfg(feature = "with-tokio")]
use tokio::io::AsyncRead;

#[cfg(feature = "with-async-std")]
use async_std::io::Read as AsyncRead;

#[cfg(feature = "with-async-std")]
use crate::request::async_std_backend::SurfRequest as RequestImpl;
#[cfg(feature = "sync")]
use crate::request::blocking::AttoRequest as RequestImpl;
#[cfg(feature = "with-tokio")]
use crate::request::tokio_backend::ReqwestRequest as RequestImpl;

/// Builder for constructing S3 PUT object requests with custom options
///
/// # Example
/// ```no_run
/// use s3::bucket::Bucket;
/// use s3::creds::Credentials;
/// use anyhow::Result;
///
/// # #[tokio::main]
/// # async fn main() -> Result<()> {
/// let bucket = Bucket::new("my-bucket", "us-east-1".parse()?, Credentials::default()?)?;
///
/// // Upload with custom headers using builder pattern
/// let response = bucket.put_object_builder("/my-file.txt", b"Hello, World!")
///     .with_content_type("text/plain")
///     .with_cache_control("public, max-age=3600")?
///     .with_content_encoding("gzip")?
///     .execute()
///     .await?;
/// # Ok(())
/// # }
/// ```
#[derive(Debug, Clone)]
pub struct PutObjectRequest<'a> {
    bucket: &'a Bucket,
    path: String,
    content: Vec<u8>,
    content_type: String,
    custom_headers: HeaderMap,
}

impl<'a> PutObjectRequest<'a> {
    /// Create a new PUT object request builder
    pub(crate) fn new<S: AsRef<str>>(bucket: &'a Bucket, path: S, content: &[u8]) -> Self {
        Self {
            bucket,
            path: path.as_ref().to_string(),
            content: content.to_vec(),
            content_type: "application/octet-stream".to_string(),
            custom_headers: HeaderMap::new(),
        }
    }

    /// Set the Content-Type header
    pub fn with_content_type<S: AsRef<str>>(mut self, content_type: S) -> Self {
        self.content_type = content_type.as_ref().to_string();
        self
    }

    /// Set the Cache-Control header
    pub fn with_cache_control<S: AsRef<str>>(mut self, cache_control: S) -> Result<Self, S3Error> {
        let value = cache_control
            .as_ref()
            .parse::<HeaderValue>()
            .map_err(S3Error::InvalidHeaderValue)?;
        self.custom_headers
            .insert(http::header::CACHE_CONTROL, value);
        Ok(self)
    }

    /// Set the Content-Encoding header
    pub fn with_content_encoding<S: AsRef<str>>(mut self, encoding: S) -> Result<Self, S3Error> {
        let value = encoding
            .as_ref()
            .parse::<HeaderValue>()
            .map_err(S3Error::InvalidHeaderValue)?;
        self.custom_headers
            .insert(http::header::CONTENT_ENCODING, value);
        Ok(self)
    }

    /// Set the Content-Disposition header
    pub fn with_content_disposition<S: AsRef<str>>(
        mut self,
        disposition: S,
    ) -> Result<Self, S3Error> {
        let value = disposition
            .as_ref()
            .parse::<HeaderValue>()
            .map_err(S3Error::InvalidHeaderValue)?;
        self.custom_headers
            .insert(http::header::CONTENT_DISPOSITION, value);
        Ok(self)
    }

    /// Set the Expires header
    pub fn with_expires<S: AsRef<str>>(mut self, expires: S) -> Result<Self, S3Error> {
        let value = expires
            .as_ref()
            .parse::<HeaderValue>()
            .map_err(S3Error::InvalidHeaderValue)?;
        self.custom_headers.insert(http::header::EXPIRES, value);
        Ok(self)
    }

    /// Add a custom header
    pub fn with_header<V>(mut self, key: &str, value: V) -> Result<Self, S3Error>
    where
        V: AsRef<str>,
    {
        let header_name = HeaderName::from_bytes(key.as_bytes())?;
        let header_value = value
            .as_ref()
            .parse::<HeaderValue>()
            .map_err(S3Error::InvalidHeaderValue)?;
        self.custom_headers.insert(header_name, header_value);
        Ok(self)
    }

    /// Add multiple custom headers (already validated HeaderMap)
    pub fn with_headers(mut self, headers: HeaderMap) -> Self {
        self.custom_headers.extend(headers);
        self
    }

    /// Add S3 metadata header (x-amz-meta-*)
    pub fn with_metadata<K: AsRef<str>, V: AsRef<str>>(
        mut self,
        key: K,
        value: V,
    ) -> Result<Self, S3Error> {
        let header_name = format!("x-amz-meta-{}", key.as_ref());
        let name = header_name.parse::<http::HeaderName>()?;
        let value = value
            .as_ref()
            .parse::<HeaderValue>()
            .map_err(S3Error::InvalidHeaderValue)?;
        self.custom_headers.insert(name, value);
        Ok(self)
    }

    /// Add x-amz-storage-class header
    pub fn with_storage_class<S: AsRef<str>>(mut self, storage_class: S) -> Result<Self, S3Error> {
        let header_value = storage_class
            .as_ref()
            .parse::<HeaderValue>()
            .map_err(S3Error::InvalidHeaderValue)?;
        self.custom_headers.insert(
            http::HeaderName::from_static("x-amz-storage-class"),
            header_value,
        );
        Ok(self)
    }

    /// Add x-amz-server-side-encryption header
    pub fn with_server_side_encryption<S: AsRef<str>>(
        mut self,
        encryption: S,
    ) -> Result<Self, S3Error> {
        let header_value = encryption
            .as_ref()
            .parse::<HeaderValue>()
            .map_err(S3Error::InvalidHeaderValue)?;
        self.custom_headers.insert(
            http::HeaderName::from_static("x-amz-server-side-encryption"),
            header_value,
        );
        Ok(self)
    }

    /// Execute the PUT request
    #[maybe_async::maybe_async]
    pub async fn execute(self) -> Result<ResponseData, S3Error> {
        let command = Command::PutObject {
            content: &self.content,
            content_type: &self.content_type,
            custom_headers: if self.custom_headers.is_empty() {
                None
            } else {
                Some(self.custom_headers)
            },
            multipart: None,
        };

        let request = RequestImpl::new(self.bucket, &self.path, command).await?;
        request.response_data(true).await
    }
}

/// Builder for streaming PUT operations
#[cfg(any(feature = "with-tokio", feature = "with-async-std"))]
#[derive(Debug, Clone)]
pub struct PutObjectStreamRequest<'a> {
    bucket: &'a Bucket,
    path: String,
    content_type: String,
    custom_headers: HeaderMap,
}

#[cfg(any(feature = "with-tokio", feature = "with-async-std"))]
impl<'a> PutObjectStreamRequest<'a> {
    /// Create a new streaming PUT request builder
    pub(crate) fn new<S: AsRef<str>>(bucket: &'a Bucket, path: S) -> Self {
        Self {
            bucket,
            path: path.as_ref().to_string(),
            content_type: "application/octet-stream".to_string(),
            custom_headers: HeaderMap::new(),
        }
    }

    /// Set the Content-Type header
    pub fn with_content_type<S: AsRef<str>>(mut self, content_type: S) -> Self {
        self.content_type = content_type.as_ref().to_string();
        self
    }

    /// Set the Cache-Control header
    pub fn with_cache_control<S: AsRef<str>>(mut self, cache_control: S) -> Result<Self, S3Error> {
        let value = cache_control
            .as_ref()
            .parse::<HeaderValue>()
            .map_err(S3Error::InvalidHeaderValue)?;
        self.custom_headers
            .insert(http::header::CACHE_CONTROL, value);
        Ok(self)
    }

    /// Set the Content-Encoding header
    pub fn with_content_encoding<S: AsRef<str>>(mut self, encoding: S) -> Result<Self, S3Error> {
        let value = encoding
            .as_ref()
            .parse::<HeaderValue>()
            .map_err(S3Error::InvalidHeaderValue)?;
        self.custom_headers
            .insert(http::header::CONTENT_ENCODING, value);
        Ok(self)
    }

    /// Add a custom header
    pub fn with_header<K, V>(mut self, key: K, value: V) -> Result<Self, S3Error>
    where
        K: Into<http::HeaderName>,
        V: AsRef<str>,
    {
        let header_value = value
            .as_ref()
            .parse::<HeaderValue>()
            .map_err(S3Error::InvalidHeaderValue)?;
        self.custom_headers.insert(key.into(), header_value);
        Ok(self)
    }

    /// Add multiple custom headers (already validated HeaderMap)
    pub fn with_headers(mut self, headers: HeaderMap) -> Self {
        self.custom_headers.extend(headers);
        self
    }

    /// Add S3 metadata header (x-amz-meta-*)
    pub fn with_metadata<K: AsRef<str>, V: AsRef<str>>(
        mut self,
        key: K,
        value: V,
    ) -> Result<Self, S3Error> {
        let header_name = format!("x-amz-meta-{}", key.as_ref());
        let name = header_name.parse::<http::HeaderName>()?;
        let value = value
            .as_ref()
            .parse::<HeaderValue>()
            .map_err(S3Error::InvalidHeaderValue)?;
        self.custom_headers.insert(name, value);
        Ok(self)
    }

    /// Execute the streaming PUT request
    #[cfg(feature = "with-tokio")]
    pub async fn execute_stream<R: AsyncRead + Unpin + ?Sized>(
        self,
        reader: &mut R,
    ) -> Result<crate::utils::PutStreamResponse, S3Error> {
        // AsyncReadExt trait is not used here

        self.bucket
            ._put_object_stream_with_content_type_and_headers(
                reader,
                &self.path,
                &self.content_type,
                if self.custom_headers.is_empty() {
                    None
                } else {
                    Some(self.custom_headers)
                },
            )
            .await
    }

    #[cfg(feature = "with-async-std")]
    pub async fn execute_stream<R: AsyncRead + Unpin + ?Sized>(
        self,
        reader: &mut R,
    ) -> Result<crate::utils::PutStreamResponse, S3Error> {
        self.bucket
            ._put_object_stream_with_content_type_and_headers(
                reader,
                &self.path,
                &self.content_type,
                if self.custom_headers.is_empty() {
                    None
                } else {
                    Some(self.custom_headers)
                },
            )
            .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Region;
    use crate::creds::Credentials;

    #[test]
    fn test_builder_chain() {
        let bucket =
            Bucket::new("test", Region::UsEast1, Credentials::anonymous().unwrap()).unwrap();

        let content = b"test content";
        let request = PutObjectRequest::new(&bucket, "/test.txt", content)
            .with_content_type("text/plain")
            .with_cache_control("max-age=3600")
            .unwrap()
            .with_content_encoding("gzip")
            .unwrap()
            .with_metadata("author", "test-user")
            .unwrap()
            .with_header("x-custom", "value")
            .unwrap()
            .with_storage_class("STANDARD_IA")
            .unwrap();

        assert_eq!(request.content_type, "text/plain");
        assert!(
            request
                .custom_headers
                .contains_key(http::header::CACHE_CONTROL)
        );
        assert!(
            request
                .custom_headers
                .contains_key(http::header::CONTENT_ENCODING)
        );
        assert!(request.custom_headers.contains_key("x-amz-meta-author"));
        assert!(request.custom_headers.contains_key("x-custom"));
        assert!(request.custom_headers.contains_key("x-amz-storage-class"));
    }

    #[test]
    fn test_metadata_headers() {
        let bucket =
            Bucket::new("test", Region::UsEast1, Credentials::anonymous().unwrap()).unwrap();

        let request = PutObjectRequest::new(&bucket, "/test.txt", b"test")
            .with_metadata("key1", "value1")
            .unwrap()
            .with_metadata("key2", "value2")
            .unwrap();

        assert!(request.custom_headers.contains_key("x-amz-meta-key1"));
        assert!(request.custom_headers.contains_key("x-amz-meta-key2"));
    }
}
