#[derive(Deserialize, Debug)]
pub struct InitiateMultipartUploadResponse {
    #[serde(rename = "Bucket")]
    _bucket: String,
    #[serde(rename = "Key")]
    pub key: String,
    #[serde(rename = "UploadId")]
    pub upload_id: String,
}

/// Owner information for the object
#[derive(Deserialize, Debug, Clone)]
pub struct Owner {
    #[serde(rename = "DisplayName")]
    /// Object owner's name.
    pub display_name: Option<String>,
    #[serde(rename = "ID")]
    /// Object owner's ID.
    pub id: String,
}

// <GetObjectAttributesOutput>
//    <ETag>string</ETag>
//    <Checksum>
//       <ChecksumCRC32>string</ChecksumCRC32>
//       <ChecksumCRC32C>string</ChecksumCRC32C>
//       <ChecksumSHA1>string</ChecksumSHA1>
//       <ChecksumSHA256>string</ChecksumSHA256>
//    </Checksum>
//    <ObjectParts>
//       <IsTruncated>boolean</IsTruncated>
//       <MaxParts>integer</MaxParts>
//       <NextPartNumberMarker>integer</NextPartNumberMarker>
//       <PartNumberMarker>integer</PartNumberMarker>
//       <Part>
//          <ChecksumCRC32>string</ChecksumCRC32>
//          <ChecksumCRC32C>string</ChecksumCRC32C>
//          <ChecksumSHA1>string</ChecksumSHA1>
//          <ChecksumSHA256>string</ChecksumSHA256>
//          <PartNumber>integer</PartNumber>
//          <Size>long</Size>
//       </Part>
//       ...
//       <PartsCount>integer</PartsCount>
//    </ObjectParts>
//    <StorageClass>string</StorageClass>
//    <ObjectSize>long</ObjectSize>
// </GetObjectAttributesOutput>
#[derive(Deserialize, Debug)]
pub struct GetObjectAttributesOutput {
    #[serde(rename = "ETag")]
    pub etag: String,
    #[serde(rename = "Checksum")]
    pub checksum: Checksum,
    #[serde(rename = "ObjectParts")]
    pub object_parts: ObjectParts,
    #[serde(rename = "StorageClass")]
    pub storage_class: String,
    #[serde(rename = "ObjectSize")]
    pub object_size: u64,
}

#[derive(Deserialize, Debug)]
pub struct Checksum {
    #[serde(rename = "ChecksumCRC32")]
    pub checksum_crc32: String,
    #[serde(rename = "ChecksumCRC32C")]
    pub checksum_crc32c: String,
    #[serde(rename = "ChecksumSHA1")]
    pub checksum_sha1: String,
    #[serde(rename = "ChecksumSHA256")]
    pub checksum_sha256: String,
}

#[derive(Deserialize, Debug)]
pub struct ObjectParts {
    #[serde(rename = "IsTruncated")]
    pub is_truncated: bool,
    #[serde(rename = "MaxParts")]
    pub max_parts: i32,
    #[serde(rename = "NextPartNumberMarker")]
    pub next_part_number_marker: i32,
    #[serde(rename = "PartNumberMarker")]
    pub part_number_marker: i32,
    #[serde(rename = "Part")]
    pub part: Vec<AttributesPart>,
    #[serde(rename = "PartsCount")]
    pub parts_count: u64,
}

#[derive(Deserialize, Debug)]
pub struct AttributesPart {
    #[serde(rename = "ChecksumCRC32")]
    pub checksum_crc32: String,
    #[serde(rename = "ChecksumCRC32C")]
    pub checksum_crc32c: String,
    #[serde(rename = "ChecksumSHA1")]
    pub checksum_sha1: String,
    #[serde(rename = "ChecksumSHA256")]
    pub checksum_sha256: String,
    #[serde(rename = "PartNumber")]
    pub part_number: i32,
    #[serde(rename = "Size")]
    pub size: u64,
}

/// An individual object in a `ListBucketResult`
#[derive(Deserialize, Debug, Clone)]
pub struct Object {
    #[serde(rename = "LastModified")]
    /// Date and time the object was last modified.
    pub last_modified: String,
    #[serde(rename = "ETag")]
    /// The entity tag is an MD5 hash of the object. The ETag only reflects changes to the
    /// contents of an object, not its metadata.
    pub e_tag: Option<String>,
    #[serde(rename = "StorageClass")]
    /// STANDARD | STANDARD_IA | REDUCED_REDUNDANCY | GLACIER
    pub storage_class: Option<String>,
    #[serde(rename = "Key")]
    /// The object's key
    pub key: String,
    #[serde(rename = "Owner")]
    /// Bucket owner
    pub owner: Option<Owner>,
    #[serde(rename = "Size")]
    /// Size in bytes of the object.
    pub size: u64,
}

