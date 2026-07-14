//! This module provides functionality for creating and managing S3 POST policies, which are used to generate presigned URLs for securely uploading files to S3 with specific conditions and metadata. It handles the generation of necessary conditions, expiration policies, and signing of the POST policy.
//!
//! ## Key Components
//!
//! - **PostPolicy Struct**
//!   - Represents a POST policy that specifies conditions and expiration for an S3 upload.
//!   - Can be constructed with an expiration time and modified by adding conditions for fields like `key`, `acl`, and more.
//!   - Supports building a policy with AWS credentials and signing it to generate a `PresignedPost` object.
//!
//! - **PostPolicyField Enum**
//!   - Enumerates various fields that can be included in a POST policy, such as `key`, `acl`, `content-length-range`, and AWS-specific fields like `x-amz-meta-*`.
//!   - Allows for the addition of custom fields not predefined in the enum.
//!
//! - **PostPolicyValue Enum**
//!   - Represents the value type associated with a `PostPolicyField`, including exact matches, start-with conditions, ranges, and wildcard matches.
//!
//! - **PostPolicyExpiration Enum**
//!   - Defines the expiration of the POST policy, either as a duration from the current time or a specific timestamp.
//!
//! - **PresignedPost Struct**
//!   - Contains the URL and fields necessary for making a POST request to S3, generated after signing a `PostPolicy`.
//!   - Includes dynamic fields for conditions that vary at upload time, such as the key or content length.
//!
//! ## Error Handling
//!
//! - **PostPolicyError Enum**
//!   - Contains error variants that can occur when constructing a POST policy, particularly when there is a mismatch between the expected and provided condition types.

use crate::error::S3Error;
use crate::utils::now_utc;
use crate::{Bucket, LONG_DATETIME, signing};

use awscreds::Rfc3339OffsetDateTime;
use awscreds::error::CredentialsError;
use serde::ser;
use serde::ser::{Serialize, SerializeMap, SerializeSeq, SerializeTuple, Serializer};
use std::borrow::Cow;
use std::collections::HashMap;
use thiserror::Error;
use time::{Duration, OffsetDateTime};

#[derive(Clone, Debug)]
pub struct PostPolicy<'a> {
    expiration: PostPolicyExpiration,
    conditions: ConditionsSerializer<'a>,
}

impl<'a> PostPolicy<'a> {
    pub fn new<T>(expiration: T) -> Self
    where
        T: Into<PostPolicyExpiration>,
    {
        Self {
            expiration: expiration.into(),
            conditions: ConditionsSerializer(Vec::new()),
        }
    }

    /// Build a finalized post policy with credentials
    #[maybe_async::maybe_async]
    async fn build(
        &self,
        now: &OffsetDateTime,
        bucket: &Bucket,
    ) -> Result<PostPolicy<'_>, S3Error> {
        let access_key = bucket.access_key().await?.ok_or(S3Error::Credentials(
            CredentialsError::ConfigMissingAccessKeyId,
        ))?;
        let credential = format!(
            "{}/{}",
            access_key,
            signing::scope_string(now, &bucket.region)?
        );

        let mut post_policy = self
            .clone()
            .condition(
                PostPolicyField::Bucket,
                PostPolicyValue::Exact(Cow::from(bucket.name.clone())),
            )?
            .condition(
                PostPolicyField::AmzAlgorithm,
                PostPolicyValue::Exact(Cow::from("AWS4-HMAC-SHA256")),
            )?
            .condition(
                PostPolicyField::AmzCredential,
                PostPolicyValue::Exact(Cow::from(credential)),
            )?
            .condition(
                PostPolicyField::AmzDate,
                PostPolicyValue::Exact(Cow::from(now.format(LONG_DATETIME)?)),
            )?;

