//! Execution-time scoped fragment read grants (`POST /v1/media/workers/read-grants`, `2.3`).
//!
//! Matches the exact wire schema and authentication headers of
//! `ServiceRadarWebNGWeb.Plugs.ControlPlaneRuntimeAuth`,
//! `ServiceRadarWebNGWeb.Plugs.ControlPlaneMediaWorkerGrants`, and
//! `ServiceRadar.Camera.VisualWorkerReadGrants`.

use crate::credentials::{EphemeralS3Credentials, WorkerAuthCredentials};
use crate::errors::{IntegrityError, MediaWorkerError};
use serde::{Deserialize, Serialize};
use std::future::Future;
use std::io::Read;
use std::time::Duration;

/// Control-plane authorization header required by `ControlPlaneRuntimeAuth`.
pub const HEADER_CONTROL_PLANE_AUTH: &str = "X-ServiceRadar-Control-Plane-Authorization";
/// Control-plane deployment reference header required by `ControlPlaneRuntimeAuth`.
pub const HEADER_DEPLOYMENT_REF: &str = "X-ServiceRadar-Deployment-Ref";
/// Control-plane media-worker generation header required by `ControlPlaneRuntimeAuth`.
pub const HEADER_MEDIA_WORKER_GENERATION: &str = "X-ServiceRadar-Media-Worker-Generation";

const MAX_GRANT_RESPONSE_BYTES: usize = 512 * 1024;

/// Request payload sent to `POST /v1/media/workers/read-grants`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReadGrantRequest {
    schema_version: u32,
    job_id: String,
    catalog_entry_id: String,
    descriptor_sha256: String,
}

impl ReadGrantRequest {
    pub fn new(
        job_id: impl Into<String>,
        catalog_entry_id: impl Into<String>,
        descriptor_sha256: impl Into<String>,
    ) -> Self {
        Self {
            schema_version: 1,
            job_id: job_id.into(),
            catalog_entry_id: catalog_entry_id.into(),
            descriptor_sha256: descriptor_sha256.into(),
        }
    }

    pub fn schema_version(&self) -> u32 {
        self.schema_version
    }

    pub fn job_id(&self) -> &str {
        &self.job_id
    }

    pub fn catalog_entry_id(&self) -> &str {
        &self.catalog_entry_id
    }

    pub fn descriptor_sha256(&self) -> &str {
        &self.descriptor_sha256
    }
}

/// Media copy backing selected by `VisualWorkerReadGrants`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BackingSource {
    Archive,
    Local,
}

/// Frozen `init.mp4` byte-slice descriptor in a `ReadGrantPlan`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct InitSlicePlan {
    #[serde(default = "default_init_name")]
    object_name: String,
    #[serde(default)]
    offset: u64,
    #[serde(default)]
    first: u64,
    #[serde(default)]
    last: u64,
    length: u64,
    sha256: String,
    #[serde(default)]
    key: Option<String>,
    #[serde(default)]
    etag: Option<String>,
    #[serde(default)]
    version_id: Option<String>,
    #[serde(default)]
    path: Option<String>,
}

fn default_init_name() -> String {
    "init.mp4".to_string()
}

impl InitSlicePlan {
    pub fn new(length: u64, sha256: impl Into<String>) -> Self {
        Self {
            object_name: "init.mp4".to_string(),
            offset: 0,
            first: 0,
            last: length.saturating_sub(1),
            length,
            sha256: sha256.into(),
            key: None,
            etag: None,
            version_id: None,
            path: None,
        }
    }

    pub fn with_archive_object(
        mut self,
        key: impl Into<String>,
        etag: Option<String>,
        version_id: Option<String>,
    ) -> Self {
        self.key = Some(key.into());
        self.etag = etag;
        self.version_id = version_id;
        self
    }

    pub fn with_local_path(mut self, path: impl Into<String>) -> Self {
        self.path = Some(path.into());
        self
    }

    pub fn object_name(&self) -> &str {
        &self.object_name
    }

    pub fn length(&self) -> u64 {
        self.length
    }

    pub fn sha256(&self) -> &str {
        &self.sha256
    }

    pub fn key(&self) -> Option<&str> {
        self.key.as_deref()
    }