/// An individual upload in a `ListMultipartUploadsResult`
#[derive(Deserialize, Debug, Clone)]
pub struct MultipartUpload {
    #[serde(rename = "Initiated")]
    /// Date and time the multipart upload was initiated
    pub initiated: String,
    #[serde(rename = "StorageClass")]
    /// STANDARD | STANDARD_IA | REDUCED_REDUNDANCY | GLACIER
    pub storage_class: String,
    #[serde(rename = "Key")]
    /// The object's key
    pub key: String,
    #[serde(rename = "Owner")]
    /// Bucket owner
    pub owner: Option<Owner>,
    #[serde(rename = "UploadId")]
    /// The identifier of the upload
    pub id: String,
}

use std::fmt::{self};

impl fmt::Display for CompleteMultipartUploadData {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mut parts = String::new();
        for part in self.parts.clone() {
            parts.push_str(&part.to_string())
        }
        write!(
            f,
            "<CompleteMultipartUpload>{}</CompleteMultipartUpload>",
            parts
        )
    }
}

impl CompleteMultipartUploadData {
    pub fn len(&self) -> usize {
        self.to_string().len()
    }

    pub fn is_empty(&self) -> bool {
        self.to_string().len() == 0
    }
}

#[derive(Debug, Clone)]
pub struct CompleteMultipartUploadData {
    pub parts: Vec<Part>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Part {
    #[serde(rename = "PartNumber")]
    pub part_number: u32,
    #[serde(rename = "ETag")]
    pub etag: String,
}

impl fmt::Display for Part {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "<Part>").expect("Can't fail");
        write!(f, "<PartNumber>{}</PartNumber>", self.part_number).expect("Can't fail");
        write!(f, "<ETag>{}</ETag>", self.etag).expect("Can't fail");
        write!(f, "</Part>")
    }
}

#[derive(Deserialize, Debug, Clone)]
pub struct BucketLocationResult {
    #[serde(rename = "$value")]
    pub region: String,
}

/// The parsed result of a s3 bucket listing
///
/// This accepts the ListBucketResult format returned for both ListObjects and ListObjectsV2
#[derive(Deserialize, Debug, Clone)]
pub struct ListBucketResult {
    #[serde(rename = "Name")]
    /// Name of the bucket.
    pub name: String,
    #[serde(rename = "Delimiter")]
    /// A delimiter is a character you use to group keys.
    pub delimiter: Option<String>,
    #[serde(rename = "MaxKeys")]
    /// Sets the maximum number of keys returned in the response body.
    pub max_keys: Option<i32>,
    #[serde(rename = "Prefix")]
    /// Limits the response to keys that begin with the specified prefix.
    pub prefix: Option<String>,
    #[serde(rename = "ContinuationToken")] // for ListObjectsV2 request
    #[serde(alias = "Marker")] // for ListObjects request
    /// Indicates where in the bucket listing begins. It is included in the response if
    /// it was sent with the request.
    pub continuation_token: Option<String>,
    #[serde(rename = "EncodingType")]
    /// Specifies the encoding method to used
    pub encoding_type: Option<String>,
    #[serde(
        default,
        rename = "IsTruncated",
        deserialize_with = "super::deserializer::bool_deserializer"
    )]
    ///  Specifies whether (true) or not (false) all of the results were returned.
    ///  If the number of results exceeds that specified by MaxKeys, all of the results
    ///  might not be returned.

    /// When the response is truncated (that is, the IsTruncated element value in the response
    /// is true), you can use the key name in in 'next_continuation_token' as a marker in the
    /// subsequent request to get next set of objects. Amazon S3 lists objects in UTF-8 character
    /// encoding in lexicographical order.
    pub is_truncated: bool,
    #[serde(rename = "NextContinuationToken", default)] // for ListObjectsV2 request
    #[serde(alias = "NextMarker")] // for ListObjects request
    pub next_continuation_token: Option<String>,
    #[serde(rename = "Contents", default)]
    /// Metadata about each object returned.
    pub contents: Vec<Object>,
    #[serde(rename = "CommonPrefixes", default)]
    /// All of the keys rolled up into a common prefix count as a single return when
    /// calculating the number of returns.
    pub common_prefixes: Option<Vec<CommonPrefix>>,
}

/// The parsed result of a s3 bucket listing of uploads
#[derive(Deserialize, Debug, Clone)]
pub struct ListMultipartUploadsResult {
    #[serde(rename = "Bucket")]
    /// Name of the bucket.
    pub name: String,
    #[serde(rename = "NextKeyMarker")]
    /// When the response is truncated (that is, the IsTruncated element value in the response
    /// is true), you can use the key name in this field as a marker in the subsequent request
    /// to get next set of objects. Amazon S3 lists objects in UTF-8 character encoding in
    /// lexicographical order.
    pub next_marker: Option<String>,
    #[serde(rename = "Prefix")]
    /// The prefix, present if the request contained a prefix too, shows the search root for the
    /// uploads listed in this structure.
    pub prefix: Option<String>,
    #[serde(rename = "KeyMarker")]
    /// Indicates where in the bucket listing begins.
    pub marker: Option<String>,
    #[serde(rename = "EncodingType")]
    /// Specifies the encoding method to used
    pub encoding_type: Option<String>,
    #[serde(
        rename = "IsTruncated",
        deserialize_with = "super::deserializer::bool_deserializer"
    )]
    ///  Specifies whether (true) or not (false) all of the results were returned.
    ///  If the number of results exceeds that specified by MaxKeys, all of the results
    ///  might not be returned.
    pub is_truncated: bool,
    #[serde(rename = "Upload", default)]
    /// Metadata about each upload returned.
    pub uploads: Vec<MultipartUpload>,
    #[serde(rename = "CommonPrefixes", default)]
    /// All of the keys rolled up into a common prefix count as a single return when
    /// calculating the number of returns.
    pub common_prefixes: Option<Vec<CommonPrefix>>,
}

