//! Bounded byte-range coalescing (`<= 4 MiB`), `longshore_s3` archive reads,
//! NVR `analysis_read` HTTP reads, and mandatory SHA-256 verification (`2.3`).

use crate::credentials::{EphemeralS3Credentials, RedactedPresignedUrl};
use crate::errors::{IntegrityError, MediaWorkerError};
use crate::grants::{
    ArchiveGrantTarget, BackingSource, BrokerGrantScope, CoalescedRange, FragmentSlicePlan,
    LocalGrantTarget, RangeSlice, ReadGrantPlan,
};
use longshore_s3::client::{Budget, BuildError, Builder};
use longshore_s3::creds::Credentials;
use longshore_s3::report::{ETAG_MAX, ETag, End, Expect, VERSION_ID_MAX, VersionId};
use sha2::{Digest, Sha256};
use std::future::Future;
use std::io::Read;
use std::net::{IpAddr, SocketAddr};
use std::time::{Duration, Instant};

/// Maximum byte length of a single coalesced ranged GET (`4 MiB`).
pub const MAX_COALESCED_RANGE_BYTES: u64 = 4 * 1024 * 1024;
/// Maximum inter-fragment byte gap merged into one coalesced GET (`256 KiB`).
pub const MAX_COALESCE_GAP_BYTES: u64 = 256 * 1024;
/// Maximum `init.mp4` byte size (`1 MiB`).
pub const MAX_INIT_SEGMENT_BYTES: u64 = 1024 * 1024;
/// Hard ceiling on locked native buffer pool memory registered by `longshore_s3` (`64 MiB`).
pub const MAX_LONGSHORE_REGISTERED_POOL_BYTES: usize = 64 * 1024 * 1024;

/// Verified `media.m4s` fragment bytes after passing mandatory SHA-256 check.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VerifiedFragmentBytes {
    sequence: u32,
    start_ns: u64,
    duration_ns: u64,
    sha256: String,
    bytes: Vec<u8>,
}

impl VerifiedFragmentBytes {
    pub fn sequence(&self) -> u32 {
        self.sequence
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

    pub fn bytes(&self) -> &[u8] {
        &self.bytes
    }
}

/// Verified `init.mp4` and sampled fragment bytes ready for CMAF parsing and decode.
///
/// Constructible only after `verify_sha256_hex` succeeds on `init.mp4` and every
/// sampled fragment slice.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VerifiedKeyframeBlock {
    init_bytes: Vec<u8>,
    fragments: Vec<VerifiedFragmentBytes>,
}

impl VerifiedKeyframeBlock {
    pub fn from_unverified(
        init_bytes: Vec<u8>,
        expected_init_sha256: &str,
        raw_fragments: Vec<(FragmentSlicePlan, Vec<u8>)>,
    ) -> Result<Self, IntegrityError> {
        verify_sha256_hex(&init_bytes, expected_init_sha256, "init.mp4")?;

        let mut verified = Vec::with_capacity(raw_fragments.len());
        for (meta, bytes) in raw_fragments {
            verify_sha256_hex(
                &bytes,
                meta.sha256(),
                &format!("fragment:{}", meta.sequence()),
            )?;
            verified.push(VerifiedFragmentBytes {
                sequence: meta.sequence(),
                start_ns: meta.start_ns(),
                duration_ns: meta.duration_ns(),
                sha256: meta.sha256().to_string(),
                bytes,
            });
        }
        verified.sort_by_key(VerifiedFragmentBytes::sequence);
        Ok(Self {
            init_bytes,
            fragments: verified,
        })
    }

    pub fn init_bytes(&self) -> &[u8] {
        &self.init_bytes
    }

    pub fn fragments(&self) -> &[VerifiedFragmentBytes] {
        &self.fragments
    }
}

/// Coalesces sampled fragment ranges into contiguous GET chunks bounded at
/// `<= 4 MiB` (`4_194_304` bytes) with `<= 256 KiB` gap tolerance, matching
/// `ServiceRadar.Camera.VisualWorkerReadGrants.coalesce_fragment_ranges/1`.
pub fn coalesce_fragment_ranges(
    fragments: &[FragmentSlicePlan],
) -> Result<Vec<CoalescedRange>, IntegrityError> {
    if fragments.is_empty() {
        return Ok(Vec::new());
    }

    let mut sorted = fragments.to_vec();
    sorted.sort_by_key(FragmentSlicePlan::offset);

    let mut pending_chunks: Vec<(u64, u64, Vec<FragmentSlicePlan>)> = Vec::new();
    for frag in sorted {
        if frag.length() == 0 || frag.length() > MAX_COALESCED_RANGE_BYTES {
            return Err(IntegrityError::range_too_large(
                frag.length(),
                MAX_COALESCED_RANGE_BYTES,
            ));
        }
        validate_hex64(frag.sha256())?;
        let frag_last = frag
            .offset()
            .checked_add(frag.length() - 1)
            .ok_or_else(|| IntegrityError::range_too_large(u64::MAX, MAX_COALESCED_RANGE_BYTES))?;

        match pending_chunks.last_mut() {
            Some((first, last, items)) if frag.offset() > *last => {
                let gap = frag.offset() - (*last + 1);
                let merged_len = frag_last - *first + 1;
                if gap <= MAX_COALESCE_GAP_BYTES && merged_len <= MAX_COALESCED_RANGE_BYTES {
                    *last = frag_last;
                    items.push(frag);
                } else {
                    pending_chunks.push((frag.offset(), frag_last, vec![frag]));
                }
            }
            None => {
                pending_chunks.push((frag.offset(), frag_last, vec![frag]));
            }
            Some(_) => {
                // Overlapping or duplicate fragment offset: isolate in its own chunk.
                pending_chunks.push((frag.offset(), frag_last, vec![frag]));
            }
        }
    }

    Ok(pending_chunks
        .into_iter()
        .map(|(first, last, frags)| {
            let length = last - first + 1;
            let seqs = frags.iter().map(FragmentSlicePlan::sequence).collect();
            let slices = frags
                .into_iter()
                .map(|f| {
                    RangeSlice::new(
                        f.sequence(),
                        f.offset(),
                        f.offset() - first,
                        f.length(),
                        f.start_ns(),
                        f.duration_ns(),
                        f.sha256(),
                    )
                })
                .collect();
            CoalescedRange::new(first, last, length, seqs, slices)
        })
        .collect())
}

