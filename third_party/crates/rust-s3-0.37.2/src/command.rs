//! This module defines and manages various commands used for interacting with Amazon S3, encapsulating common operations such as creating buckets, uploading objects, and managing multipart uploads.
//! It also provides utilities for calculating necessary metadata (like content length and SHA-256 hashes) required for secure and efficient communication with the S3 service.
//!
//! ## Key Components
//!
//! - **HttpMethod Enum**
//!   - Represents HTTP methods used in S3 operations, including `GET`, `PUT`, `DELETE`, `POST`, and `HEAD`.
//!   - Implements `fmt::Display` for easy conversion to string representations suitable for HTTP requests.
//!
//! - **Multipart Struct**
//!   - Represents a part of a multipart upload, containing the part number and the associated upload ID.
//!   - Provides methods for constructing a new multipart part and generating a query string for the S3 API.
//!
//! - **Command Enum**
//!   - The core of this module, encapsulating various S3 operations, such as:
//!     - Object management (`GetObject`, `PutObject`, `DeleteObject`, etc.)
//!     - Bucket management (`CreateBucket`, `DeleteBucket`, etc.)
//!     - Multipart upload management (`InitiateMultipartUpload`, `UploadPart`, `CompleteMultipartUpload`, etc.)
//!   - For each command, you can determine the associated HTTP method using `http_verb()` and calculate the content length or content type using `content_length()` and `content_type()` respectively.
//!   - The `sha256()` method computes the SHA-256 hash of the request payload, a critical part of S3's security features.
//!
use std::collections::HashMap;

use crate::error::S3Error;
use crate::serde_types::{
    BucketLifecycleConfiguration, CompleteMultipartUploadData, CorsConfiguration,
    DeleteObjectsRequest,
};

use crate::EMPTY_PAYLOAD_SHA;
use sha2::{Digest, Sha256};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum HttpMethod {
    Delete,
    Get,
    Put,
    Post,
    Head,
}

use std::fmt;

impl fmt::Display for HttpMethod {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            HttpMethod::Delete => write!(f, "DELETE"),
            HttpMethod::Get => write!(f, "GET"),
            HttpMethod::Post => write!(f, "POST"),
            HttpMethod::Put => write!(f, "PUT"),
            HttpMethod::Head => write!(f, "HEAD"),
        }
    }
}
use crate::bucket_ops::BucketConfiguration;
use http::HeaderMap;

#[derive(Clone, Debug)]
pub struct Multipart<'a> {
    part_number: u32,
    upload_id: &'a str,
}

impl<'a> Multipart<'a> {
    pub fn query_string(&self) -> String {
        format!(
            "?partNumber={}&uploadId={}",
            self.part_number, self.upload_id
        )
    }

    pub fn new(part_number: u32, upload_id: &'a str) -> Self {
        Multipart {
            part_number,
            upload_id,
        }
    }
}

#[derive(Clone, Debug)]
pub enum Command<'a> {
    HeadObject,
    CopyObject {
        from: &'a str,
    },
    DeleteObject,
    DeleteObjectTagging,
    GetObject,
    GetObjectTorrent,
    GetObjectRange {
        start: u64,
        end: Option<u64>,
    },
    GetObjectTagging,
    PutObject {
        content: &'a [u8],
        content_type: &'a str,
        custom_headers: Option<HeaderMap>,
        multipart: Option<Multipart<'a>>,
    },
    PutObjectTagging {
        tags: &'a str,
    },
    ListMultipartUploads {
        prefix: Option<&'a str>,
        delimiter: Option<&'a str>,
        key_marker: Option<String>,
        max_uploads: Option<usize>,
    },
    ListObjects {
        prefix: String,
        delimiter: Option<String>,
        marker: Option<String>,
        max_keys: Option<usize>,
    },
    ListObjectsV2 {
        prefix: String,
        delimiter: Option<String>,
        continuation_token: Option<String>,
        start_after: Option<String>,
        max_keys: Option<usize>,
    },
    GetBucketLocation,
    PresignGet {
        expiry_secs: u32,
        custom_queries: Option<HashMap<String, String>>,
    },
    PresignPut {
        expiry_secs: u32,
        custom_headers: Option<HeaderMap>,
        custom_queries: Option<HashMap<String, String>>,
    },
    PresignDelete {
        expiry_secs: u32,
    },
    InitiateMultipartUpload {
        content_type: &'a str,
    },
    UploadPart {
        part_number: u32,
        content: &'a [u8],
        upload_id: &'a str,
    },
    AbortMultipartUpload {
        upload_id: &'a str,
    },
    CompleteMultipartUpload {
        upload_id: &'a str,
        data: CompleteMultipartUploadData,
    },
    CreateBucket {
        config: BucketConfiguration,
    },
    DeleteBucket,
    ListBuckets,
    GetBucketCors {
        expected_bucket_owner: String,
    },
    PutBucketCors {
        expected_bucket_owner: String,
        configuration: CorsConfiguration,
    },
    DeleteBucketCors {
        expected_bucket_owner: String,
    },
    GetBucketLifecycle,
    PutBucketLifecycle {
        configuration: BucketLifecycleConfiguration,
    },
    DeleteBucketLifecycle,
    GetObjectAttributes {
        expected_bucket_owner: String,
        version_id: Option<String>,
    },
    DeleteObjects {
        data: DeleteObjectsRequest,
    },
}