    pub fn etag(&self) -> Option<&str> {
        self.etag.as_deref()
    }

    pub fn version_id(&self) -> Option<&str> {
        self.version_id.as_deref()
    }

    pub fn path(&self) -> Option<&str> {
        self.path.as_deref()
    }
}

/// Archived `media.m4s` object metadata from `NVRArchiveReceipt`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ArchiveMediaObjectPlan {
    #[serde(default = "default_media_name")]
    object_name: String,
    key: String,
    length: u64,
    sha256: String,
    #[serde(default)]
    etag: Option<String>,
    #[serde(default)]
    version_id: Option<String>,
}

fn default_media_name() -> String {
    "media.m4s".to_string()
}

impl ArchiveMediaObjectPlan {
    pub fn new(
        key: impl Into<String>,
        length: u64,
        sha256: impl Into<String>,
        etag: Option<String>,
        version_id: Option<String>,
    ) -> Self {
        Self {
            object_name: "media.m4s".to_string(),
            key: key.into(),
            length,
            sha256: sha256.into(),
            etag,
            version_id,
        }
    }

    pub fn object_name(&self) -> &str {
        &self.object_name
    }

    pub fn key(&self) -> &str {
        &self.key
    }

    pub fn length(&self) -> u64 {
        self.length
    }

    pub fn sha256(&self) -> &str {
        &self.sha256
    }

    pub fn etag(&self) -> Option<&str> {
        self.etag.as_deref()
    }

    pub fn version_id(&self) -> Option<&str> {
        self.version_id.as_deref()
    }
}

/// Sampled IDR keyframe fragment metadata from the frozen block descriptor.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FragmentSlicePlan {
    sequence: u32,
    offset: u64,
    #[serde(default)]
    first: u64,
    #[serde(default)]
    last: u64,
    length: u64,
    #[serde(default)]
    start_ns: u64,
    #[serde(default)]
    duration_ns: u64,
    sha256: String,
    #[serde(default)]
    path: Option<String>,
}

impl FragmentSlicePlan {
    pub fn new(
        sequence: u32,
        offset: u64,
        length: u64,
        start_ns: u64,
        duration_ns: u64,
        sha256: impl Into<String>,
    ) -> Self {
        Self {
            sequence,
            offset,
            first: offset,
            last: offset + length.saturating_sub(1),
            length,
            start_ns,
            duration_ns,
            sha256: sha256.into(),
            path: None,
        }
    }

    pub fn with_local_path(mut self, path: impl Into<String>) -> Self {
        self.path = Some(path.into());
        self
    }

    pub fn sequence(&self) -> u32 {
        self.sequence
    }

    pub fn offset(&self) -> u64 {
        self.offset
    }

    pub fn length(&self) -> u64 {
        self.length
    }

    pub fn start_ns(&self) -> u64 {
        self.start_ns
    }

    pub fn duration_ns(&self) -> u64 {
        self.duration_ns
    }

    pub fn sha256(&self) -> &str {
        &self.sha256
    }

    pub fn path(&self) -> Option<&str> {
        self.path.as_deref()
    }
}

/// Individual fragment slice inside a coalesced byte-range GET (`<= 4 MiB`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RangeSlice {
    sequence: u32,
    offset: u64,
    relative_offset: u64,
    length: u64,
    #[serde(default)]
    start_ns: u64,
    #[serde(default)]
    duration_ns: u64,
    sha256: String,
}

impl RangeSlice {
    pub fn new(
        sequence: u32,
        offset: u64,
        relative_offset: u64,
        length: u64,
        start_ns: u64,
        duration_ns: u64,
        sha256: impl Into<String>,
    ) -> Self {
        Self {
            sequence,
            offset,
            relative_offset,
            length,
            start_ns,
            duration_ns,
            sha256: sha256.into(),
        }
    }

    pub fn sequence(&self) -> u32 {
        self.sequence
    }

    pub fn offset(&self) -> u64 {
        self.offset
    }

    pub fn relative_offset(&self) -> u64 {
        self.relative_offset
    }

    pub fn length(&self) -> u64 {
        self.length
    }

    pub fn start_ns(&self) -> u64 {
        self.start_ns
    }