/// Validates and extracts individual fragment byte slices from a fetched coalesced
/// range buffer, verifying each fragment's SHA-256 digest against the frozen descriptor
/// BEFORE returning any slice.
pub fn extract_and_verify_slices(
    chunk_bytes: &[u8],
    range: &CoalescedRange,
) -> Result<Vec<VerifiedFragmentBytes>, IntegrityError> {
    if range.length() > MAX_COALESCED_RANGE_BYTES {
        return Err(IntegrityError::range_too_large(
            range.length(),
            MAX_COALESCED_RANGE_BYTES,
        ));
    }

    let mut out = Vec::with_capacity(range.slices().len());
    for slice in range.slices() {
        let start = usize::try_from(slice.relative_offset()).map_err(|_| {
            IntegrityError::out_of_bounds_slice(
                slice.sequence(),
                slice.relative_offset(),
                slice.length(),
                chunk_bytes.len(),
            )
        })?;
        let len = usize::try_from(slice.length()).map_err(|_| {
            IntegrityError::out_of_bounds_slice(
                slice.sequence(),
                slice.relative_offset(),
                slice.length(),
                chunk_bytes.len(),
            )
        })?;
        let end = start.checked_add(len).ok_or_else(|| {
            IntegrityError::out_of_bounds_slice(
                slice.sequence(),
                slice.relative_offset(),
                slice.length(),
                chunk_bytes.len(),
            )
        })?;

        if end > chunk_bytes.len() {
            return Err(IntegrityError::out_of_bounds_slice(
                slice.sequence(),
                slice.relative_offset(),
                slice.length(),
                chunk_bytes.len(),
            ));
        }

        let frag_bytes = &chunk_bytes[start..end];
        verify_sha256_hex(
            frag_bytes,
            slice.sha256(),
            &format!("fragment:{}", slice.sequence()),
        )?;

        out.push(VerifiedFragmentBytes {
            sequence: slice.sequence(),
            start_ns: slice.start_ns(),
            duration_ns: slice.duration_ns(),
            sha256: slice.sha256().to_string(),
            bytes: frag_bytes.to_vec(),
        });
    }
    Ok(out)
}

/// Verifies `bytes` match a 64-character lowercase hexadecimal SHA-256 digest.
pub fn verify_sha256_hex(
    bytes: &[u8],
    expected_hex: &str,
    target: &str,
) -> Result<(), IntegrityError> {
    validate_hex64(expected_hex)?;
    let actual_hex = hex::encode(Sha256::digest(bytes));
    if actual_hex != expected_hex {
        return Err(IntegrityError::digest_mismatch(
            target,
            expected_hex,
            actual_hex,
        ));
    }
    Ok(())
}

fn validate_hex64(hex_str: &str) -> Result<(), IntegrityError> {
    let valid = hex_str.len() == 64
        && hex_str
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b));
    if !valid {
        return Err(IntegrityError::invalid_hex_digest(hex_str));
    }
    Ok(())
}

/// Computes the exact native buffer memory `longshore_s3` locks for one I/O thread
/// (`longshore_nif/src/lib.rs:82-89`), including two TLS record buffers per connection.
pub fn longshore_registered_pool_bytes(concurrency: usize, buffer_size: usize, tls: bool) -> usize {
    let (record_buffers, size_floor) = if tls {
        (2 * concurrency, 256 * 1024)
    } else {
        (0, 8192)
    };
    (concurrency + record_buffers) * buffer_size.max(size_floor)
}

/// Static-dispatch trait for fetching and SHA-256-verifying keyframe blocks from
/// an admitted `ReadGrantPlan`.
pub trait FragmentStore: Send + Sync {
    fn fetch_verified_block(
        &self,
        plan: &ReadGrantPlan,
    ) -> impl Future<Output = Result<VerifiedKeyframeBlock, MediaWorkerError>> + Send;
}

/// Archive S3 byte-range reader backed by `longshore_s3::Client` (`<= 64 MiB` pool).
#[derive(Debug, Clone)]
pub struct LongshoreArchiveReader {
    concurrency: usize,
    timeout: Duration,
    portable: bool,
    fallback_credentials: Option<EphemeralS3Credentials>,
}

impl Default for LongshoreArchiveReader {
    fn default() -> Self {
        Self {
            concurrency: 2,
            timeout: Duration::from_secs(15),
            portable: false,
            fallback_credentials: None,
        }
    }
}

impl LongshoreArchiveReader {
    pub fn new(concurrency: usize, timeout: Duration) -> Self {
        Self {
            concurrency: concurrency.clamp(1, 4),
            timeout,
            portable: false,
            fallback_credentials: None,
        }
    }

    pub fn with_portable(mut self, portable: bool) -> Self {
        self.portable = portable;
        self
    }

    pub fn with_fallback_credentials(mut self, creds: EphemeralS3Credentials) -> Self {
        self.fallback_credentials = Some(creds);
        self
    }