/// `CommonPrefix` is used to group keys
#[derive(Deserialize, Debug, Clone)]
pub struct CommonPrefix {
    #[serde(rename = "Prefix")]
    /// Keys that begin with the indicated prefix.
    pub prefix: String,
}

// Taken from https://github.com/rusoto/rusoto
#[derive(Deserialize, Debug, Default, Clone)]
pub struct HeadObjectResult {
    #[serde(rename = "AcceptRanges")]
    /// Indicates that a range of bytes was specified.
    pub accept_ranges: Option<String>,
    #[serde(rename = "CacheControl")]
    /// Specifies caching behavior along the request/reply chain.
    pub cache_control: Option<String>,
    #[serde(rename = "ContentDisposition")]
    /// Specifies presentational information for the object.
    pub content_disposition: Option<String>,
    #[serde(rename = "ContentEncoding")]
    /// Specifies what content encodings have been applied to the object and thus what decoding mechanisms must be applied to obtain the media-type referenced by the Content-Type header field.
    pub content_encoding: Option<String>,
    #[serde(rename = "ContentLanguage")]
    /// The language the content is in.
    pub content_language: Option<String>,
    #[serde(rename = "ContentLength")]
    /// Size of the body in bytes.
    pub content_length: Option<i64>,
    #[serde(rename = "ContentType")]
    /// A standard MIME type describing the format of the object data.
    pub content_type: Option<String>,
    #[serde(rename = "DeleteMarker")]
    /// Specifies whether the object retrieved was (true) or was not (false) a Delete Marker.
    pub delete_marker: Option<bool>,
    #[serde(rename = "ETag")]
    /// An ETag is an opaque identifier assigned by a web server to a specific version of a resource found at a URL.
    pub e_tag: Option<String>,
    #[serde(rename = "Expiration")]
    /// If the object expiration is configured, the response includes this header. It includes the expiry-date and rule-id key-value pairs providing object expiration information.
    /// The value of the rule-id is URL encoded.
    pub expiration: Option<String>,
    #[serde(rename = "Expires")]
    /// The date and time at which the object is no longer cacheable.
    pub expires: Option<String>,
    #[serde(rename = "LastModified")]
    /// Last modified date of the object
    pub last_modified: Option<String>,
    #[serde(rename = "Metadata", default)]
    /// A map of metadata to store with the object in S3.
    pub metadata: Option<::std::collections::HashMap<String, String>>,
    #[serde(rename = "MissingMeta")]
    /// This is set to the number of metadata entries not returned in x-amz-meta headers. This can happen if you create metadata using an API like SOAP that supports more flexible metadata than
    /// the REST API. For example, using SOAP, you can create metadata whose values are not legal HTTP headers.
    pub missing_meta: Option<i64>,
    #[serde(rename = "ObjectLockLegalHoldStatus")]
    /// Specifies whether a legal hold is in effect for this object. This header is only returned if the requester has the s3:GetObjectLegalHold permission.
    /// This header is not returned if the specified version of this object has never had a legal hold applied.
    pub object_lock_legal_hold_status: Option<String>,
    #[serde(rename = "ObjectLockMode")]
    /// The Object Lock mode, if any, that's in effect for this object.
    pub object_lock_mode: Option<String>,
    #[serde(rename = "ObjectLockRetainUntilDate")]
    /// The date and time when the Object Lock retention period expires.
    /// This header is only returned if the requester has the s3:GetObjectRetention permission.
    pub object_lock_retain_until_date: Option<String>,
    #[serde(rename = "PartsCount")]
    /// The count of parts this object has.
    pub parts_count: Option<i64>,
    #[serde(rename = "ReplicationStatus")]
    /// If your request involves a bucket that is either a source or destination in a replication rule.
    pub replication_status: Option<String>,
    #[serde(rename = "RequestCharged")]
    pub request_charged: Option<String>,
    #[serde(rename = "Restore")]
    /// If the object is an archived object (an object whose storage class is GLACIER), the response includes this header if either the archive restoration is in progress or an archive copy is already restored.
    /// If an archive copy is already restored, the header value indicates when Amazon S3 is scheduled to delete the object copy.
    pub restore: Option<String>,
    #[serde(rename = "SseCustomerAlgorithm")]
    /// If server-side encryption with a customer-provided encryption key was requested, the response will include this header confirming the encryption algorithm used.
    pub sse_customer_algorithm: Option<String>,
    #[serde(rename = "SseCustomerKeyMd5")]
    /// If server-side encryption with a customer-provided encryption key was requested, the response will include this header to provide round-trip message integrity verification of the customer-provided encryption key.
    pub sse_customer_key_md5: Option<String>,
    #[serde(rename = "SsekmsKeyId")]
    /// If present, specifies the ID of the AWS Key Management Service (AWS KMS) symmetric customer managed customer master key (CMK) that was used for the object.
    pub ssekms_key_id: Option<String>,
    #[serde(rename = "ServerSideEncryption")]
    /// If the object is stored using server-side encryption either with an AWS KMS customer master key (CMK) or an Amazon S3-managed encryption key,
    /// The response includes this header with the value of the server-side encryption algorithm used when storing this object in Amazon S3 (for example, AES256, aws:kms).
    pub server_side_encryption: Option<String>,
    #[serde(rename = "StorageClass")]
    /// Provides storage class information of the object. Amazon S3 returns this header for all objects except for S3 Standard storage class objects.
    pub storage_class: Option<String>,
    #[serde(rename = "VersionId")]
    /// Version of the object.
    pub version_id: Option<String>,
    #[serde(rename = "WebsiteRedirectLocation")]
    /// If the bucket is configured as a website, redirects requests for this object to another object in the same bucket or to an external URL. Amazon S3 stores the value of this header in the object metadata.
    pub website_redirect_location: Option<String>,
}