    pub fn duration_ns(&self) -> u64 {
        self.duration_ns
    }

    pub fn sha256(&self) -> &str {
        &self.sha256
    }
}

/// Coalesced byte-range GET chunk (`first..=last`, `length <= 4 MiB`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CoalescedRange {
    first: u64,
    last: u64,
    length: u64,
    fragment_sequences: Vec<u32>,
    slices: Vec<RangeSlice>,
}

impl CoalescedRange {
    pub fn new(
        first: u64,
        last: u64,
        length: u64,
        fragment_sequences: Vec<u32>,
        slices: Vec<RangeSlice>,
    ) -> Self {
        Self {
            first,
            last,
            length,
            fragment_sequences,
            slices,
        }
    }

    pub fn first(&self) -> u64 {
        self.first
    }

    pub fn last(&self) -> u64 {
        self.last
    }

    pub fn length(&self) -> u64 {
        self.length
    }

    pub fn fragment_sequences(&self) -> &[u32] {
        &self.fragment_sequences
    }

    pub fn slices(&self) -> &[RangeSlice] {
        &self.slices
    }
}

/// S3-compatible archive destination details from `VisualWorkerReadGrants`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ArchiveGrantTarget {
    #[serde(default)]
    binding_id: Option<String>,
    #[serde(default)]
    provider: Option<String>,
    endpoint: String,
    region: String,
    bucket: String,
    #[serde(default)]
    namespace: Option<String>,
    #[serde(default)]
    destination_sha256: Option<String>,
    init_key: String,
    #[serde(default)]
    init_etag: Option<String>,
    media_key: String,
    #[serde(default)]
    media_etag: Option<String>,
}

impl ArchiveGrantTarget {
    pub fn new(
        endpoint: impl Into<String>,
        region: impl Into<String>,
        bucket: impl Into<String>,
        init_key: impl Into<String>,
        media_key: impl Into<String>,
    ) -> Self {
        Self {
            binding_id: None,
            provider: Some("s3_compatible".to_string()),
            endpoint: endpoint.into(),
            region: region.into(),
            bucket: bucket.into(),
            namespace: None,
            destination_sha256: None,
            init_key: init_key.into(),
            init_etag: None,
            media_key: media_key.into(),
            media_etag: None,
        }
    }

    pub fn with_etags(mut self, init_etag: Option<String>, media_etag: Option<String>) -> Self {
        self.init_etag = init_etag;
        self.media_etag = media_etag;
        self
    }

    pub fn endpoint(&self) -> &str {
        &self.endpoint
    }

    pub fn region(&self) -> &str {
        &self.region
    }

    pub fn bucket(&self) -> &str {
        &self.bucket
    }

    pub fn init_key(&self) -> &str {
        &self.init_key
    }

    pub fn init_etag(&self) -> Option<&str> {
        self.init_etag.as_deref()
    }

    pub fn media_key(&self) -> &str {
        &self.media_key
    }

    pub fn media_etag(&self) -> Option<&str> {
        self.media_etag.as_deref()
    }
}

/// `:reader`-only (`["GET", "HEAD"]`) `CredentialBrokerGrant` scope restrictions.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BrokerGrantScope {
    #[serde(default)]
    grant_id: Option<String>,
    #[serde(default)]
    grant_type: Option<String>,
    role: String,
    #[serde(default)]
    purpose: Option<String>,
    #[serde(default)]
    secret_ref: Option<String>,
    #[serde(default)]
    allowed_schemes: Vec<String>,
    #[serde(default)]
    allowed_hosts: Vec<String>,
    #[serde(default)]
    allowed_ports: Vec<u16>,
    #[serde(default)]
    allowed_paths: Vec<String>,
    allowed_methods: Vec<String>,
}

impl BrokerGrantScope {
    pub fn reader_only(
        allowed_schemes: Vec<String>,
        allowed_hosts: Vec<String>,
        allowed_ports: Vec<u16>,
        allowed_paths: Vec<String>,
    ) -> Self {
        Self {
            grant_id: None,
            grant_type: Some("camera_archive_credential".to_string()),
            role: "reader".to_string(),
            purpose: Some("camera_archive_read".to_string()),
            secret_ref: None,
            allowed_schemes,
            allowed_hosts,
            allowed_ports,
            allowed_paths,
            allowed_methods: vec!["HEAD".to_string(), "GET".to_string()],
        }
    }