    pub async fn fetch_archive_plan(
        &self,
        plan: &ReadGrantPlan,
    ) -> Result<VerifiedKeyframeBlock, MediaWorkerError> {
        let archive = plan.archive().ok_or_else(|| {
            MediaWorkerError::integrity(IntegrityError::grant_scope_violation(
                "archive plan missing archive target",
            ))
        })?;
        let scope = plan.grant().ok_or_else(|| {
            MediaWorkerError::integrity(IntegrityError::grant_scope_violation(
                "archive plan missing broker grant scope",
            ))
        })?;
        scope.validate_reader_only()?;

        let coalesced = if plan.coalesced_ranges().is_empty() {
            coalesce_fragment_ranges(plan.fragments())?
        } else {
            validate_coalesced_ranges(plan.coalesced_ranges())?;
            plan.coalesced_ranges().to_vec()
        };

        let init_len = plan.init().length();
        if init_len == 0 || init_len > MAX_INIT_SEGMENT_BYTES {
            return Err(MediaWorkerError::integrity(
                IntegrityError::range_too_large(init_len, MAX_INIT_SEGMENT_BYTES),
            ));
        }

        if let Some((init_presigned, media_presigned)) = plan.resolve_presigned_urls()? {
            let plan_clone = plan.clone();
            let archive_clone = archive.clone();
            let scope_clone = scope.clone();
            let timeout = self.timeout;

            return tokio::task::spawn_blocking(move || {
                execute_presigned_ranged_reads(
                    &plan_clone,
                    &archive_clone,
                    &scope_clone,
                    &init_presigned,
                    &media_presigned,
                    &coalesced,
                    timeout,
                )
            })
            .await
            .map_err(|err| {
                MediaWorkerError::storage_transport(format!(
                    "pre-signed archive reader task panicked: {err}"
                ))
            })?;
        }

        let creds = plan
            .credential()
            .filter(|c| c.has_key_material())
            .or(self.fallback_credentials.as_ref())
            .filter(|c| c.has_key_material())
            .cloned()
            .ok_or_else(|| {
                MediaWorkerError::storage_transport(
                    "archive read grant contains neither pre-signed URLs nor fallback reader credentials",
                )
            })?;

        let plan_clone = plan.clone();
        let archive_clone = archive.clone();
        let scope_clone = scope.clone();
        let options = LongshoreReadOptions {
            concurrency: self.concurrency,
            timeout: self.timeout,
            portable: self.portable,
        };

        tokio::task::spawn_blocking(move || {
            execute_longshore_ranged_reads(
                &plan_clone,
                &archive_clone,
                &scope_clone,
                &creds,
                &coalesced,
                options,
            )
        })
        .await
        .map_err(|err| {
            MediaWorkerError::storage_transport(format!(
                "longshore_s3 archive reader task panicked: {err}"
            ))
        })?
    }
}

fn validate_coalesced_ranges(ranges: &[CoalescedRange]) -> Result<(), IntegrityError> {
    for range in ranges {
        if range.length() == 0 || range.length() > MAX_COALESCED_RANGE_BYTES {
            return Err(IntegrityError::range_too_large(
                range.length(),
                MAX_COALESCED_RANGE_BYTES,
            ));
        }
        if range.last() < range.first() || (range.last() - range.first() + 1) != range.length() {
            return Err(IntegrityError::grant_scope_violation(
                "coalesced range bounds (first, last, length) are inconsistent",
            ));
        }
        for slice in range.slices() {
            validate_hex64(slice.sha256())?;
        }
    }
    Ok(())
}

#[derive(Debug, Clone)]
struct ParsedEndpoint {
    tls: bool,
    host: String,
    port: u16,
    ip_addr: Option<IpAddr>,
}

fn parse_and_verify_endpoint(
    endpoint: &str,
    bucket: &str,
    keys: &[&str],
    scope: &BrokerGrantScope,
) -> Result<ParsedEndpoint, MediaWorkerError> {
    let trimmed = endpoint.trim().trim_end_matches('/');
    let (scheme, rest) = trimmed.split_once("://").ok_or_else(|| {
        MediaWorkerError::integrity(IntegrityError::grant_scope_violation(format!(
            "archive endpoint '{endpoint}' missing scheme"
        )))
    })?;

    let tls = match scheme.to_ascii_lowercase().as_str() {
        "https" => true,
        "http" => false,
        other => {
            return Err(MediaWorkerError::integrity(
                IntegrityError::grant_scope_violation(format!(
                    "unsupported archive endpoint scheme '{other}'"
                )),
            ));
        }
    };

    let host_port = rest.split('/').next().unwrap_or(rest);
    let (host, port) = split_host_port(host_port, if tls { 443 } else { 80 })?;
    let ip_addr = host.parse::<IpAddr>().ok();

    // Non-TLS S3 connections are strictly prohibited except on loopback IPs for local hermetic tests.
    if !tls && !ip_addr.is_some_and(|ip| ip.is_loopback()) {
        return Err(MediaWorkerError::integrity(
            IntegrityError::grant_scope_violation(format!(
                "plaintext HTTP archive endpoint '{host}' is forbidden outside loopback"
            )),
        ));
    }

    if !scope.allowed_schemes().is_empty()
        && !scope
            .allowed_schemes()
            .iter()
            .any(|s| s.eq_ignore_ascii_case(scheme))
    {
        return Err(MediaWorkerError::integrity(
            IntegrityError::grant_scope_violation(format!(
                "endpoint scheme '{scheme}' not permitted by grant allowed_schemes"
            )),
        ));
    }

    if !scope.allowed_hosts().is_empty()
        && !scope
            .allowed_hosts()
            .iter()
            .any(|h| h.eq_ignore_ascii_case(&host))
    {
        return Err(MediaWorkerError::integrity(
            IntegrityError::grant_scope_violation(format!(
                "endpoint host '{host}' not permitted by grant allowed_hosts"
            )),
        ));
    }

    if !scope.allowed_ports().is_empty() && !scope.allowed_ports().contains(&port) {
        return Err(MediaWorkerError::integrity(
            IntegrityError::grant_scope_violation(format!(
                "endpoint port {port} not permitted by grant allowed_ports"
            )),
        ));
    }

    if !scope.allowed_paths().is_empty() {
        for key in keys {
            let full_path = format!("/{bucket}/{}", key.trim_start_matches('/'));
            let matched = scope.allowed_paths().iter().any(|pattern| {
                let prefix = pattern.trim_end_matches('*');
                full_path.starts_with(prefix)
            });
            if !matched {
                return Err(MediaWorkerError::integrity(
                    IntegrityError::grant_scope_violation(format!(
                        "object path '{full_path}' outside grant allowed_paths"
                    )),
                ));
            }
        }
    }

    Ok(ParsedEndpoint {
        tls,
        host,
        port,
        ip_addr,
    })
}