impl<'a> Command<'a> {
    pub fn http_verb(&self) -> HttpMethod {
        match *self {
            Command::GetObject
            | Command::GetObjectTorrent
            | Command::GetBucketCors { .. }
            | Command::GetObjectRange { .. }
            | Command::ListBuckets
            | Command::ListObjects { .. }
            | Command::ListObjectsV2 { .. }
            | Command::GetBucketLocation
            | Command::GetObjectTagging
            | Command::GetBucketLifecycle
            | Command::ListMultipartUploads { .. }
            | Command::PresignGet { .. } => HttpMethod::Get,
            Command::PutObject { .. }
            | Command::CopyObject { from: _ }
            | Command::PutObjectTagging { .. }
            | Command::PresignPut { .. }
            | Command::UploadPart { .. }
            | Command::PutBucketCors { .. }
            | Command::CreateBucket { .. }
            | Command::PutBucketLifecycle { .. } => HttpMethod::Put,
            Command::DeleteObject
            | Command::DeleteObjectTagging
            | Command::AbortMultipartUpload { .. }
            | Command::PresignDelete { .. }
            | Command::DeleteBucket
            | Command::DeleteBucketCors { .. }
            | Command::DeleteBucketLifecycle => HttpMethod::Delete,
            Command::InitiateMultipartUpload { .. }
            | Command::CompleteMultipartUpload { .. }
            | Command::DeleteObjects { .. } => HttpMethod::Post,
            Command::HeadObject => HttpMethod::Head,
            Command::GetObjectAttributes { .. } => HttpMethod::Get,
        }
    }

    pub fn content_length(&self) -> Result<usize, S3Error> {
        let result = match &self {
            Command::CopyObject { from: _ } => 0,
            Command::PutObject { content, .. } => content.len(),
            Command::PutObjectTagging { tags } => tags.len(),
            Command::UploadPart { content, .. } => content.len(),
            Command::CompleteMultipartUpload { data, .. } => data.len(),
            Command::CreateBucket { config } => {
                if let Some(payload) = config.location_constraint_payload() {
                    Vec::from(payload).len()
                } else {
                    0
                }
            }
            Command::PutBucketLifecycle { configuration } => {
                quick_xml::se::to_string(configuration)?.len()
            }
            Command::PutBucketCors { configuration, .. } => configuration.to_string().len(),
            Command::HeadObject => 0,
            Command::DeleteObject => 0,
            Command::DeleteObjectTagging => 0,
            Command::GetObject => 0,
            Command::GetObjectTorrent => 0,
            Command::GetObjectRange { .. } => 0,
            Command::GetObjectTagging => 0,
            Command::ListMultipartUploads { .. } => 0,
            Command::ListObjects { .. } => 0,
            Command::ListObjectsV2 { .. } => 0,
            Command::GetBucketLocation => 0,
            Command::PresignGet { .. } => 0,
            Command::PresignPut { .. } => 0,
            Command::PresignDelete { .. } => 0,
            Command::InitiateMultipartUpload { .. } => 0,
            Command::AbortMultipartUpload { .. } => 0,
            Command::DeleteBucket => 0,
            Command::ListBuckets => 0,
            Command::GetBucketCors { .. } => 0,
            Command::DeleteBucketCors { .. } => 0,
            Command::GetBucketLifecycle => 0,
            Command::DeleteBucketLifecycle { .. } => 0,
            Command::GetObjectAttributes { .. } => 0,
            Command::DeleteObjects { data } => data.len(),
        };
        Ok(result)
    }

