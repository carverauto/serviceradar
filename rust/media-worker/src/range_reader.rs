//! Bounded byte-range coalescing (`<= 4 MiB`), `longshore_s3` archive reads,
//! NVR `analysis_read` HTTP reads, and mandatory SHA-256 verification (`2.3`).

use crate::credentials::EphemeralS3Credentials;
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
    fallback_credentials: Option<EphemeralS3Credentials>,
}

impl Default for LongshoreArchiveReader {
    fn default() -> Self {
        Self {
            concurrency: 2,
            timeout: Duration::from_secs(15),
            fallback_credentials: None,
        }
    }
}

impl LongshoreArchiveReader {
    pub fn new(concurrency: usize, timeout: Duration) -> Self {
        Self {
            concurrency: concurrency.clamp(1, 4),
            timeout,
            fallback_credentials: None,
        }
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

        let creds = plan
            .credential()
            .filter(|c| c.has_key_material())
            .or(self.fallback_credentials.as_ref())
            .filter(|c| c.has_key_material())
            .cloned()
            .ok_or_else(|| {
                MediaWorkerError::storage_transport(
                    "archive read grant contains no ephemeral reader credential key material",
                )
            })?;

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

        let plan_clone = plan.clone();
        let archive_clone = archive.clone();
        let scope_clone = scope.clone();
        let concurrency = self.concurrency;
        let timeout = self.timeout;

        tokio::task::spawn_blocking(move || {
            execute_longshore_ranged_reads(
                &plan_clone,
                &archive_clone,
                &scope_clone,
                &creds,
                &coalesced,
                concurrency,
                timeout,
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

fn execute_longshore_ranged_reads(
    plan: &ReadGrantPlan,
    archive: &ArchiveGrantTarget,
    scope: &BrokerGrantScope,
    creds: &EphemeralS3Credentials,
    coalesced: &[CoalescedRange],
    concurrency: usize,
    timeout: Duration,
) -> Result<VerifiedKeyframeBlock, MediaWorkerError> {
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
        #[cfg(not(target_os = "linux"))]
        Err(BuildError::Unsupported) => {
            // macOS XNU has no io_uring; execute identical ranged HTTP GET + If-Match + SHA-256
            // verification after validating longshore_s3::Credentials, Builder, and Expect above.
            return execute_non_linux_ranged_http_fallback(
                &parsed, archive, plan, init_key, media_key, coalesced, timeout,
            );
        }
        #[cfg(target_os = "linux")]
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

#[cfg(not(target_os = "linux"))]
fn execute_non_linux_ranged_http_fallback(
    parsed: &ParsedEndpoint,
    archive: &ArchiveGrantTarget,
    plan: &ReadGrantPlan,
    init_key: &str,
    media_key: &str,
    coalesced: &[CoalescedRange],
    timeout: Duration,
) -> Result<VerifiedKeyframeBlock, MediaWorkerError> {
    let scheme = if parsed.tls { "https" } else { "http" };
    let base = format!(
        "{scheme}://{}:{}/{}",
        parsed.host,
        parsed.port,
        archive.bucket()
    );
    let agent = ureq::config::Config::builder()
        .http_status_as_error(false)
        .timeout_global(Some(timeout))
        .build()
        .new_agent();

    let init_etag = plan.init().etag().or_else(|| archive.init_etag());
    let init_url = format!("{base}/{}", init_key.trim_start_matches('/'));
    let init_bytes =
        fetch_http_range_slice(&agent, &init_url, 0, plan.init().length() - 1, init_etag)?;
    verify_sha256_hex(&init_bytes, plan.init_sha256(), "init.mp4")?;

    let media_etag = plan
        .media()
        .and_then(|m| m.etag())
        .or_else(|| archive.media_etag());
    let media_url = format!("{base}/{}", media_key.trim_start_matches('/'));
    let mut verified_fragments = Vec::with_capacity(plan.fragments().len());

    for range in coalesced {
        let chunk_bytes =
            fetch_http_range_slice(&agent, &media_url, range.first(), range.last(), media_etag)?;
        let mut verified_slices = extract_and_verify_slices(&chunk_bytes, range)?;
        verified_fragments.append(&mut verified_slices);
    }
    verified_fragments.sort_by_key(VerifiedFragmentBytes::sequence);

    Ok(VerifiedKeyframeBlock {
        init_bytes,
        fragments: verified_fragments,
    })
}

#[cfg(not(target_os = "linux"))]
fn fetch_http_range_slice(
    agent: &ureq::Agent,
    url: &str,
    first: u64,
    last: u64,
    etag: Option<&str>,
) -> Result<Vec<u8>, MediaWorkerError> {
    let expected_len = usize::try_from(last - first + 1)
        .map_err(|_| MediaWorkerError::storage_transport("range length overflow"))?;
    let mut req = agent
        .get(url)
        .header("Range", &format!("bytes={first}-{last}"));
    if let Some(tag) = etag {
        req = req.header("If-Match", tag);
    }
    let mut resp = req.call().map_err(|err| {
        MediaWorkerError::storage_transport(format!("S3 fallback GET '{url}' failed: {err}"))
    })?;
    let status = resp.status().as_u16();
    if status != 200 && status != 206 {
        return Err(MediaWorkerError::storage_transport(format!(
            "S3 fallback GET '{url}' returned HTTP {status}"
        )));
    }
    let mut buf = Vec::new();
    resp.body_mut()
        .as_reader()
        .take((expected_len + 1) as u64)
        .read_to_end(&mut buf)
        .map_err(|err| {
            MediaWorkerError::storage_transport(format!(
                "failed reading S3 fallback response '{url}': {err}"
            ))
        })?;
    if buf.len() != expected_len {
        return Err(MediaWorkerError::storage_transport(format!(
            "S3 fallback response length {} != expected {expected_len}",
            buf.len()
        )));
    }
    Ok(buf)
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