    pub fn with_role_and_methods(mut self, role: impl Into<String>, methods: Vec<String>) -> Self {
        self.role = role.into();
        self.allowed_methods = methods;
        self
    }

    pub fn role(&self) -> &str {
        &self.role
    }

    pub fn allowed_schemes(&self) -> &[String] {
        &self.allowed_schemes
    }

    pub fn allowed_hosts(&self) -> &[String] {
        &self.allowed_hosts
    }

    pub fn allowed_ports(&self) -> &[u16] {
        &self.allowed_ports
    }

    pub fn allowed_paths(&self) -> &[String] {
        &self.allowed_paths
    }

    pub fn allowed_methods(&self) -> &[String] {
        &self.allowed_methods
    }

    pub fn validate_reader_only(&self) -> Result<(), IntegrityError> {
        if self.role != "reader" {
            return Err(IntegrityError::grant_scope_violation(format!(
                "archive broker grant role must be 'reader', got '{}'",
                self.role
            )));
        }
        if self.allowed_methods.is_empty() {
            return Err(IntegrityError::grant_scope_violation(
                "archive broker grant allowed_methods must not be empty",
            ));
        }
        let all_reader = self
            .allowed_methods
            .iter()
            .all(|m| m.eq_ignore_ascii_case("GET") || m.eq_ignore_ascii_case("HEAD"));
        if !all_reader {
            return Err(IntegrityError::grant_scope_violation(format!(
                "archive broker grant allowed_methods {:?} exceeds reader-only GET/HEAD scope",
                self.allowed_methods
            )));
        }
        Ok(())
    }
}

/// Local NVR `analysis_read` target descriptor from `VisualWorkerReadGrants`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LocalGrantTarget {
    #[serde(default)]
    nvr_member: Option<String>,
    storage_id: String,
    block_key: String,
    #[serde(default = "default_analysis_pool")]
    pool: String,
    #[serde(default = "default_analysis_pool")]
    purpose: String,
    #[serde(default)]
    init_path: Option<String>,
    #[serde(default)]
    endpoint: Option<String>,
}

fn default_analysis_pool() -> String {
    "analysis_read".to_string()
}

impl LocalGrantTarget {
    pub fn new(
        nvr_member: Option<String>,
        storage_id: impl Into<String>,
        block_key: impl Into<String>,
    ) -> Self {
        let bkey = block_key.into();
        let init_path = format!("/v1/blocks/{bkey}/init");
        Self {
            nvr_member,
            storage_id: storage_id.into(),
            block_key: bkey,
            pool: "analysis_read".to_string(),
            purpose: "analysis_read".to_string(),
            init_path: Some(init_path),
            endpoint: None,
        }
    }

    pub fn with_endpoint(mut self, endpoint: impl Into<String>) -> Self {
        self.endpoint = Some(endpoint.into());
        self
    }

    pub fn nvr_member(&self) -> Option<&str> {
        self.nvr_member.as_deref()
    }

    pub fn storage_id(&self) -> &str {
        &self.storage_id
    }

    pub fn block_key(&self) -> &str {
        &self.block_key
    }

    pub fn pool(&self) -> &str {
        &self.pool
    }

    pub fn purpose(&self) -> &str {
        &self.purpose
    }

    pub fn init_path(&self) -> Option<&str> {
        self.init_path.as_deref()
    }

    pub fn endpoint(&self) -> Option<&str> {
        self.endpoint.as_deref()
    }
}