#[derive(Deserialize, Debug)]
pub struct AwsError {
    #[serde(rename = "Code")]
    pub code: String,
    #[serde(rename = "Message")]
    pub message: String,
    #[serde(rename = "RequestId")]
    pub request_id: String,
}

/// Represents a single object identifier for the bulk delete request.
#[derive(Debug, Clone)]
pub struct ObjectIdentifier {
    /// The key of the object to delete.
    pub key: String,
    /// The version ID of the object to delete (optional).
    pub version_id: Option<String>,
}

impl ObjectIdentifier {
    pub fn new(key: impl Into<String>) -> Self {
        Self {
            key: key.into(),
            version_id: None,
        }
    }

    pub fn with_version(key: impl Into<String>, version_id: impl Into<String>) -> Self {
        Self {
            key: key.into(),
            version_id: Some(version_id.into()),
        }
    }
}

/// Request body for the DeleteObjects (bulk delete) API.
#[derive(Debug, Clone)]
pub struct DeleteObjectsRequest {
    pub objects: Vec<ObjectIdentifier>,
    /// If true, the response only includes errors (Quiet mode).
    pub quiet: bool,
}

impl fmt::Display for DeleteObjectsRequest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            r#"<Delete xmlns="http://s3.amazonaws.com/doc/2006-03-01/">"#
        )
        .expect("Can't fail");
        if self.quiet {
            write!(f, "<Quiet>true</Quiet>").expect("Can't fail");
        }
        for obj in &self.objects {
            let escaped_key = quick_xml::escape::escape(&obj.key);
            write!(f, "<Object><Key>{}</Key>", escaped_key).expect("Can't fail");
            if let Some(ref vid) = obj.version_id {
                let escaped_vid = quick_xml::escape::escape(vid);
                write!(f, "<VersionId>{}</VersionId>", escaped_vid).expect("Can't fail");
            }
            write!(f, "</Object>").expect("Can't fail");
        }
        write!(f, "</Delete>")
    }
}

impl DeleteObjectsRequest {
    pub fn len(&self) -> usize {
        self.to_string().len()
    }

    pub fn is_empty(&self) -> bool {
        self.objects.is_empty()
    }
}

/// A single deleted object in the DeleteObjects response.
#[derive(Deserialize, Debug, Clone)]
pub struct DeletedObject {
    #[serde(rename = "Key")]
    pub key: String,
    #[serde(rename = "VersionId")]
    pub version_id: Option<String>,
    #[serde(rename = "DeleteMarker")]
    pub delete_marker: Option<bool>,
    #[serde(rename = "DeleteMarkerVersionId")]
    pub delete_marker_version_id: Option<String>,
}

/// A single error entry in the DeleteObjects response.
#[derive(Deserialize, Debug, Clone)]
pub struct DeleteError {
    #[serde(rename = "Key")]
    pub key: String,
    #[serde(rename = "Code")]
    pub code: String,
    #[serde(rename = "Message")]
    pub message: String,
    #[serde(rename = "VersionId")]
    pub version_id: Option<String>,
}

/// The parsed result of a DeleteObjects (bulk delete) response.
#[derive(Deserialize, Debug, Clone)]
pub struct DeleteObjectsResult {
    #[serde(rename = "Deleted", default)]
    pub deleted: Vec<DeletedObject>,
    #[serde(rename = "Error", default)]
    pub errors: Vec<DeleteError>,
}