        if let Some(security_token) = bucket.security_token().await? {
            post_policy = post_policy.condition(
                PostPolicyField::AmzSecurityToken,
                PostPolicyValue::Exact(Cow::from(security_token)),
            )?;
        }
        Ok(post_policy.clone())
    }

    fn policy_string(&self) -> Result<String, S3Error> {
        use base64::Engine;
        use base64::engine::general_purpose;

        let data = serde_json::to_string(self)?;

        Ok(general_purpose::STANDARD.encode(data))
    }

    #[maybe_async::maybe_async]
    pub async fn sign(&self, bucket: Box<Bucket>) -> Result<PresignedPost, S3Error> {
        use hmac::Mac;

        bucket.credentials_refresh().await?;
        let now = now_utc();

        let policy = self.build(&now, &bucket).await?;
        let policy_string = policy.policy_string()?;

        let signing_key = signing::signing_key(
            &now,
            &bucket.secret_key().await?.ok_or(S3Error::Credentials(
                CredentialsError::ConfigMissingSecretKey,
            ))?,
            &bucket.region,
            "s3",
        )?;

        let mut hmac = signing::HmacSha256::new_from_slice(&signing_key)?;
        hmac.update(policy_string.as_bytes());
        let signature = hex::encode(hmac.finalize().into_bytes());
        let mut fields: HashMap<String, String> = HashMap::new();
        let mut dynamic_fields = HashMap::new();
        for field in policy.conditions.0.iter() {
            let f: Cow<str> = field.field.clone().into();
            match &field.value {
                PostPolicyValue::Anything => {
                    dynamic_fields.insert(f.to_string(), "".to_string());
                }
                PostPolicyValue::StartsWith(e) => {
                    dynamic_fields.insert(f.to_string(), e.clone().into_owned());
                }
                PostPolicyValue::Range(b, e) => {
                    dynamic_fields.insert(f.to_string(), format!("{},{}", b, e));
                }
                PostPolicyValue::Exact(e) => {
                    fields.insert(f.to_string(), e.clone().into_owned());
                }
            }
        }
        fields.insert("x-amz-signature".to_string(), signature);
        fields.insert("Policy".to_string(), policy_string);
        let url = bucket.url();
        Ok(PresignedPost {
            url,
            fields,
            dynamic_fields,
            expiration: policy.expiration.into(),
        })
    }

    /// Adds another condition to the policy by consuming this object
    pub fn condition(
        mut self,
        field: PostPolicyField<'a>,
        value: PostPolicyValue<'a>,
    ) -> Result<Self, S3Error> {
        if matches!(field, PostPolicyField::ContentLengthRange)
            != matches!(value, PostPolicyValue::Range(_, _))
        {
            Err(PostPolicyError::MismatchedCondition)?
        }
        self.conditions.0.push(PostPolicyCondition { field, value });
        Ok(self)
    }
}

impl Serialize for PostPolicy<'_> {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        let mut map = serializer.serialize_map(Some(2))?;
        map.serialize_entry("expiration", &self.expiration)?;
        map.serialize_entry("conditions", &self.conditions)?;
        map.end()
    }
}

#[derive(Clone, Debug)]
struct ConditionsSerializer<'a>(Vec<PostPolicyCondition<'a>>);

impl Serialize for ConditionsSerializer<'_> {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        let mut seq = serializer.serialize_seq(None)?;
        for e in self.0.iter() {
            if let PostPolicyField::AmzChecksumAlgorithm(checksum) = &e.field {
                let checksum: Cow<str> = (*checksum).into();
                seq.serialize_element(&PostPolicyCondition {
                    field: PostPolicyField::Custom(Cow::from("x-amz-checksum-algorithm")),
                    value: PostPolicyValue::Exact(Cow::from(checksum.to_uppercase())),
                })?;
            }
            seq.serialize_element(&e)?;
        }
        seq.end()
    }
}

#[derive(Clone, Debug)]
struct PostPolicyCondition<'a> {
    field: PostPolicyField<'a>,
    value: PostPolicyValue<'a>,
}