/// Execution-time read grant plan returned by `POST /v1/media/workers/read-grants`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReadGrantPlan {
    #[serde(default = "default_schema_v1")]
    schema_version: u32,
    #[serde(alias = "backing")]
    source: BackingSource,
    job_id: String,
    catalog_entry_id: String,
    camera_source_id: String,
    stream_profile_id: String,
    storage_id: String,
    block_key: String,
    descriptor_sha256: String,
    init_sha256: String,
    #[serde(default = "default_ttl_secs")]
    ttl_seconds: u64,
    init: InitSlicePlan,
    #[serde(default)]
    media: Option<ArchiveMediaObjectPlan>,
    fragments: Vec<FragmentSlicePlan>,
    #[serde(default)]
    coalesced_ranges: Vec<CoalescedRange>,
    #[serde(default)]
    archive: Option<ArchiveGrantTarget>,
    #[serde(default)]
    grant: Option<BrokerGrantScope>,
    #[serde(default)]
    credential: Option<EphemeralS3Credentials>,
    #[serde(default)]
    local: Option<LocalGrantTarget>,
    #[serde(default)]
    nvr_member: Option<String>,
    #[serde(default)]
    read_pool: Option<String>,
}

fn default_schema_v1() -> u32 {
    1
}

fn default_ttl_secs() -> u64 {
    300
}

/// Parameters for constructing a synthetic or resolved archive-backed `ReadGrantPlan`.
#[derive(Debug, Clone)]
pub struct ArchivePlanSpec {
    pub job_id: String,
    pub catalog_entry_id: String,
    pub camera_source_id: String,
    pub stream_profile_id: String,
    pub storage_id: String,
    pub block_key: String,
    pub descriptor_sha256: String,
    pub init: InitSlicePlan,
    pub media: ArchiveMediaObjectPlan,
    pub fragments: Vec<FragmentSlicePlan>,
    pub coalesced_ranges: Vec<CoalescedRange>,
    pub archive: ArchiveGrantTarget,
    pub grant: BrokerGrantScope,
    pub credential: Option<EphemeralS3Credentials>,
}

/// Parameters for constructing a synthetic or resolved local-NVR `ReadGrantPlan`.
#[derive(Debug, Clone)]
pub struct LocalPlanSpec {
    pub job_id: String,
    pub catalog_entry_id: String,
    pub camera_source_id: String,
    pub stream_profile_id: String,
    pub storage_id: String,
    pub block_key: String,
    pub descriptor_sha256: String,
    pub init: InitSlicePlan,
    pub fragments: Vec<FragmentSlicePlan>,
    pub coalesced_ranges: Vec<CoalescedRange>,
    pub local: LocalGrantTarget,
}

impl ReadGrantPlan {
    pub fn from_archive_spec(spec: ArchivePlanSpec) -> Self {
        let init_sha256 = spec.init.sha256().to_string();
        Self {
            schema_version: 1,
            source: BackingSource::Archive,
            job_id: spec.job_id,
            catalog_entry_id: spec.catalog_entry_id,
            camera_source_id: spec.camera_source_id,
            stream_profile_id: spec.stream_profile_id,
            storage_id: spec.storage_id,
            block_key: spec.block_key,
            descriptor_sha256: spec.descriptor_sha256,
            init_sha256,
            ttl_seconds: 300,
            init: spec.init,
            media: Some(spec.media),
            fragments: spec.fragments,
            coalesced_ranges: spec.coalesced_ranges,
            archive: Some(spec.archive),
            grant: Some(spec.grant),
            credential: spec.credential,
            local: None,
            nvr_member: None,
            read_pool: None,
        }
    }

    pub fn from_local_spec(spec: LocalPlanSpec) -> Self {
        let init_sha256 = spec.init.sha256().to_string();
        let member = spec.local.nvr_member().map(str::to_string);
        Self {
            schema_version: 1,
            source: BackingSource::Local,
            job_id: spec.job_id,
            catalog_entry_id: spec.catalog_entry_id,
            camera_source_id: spec.camera_source_id,
            stream_profile_id: spec.stream_profile_id,
            storage_id: spec.storage_id,
            block_key: spec.block_key,
            descriptor_sha256: spec.descriptor_sha256,
            init_sha256,
            ttl_seconds: 300,
            init: spec.init,
            media: None,
            fragments: spec.fragments,
            coalesced_ranges: spec.coalesced_ranges,
            archive: None,
            grant: None,
            credential: None,
            local: Some(spec.local),
            nvr_member: member,
            read_pool: Some("analysis_read".to_string()),
        }
    }

    pub fn source(&self) -> BackingSource {
        self.source
    }