    pub fn content_type(&self) -> String {
        match self {
            Command::InitiateMultipartUpload { content_type } => content_type.to_string(),
            Command::PutObject { content_type, .. } => content_type.to_string(),
            Command::CompleteMultipartUpload { .. }
            | Command::PutBucketLifecycle { .. }
            | Command::PutBucketCors { .. } => "application/xml".into(),
            Command::HeadObject => "text/plain".into(),
            Command::DeleteObject => "text/plain".into(),
            Command::DeleteObjectTagging => "text/plain".into(),
            Command::GetObject => "text/plain".into(),
            Command::GetObjectTorrent => "text/plain".into(),
            Command::GetObjectRange { .. } => "text/plain".into(),
            Command::GetObjectTagging => "text/plain".into(),
            Command::ListMultipartUploads { .. } => "text/plain".into(),
            Command::ListObjects { .. } => "text/plain".into(),
            Command::ListObjectsV2 { .. } => "text/plain".into(),
            Command::GetBucketLocation => "text/plain".into(),
            Command::PresignGet { .. } => "text/plain".into(),
            Command::PresignPut { .. } => "text/plain".into(),
            Command::PresignDelete { .. } => "text/plain".into(),
            Command::AbortMultipartUpload { .. } => "text/plain".into(),
            Command::DeleteBucket => "text/plain".into(),
            Command::ListBuckets => "text/plain".into(),
            Command::GetBucketCors { .. } => "text/plain".into(),
            Command::DeleteBucketCors { .. } => "text/plain".into(),
            Command::GetBucketLifecycle => "text/plain".into(),
            Command::DeleteBucketLifecycle { .. } => "text/plain".into(),
            Command::CopyObject { .. } => "text/plain".into(),
            Command::PutObjectTagging { .. } => "text/plain".into(),
            Command::UploadPart { .. } => "text/plain".into(),
            Command::CreateBucket { .. } => "text/plain".into(),
            Command::GetObjectAttributes { .. } => "text/plain".into(),
            Command::DeleteObjects { .. } => "application/xml".into(),
        }
    }

    pub fn sha256(&self) -> Result<String, S3Error> {
        let result = match &self {
            Command::PutObject { content, .. } => {
                let mut sha = Sha256::default();
                sha.update(content);
                hex::encode(sha.finalize().as_slice())
            }
            Command::PutObjectTagging { tags } => {
                let mut sha = Sha256::default();
                sha.update(tags.as_bytes());
                hex::encode(sha.finalize().as_slice())
            }
            Command::CompleteMultipartUpload { data, .. } => {
                let mut sha = Sha256::default();
                sha.update(data.to_string().as_bytes());
                hex::encode(sha.finalize().as_slice())
            }
            Command::CreateBucket { config } => {
                if let Some(payload) = config.location_constraint_payload() {
                    let mut sha = Sha256::default();
                    sha.update(payload.as_bytes());
                    hex::encode(sha.finalize().as_slice())
                } else {
                    EMPTY_PAYLOAD_SHA.into()
                }
            }
            Command::PutBucketLifecycle { configuration } => {
                let mut sha = Sha256::default();
                sha.update(quick_xml::se::to_string(configuration)?.as_bytes());
                hex::encode(sha.finalize().as_slice())
            }
            Command::PutBucketCors { configuration, .. } => {
                let mut sha = Sha256::default();
                sha.update(configuration.to_string().as_bytes());
                hex::encode(sha.finalize().as_slice())
            }
            Command::HeadObject => EMPTY_PAYLOAD_SHA.into(),
            Command::DeleteObject => EMPTY_PAYLOAD_SHA.into(),
            Command::DeleteObjectTagging => EMPTY_PAYLOAD_SHA.into(),
            Command::GetObject => EMPTY_PAYLOAD_SHA.into(),
            Command::GetObjectTorrent => EMPTY_PAYLOAD_SHA.into(),
            Command::GetObjectRange { .. } => EMPTY_PAYLOAD_SHA.into(),
            Command::GetObjectTagging => EMPTY_PAYLOAD_SHA.into(),
            Command::ListMultipartUploads { .. } => EMPTY_PAYLOAD_SHA.into(),
            Command::ListObjects { .. } => EMPTY_PAYLOAD_SHA.into(),
            Command::ListObjectsV2 { .. } => EMPTY_PAYLOAD_SHA.into(),
            Command::GetBucketLocation => EMPTY_PAYLOAD_SHA.into(),
            Command::PresignGet { .. } => EMPTY_PAYLOAD_SHA.into(),
            Command::PresignPut { .. } => EMPTY_PAYLOAD_SHA.into(),
            Command::PresignDelete { .. } => EMPTY_PAYLOAD_SHA.into(),
            Command::AbortMultipartUpload { .. } => EMPTY_PAYLOAD_SHA.into(),
            Command::DeleteBucket => EMPTY_PAYLOAD_SHA.into(),
            Command::ListBuckets => EMPTY_PAYLOAD_SHA.into(),
            Command::GetBucketCors { .. } => EMPTY_PAYLOAD_SHA.into(),
            Command::DeleteBucketCors { .. } => EMPTY_PAYLOAD_SHA.into(),
            Command::GetBucketLifecycle => EMPTY_PAYLOAD_SHA.into(),
            Command::DeleteBucketLifecycle { .. } => EMPTY_PAYLOAD_SHA.into(),
            Command::CopyObject { .. } => EMPTY_PAYLOAD_SHA.into(),
            Command::UploadPart { .. } => EMPTY_PAYLOAD_SHA.into(),
            Command::InitiateMultipartUpload { .. } => EMPTY_PAYLOAD_SHA.into(),
            Command::GetObjectAttributes { .. } => EMPTY_PAYLOAD_SHA.into(),
            Command::DeleteObjects { data } => {
                let mut sha = Sha256::default();
                sha.update(data.to_string().as_bytes());
                hex::encode(sha.finalize().as_slice())
            }
        };
        Ok(result)
    }
}