#[derive(Clone, Debug, Serialize, Deserialize, Eq, PartialEq)]
#[serde(rename = "CORSConfiguration")]
pub struct CorsConfiguration {
    #[serde(rename = "CORSRule")]
    rules: Vec<CorsRule>,
}

impl CorsConfiguration {
    pub fn new(rules: Vec<CorsRule>) -> Self {
        CorsConfiguration { rules }
    }
}

impl fmt::Display for CorsConfiguration {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let cors = quick_xml::se::to_string(&self).map_err(|_| fmt::Error)?;
        let preamble = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>";
        let cors = format!("{}{}", preamble, cors);
        let cors = cors.replace(
            "<CORSConfiguration>",
            "<CORSConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">",
        );

        write!(f, "{}", cors)
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, Eq, PartialEq)]
pub struct CorsRule {
    #[serde(rename = "AllowedHeader")]
    #[serde(skip_serializing_if = "Option::is_none")]
    allowed_headers: Option<Vec<String>>,
    #[serde(rename = "AllowedMethod")]
    allowed_methods: Vec<String>,
    #[serde(rename = "AllowedOrigin")]
    allowed_origins: Vec<String>,
    #[serde(rename = "ExposeHeader")]
    #[serde(skip_serializing_if = "Option::is_none")]
    expose_headers: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "ID")]
    id: Option<String>,
    #[serde(rename = "MaxAgeSeconds")]
    #[serde(skip_serializing_if = "Option::is_none")]
    max_age_seconds: Option<u32>,
}

impl CorsRule {
    pub fn new(
        allowed_headers: Option<Vec<String>>,
        allowed_methods: Vec<String>,
        allowed_origins: Vec<String>,
        expose_headers: Option<Vec<String>>,
        id: Option<String>,
        max_age_seconds: Option<u32>,
    ) -> Self {
        Self {
            allowed_headers,
            allowed_methods,
            allowed_origins,
            expose_headers,
            id,
            max_age_seconds,
        }
    }
}

#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(rename = "LifecycleConfiguration")]
pub struct BucketLifecycleConfiguration {
    #[serde(rename = "Rule")]
    pub rules: Vec<LifecycleRule>,
}

impl BucketLifecycleConfiguration {
    pub fn new(rules: Vec<LifecycleRule>) -> Self {
        BucketLifecycleConfiguration { rules }
    }
}

#[derive(Serialize, Deserialize, Debug, Clone, Default)]
pub struct LifecycleRule {
    #[serde(
        rename = "AbortIncompleteMultipartUpload",
        skip_serializing_if = "Option::is_none"
    )]
    pub abort_incomplete_multipart_upload: Option<AbortIncompleteMultipartUpload>,

    #[serde(rename = "Expiration", skip_serializing_if = "Option::is_none")]
    pub expiration: Option<Expiration>,

    #[serde(rename = "Filter", skip_serializing_if = "Option::is_none")]
    pub filter: Option<LifecycleFilter>,

    #[serde(rename = "ID", skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,

    #[serde(
        rename = "NoncurrentVersionExpiration",
        skip_serializing_if = "Option::is_none"
    )]
    pub noncurrent_version_expiration: Option<NoncurrentVersionExpiration>,

    #[serde(
        rename = "NoncurrentVersionTransition",
        skip_serializing_if = "Option::is_none"
    )]
    pub noncurrent_version_transition: Option<Vec<NoncurrentVersionTransition>>,

    #[serde(rename = "Status")]
    /// Valid Values: Enabled | Disabled
    pub status: String,

    #[serde(rename = "Transition", skip_serializing_if = "Option::is_none")]
    pub transition: Option<Vec<Transition>>,
}

pub struct LifecycleRuleBuilder {
    lifecycle_rule: LifecycleRule,
}

impl LifecycleRule {
    pub fn builder(status: &str) -> LifecycleRuleBuilder {
        LifecycleRuleBuilder::new(status)
    }
}

impl LifecycleRuleBuilder {
    pub fn new(status: &str) -> LifecycleRuleBuilder {
        LifecycleRuleBuilder {
            lifecycle_rule: LifecycleRule {
                status: status.to_string(),
                ..Default::default()
            },
        }
    }

    pub fn abort_incomplete_multipart_upload(
        mut self,
        abort_incomplete_multipart_upload: AbortIncompleteMultipartUpload,
    ) -> LifecycleRuleBuilder {
        self.lifecycle_rule.abort_incomplete_multipart_upload =
            Some(abort_incomplete_multipart_upload);
        self
    }

    pub fn expiration(mut self, expiration: Expiration) -> LifecycleRuleBuilder {
        self.lifecycle_rule.expiration = Some(expiration);
        self
    }

    pub fn filter(mut self, filter: LifecycleFilter) -> LifecycleRuleBuilder {
        self.lifecycle_rule.filter = Some(filter);
        self
    }