    pub fn job_id(&self) -> &str {
        &self.job_id
    }

    pub fn catalog_entry_id(&self) -> &str {
        &self.catalog_entry_id
    }

    pub fn camera_source_id(&self) -> &str {
        &self.camera_source_id
    }

    pub fn stream_profile_id(&self) -> &str {
        &self.stream_profile_id
    }

    pub fn storage_id(&self) -> &str {
        &self.storage_id
    }

    pub fn block_key(&self) -> &str {
        &self.block_key
    }

    pub fn descriptor_sha256(&self) -> &str {
        &self.descriptor_sha256
    }

    pub fn init_sha256(&self) -> &str {
        &self.init_sha256
    }

    pub fn init(&self) -> &InitSlicePlan {
        &self.init
    }

    pub fn media(&self) -> Option<&ArchiveMediaObjectPlan> {
        self.media.as_ref()
    }

    pub fn fragments(&self) -> &[FragmentSlicePlan] {
        &self.fragments
    }

    pub fn coalesced_ranges(&self) -> &[CoalescedRange] {
        &self.coalesced_ranges
    }

    pub fn archive(&self) -> Option<&ArchiveGrantTarget> {
        self.archive.as_ref()
    }

    pub fn grant(&self) -> Option<&BrokerGrantScope> {
        self.grant.as_ref()
    }

    pub fn credential(&self) -> Option<&EphemeralS3Credentials> {
        self.credential.as_ref()
    }

    pub fn local(&self) -> Option<&LocalGrantTarget> {
        self.local.as_ref()
    }

    pub fn nvr_member(&self) -> Option<&str> {
        self.local
            .as_ref()
            .and_then(|l| l.nvr_member())
            .or(self.nvr_member.as_deref())
    }

    pub fn validate_for_request(&self, req: &ReadGrantRequest) -> Result<(), IntegrityError> {
        if self.schema_version != 1 {
            return Err(IntegrityError::grant_scope_violation(format!(
                "unsupported read grant schema_version {}",
                self.schema_version
            )));
        }
        if self.job_id != req.job_id() {
            return Err(IntegrityError::grant_scope_violation(format!(
                "read grant job_id '{}' does not match requested '{}'",
                self.job_id,
                req.job_id()
            )));
        }
        if self.catalog_entry_id != req.catalog_entry_id() {
            return Err(IntegrityError::grant_scope_violation(format!(
                "read grant catalog_entry_id '{}' does not match requested '{}'",
                self.catalog_entry_id,
                req.catalog_entry_id()
            )));
        }
        if self.descriptor_sha256 != req.descriptor_sha256() {
            return Err(IntegrityError::grant_scope_violation(
                "read grant descriptor_sha256 does not match frozen job descriptor_sha256",
            ));
        }
        if self.init_sha256 != self.init.sha256() {
            return Err(IntegrityError::grant_scope_violation(
                "read grant top-level init_sha256 disagrees with init.sha256",
            ));
        }
        if self.fragments.is_empty() {
            return Err(IntegrityError::grant_scope_violation(
                "read grant contains zero sampled fragments",
            ));
        }

        match self.source {
            BackingSource::Archive => {
                let Some(grant) = &self.grant else {
                    return Err(IntegrityError::grant_scope_violation(
                        "archive read grant missing CredentialBrokerGrant scope",
                    ));
                };
                grant.validate_reader_only()?;
                if self.archive.is_none() {
                    return Err(IntegrityError::grant_scope_violation(
                        "archive read grant missing archive destination target",
                    ));
                }
            }
            BackingSource::Local => {
                if let Some(pool) = self
                    .local
                    .as_ref()
                    .map(LocalGrantTarget::pool)
                    .or(self.read_pool.as_deref())
                    && pool != "analysis_read"
                {
                    return Err(IntegrityError::grant_scope_violation(format!(
                        "local read grant must target 'analysis_read' pool, got '{pool}'"
                    )));
                }
            }
        }
        Ok(())
    }
}

/// Outcome of requesting an execution-time read grant (`200 OK` vs `410 Gone`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GrantResolution {
    Admitted(Box<ReadGrantPlan>),
    /// `410 Gone` (`recording_gone` / deleted or quarantined block): clean skip without retry.
    Gone,
}