fn split_host_port(host_port: &str, default_port: u16) -> Result<(String, u16), MediaWorkerError> {
    if let Some((host, port_str)) = host_port.rsplit_once(':')
        && !host.contains(':')
    {
        let port = port_str.parse::<u16>().map_err(|_| {
            MediaWorkerError::integrity(IntegrityError::grant_scope_violation(format!(
                "invalid endpoint port '{port_str}'"
            )))
        })?;
        if port == 0 {
            return Err(MediaWorkerError::integrity(
                IntegrityError::grant_scope_violation("endpoint port cannot be 0"),
            ));
        }
        return Ok((host.to_string(), port));
    }
    Ok((host_port.to_string(), default_port))
}

#[derive(Debug, Clone, Copy)]
struct LongshoreReadOptions {
    concurrency: usize,
    timeout: Duration,
    portable: bool,
}

fn execute_longshore_ranged_reads(
    plan: &ReadGrantPlan,
    archive: &ArchiveGrantTarget,
    scope: &BrokerGrantScope,
    creds: &EphemeralS3Credentials,
    coalesced: &[CoalescedRange],
    options: LongshoreReadOptions,
) -> Result<VerifiedKeyframeBlock, MediaWorkerError> {
    let LongshoreReadOptions {
        concurrency,
        timeout,
        portable,
    } = options;
    let init_key = plan.init().key().unwrap_or_else(|| archive.init_key());
    let media_key = plan
        .media()
        .map(|m| m.key())
        .unwrap_or_else(|| archive.media_key());

    let parsed = parse_and_verify_endpoint(
        archive.endpoint(),
        archive.bucket(),
        &[init_key, media_key],
        scope,
    )?;

    let max_range_len = coalesced
        .iter()
        .map(CoalescedRange::length)
        .max()
        .unwrap_or(65_536)
        .max(plan.init().length());
    // Longshore requires `last - first < buffer_size` (strictly greater than range length),
    // rounded to a clean 8 KiB page multiple within `8 KiB ..= 16 MiB`.
    let buffer_size = ((usize::try_from(max_range_len).unwrap_or(4 * 1024 * 1024) + 8192)
        .next_multiple_of(8192))
    .clamp(16_384, 8 * 1024 * 1024);

    let pool_bytes = longshore_registered_pool_bytes(concurrency, buffer_size, parsed.tls);
    if pool_bytes > MAX_LONGSHORE_REGISTERED_POOL_BYTES {
        return Err(MediaWorkerError::storage_transport(format!(
            "longshore registered buffer pool ({pool_bytes} bytes) exceeds 64 MiB safety ceiling"
        )));
    }

    let access_key = creds.access_key_id().unwrap_or_default();
    let secret_key = creds.secret_access_key().unwrap_or_default();
    let ls_creds = match creds.session_token() {
        Some(token) => Credentials::with_session(access_key, secret_key, token),
        None => Credentials::new(access_key, secret_key),
    }
    .ok_or_else(|| {
        MediaWorkerError::storage_transport(
            "invalid ephemeral S3 credential format for longshore_s3",
        )
    })?;

    let mut builder = Builder::new(&parsed.host, archive.region(), ls_creds);
    builder.port = parsed.port;
    builder.tls = parsed.tls;
    builder.bucket_in_path = Some(archive.bucket().to_string());
    builder.address = parsed.ip_addr.map(|ip| SocketAddr::new(ip, parsed.port));
    builder.threads = 1;
    builder.portable = portable;
    builder.buffers = concurrency as u32;
    builder.connections = concurrency as u32;
    builder.operations = concurrency as u32;
    builder.buffer_size = buffer_size as u32;

    let init_expect = build_expect(
        plan.init().etag().or_else(|| archive.init_etag()),
        plan.init().version_id(),
    )?;
    let media_expect = build_expect(
        plan.media()
            .and_then(|m| m.etag())
            .or_else(|| archive.media_etag()),
        plan.media().and_then(|m| m.version_id()),
    )?;

    let client = match builder.build() {
        Ok(c) => c,
        Err(BuildError::Unsupported) => {
            return Err(MediaWorkerError::storage_transport(
                "longshore_s3 I/O backend unsupported on host",
            ));
        }
        Err(BuildError::Setting(msg)) => {
            return Err(MediaWorkerError::storage_transport(format!(
                "longshore_s3 builder setting error: {msg}"
            )));
        }
        Err(BuildError::NoNameserver) => {
            return Err(MediaWorkerError::storage_transport(
                "longshore_s3 found no system DNS nameserver",
            ));
        }
        Err(BuildError::Io(io_err)) => {
            return Err(MediaWorkerError::storage_transport(format!(
                "longshore_s3 setup I/O error: {io_err}"
            )));
        }
    };

    let init_len = plan.init().length();
    let init_bytes =
        longshore_get_range(&client, init_key, 0, init_len - 1, &init_expect, timeout)?;

    // Mandatory SHA-256 check on `init.mp4` BEFORE reading/decoding media fragments.
    verify_sha256_hex(&init_bytes, plan.init_sha256(), "init.mp4")?;

    let mut verified_fragments = Vec::with_capacity(plan.fragments().len());
    for range in coalesced {
        let chunk_bytes = longshore_get_range(
            &client,
            media_key,
            range.first(),
            range.last(),
            &media_expect,
            timeout,
        )?;
        let mut verified_slices = extract_and_verify_slices(&chunk_bytes, range)?;
        verified_fragments.append(&mut verified_slices);
    }
    verified_fragments.sort_by_key(VerifiedFragmentBytes::sequence);

    Ok(VerifiedKeyframeBlock {
        init_bytes,
        fragments: verified_fragments,
    })
}