    pub fn id(mut self, id: &str) -> LifecycleRuleBuilder {
        self.lifecycle_rule.id = Some(id.to_string());
        self
    }

    pub fn noncurrent_version_expiration(
        mut self,
        noncurrent_version_expiration: NoncurrentVersionExpiration,
    ) -> LifecycleRuleBuilder {
        self.lifecycle_rule.noncurrent_version_expiration = Some(noncurrent_version_expiration);
        self
    }

    pub fn noncurrent_version_transition(
        mut self,
        noncurrent_version_transition: Vec<NoncurrentVersionTransition>,
    ) -> LifecycleRuleBuilder {
        self.lifecycle_rule.noncurrent_version_transition = Some(noncurrent_version_transition);
        self
    }

    pub fn transition(mut self, transition: Vec<Transition>) -> LifecycleRuleBuilder {
        self.lifecycle_rule.transition = Some(transition);
        self
    }

    pub fn build(self) -> LifecycleRule {
        self.lifecycle_rule
    }
}
#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct AbortIncompleteMultipartUpload {
    #[serde(
        rename = "DaysAfterInitiation",
        skip_serializing_if = "Option::is_none"
    )]
    pub days_after_initiation: Option<i32>,
}

impl AbortIncompleteMultipartUpload {
    pub fn new(days_after_initiation: Option<i32>) -> Self {
        Self {
            days_after_initiation,
        }
    }
}

#[derive(Serialize, Deserialize, Debug, Clone, Default)]
pub struct Expiration {
    /// Indicates at what date the object is to be moved or deleted. The date value must conform to the ISO 8601 format. The time is always midnight UTC.
    #[serde(rename = "Date", skip_serializing_if = "Option::is_none")]
    pub date: Option<String>,

    #[serde(rename = "Days", skip_serializing_if = "Option::is_none")]
    pub days: Option<u32>,

    /// Indicates whether Amazon S3 will remove a delete marker with no noncurrent versions. If set to true, the delete marker will be expired; if set to false the policy takes no action. This cannot be specified with Days or Date in a Lifecycle Expiration Policy.
    #[serde(
        rename = "ExpiredObjectDeleteMarker",
        skip_serializing_if = "Option::is_none"
    )]
    pub expired_object_delete_marker: Option<bool>,
}

impl Expiration {
    pub fn new(
        date: Option<String>,
        days: Option<u32>,
        expired_object_delete_marker: Option<bool>,
    ) -> Self {
        Self {
            date,
            days,
            expired_object_delete_marker,
        }
    }
}

#[derive(Serialize, Deserialize, Debug, Clone, Default)]
pub struct LifecycleFilter {
    #[serde(rename = "And", skip_serializing_if = "Option::is_none")]
    pub and: Option<And>,

    #[serde(
        rename = "ObjectSizeGreaterThan",
        skip_serializing_if = "Option::is_none"
    )]
    pub object_size_greater_than: Option<i64>,

    #[serde(rename = "ObjectSizeLessThan", skip_serializing_if = "Option::is_none")]
    pub object_size_less_than: Option<i64>,

    #[serde(rename = "Prefix", skip_serializing_if = "Option::is_none")]
    pub prefix: Option<String>,

    #[serde(rename = "Tag", skip_serializing_if = "Option::is_none")]
    pub tag: Option<Tag>,
}
impl LifecycleFilter {
    pub fn new(
        and: Option<And>,
        object_size_greater_than: Option<i64>,
        object_size_less_than: Option<i64>,
        prefix: Option<String>,
        tag: Option<Tag>,
    ) -> Self {
        Self {
            and,
            object_size_greater_than,
            object_size_less_than,
            prefix,
            tag,
        }
    }
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct And {
    #[serde(
        rename = "ObjectSizeGreaterThan",
        skip_serializing_if = "Option::is_none"
    )]
    pub object_size_greater_than: Option<i64>,

    #[serde(rename = "ObjectSizeLessThan", skip_serializing_if = "Option::is_none")]
    pub object_size_less_than: Option<i64>,

    #[serde(rename = "Prefix", skip_serializing_if = "Option::is_none")]
    pub prefix: Option<String>,

    #[serde(rename = "Tag", skip_serializing_if = "Option::is_none")]
    pub tags: Option<Vec<Tag>>,
}

impl And {
    pub fn new(
        object_size_greater_than: Option<i64>,
        object_size_less_than: Option<i64>,
        prefix: Option<String>,
        tags: Option<Vec<Tag>>,
    ) -> Self {
        Self {
            object_size_greater_than,
            object_size_less_than,
            prefix,
            tags,
        }
    }
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct Tag {
    #[serde(rename = "Key")]
    pub key: String,

    #[serde(rename = "Value")]
    pub value: String,
}

impl Tag {
    pub fn new(key: &str, value: &str) -> Self {
        Self {
            key: key.to_string(),
            value: value.to_string(),
        }
    }
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct NoncurrentVersionExpiration {
    #[serde(
        rename = "NewerNoncurrentVersions",
        skip_serializing_if = "Option::is_none"
    )]
    pub newer_noncurrent_versions: Option<i32>,