impl Serialize for PostPolicyCondition<'_> {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        let f: Cow<str> = self.field.clone().into();

        match &self.value {
            PostPolicyValue::Exact(e) => {
                let mut map = serializer.serialize_map(Some(1))?;
                map.serialize_entry(&f, e)?;
                map.end()
            }
            PostPolicyValue::StartsWith(e) => {
                let mut seq = serializer.serialize_tuple(3)?;
                seq.serialize_element("starts-with")?;
                let field = format!("${}", f);
                seq.serialize_element(&field)?;
                seq.serialize_element(e)?;
                seq.end()
            }
            PostPolicyValue::Anything => {
                let mut seq = serializer.serialize_tuple(3)?;
                seq.serialize_element("starts-with")?;
                let field = format!("${}", f);
                seq.serialize_element(&field)?;
                seq.serialize_element("")?;
                seq.end()
            }
            PostPolicyValue::Range(b, e) => {
                if matches!(self.field, PostPolicyField::ContentLengthRange) {
                    let mut seq = serializer.serialize_tuple(3)?;
                    seq.serialize_element("content-length-range")?;
                    seq.serialize_element(b)?;
                    seq.serialize_element(e)?;
                    seq.end()
                } else {
                    Err(ser::Error::custom(
                        "Range is only valid for ContentLengthRange",
                    ))
                }
            }
        }
    }
}