fn execute_presigned_ranged_reads(
    plan: &ReadGrantPlan,
    archive: &ArchiveGrantTarget,
    scope: &BrokerGrantScope,
    init_presigned: &RedactedPresignedUrl,
    media_presigned: &RedactedPresignedUrl,
    coalesced: &[CoalescedRange],
    timeout: Duration,
) -> Result<VerifiedKeyframeBlock, MediaWorkerError> {
    let init_key = plan.init().key().unwrap_or_else(|| archive.init_key());
    let media_key = plan
        .media()
        .map(|m| m.key())
        .unwrap_or_else(|| archive.media_key());

    let parsed_endpoint = parse_and_verify_endpoint(
        archive.endpoint(),
        archive.bucket(),
        &[init_key, media_key],
        scope,
    )?;

    verify_presigned_object_url(
        init_presigned,
        &parsed_endpoint,
        archive.bucket(),
        init_key,
        plan.init().version_id(),
        scope,
    )?;
    verify_presigned_object_url(
        media_presigned,
        &parsed_endpoint,
        archive.bucket(),
        media_key,
        plan.media().and_then(|m| m.version_id()),
        scope,
    )?;

    let agent = ureq::config::Config::builder()
        .http_status_as_error(false)
        .max_redirects(0)
        .timeout_global(Some(timeout))
        .build()
        .new_agent();

    let init_etag = plan.init().etag().or_else(|| archive.init_etag());
    let init_bytes = fetch_presigned_range_slice(
        &agent,
        init_presigned,
        0,
        plan.init().length() - 1,
        init_etag,
    )?;
    // Mandatory SHA-256 check on `init.mp4` BEFORE reading/decoding media fragments.
    verify_sha256_hex(&init_bytes, plan.init_sha256(), "init.mp4")?;

    let media_etag = plan
        .media()
        .and_then(|m| m.etag())
        .or_else(|| archive.media_etag());
    let mut verified_fragments = Vec::with_capacity(plan.fragments().len());

    for range in coalesced {
        let chunk_bytes = fetch_presigned_range_slice(
            &agent,
            media_presigned,
            range.first(),
            range.last(),
            media_etag,
        )?;
        let mut verified_slices = extract_and_verify_slices(&chunk_bytes, range)?;
        verified_fragments.append(&mut verified_slices);
    }
    verified_fragments.sort_by_key(VerifiedFragmentBytes::sequence);

    Ok(VerifiedKeyframeBlock {
        init_bytes,
        fragments: verified_fragments,
    })
}

fn verify_presigned_object_url(
    presigned: &RedactedPresignedUrl,
    expected_endpoint: &ParsedEndpoint,
    bucket: &str,
    expected_key: &str,
    expected_version_id: Option<&str>,
    scope: &BrokerGrantScope,
) -> Result<(), MediaWorkerError> {
    let raw = presigned.as_str();
    if raw.bytes().any(|b| b <= b' ' || b == 0x7f) || raw.contains('#') {
        return Err(MediaWorkerError::integrity(
            IntegrityError::grant_scope_violation(
                "pre-signed archive URL contains forbidden control or fragment characters",
            ),
        ));
    }

    let (scheme, after_scheme) = raw.split_once("://").ok_or_else(|| {
        MediaWorkerError::integrity(IntegrityError::grant_scope_violation(
            "pre-signed archive URL missing scheme",
        ))
    })?;

    let tls = match scheme.to_ascii_lowercase().as_str() {
        "https" => true,
        "http" => false,
        other => {
            return Err(MediaWorkerError::integrity(
                IntegrityError::grant_scope_violation(format!(
                    "unsupported pre-signed URL scheme '{other}'"
                )),
            ));
        }
    };

    let (authority_and_path, query) = after_scheme.split_once('?').ok_or_else(|| {
        MediaWorkerError::integrity(IntegrityError::grant_scope_violation(
            "pre-signed archive URL missing AWS SigV4 query parameters",
        ))
    })?;

    let (authority, rel_path) = authority_and_path.split_once('/').ok_or_else(|| {
        MediaWorkerError::integrity(IntegrityError::grant_scope_violation(
            "pre-signed archive URL missing object path",
        ))
    })?;

    if authority.is_empty() || authority.contains('@') {
        return Err(MediaWorkerError::integrity(
            IntegrityError::grant_scope_violation(
                "pre-signed archive URL contains invalid or userinfo-bearing authority",
            ),
        ));
    }

    let (host, port) = split_host_port(authority, if tls { 443 } else { 80 })?;
    let ip_addr = host.parse::<IpAddr>().ok();

    if !tls && !ip_addr.is_some_and(|ip| ip.is_loopback()) {
        return Err(MediaWorkerError::integrity(
            IntegrityError::grant_scope_violation(format!(
                "plaintext HTTP pre-signed URL host '{host}' is forbidden outside loopback"
            )),
        ));
    }

    if scope.allowed_schemes().is_empty()
        || !scope
            .allowed_schemes()
            .iter()
            .any(|s| s.eq_ignore_ascii_case(scheme))
    {
        return Err(MediaWorkerError::integrity(
            IntegrityError::grant_scope_violation(format!(
                "pre-signed URL scheme '{scheme}' not permitted by grant allowed_schemes"
            )),
        ));
    }

    if scope.allowed_hosts().is_empty()
        || !scope
            .allowed_hosts()
            .iter()
            .any(|h| h.eq_ignore_ascii_case(&host))
    {
        return Err(MediaWorkerError::integrity(
            IntegrityError::grant_scope_violation(format!(
                "pre-signed URL host '{host}' not permitted by grant allowed_hosts"
            )),
        ));
    }

    if scope.allowed_ports().is_empty() || !scope.allowed_ports().contains(&port) {
        return Err(MediaWorkerError::integrity(
            IntegrityError::grant_scope_violation(format!(
                "pre-signed URL port {port} not permitted by grant allowed_ports"
            )),
        ));
    }

    if tls != expected_endpoint.tls
        || !host.eq_ignore_ascii_case(&expected_endpoint.host)
        || port != expected_endpoint.port
    {
        return Err(MediaWorkerError::integrity(
            IntegrityError::grant_scope_violation(
                "pre-signed URL authority disagrees with archive binding endpoint",
            ),
        ));
    }

    let raw_path = format!("/{rel_path}");
    let decoded_path = percent_decode_str(&raw_path)?;
    if decoded_path.split('/').any(|seg| seg == "." || seg == "..") {
        return Err(MediaWorkerError::integrity(
            IntegrityError::grant_scope_violation(
                "pre-signed URL path contains dot-segment traversal",
            ),
        ));
    }

    let expected_path = format!(
        "/{}/{}",
        bucket.trim_matches('/'),
        expected_key.trim_start_matches('/')
    );
    if decoded_path != expected_path {
        return Err(MediaWorkerError::integrity(
            IntegrityError::grant_scope_violation(format!(
                "pre-signed URL path '{decoded_path}' does not match expected '{expected_path}'"
            )),
        ));
    }

    let path_matched = !scope.allowed_paths().is_empty()
        && scope.allowed_paths().iter().any(|pattern| {
            let prefix = pattern.trim_end_matches('*');
            decoded_path.starts_with(prefix)
        });
    if !path_matched {
        return Err(MediaWorkerError::integrity(
            IntegrityError::grant_scope_violation(format!(
                "pre-signed URL path '{decoded_path}' outside grant allowed_paths"
            )),
        ));
    }

    verify_sigv4_query_params(query, expected_version_id)
}