    #[serde(rename = "NoncurrentDays", skip_serializing_if = "Option::is_none")]
    pub noncurrent_days: Option<i32>,
}

impl NoncurrentVersionExpiration {
    pub fn new(newer_noncurrent_versions: Option<i32>, noncurrent_days: Option<i32>) -> Self {
        NoncurrentVersionExpiration {
            newer_noncurrent_versions,
            noncurrent_days,
        }
    }
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct NoncurrentVersionTransition {
    #[serde(
        rename = "NewerNoncurrentVersions",
        skip_serializing_if = "Option::is_none"
    )]
    pub newer_noncurrent_versions: Option<i32>,

    #[serde(rename = "NoncurrentDays", skip_serializing_if = "Option::is_none")]
    pub noncurrent_days: Option<i32>,

    #[serde(rename = "StorageClass", skip_serializing_if = "Option::is_none")]
    /// Valid Values: GLACIER | STANDARD_IA | ONEZONE_IA | INTELLIGENT_TIERING | DEEP_ARCHIVE | GLACIER_IR
    pub storage_class: Option<String>,
}

impl NoncurrentVersionTransition {
    pub fn new(
        newer_noncurrent_versions: Option<i32>,
        noncurrent_days: Option<i32>,
        storage_class: Option<String>,
    ) -> Self {
        NoncurrentVersionTransition {
            newer_noncurrent_versions,
            noncurrent_days,
            storage_class,
        }
    }
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct Transition {
    #[serde(rename = "Date", skip_serializing_if = "Option::is_none")]
    pub date: Option<String>,

    #[serde(rename = "Days", skip_serializing_if = "Option::is_none")]
    pub days: Option<u32>,
    /// Valid Values: GLACIER | STANDARD_IA | ONEZONE_IA | INTELLIGENT_TIERING | DEEP_ARCHIVE | GLACIER_IR
    #[serde(rename = "StorageClass")]
    pub storage_class: Option<String>,
}

impl Transition {
    pub fn new(date: Option<String>, days: Option<u32>, storage_class: Option<String>) -> Self {
        Transition {
            date,
            days,
            storage_class,
        }
    }
}

#[cfg(test)]
mod test {
    use crate::serde_types::{
        AbortIncompleteMultipartUpload, BucketLifecycleConfiguration, Expiration, LifecycleFilter,
        LifecycleRule, NoncurrentVersionExpiration, NoncurrentVersionTransition, Transition,
    };

    use super::{
        CorsConfiguration, CorsRule, DeleteObjectsRequest, DeleteObjectsResult, ObjectIdentifier,
    };

    #[test]
    fn cors_config_serde() {
        let rule = CorsRule {
            allowed_headers: Some(vec!["Authorization".to_string(), "Header2".to_string()]),
            allowed_methods: vec!["GET".to_string(), "DELETE".to_string()],
            allowed_origins: vec!["*".to_string()],
            expose_headers: None,
            id: Some("lala".to_string()),
            max_age_seconds: None,
        };

        let config = CorsConfiguration {
            rules: vec![rule.clone(), rule],
        };

        let se = quick_xml::se::to_string(&config).unwrap();
        assert_eq!(
            se,
            r#"<CORSConfiguration><CORSRule><AllowedHeader>Authorization</AllowedHeader><AllowedHeader>Header2</AllowedHeader><AllowedMethod>GET</AllowedMethod><AllowedMethod>DELETE</AllowedMethod><AllowedOrigin>*</AllowedOrigin><ID>lala</ID></CORSRule><CORSRule><AllowedHeader>Authorization</AllowedHeader><AllowedHeader>Header2</AllowedHeader><AllowedMethod>GET</AllowedMethod><AllowedMethod>DELETE</AllowedMethod><AllowedOrigin>*</AllowedOrigin><ID>lala</ID></CORSRule></CORSConfiguration>"#
        )
    }