/// Static-dispatch trait for acquiring execution-time read grants.
pub trait GrantClient: Send + Sync {
    fn acquire_read_grant(
        &self,
        request: &ReadGrantRequest,
    ) -> impl Future<Output = Result<GrantResolution, MediaWorkerError>> + Send;
}

/// HTTP client calling `POST <control_plane_url>/v1/media/workers/read-grants`.
#[derive(Debug, Clone)]
pub struct HttpControlPlaneGrantClient {
    base_url: String,
    auth: WorkerAuthCredentials,
    timeout: Duration,
}

impl HttpControlPlaneGrantClient {
    pub fn new(
        base_url: impl Into<String>,
        auth: WorkerAuthCredentials,
        timeout: Duration,
    ) -> Self {
        Self {
            base_url: base_url.into(),
            auth,
            timeout,
        }
    }
}

impl GrantClient for HttpControlPlaneGrantClient {
    async fn acquire_read_grant(
        &self,
        request: &ReadGrantRequest,
    ) -> Result<GrantResolution, MediaWorkerError> {
        let url = format!(
            "{}/v1/media/workers/read-grants",
            self.base_url.trim_end_matches('/')
        );
        let auth = self.auth.clone();
        let req_clone = request.clone();
        let timeout = self.timeout;

        tokio::task::spawn_blocking(move || execute_grant_post(&url, &auth, &req_clone, timeout))
            .await
            .map_err(|err| {
                MediaWorkerError::storage_transport(format!("grant HTTP task panicked: {err}"))
            })?
    }
}

fn execute_grant_post(
    url: &str,
    auth: &WorkerAuthCredentials,
    request: &ReadGrantRequest,
    timeout: Duration,
) -> Result<GrantResolution, MediaWorkerError> {
    let agent = ureq::config::Config::builder()
        .http_status_as_error(false)
        .timeout_global(Some(timeout))
        .build()
        .new_agent();

    let bearer = format!("Bearer {}", auth.token());
    let mut response = agent
        .post(url)
        .header("Content-Type", "application/json")
        .header("Accept", "application/json")
        .header(HEADER_CONTROL_PLANE_AUTH, &bearer)
        .header(HEADER_DEPLOYMENT_REF, auth.deployment_ref())
        .header(HEADER_MEDIA_WORKER_GENERATION, auth.generation())
        .send_json(request)
        .map_err(|err| {
            MediaWorkerError::storage_transport(format!(
                "POST /v1/media/workers/read-grants transport failed: {err}"
            ))
        })?;

    let status = response.status().as_u16();
    let mut raw_body = Vec::new();
    response
        .body_mut()
        .as_reader()
        .take((MAX_GRANT_RESPONSE_BYTES + 1) as u64)
        .read_to_end(&mut raw_body)
        .map_err(|err| {
            MediaWorkerError::storage_transport(format!(
                "failed reading read-grants response body: {err}"
            ))
        })?;

    if raw_body.len() > MAX_GRANT_RESPONSE_BYTES {
        return Err(MediaWorkerError::control_plane_rejected(
            status,
            "read-grants response exceeded 512 KiB bound",
        ));
    }

    if status == 410 {
        return Ok(GrantResolution::Gone);
    }

    if status != 200 {
        let reason = extract_status_reason(&raw_body);
        return Err(MediaWorkerError::control_plane_rejected(status, reason));
    }

    let plan: ReadGrantPlan = serde_json::from_slice(&raw_body).map_err(|err| {
        MediaWorkerError::control_plane_rejected(
            200,
            format!("invalid read-grants JSON payload: {err}"),
        )
    })?;
    plan.validate_for_request(request)?;
    Ok(GrantResolution::Admitted(Box::new(plan)))
}

fn extract_status_reason(raw_body: &[u8]) -> String {
    if let Ok(val) = serde_json::from_slice::<serde_json::Value>(raw_body)
        && let Some(reason) = val
            .get("status")
            .or_else(|| val.get("error"))
            .and_then(|v| v.as_str())
    {
        return reason.to_string();
    }
    "read_grant_rejected".to_string()
}