fn verify_sigv4_query_params(
    query: &str,
    expected_version_id: Option<&str>,
) -> Result<(), MediaWorkerError> {
    let mut algorithm: Option<String> = None;
    let mut credential: Option<String> = None;
    let mut amz_date: Option<String> = None;
    let mut expires: Option<String> = None;
    let mut signed_headers: Option<String> = None;
    let mut signature: Option<String> = None;
    let mut version_id: Option<String> = None;

    for pair in query.split('&') {
        if pair.is_empty() {
            continue;
        }
        let (k_raw, v_raw) = pair.split_once('=').unwrap_or((pair, ""));
        let key = percent_decode_str(k_raw)?;
        let val = percent_decode_str(v_raw)?;
        match key.as_str() {
            "X-Amz-Algorithm" => algorithm = Some(val),
            "X-Amz-Credential" => credential = Some(val),
            "X-Amz-Date" => amz_date = Some(val),
            "X-Amz-Expires" => expires = Some(val),
            "X-Amz-SignedHeaders" => signed_headers = Some(val),
            "X-Amz-Signature" => signature = Some(val),
            "versionId" => version_id = Some(val),
            _ => {}
        }
    }

    if algorithm.as_deref() != Some("AWS4-HMAC-SHA256") {
        return Err(MediaWorkerError::integrity(
            IntegrityError::grant_scope_violation(
                "pre-signed URL missing X-Amz-Algorithm=AWS4-HMAC-SHA256",
            ),
        ));
    }
    if credential.as_deref().is_none_or(|c| c.trim().is_empty()) {
        return Err(MediaWorkerError::integrity(
            IntegrityError::grant_scope_violation("pre-signed URL missing X-Amz-Credential"),
        ));
    }
    if amz_date.as_deref().is_none_or(|d| d.trim().is_empty()) {
        return Err(MediaWorkerError::integrity(
            IntegrityError::grant_scope_violation("pre-signed URL missing X-Amz-Date"),
        ));
    }
    let ttl = expires
        .as_deref()
        .and_then(|v| v.parse::<u64>().ok())
        .filter(|&v| (1..=900).contains(&v))
        .ok_or_else(|| {
            MediaWorkerError::integrity(IntegrityError::grant_scope_violation(
                "pre-signed URL X-Amz-Expires must be between 1 and 900 seconds",
            ))
        })?;
    let _ = ttl;

    let has_host_hdr = signed_headers.as_deref().is_some_and(|hdrs| {
        hdrs.split(';')
            .any(|h| h.trim().eq_ignore_ascii_case("host"))
    });
    if !has_host_hdr {
        return Err(MediaWorkerError::integrity(
            IntegrityError::grant_scope_violation(
                "pre-signed URL X-Amz-SignedHeaders must include 'host'",
            ),
        ));
    }

    let valid_sig = signature
        .as_deref()
        .is_some_and(|sig| sig.len() == 64 && sig.bytes().all(|b| b.is_ascii_hexdigit()));
    if !valid_sig {
        return Err(MediaWorkerError::integrity(
            IntegrityError::grant_scope_violation(
                "pre-signed URL missing valid 64-hex X-Amz-Signature",
            ),
        ));
    }

    let normalized_expected_vid = expected_version_id
        .map(str::trim)
        .filter(|v| !v.is_empty() && *v != "null");
    if version_id.as_deref() != normalized_expected_vid {
        return Err(MediaWorkerError::integrity(
            IntegrityError::grant_scope_violation(
                "pre-signed URL versionId query parameter disagrees with archive receipt version_id",
            ),
        ));
    }

    Ok(())
}

fn percent_decode_str(input: &str) -> Result<String, MediaWorkerError> {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut idx = 0;
    while idx < bytes.len() {
        if bytes[idx] == b'%' {
            if idx + 2 >= bytes.len() {
                return Err(MediaWorkerError::integrity(
                    IntegrityError::grant_scope_violation(
                        "truncated percent-encoding in pre-signed URL",
                    ),
                ));
            }
            let hi = hex_nibble(bytes[idx + 1])?;
            let lo = hex_nibble(bytes[idx + 2])?;
            let decoded = (hi << 4) | lo;
            if decoded == 0 {
                return Err(MediaWorkerError::integrity(
                    IntegrityError::grant_scope_violation("null byte forbidden in pre-signed URL"),
                ));
            }
            out.push(decoded);
            idx += 3;
        } else {
            out.push(bytes[idx]);
            idx += 1;
        }
    }
    String::from_utf8(out).map_err(|_| {
        MediaWorkerError::integrity(IntegrityError::grant_scope_violation(
            "non-UTF8 percent-encoding in pre-signed URL",
        ))
    })
}

fn hex_nibble(byte: u8) -> Result<u8, MediaWorkerError> {
    match byte {
        b'0'..=b'9' => Ok(byte - b'0'),
        b'a'..=b'f' => Ok(byte - b'a' + 10),
        b'A'..=b'F' => Ok(byte - b'A' + 10),
        _ => Err(MediaWorkerError::integrity(
            IntegrityError::grant_scope_violation("invalid percent-encoding hex digit"),
        )),
    }
}