    #[test]
    fn lifecycle_config_serde() {
        let rule = LifecycleRule {
            abort_incomplete_multipart_upload: Some(AbortIncompleteMultipartUpload {
                days_after_initiation: Some(30),
            }),
            expiration: Some(Expiration {
                date: Some("2024-06-017".to_string()),
                days: Some(30),
                expired_object_delete_marker: Some(true),
            }),
            filter: Some(LifecycleFilter {
                and: None,
                object_size_greater_than: Some(10),
                object_size_less_than: Some(50),
                prefix: None,
                tag: None,
            }),
            id: Some("lala".to_string()),
            noncurrent_version_expiration: Some(NoncurrentVersionExpiration {
                newer_noncurrent_versions: Some(30),
                noncurrent_days: Some(30),
            }),
            noncurrent_version_transition: Some(vec![NoncurrentVersionTransition {
                newer_noncurrent_versions: Some(30),
                noncurrent_days: Some(30),
                storage_class: Some("GLACIER".to_string()),
            }]),
            status: "Enabled".to_string(),
            transition: Some(vec![Transition {
                date: Some("2024-06-017".to_string()),
                days: Some(30),
                storage_class: Some("GLACIER".to_string()),
            }]),
        };

        let config = BucketLifecycleConfiguration { rules: vec![rule] };

        let se = quick_xml::se::to_string(&config).unwrap();
        assert_eq!(
            se,
            r#"<LifecycleConfiguration><Rule><AbortIncompleteMultipartUpload><DaysAfterInitiation>30</DaysAfterInitiation></AbortIncompleteMultipartUpload><Expiration><Date>2024-06-017</Date><Days>30</Days><ExpiredObjectDeleteMarker>true</ExpiredObjectDeleteMarker></Expiration><Filter><ObjectSizeGreaterThan>10</ObjectSizeGreaterThan><ObjectSizeLessThan>50</ObjectSizeLessThan></Filter><ID>lala</ID><NoncurrentVersionExpiration><NewerNoncurrentVersions>30</NewerNoncurrentVersions><NoncurrentDays>30</NoncurrentDays></NoncurrentVersionExpiration><NoncurrentVersionTransition><NewerNoncurrentVersions>30</NewerNoncurrentVersions><NoncurrentDays>30</NoncurrentDays><StorageClass>GLACIER</StorageClass></NoncurrentVersionTransition><Status>Enabled</Status><Transition><Date>2024-06-017</Date><Days>30</Days><StorageClass>GLACIER</StorageClass></Transition></Rule></LifecycleConfiguration>"#
        )
    }

    #[test]
    fn delete_objects_request_serialize() {
        let request = DeleteObjectsRequest {
            objects: vec![
                ObjectIdentifier::new("file1.txt"),
                ObjectIdentifier::new("file2.txt"),
                ObjectIdentifier::with_version("file3.txt", "v1"),
            ],
            quiet: false,
        };

        let se = request.to_string();
        assert_eq!(
            se,
            r#"<Delete xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Object><Key>file1.txt</Key></Object><Object><Key>file2.txt</Key></Object><Object><Key>file3.txt</Key><VersionId>v1</VersionId></Object></Delete>"#
        )
    }

    #[test]
    fn delete_objects_request_serialize_quiet() {
        let request = DeleteObjectsRequest {
            objects: vec![ObjectIdentifier::new("file1.txt")],
            quiet: true,
        };

        let se = request.to_string();
        assert_eq!(
            se,
            r#"<Delete xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Quiet>true</Quiet><Object><Key>file1.txt</Key></Object></Delete>"#
        )
    }

    #[test]
    fn delete_objects_request_xml_escaping() {
        let request = DeleteObjectsRequest {
            objects: vec![ObjectIdentifier::new("file&name<>.txt")],
            quiet: false,
        };

        let se = request.to_string();
        assert_eq!(
            se,
            r#"<Delete xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Object><Key>file&amp;name&lt;&gt;.txt</Key></Object></Delete>"#
        )
    }

    #[test]
    fn delete_objects_request_len() {
        let request = DeleteObjectsRequest {
            objects: vec![ObjectIdentifier::new("file1.txt")],
            quiet: false,
        };

        assert_eq!(request.len(), request.to_string().len());
        assert!(!request.is_empty());
    }

    #[test]
    fn delete_objects_result_deserialize() {
        let xml = r#"<?xml version="1.0" encoding="UTF-8"?>
<DeleteResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
  <Deleted>
    <Key>file1.txt</Key>
  </Deleted>
  <Deleted>
    <Key>file2.txt</Key>
    <DeleteMarker>true</DeleteMarker>
    <DeleteMarkerVersionId>abc123</DeleteMarkerVersionId>
  </Deleted>
  <Error>
    <Key>file3.txt</Key>
    <Code>AccessDenied</Code>
    <Message>Access Denied</Message>
  </Error>
</DeleteResult>"#;

        let result: DeleteObjectsResult = quick_xml::de::from_str(xml).unwrap();
        assert_eq!(result.deleted.len(), 2);
        assert_eq!(result.deleted[0].key, "file1.txt");
        assert_eq!(result.deleted[1].key, "file2.txt");
        assert_eq!(result.deleted[1].delete_marker, Some(true));
        assert_eq!(
            result.deleted[1].delete_marker_version_id,
            Some("abc123".to_string())
        );
        assert_eq!(result.errors.len(), 1);
        assert_eq!(result.errors[0].key, "file3.txt");
        assert_eq!(result.errors[0].code, "AccessDenied");
        assert_eq!(result.errors[0].message, "Access Denied");
    }

    #[test]
    fn delete_objects_result_deserialize_empty() {
        let xml = r#"<?xml version="1.0" encoding="UTF-8"?>
<DeleteResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
</DeleteResult>"#;

        let result: DeleteObjectsResult = quick_xml::de::from_str(xml).unwrap();
        assert_eq!(result.deleted.len(), 0);
        assert_eq!(result.errors.len(), 0);
    }
}