/// Policy fields to add to the conditions of the policy
#[derive(Clone, Debug)]
#[non_exhaustive]
pub enum PostPolicyField<'a> {
    /// The destination path. Supports [`PostPolicyValue::StartsWith`]
    Key,
    /// The ACL policy. Supports [`PostPolicyValue::StartsWith`]
    Acl,
    /// Custom tag XML document
    Tagging,
    /// Successful redirect URL. Supports [`PostPolicyValue::StartsWith`]
    SuccessActionRedirect,
    /// Successful action status (e.g. 200, 201, or 204).
    SuccessActionStatus,

    /// The cache control  Supports [`PostPolicyValue::StartsWith`]
    CacheControl,
    /// The content length (must use the [`PostPolicyValue::Range`])
    ContentLengthRange,
    /// The content type. Supports [`PostPolicyValue::StartsWith`]
    ContentType,
    /// Content Disposition. Supports [`PostPolicyValue::StartsWith`]
    ContentDisposition,
    /// The content encoding. Supports [`PostPolicyValue::StartsWith`]
    ContentEncoding,
    /// The Expires header to respond when fetching. Supports [`PostPolicyValue::StartsWith`]
    Expires,

    /// The server-side encryption type
    AmzServerSideEncryption,
    /// The SSE key ID to use (if the algorithm specified requires it)
    AmzServerSideEncryptionKeyId,
    /// The SSE context to use (if the algorithm specified requires it)
    AmzServerSideEncryptionContext,
    /// The storage class to use
    AmzStorageClass,
    /// Specify a bucket relative or absolute UR redirect to redirect to when fetching this object
    AmzWebsiteRedirectLocation,
    /// Checksum algorithm, the value is the checksum
    AmzChecksumAlgorithm(PostPolicyChecksum),
    /// Any user-defined meta fields (AmzMeta("uuid".to_string) creates an x-amz-meta-uuid)
    AmzMeta(Cow<'a, str>),

    /// The credential. Auto added by the presign_post
    AmzCredential,
    /// The signing algorithm. Auto added by the presign_post
    AmzAlgorithm,
    /// The signing date. Auto added by the presign_post
    AmzDate,
    /// The Security token (for Amazon DevPay)
    AmzSecurityToken,
    /// The Bucket. Auto added by the presign_post
    Bucket,

    /// Custom field. Any other string not enumerated above
    Custom(Cow<'a, str>),
}

#[allow(clippy::from_over_into)]
impl<'a> Into<Cow<'a, str>> for PostPolicyField<'a> {
    fn into(self) -> Cow<'a, str> {
        match self {
            PostPolicyField::Key => Cow::from("key"),
            PostPolicyField::Acl => Cow::from("acl"),
            PostPolicyField::Tagging => Cow::from("tagging"),
            PostPolicyField::SuccessActionRedirect => Cow::from("success_action_redirect"),
            PostPolicyField::SuccessActionStatus => Cow::from("success_action_status"),
            PostPolicyField::CacheControl => Cow::from("Cache-Control"),
            PostPolicyField::ContentLengthRange => Cow::from("content-length-range"),
            PostPolicyField::ContentType => Cow::from("Content-Type"),
            PostPolicyField::ContentDisposition => Cow::from("Content-Disposition"),
            PostPolicyField::ContentEncoding => Cow::from("Content-Encoding"),
            PostPolicyField::Expires => Cow::from("Expires"),

            PostPolicyField::AmzServerSideEncryption => Cow::from("x-amz-server-side-encryption"),
            PostPolicyField::AmzServerSideEncryptionKeyId => {
                Cow::from("x-amz-server-side-encryption-aws-kms-key-id")
            }
            PostPolicyField::AmzServerSideEncryptionContext => {
                Cow::from("x-amz-server-side-encryption-context")
            }
            PostPolicyField::AmzStorageClass => Cow::from("x-amz-storage-class"),
            PostPolicyField::AmzWebsiteRedirectLocation => {
                Cow::from("x-amz-website-redirect-location")
            }
            PostPolicyField::AmzChecksumAlgorithm(e) => {
                let e: Cow<str> = e.into();
                Cow::from(format!("x-amz-checksum-{}", e))
            }
            PostPolicyField::AmzMeta(e) => Cow::from(format!("x-amz-meta-{}", e)),
            PostPolicyField::AmzCredential => Cow::from("x-amz-credential"),
            PostPolicyField::AmzAlgorithm => Cow::from("x-amz-algorithm"),
            PostPolicyField::AmzDate => Cow::from("x-amz-date"),
            PostPolicyField::AmzSecurityToken => Cow::from("x-amz-security-token"),
            PostPolicyField::Bucket => Cow::from("bucket"),
            PostPolicyField::Custom(e) => e,
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub enum PostPolicyChecksum {
    CRC32,
    CRC32c,
    SHA1,
    SHA256,
}

#[allow(clippy::from_over_into)]
impl<'a> Into<Cow<'a, str>> for PostPolicyChecksum {
    fn into(self) -> Cow<'a, str> {
        match self {
            PostPolicyChecksum::CRC32 => Cow::from("crc32"),
            PostPolicyChecksum::CRC32c => Cow::from("crc32c"),
            PostPolicyChecksum::SHA1 => Cow::from("sha1"),
            PostPolicyChecksum::SHA256 => Cow::from("sha256"),
        }
    }
}

#[derive(Clone, Debug)]
pub enum PostPolicyValue<'a> {
    /// Shortcut for StartsWith("".to_string())
    Anything,
    /// A string starting with a value
    StartsWith(Cow<'a, str>),
    /// A range of integer values. Only valid for some fields
    Range(u32, u32),
    /// An exact string value
    Exact(Cow<'a, str>),
}

#[derive(Clone, Debug)]
pub enum PostPolicyExpiration {
    /// Expires in X seconds from "now"
    ExpiresIn(u32),
    /// Expires at exactly this time
    ExpiresAt(Rfc3339OffsetDateTime),
}

impl From<u32> for PostPolicyExpiration {
    fn from(value: u32) -> Self {
        Self::ExpiresIn(value)
    }
}

impl From<Rfc3339OffsetDateTime> for PostPolicyExpiration {
    fn from(value: Rfc3339OffsetDateTime) -> Self {
        Self::ExpiresAt(value)
    }
}

impl From<PostPolicyExpiration> for Rfc3339OffsetDateTime {
    fn from(value: PostPolicyExpiration) -> Self {
        match value {
            PostPolicyExpiration::ExpiresIn(d) => {
                Rfc3339OffsetDateTime(now_utc().saturating_add(Duration::seconds(d as i64)))
            }
            PostPolicyExpiration::ExpiresAt(t) => t,
        }
    }
}

impl Serialize for PostPolicyExpiration {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        Rfc3339OffsetDateTime::from(self.clone()).serialize(serializer)
    }
}

#[derive(Debug)]
pub struct PresignedPost {
    pub url: String,
    pub fields: HashMap<String, String>,
    pub dynamic_fields: HashMap<String, String>,
    pub expiration: Rfc3339OffsetDateTime,
}

#[derive(Error, Debug)]
#[non_exhaustive]
pub enum PostPolicyError {
    #[error("This value is not supported for this field")]
    MismatchedCondition,
}

#[cfg(test)]
mod test {
    use super::*;

    use crate::creds::Credentials;
    use crate::region::Region;
    use crate::utils::with_timestamp;

    use serde_json::json;

    fn test_bucket() -> Box<Bucket> {
        Bucket::new(
            "rust-s3",
            Region::UsEast1,
            Credentials::new(
                Some("AKIAIOSFODNN7EXAMPLE"),
                Some("wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"),
                None,
                None,
                None,
            )
            .unwrap(),
        )
        .unwrap()
    }

    fn test_bucket_with_security_token() -> Box<Bucket> {
        Bucket::new(
            "rust-s3",
            Region::UsEast1,
            Credentials::new(
                Some("AKIAIOSFODNN7EXAMPLE"),
                Some("wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"),
                Some("SomeSecurityToken"),
                None,
                None,
            )
            .unwrap(),
        )
        .unwrap()
    }

    mod conditions {
        use super::*;

        #[test]
        fn starts_with_condition() {
            let policy = PostPolicy::new(300)
                .condition(
                    PostPolicyField::Key,
                    PostPolicyValue::StartsWith(Cow::from("users/user1/")),
                )
                .unwrap();

            let data = serde_json::to_value(&policy).unwrap();

            assert!(data["expiration"].is_string());
            assert_eq!(
                data["conditions"],
                json!([["starts-with", "$key", "users/user1/"]])
            );
        }

        #[test]
        fn exact_condition() {
            let policy = PostPolicy::new(300)
                .condition(
                    PostPolicyField::Acl,
                    PostPolicyValue::Exact(Cow::from("public-read")),
                )
                .unwrap();

            let data = serde_json::to_value(&policy).unwrap();

            assert!(data["expiration"].is_string());
            assert_eq!(data["conditions"], json!([{"acl":"public-read"}]));
        }

        #[test]
        fn anything_condition() {
            let policy = PostPolicy::new(300)
                .condition(PostPolicyField::Key, PostPolicyValue::Anything)
                .unwrap();

            let data = serde_json::to_value(&policy).unwrap();

            assert!(data["expiration"].is_string());
            assert_eq!(data["conditions"], json!([["starts-with", "$key", ""]]));
        }

        #[test]
        fn range_condition() {
            let policy = PostPolicy::new(300)
                .condition(
                    PostPolicyField::ContentLengthRange,
                    PostPolicyValue::Range(0, 3_000_000),
                )
                .unwrap();

            let data = serde_json::to_value(&policy).unwrap();

            assert!(data["expiration"].is_string());
            assert_eq!(
                data["conditions"],
                json!([["content-length-range", 0, 3_000_000]])
            );
        }

        #[test]
        fn range_condition_for_non_content_length_range() -> Result<(), S3Error> {
            let result = PostPolicy::new(86400)
                .condition(PostPolicyField::ContentType, PostPolicyValue::Range(0, 100));

            assert!(matches!(
                result,
                Err(S3Error::PostPolicyError(
                    PostPolicyError::MismatchedCondition
                ))
            ));

            Ok(())
        }

        #[test]
        fn starts_with_condition_for_content_length_range() -> Result<(), S3Error> {
            let result = PostPolicy::new(86400).condition(
                PostPolicyField::ContentLengthRange,
                PostPolicyValue::StartsWith(Cow::from("")),
            );

            assert!(matches!(
                result,
                Err(S3Error::PostPolicyError(
                    PostPolicyError::MismatchedCondition
                ))
            ));

            Ok(())
        }

        #[test]
        fn exact_condition_for_content_length_range() -> Result<(), S3Error> {
            let result = PostPolicy::new(86400).condition(
                PostPolicyField::ContentLengthRange,
                PostPolicyValue::Exact(Cow::from("test")),
            );

            assert!(matches!(
                result,
                Err(S3Error::PostPolicyError(
                    PostPolicyError::MismatchedCondition
                ))
            ));

            Ok(())
        }

        #[test]
        fn anything_condition_for_content_length_range() -> Result<(), S3Error> {
            let result = PostPolicy::new(86400).condition(
                PostPolicyField::ContentLengthRange,
                PostPolicyValue::Anything,
            );

            assert!(matches!(
                result,
                Err(S3Error::PostPolicyError(
                    PostPolicyError::MismatchedCondition
                ))
            ));

            Ok(())
        }

        #[test]
        fn checksum_policy() {
            let policy = PostPolicy::new(300)
                .condition(
                    PostPolicyField::AmzChecksumAlgorithm(PostPolicyChecksum::SHA256),
                    PostPolicyValue::Exact(Cow::from("abcdef1234567890")),
                )
                .unwrap();

            let data = serde_json::to_value(&policy).unwrap();

            assert!(data["expiration"].is_string());
            assert_eq!(
                data["conditions"],
                json!([
                    {"x-amz-checksum-algorithm": "SHA256"},
                    {"x-amz-checksum-sha256": "abcdef1234567890"}
                ])
            );
        }
    }

    mod build {
        use super::*;

        #[maybe_async::test(
            feature = "sync",
            async(all(not(feature = "sync"), feature = "with-tokio"), tokio::test),
            async(
                all(not(feature = "sync"), feature = "with-async-std"),
                async_std::test
            )
        )]
        async fn adds_credentials() {
            let policy = PostPolicy::new(86400)
                .condition(
                    PostPolicyField::Key,
                    PostPolicyValue::StartsWith(Cow::from("user/user1/")),
                )
                .unwrap();

            let bucket = test_bucket();

            let _ts = with_timestamp(1_451_347_200);
            let policy = policy.build(&now_utc(), &bucket).await.unwrap();

            let data = serde_json::to_value(&policy).unwrap();

            assert_eq!(
                data["conditions"],
                json!([
                    ["starts-with", "$key", "user/user1/"],
                    {"bucket": "rust-s3"},
                    {"x-amz-algorithm": "AWS4-HMAC-SHA256"},
                    {"x-amz-credential": "AKIAIOSFODNN7EXAMPLE/20151229/us-east-1/s3/aws4_request"},
                    {"x-amz-date": "20151229T000000Z"},
                ])
            );
        }

        #[maybe_async::test(
            feature = "sync",
            async(all(not(feature = "sync"), feature = "with-tokio"), tokio::test),
            async(
                all(not(feature = "sync"), feature = "with-async-std"),
                async_std::test
            )
        )]
        async fn with_security_token() {
            let policy = PostPolicy::new(86400)
                .condition(
                    PostPolicyField::Key,
                    PostPolicyValue::StartsWith(Cow::from("user/user1/")),
                )
                .unwrap();

            let bucket = test_bucket_with_security_token();

            let _ts = with_timestamp(1_451_347_200);
            let policy = policy.build(&now_utc(), &bucket).await.unwrap();

            let data = serde_json::to_value(&policy).unwrap();

            assert_eq!(
                data["conditions"],
                json!([
                    ["starts-with", "$key", "user/user1/"],
                    {"bucket": "rust-s3"},
                    {"x-amz-algorithm": "AWS4-HMAC-SHA256"},
                    {"x-amz-credential": "AKIAIOSFODNN7EXAMPLE/20151229/us-east-1/s3/aws4_request"},
                    {"x-amz-date": "20151229T000000Z"},
                    {"x-amz-security-token": "SomeSecurityToken"},
                ])
            );
        }
    }

    mod policy_string {
        use super::*;

        #[test]
        fn returns_base64_encoded() {
            let policy = PostPolicy::new(129600)
                .condition(
                    PostPolicyField::Key,
                    PostPolicyValue::StartsWith(Cow::from("user/user1/")),
                )
                .unwrap();

            let _ts = with_timestamp(1_451_347_200);

            let expected = "eyJleHBpcmF0aW9uIjoiMjAxNS0xMi0zMFQxMjowMDowMFoiLCJjb25kaXRpb25zIjpbWyJzdGFydHMtd2l0aCIsIiRrZXkiLCJ1c2VyL3VzZXIxLyJdXX0=";

            assert_eq!(policy.policy_string().unwrap(), expected);
        }
    }

    mod sign {
        use super::*;

        #[maybe_async::test(
            feature = "sync",
            async(all(not(feature = "sync"), feature = "with-tokio"), tokio::test),
            async(
                all(not(feature = "sync"), feature = "with-async-std"),
                async_std::test
            )
        )]
        async fn returns_full_details() {
            let policy = PostPolicy::new(86400)
                .condition(
                    PostPolicyField::Key,
                    PostPolicyValue::StartsWith(Cow::from("user/user1/")),
                )
                .unwrap()
                .condition(
                    PostPolicyField::ContentLengthRange,
                    PostPolicyValue::Range(0, 3_000_000),
                )
                .unwrap();

            let bucket = test_bucket();

            let _ts = with_timestamp(1_451_347_200);
            let post = policy.sign(bucket).await.unwrap();

            assert_eq!(post.url, "https://rust-s3.s3.amazonaws.com");
            assert_eq!(
                serde_json::to_value(&post.fields).unwrap(),
                json!({
                    "x-amz-credential": "AKIAIOSFODNN7EXAMPLE/20151229/us-east-1/s3/aws4_request",
                    "bucket": "rust-s3",
                    "Policy": "eyJleHBpcmF0aW9uIjoiMjAxNS0xMi0zMFQwMDowMDowMFoiLCJjb25kaXRpb25zIjpbWyJzdGFydHMtd2l0aCIsIiRrZXkiLCJ1c2VyL3VzZXIxLyJdLFsiY29udGVudC1sZW5ndGgtcmFuZ2UiLDAsMzAwMDAwMF0seyJidWNrZXQiOiJydXN0LXMzIn0seyJ4LWFtei1hbGdvcml0aG0iOiJBV1M0LUhNQUMtU0hBMjU2In0seyJ4LWFtei1jcmVkZW50aWFsIjoiQUtJQUlPU0ZPRE5ON0VYQU1QTEUvMjAxNTEyMjkvdXMtZWFzdC0xL3MzL2F3czRfcmVxdWVzdCJ9LHsieC1hbXotZGF0ZSI6IjIwMTUxMjI5VDAwMDAwMFoifV19",
                    "x-amz-date": "20151229T000000Z",
                    "x-amz-signature": "0ff9c50ab7e543a841e91e5c663fd32117c5243e56e7a69db88f94ee95c4706f",
                    "x-amz-algorithm": "AWS4-HMAC-SHA256"
                })
            );
            assert_eq!(
                serde_json::to_value(&post.dynamic_fields).unwrap(),
                json!({
                    "key": "user/user1/",
                    "content-length-range": "0,3000000",
                })
            );
        }
    }
}