fn fetch_presigned_range_slice(
    agent: &ureq::Agent,
    presigned: &RedactedPresignedUrl,
    first: u64,
    last: u64,
    etag: Option<&str>,
) -> Result<Vec<u8>, MediaWorkerError> {
    let expected_len = usize::try_from(last - first + 1)
        .map_err(|_| MediaWorkerError::storage_transport("range length overflow"))?;
    let redacted_label = presigned.redacted_target();
    let mut req = agent
        .get(presigned.as_str())
        .header("Range", &format!("bytes={first}-{last}"))
        .header("Accept-Encoding", "identity");
    if let Some(tag) = etag.map(str::trim).filter(|t| !t.is_empty()) {
        req = req.header("If-Match", tag);
    }
    let mut resp = req.call().map_err(|err| {
        let clean = redact_query_from_error(&err.to_string(), presigned.as_str());
        MediaWorkerError::storage_transport(format!(
            "pre-signed S3 GET '{redacted_label}' failed: {clean}"
        ))
    })?;
    let status = resp.status().as_u16();
    if status != 206 && !(status == 200 && first == 0) {
        return Err(MediaWorkerError::storage_transport(format!(
            "pre-signed S3 GET '{redacted_label}' returned HTTP {status}"
        )));
    }
    let mut buf = Vec::new();
    resp.body_mut()
        .as_reader()
        .take((expected_len + 1) as u64)
        .read_to_end(&mut buf)
        .map_err(|err| {
            let clean = redact_query_from_error(&err.to_string(), presigned.as_str());
            MediaWorkerError::storage_transport(format!(
                "failed reading pre-signed S3 response '{redacted_label}': {clean}"
            ))
        })?;
    if buf.len() != expected_len {
        return Err(MediaWorkerError::storage_transport(format!(
            "pre-signed S3 response length {} != expected {expected_len}",
            buf.len()
        )));
    }
    Ok(buf)
}

fn redact_query_from_error(err_msg: &str, raw_url: &str) -> String {
    let mut sanitized = err_msg.replace(raw_url, "[REDACTED_PRESIGNED_URL]");
    if let Some((_, query)) = raw_url.split_once('?')
        && !query.is_empty()
    {
        sanitized = sanitized.replace(query, "[REDACTED]");
    }
    sanitized
}

fn build_expect(
    etag_str: Option<&str>,
    version_str: Option<&str>,
) -> Result<Expect, MediaWorkerError> {
    let etag = match etag_str.map(str::trim).filter(|s| !s.is_empty()) {
        Some(raw) => {
            if raw.len() > ETAG_MAX || !raw.bytes().all(|b| (b' '..=b'~').contains(&b)) {
                return Err(MediaWorkerError::storage_transport(
                    "invalid archive receipt ETag header value",
                ));
            }
            Some(ETag::new(raw.as_bytes()).ok_or_else(|| {
                MediaWorkerError::storage_transport("failed constructing longshore ETag")
            })?)
        }
        None => None,
    };

    let version = match version_str
        .map(str::trim)
        .filter(|s| !s.is_empty() && *s != "null")
    {
        Some(raw) => {
            if raw.len() > VERSION_ID_MAX || !raw.bytes().all(|b| (b' '..=b'~').contains(&b)) {
                return Err(MediaWorkerError::storage_transport(
                    "invalid archive receipt version_id header value",
                ));
            }
            Some(VersionId::new(raw.as_bytes()).ok_or_else(|| {
                MediaWorkerError::storage_transport("failed constructing longshore VersionId")
            })?)
        }
        None => None,
    };

    Ok(Expect { etag, version })
}

fn longshore_get_range(
    client: &longshore_s3::client::Client,
    key: &str,
    first: u64,
    last: u64,
    expect: &Expect,
    timeout: Duration,
) -> Result<Vec<u8>, MediaWorkerError> {
    let expected_len = usize::try_from(last - first + 1)
        .map_err(|_| MediaWorkerError::storage_transport("range length overflow"))?;
    let buffer = client.buffer_blocking();
    if buffer.is_empty() {
        return Err(MediaWorkerError::storage_transport(
            "longshore_s3 client returned closed/empty native buffer",
        ));
    }

    let budget = Budget::once(Instant::now() + timeout);
    let (res, buffer) = client
        .get(key, Some((first, last)), expect, buffer, budget)
        .wait();
    let report = res.map_err(|err| {
        MediaWorkerError::storage_transport(format!("longshore_s3 get('{key}') failed: {err:?}"))
    })?;

    match report.end {
        End::Answered(answer)
            if (answer.status == 200 || answer.status == 206) && !answer.malformed =>
        {
            let len = usize::try_from(answer.body_len).unwrap_or(0);
            if answer.status == 206 && len != expected_len {
                return Err(MediaWorkerError::storage_transport(format!(
                    "longshore_s3 206 Partial Content length {len} != requested {expected_len}"
                )));
            }
            if len > buffer.as_slice().len() {
                return Err(MediaWorkerError::storage_transport(
                    "longshore_s3 response exceeded native buffer slice",
                ));
            }
            if answer.status == 200 {
                // Full object returned when range starts at 0 and spans entire small object (e.g. init.mp4).
                let start = usize::try_from(first).unwrap_or(0);
                let end = start.saturating_add(expected_len);
                if end > len {
                    return Err(MediaWorkerError::storage_transport(
                        "longshore_s3 200 response shorter than requested range",
                    ));
                }
                Ok(buffer.as_slice()[start..end].to_vec())
            } else {
                Ok(buffer.as_slice()[..len].to_vec())
            }
        }
        End::Answered(answer) => Err(MediaWorkerError::storage_transport(format!(
            "S3 archive GET '{key}' refused with HTTP status {} (malformed={})",
            answer.status, answer.malformed
        ))),
        End::NotSent(cause) => Err(MediaWorkerError::storage_transport(format!(
            "S3 archive GET '{key}' not sent: {cause:?}"
        ))),
        End::Unknown(cause) => Err(MediaWorkerError::storage_transport(format!(
            "S3 archive GET '{key}' transport failed: {cause:?}"
        ))),
    }
}

/// Local NVR `analysis_read` HTTP reader (`GET /v1/blocks/<block_key>/init` and `/fragments/<seq>`).
#[derive(Debug, Clone)]
pub struct NvrAnalysisReader {
    scheme: String,
    port: u16,
    timeout: Duration,
    explicit_base_url: Option<String>,
}

impl Default for NvrAnalysisReader {
    fn default() -> Self {
        Self {
            scheme: "http".to_string(),
            port: 8444,
            timeout: Duration::from_secs(10),
            explicit_base_url: None,
        }
    }
}

impl NvrAnalysisReader {
    pub fn new(scheme: impl Into<String>, port: u16, timeout: Duration) -> Self {
        Self {
            scheme: scheme.into(),
            port,
            timeout,
            explicit_base_url: None,
        }
    }

    pub fn with_explicit_base_url(mut self, base_url: impl Into<String>) -> Self {
        self.explicit_base_url = Some(base_url.into());
        self
    }

    pub async fn fetch_local_plan(
        &self,
        plan: &ReadGrantPlan,
    ) -> Result<VerifiedKeyframeBlock, MediaWorkerError> {
        let base_url = self.resolve_base_url(plan)?;
        let plan_clone = plan.clone();
        let timeout = self.timeout;

        tokio::task::spawn_blocking(move || {
            execute_nvr_local_reads(&base_url, &plan_clone, timeout)
        })
        .await
        .map_err(|err| {
            MediaWorkerError::storage_transport(format!("NVR local read task panicked: {err}"))
        })?
    }

    fn resolve_base_url(&self, plan: &ReadGrantPlan) -> Result<String, MediaWorkerError> {
        if let Some(url) = plan.local().and_then(LocalGrantTarget::endpoint) {
            return Ok(url.trim_end_matches('/').to_string());
        }
        if let Some(url) = &self.explicit_base_url {
            return Ok(url.trim_end_matches('/').to_string());
        }
        let member = plan.nvr_member().ok_or_else(|| {
            MediaWorkerError::storage_transport(
                "local read grant missing nvr_member target hostname",
            )
        })?;
        Ok(format!("{}://{}:{}", self.scheme, member, self.port))
    }
}

fn execute_nvr_local_reads(
    base_url: &str,
    plan: &ReadGrantPlan,
    timeout: Duration,
) -> Result<VerifiedKeyframeBlock, MediaWorkerError> {
    let agent = ureq::config::Config::builder()
        .http_status_as_error(false)
        .timeout_global(Some(timeout))
        .build()
        .new_agent();

    let default_init_path = format!("/v1/blocks/{}/init", plan.block_key());
    let init_path = plan
        .init()
        .path()
        .or_else(|| plan.local().and_then(LocalGrantTarget::init_path))
        .unwrap_or(&default_init_path);

    let init_url = format!("{base_url}/{}", init_path.trim_start_matches('/'));
    let init_bytes = fetch_nvr_bytes(&agent, &init_url, MAX_INIT_SEGMENT_BYTES as usize)?;

    // Mandatory SHA-256 check on `init.mp4` BEFORE reading fragments.
    verify_sha256_hex(&init_bytes, plan.init_sha256(), "init.mp4")?;

    let mut raw_fragments = Vec::with_capacity(plan.fragments().len());
    for frag in plan.fragments() {
        let default_frag_path = format!(
            "/v1/blocks/{}/fragments/{}",
            plan.block_key(),
            frag.sequence()
        );
        let frag_path = frag.path().unwrap_or(&default_frag_path);
        let frag_url = format!("{base_url}/{}", frag_path.trim_start_matches('/'));
        let bytes = fetch_nvr_bytes(&agent, &frag_url, MAX_COALESCED_RANGE_BYTES as usize)?;
        raw_fragments.push((frag.clone(), bytes));
    }

    VerifiedKeyframeBlock::from_unverified(init_bytes, plan.init_sha256(), raw_fragments)
        .map_err(MediaWorkerError::from)
}

fn fetch_nvr_bytes(
    agent: &ureq::Agent,
    url: &str,
    max_bytes: usize,
) -> Result<Vec<u8>, MediaWorkerError> {
    let mut resp = agent
        .get(url)
        .header("X-ServiceRadar-Read-Pool", "analysis_read")
        .header("X-ServiceRadar-Read-Purpose", "analysis_read")
        .call()
        .map_err(|err| {
            MediaWorkerError::storage_transport(format!(
                "NVR analysis_read GET '{url}' failed: {err}"
            ))
        })?;

    let status = resp.status().as_u16();
    if status != 200 && status != 206 {
        return Err(MediaWorkerError::storage_transport(format!(
            "NVR analysis_read GET '{url}' returned HTTP {status}"
        )));
    }

    let mut buf = Vec::new();
    resp.body_mut()
        .as_reader()
        .take((max_bytes + 1) as u64)
        .read_to_end(&mut buf)
        .map_err(|err| {
            MediaWorkerError::storage_transport(format!(
                "failed reading NVR analysis_read response from '{url}': {err}"
            ))
        })?;

    if buf.len() > max_bytes {
        return Err(MediaWorkerError::integrity(
            IntegrityError::range_too_large(buf.len() as u64, max_bytes as u64),
        ));
    }
    Ok(buf)
}

/// Combined fragment store routing `:archive` plans through `LongshoreArchiveReader`
/// and `:local` plans through `NvrAnalysisReader`.
#[derive(Debug, Clone, Default)]
pub struct HybridGrantStore {
    archive_reader: LongshoreArchiveReader,
    local_reader: NvrAnalysisReader,
}

impl HybridGrantStore {
    pub fn new(archive_reader: LongshoreArchiveReader, local_reader: NvrAnalysisReader) -> Self {
        Self {
            archive_reader,
            local_reader,
        }
    }
}

impl FragmentStore for HybridGrantStore {
    async fn fetch_verified_block(
        &self,
        plan: &ReadGrantPlan,
    ) -> Result<VerifiedKeyframeBlock, MediaWorkerError> {
        match plan.source() {
            BackingSource::Archive => self.archive_reader.fetch_archive_plan(plan).await,
            BackingSource::Local => self.local_reader.fetch_local_plan(plan).await,
        }
    }
}
