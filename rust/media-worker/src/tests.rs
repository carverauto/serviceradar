//! Unit and integration test suite for `serviceradar-media-worker` (`5.3`).
//!
//! All fixtures, tokens, UUIDs, endpoints, and video frames are 100% synthetic.

use crate::cmaf::{SyntheticRasterKeyframeDecoder, assemble_cmaf_block, avcc_box};
use crate::cmaf::{build_fragment_m4s, build_init_mp4};
use crate::keyframe_decoder_tests::{annex_b_nals, encode_idr, nals_of_type, pattern};
use crate::worker::log_worker_error;
use crate::{
    ArchiveGrantTarget, ArchiveMediaObjectPlan, ArchivePlanSpec, BackingSource, BrokerGrantScope,
    CapabilityErrorKind, EphemeralS3Credentials, ExecutionProvider, FragmentSlicePlan,
    FragmentStore, GpuEnvironmentObservation, GpuEnvironmentProbe, GpuSharingMode, GrantClient,
    GrantResolution, HEADER_CONTROL_PLANE_AUTH, HEADER_DEPLOYMENT_REF,
    HEADER_MEDIA_WORKER_GENERATION, HttpControlPlaneGrantClient, IntegrityErrorKind, JobDelivery,
    JobOutcome, LocalGrantTarget, LocalPlanSpec, LongshoreArchiveReader, MAX_COALESCED_RANGE_BYTES,
    MAX_LONGSHORE_REGISTERED_POOL_BYTES, MediaWorkerError, MediaWorkerErrorKind, ModelPinConfig,
    NvrAnalysisReader, ObjectClass, OrtRuntimeProbeResult, ReadGrantPlan, ReadGrantRequest,
    ReadinessState, ResultPublisher, SyntheticColor, SyntheticFragmentSpec, SyntheticObjectSpec,
    TextEmbedRpcRequest, TextEmbedRpcResponse, TextEmbedService, VISUAL_INDEX_RESULTS_SUBJECT,
    VerifiedKeyframeBlock, VisualIndexJobEnvelope, VisualIndexProcessor, VisualIndexResultEnvelope,
    WorkerAuthCredentials, WorkerConfig, WorkerMetrics, coalesce_fragment_ranges,
    cosine_similarity, embed_query_text, generate_synthetic_cmaf_block,
    longshore_registered_pool_bytes, serve_http_probes, spawn_nats_text_embed_responder,
    text_embed_rpc_subject, verify_startup_capabilities,
};
use crate::{
    KeyframeDecodeError, KeyframeDecoder, ParsedInitSegment, ParsedMediaFragment, RgbFrame,
};
use parking_lot::Mutex;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{SocketAddr, TcpListener};
use std::sync::Arc;
use std::time::{Duration, Instant};

struct StaticGpuProbe(GpuEnvironmentObservation);

impl GpuEnvironmentProbe for StaticGpuProbe {
    fn observe(
        &self,
        _config: &WorkerConfig,
    ) -> Result<GpuEnvironmentObservation, crate::CapabilityError> {
        Ok(self.0.clone())
    }
}

#[test]
fn gpu_providers_fail_closed_with_zero_cpu_fallback_and_verify_sharing_and_model_digests() {
    // 1. CUDA & TensorRT fail closed when no GPU device nodes exist — ZERO silent CPU fallback.
    for provider in [ExecutionProvider::Cuda, ExecutionProvider::Tensorrt] {
        let cfg = WorkerConfig::default().with_execution_provider(provider);
        let err =
            verify_startup_capabilities(&cfg, &StaticGpuProbe(GpuEnvironmentObservation::no_gpu()))
                .expect_err("GPU provider without hardware must fail closed");
        assert!(
            matches!(err.kind(), CapabilityErrorKind::GpuUnavailable(_)),
            "expected GpuUnavailable for {provider}, got {err:?}"
        );
    }

    // 2. CUDA present on host, but ORT lacks CUDAExecutionProvider -> fails closed.
    let gpu_no_ort = GpuEnvironmentObservation::new(
        1,
        false,
        false,
        Some("565.57.01".to_string()),
        Some(16_384),
        OrtRuntimeProbeResult::synthetic("1.20.1", false, false),
    );
    let cuda_cfg = WorkerConfig::default().with_execution_provider(ExecutionProvider::Cuda);
    let ort_err = verify_startup_capabilities(&cuda_cfg, &StaticGpuProbe(gpu_no_ort))
        .expect_err("missing CUDA EP must fail closed");
    assert!(matches!(
        ort_err.kind(),
        CapabilityErrorKind::GpuUnavailable(_)
    ));

    // 3. TensorRT fails closed when only CUDA EP is available (no silent downgrade to CUDA or CPU).
    let cuda_only_obs = GpuEnvironmentObservation::new(
        1,
        false,
        false,
        Some("565.57.01".to_string()),
        Some(24_576),
        OrtRuntimeProbeResult::synthetic("1.20.1", true, false),
    );
    let trt_cfg = WorkerConfig::default().with_execution_provider(ExecutionProvider::Tensorrt);
    let trt_err = verify_startup_capabilities(&trt_cfg, &StaticGpuProbe(cuda_only_obs.clone()))
        .expect_err("TensorRT without TensorRT EP must fail closed");
    assert!(matches!(
        trt_err.kind(),
        CapabilityErrorKind::GpuUnavailable(_)
    ));

    // 4. CUDA succeeds when GPU + VRAM + CUDA EP are verified, and classifies physical / MIG / time_sliced.
    let phys_manifest = verify_startup_capabilities(&cuda_cfg, &StaticGpuProbe(cuda_only_obs))
        .expect("verified CUDA capability should succeed");
    assert_eq!(phys_manifest.execution_provider(), ExecutionProvider::Cuda);
    assert_eq!(phys_manifest.gpu_sharing_mode(), GpuSharingMode::Physical);
    assert_eq!(phys_manifest.max_stage2_batch_size(), 16);

    let mig_obs = GpuEnvironmentObservation::new(
        1,
        true,
        false,
        Some("565.57.01".to_string()),
        Some(20_480),
        OrtRuntimeProbeResult::synthetic("1.20.1", true, true),
    );
    let mig_manifest = verify_startup_capabilities(&trt_cfg, &StaticGpuProbe(mig_obs))
        .expect("verified TensorRT MIG capability should succeed");
    assert_eq!(mig_manifest.gpu_sharing_mode(), GpuSharingMode::Mig);

    let ts_obs = GpuEnvironmentObservation::new(
        1,
        false,
        true,
        Some("565.57.01".to_string()),
        Some(8_192),
        OrtRuntimeProbeResult::synthetic("1.20.1", true, false),
    );
    let ts_manifest = verify_startup_capabilities(&cuda_cfg, &StaticGpuProbe(ts_obs))
        .expect("verified CUDA time-sliced capability should succeed");
    assert_eq!(ts_manifest.gpu_sharing_mode(), GpuSharingMode::TimeSliced);
    assert_eq!(ts_manifest.max_stage2_batch_size(), 4);

    // 5. Pinned model SHA-256 verification succeeds on exact match and rejects tampered weights.
    let temp_dir = tempfile::tempdir().expect("tempdir");
    let det_path = temp_dir.path().join("detector.onnx");
    let emb_path = temp_dir.path().join("embedder.onnx");
    let txt_path = temp_dir.path().join("text.onnx");

    let det_bytes = b"synthetic-rtdetr-onnx-weights-v1";
    let emb_bytes = b"synthetic-siglip-vision-onnx-weights-v1";
    let txt_bytes = b"synthetic-siglip-text-onnx-weights-v1";
    std::fs::write(&det_path, det_bytes).expect("write detector");
    std::fs::write(&emb_path, emb_bytes).expect("write embedder");
    std::fs::write(&txt_path, txt_bytes).expect("write text");

    let det_sha = hex::encode(Sha256::digest(det_bytes));
    let emb_sha = hex::encode(Sha256::digest(emb_bytes));
    let txt_sha = hex::encode(Sha256::digest(txt_bytes));

    let pinned_models = ModelPinConfig::default()
        .with_detector_pin(det_path.clone(), det_sha)
        .with_embedder_pin(emb_path.clone(), emb_sha)
        .with_text_pin(txt_path.clone(), txt_sha);

    let cpu_cfg = WorkerConfig::cpu_explicit_default().with_models(pinned_models);
    let cpu_manifest = verify_startup_capabilities(
        &cpu_cfg,
        &StaticGpuProbe(GpuEnvironmentObservation::no_gpu()),
    )
    .expect("cpu_explicit with matching model SHA-256 digests must succeed");
    assert_eq!(
        cpu_manifest.execution_provider(),
        ExecutionProvider::CpuExplicit
    );
    assert_eq!(cpu_manifest.gpu_sharing_mode(), GpuSharingMode::CpuExplicit);

    // Tamper 1 byte in embedder.onnx -> fails closed with ModelDigestMismatch!
    std::fs::write(&emb_path, b"tampered-siglip-vision-onnx-weights-v1").expect("tamper embedder");
    let tamper_err = verify_startup_capabilities(
        &cpu_cfg,
        &StaticGpuProbe(GpuEnvironmentObservation::no_gpu()),
    )
    .expect_err("tampered model file must fail startup verification");
    assert!(matches!(
        tamper_err.kind(),
        CapabilityErrorKind::ModelDigestMismatch { role, .. } if role == "embedder"
    ));

    // 6. Dynamic ORT C-ABI loader fails cleanly on missing or invalid shared library.
    let missing_ort = crate::probe_ort_dylib(&temp_dir.path().join("missing_ort.so"))
        .expect_err("missing ORT dylib must fail");
    assert!(matches!(
        missing_ort.kind(),
        CapabilityErrorKind::OrtRuntimeUnavailable(_)
    ));
    let invalid_dylib = temp_dir.path().join("invalid_ort.so");
    std::fs::write(&invalid_dylib, b"not-an-elf-or-macho-binary").expect("write invalid dylib");
    let invalid_ort =
        crate::probe_ort_dylib(&invalid_dylib).expect_err("invalid ORT dylib must fail dlopen");
    assert!(matches!(
        invalid_ort.kind(),
        CapabilityErrorKind::OrtRuntimeUnavailable(_)
    ));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn http_probe_server_serves_healthz_readyz_draining_503_and_prometheus_metrics() {
    let metrics = Arc::new(WorkerMetrics::new());
    metrics.inc_keyframes_decoded(3);
    metrics.observe_stage1_latency(0.004);
    metrics.observe_stage2_latency(0.008);
    metrics.observe_text_embed_latency(0.002);
    metrics.inc_jobs_completed();
    metrics.inc_jobs_gone();

    let readiness = ReadinessState::not_ready("booting", Arc::clone(&metrics));
    let (shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);
    let addr = serve_http_probes(
        SocketAddr::from(([127, 0, 0, 1], 0)),
        readiness.clone(),
        shutdown_rx,
    )
    .await
    .expect("bind probe server");

    let agent = ureq::config::Config::builder()
        .http_status_as_error(false)
        .build()
        .new_agent();

    // 1. /healthz returns 200 OK while /readyz returns 503 before admission.
    let hz = agent
        .get(&format!("http://{addr}/healthz"))
        .call()
        .expect("GET /healthz");
    assert_eq!(hz.status().as_u16(), 200);

    let rz_initial = agent
        .get(&format!("http://{addr}/readyz"))
        .call()
        .expect("GET /readyz");
    assert_eq!(rz_initial.status().as_u16(), 503);

    // 2. Admit capabilities -> /readyz returns 200 JSON CapabilityManifest.
    let manifest = verify_startup_capabilities(
        &WorkerConfig::cpu_explicit_default(),
        &StaticGpuProbe(GpuEnvironmentObservation::no_gpu()),
    )
    .expect("cpu_explicit admission");
    readiness.mark_ready(manifest);

    let mut rz_ready = agent
        .get(&format!("http://{addr}/readyz"))
        .call()
        .expect("GET /readyz ready");
    assert_eq!(rz_ready.status().as_u16(), 200);
    let ready_json: serde_json::Value = rz_ready.body_mut().read_json().expect("readyz json");
    assert_eq!(ready_json["status"], "ready");
    assert_eq!(ready_json["execution_provider"], "cpu_explicit");
    assert_eq!(ready_json["embedding_dim"], 768);

    // 3. /metrics exposes all required Stage 5.2 Prometheus counters, gauges, and histograms.
    let mut m_resp = agent
        .get(&format!("http://{addr}/metrics"))
        .call()
        .expect("GET /metrics");
    assert_eq!(m_resp.status().as_u16(), 200);
    let metrics_text = m_resp.body_mut().read_to_string().expect("metrics text");
    for required_metric in [
        "keyframes_decoded_total",
        "stage1_latency_seconds",
        "stage2_latency_seconds",
        "text_embed_latency_seconds",
        "jobs_completed_total",
        "jobs_gone_total",
        "jobs_failed_total",
        "inflight_index_jobs",
        "inflight_text_embeds",
    ] {
        assert!(
            metrics_text.contains(required_metric),
            "missing metric '{required_metric}' in:\n{metrics_text}"
        );
    }

    // 4. Mark draining -> /readyz transitions to 503 Service Unavailable.
    readiness.mark_draining("sigterm");
    let rz_draining = agent
        .get(&format!("http://{addr}/readyz"))
        .call()
        .expect("GET /readyz draining");
    assert_eq!(rz_draining.status().as_u16(), 503);

    let _ = shutdown_tx.send(true);
}

#[tokio::test]
async fn read_grant_client_redacts_secrets_enforces_reader_only_and_handles_410_gone() {
    let secret_access = "SYNTHETIC_ACCESS_KEY_NEVER_LOG_0001";
    let secret_key = "SYNTHETIC_SECRET_KEY_NEVER_LOG_9999999999";
    let session_tok = "SYNTHETIC_SESSION_TOKEN_NEVER_LOG_888888";
    let worker_bearer = "synthetic-media-worker-bearer-token-32bytes-0001";

    let s3_creds =
        EphemeralS3Credentials::new(secret_access, secret_key, Some(session_tok.to_string()))
            .with_metadata(
                Some("cred-ref-1".to_string()),
                Some(3),
                Some("00000000-0000-4000-8000-000000000501".to_string()),
            );
    let worker_auth =
        WorkerAuthCredentials::new(worker_bearer, "00000000-0000-4000-8000-000000000001", "7");

    // Verify Debug and Serialize output NEVER contain any secret bytes.
    let debug_s3 = format!("{s3_creds:?}");
    let json_s3 = serde_json::to_string(&s3_creds).expect("serialize redacted creds");
    let debug_auth = format!("{worker_auth:?}");
    for leaked in [secret_access, secret_key, session_tok, worker_bearer] {
        assert!(
            !debug_s3.contains(leaked),
            "Debug leaked secret: {debug_s3}"
        );
        assert!(
            !json_s3.contains(leaked),
            "Serialize leaked secret: {json_s3}"
        );
        assert!(
            !debug_auth.contains(leaked),
            "Auth Debug leaked secret: {debug_auth}"
        );
    }
    assert!(debug_s3.contains("[REDACTED]"));
    assert!(debug_auth.contains("[REDACTED]"));

    // Non-reader grant methods (`PUT`, `DELETE`) are rejected immediately.
    let bad_scope = BrokerGrantScope::reader_only(
        vec!["https".to_string()],
        vec!["objects.example.invalid".to_string()],
        vec![443],
        vec!["/synthetic-archive/*".to_string()],
    )
    .with_role_and_methods("reader", vec!["GET".to_string(), "PUT".to_string()]);
    let scope_err = bad_scope
        .validate_reader_only()
        .expect_err("PUT method in reader grant must fail");
    assert!(matches!(
        scope_err.kind(),
        IntegrityErrorKind::GrantScopeViolation(_)
    ));

    // Loopback HTTP server verifying headers and returning `410 Gone` on deleted/quarantined block.
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind mock control plane");
    let addr = listener.local_addr().expect("local_addr");
    let captured_headers: Arc<Mutex<HashMap<String, String>>> =
        Arc::new(Mutex::new(HashMap::new()));
    let headers_sink = Arc::clone(&captured_headers);

    let server_thread = std::thread::spawn(move || {
        let (mut sock, _) = listener.accept().expect("accept");
        let mut reader = BufReader::new(sock.try_clone().expect("clone sock"));
        let mut req_line = String::new();
        reader.read_line(&mut req_line).expect("read request line");
        assert!(req_line.starts_with("POST /v1/media/workers/read-grants "));

        let mut content_len = 0usize;
        loop {
            let mut line = String::new();
            reader.read_line(&mut line).expect("read header");
            let trimmed = line.trim();
            if trimmed.is_empty() {
                break;
            }
            if let Some((k, v)) = trimmed.split_once(':') {
                let key = k.trim().to_ascii_lowercase();
                let val = v.trim().to_string();
                if key == "content-length" {
                    content_len = val.parse().unwrap_or(0);
                }
                headers_sink.lock().insert(key, val);
            }
        }
        let mut body = vec![0u8; content_len];
        reader.read_exact(&mut body).expect("read request body");

        let resp_body = r#"{"status":"recording_gone"}"#;
        let http_resp = format!(
            "HTTP/1.1 410 Gone\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            resp_body.len(),
            resp_body
        );
        sock.write_all(http_resp.as_bytes()).expect("write 410");
    });

    let client = HttpControlPlaneGrantClient::new(
        format!("http://{addr}"),
        worker_auth,
        Duration::from_secs(5),
    );
    let req = ReadGrantRequest::new(
        "00000000-0000-7000-8000-000000000801",
        "00000000-0000-7000-8000-000000000601",
        "22".repeat(32),
    );
    let res = client
        .acquire_read_grant(&req)
        .await
        .expect("410 Gone must resolve cleanly without error");
    assert_eq!(res, GrantResolution::Gone);
    server_thread.join().expect("join mock control plane");

    let seen = captured_headers.lock();
    assert_eq!(
        seen.get(&HEADER_CONTROL_PLANE_AUTH.to_ascii_lowercase())
            .map(String::as_str),
        Some("Bearer synthetic-media-worker-bearer-token-32bytes-0001")
    );
    assert_eq!(
        seen.get(&HEADER_DEPLOYMENT_REF.to_ascii_lowercase())
            .map(String::as_str),
        Some("00000000-0000-4000-8000-000000000001")
    );
    assert_eq!(
        seen.get(&HEADER_MEDIA_WORKER_GENERATION.to_ascii_lowercase())
            .map(String::as_str),
        Some("7")
    );
}

#[tokio::test]
async fn presigned_wire_json_grant_fetches_coalesced_fragments_with_zero_s3_secrets_and_enforces_scope()
 {
    let block = generate_synthetic_cmaf_block(
        160,
        120,
        90_000,
        &[
            SyntheticFragmentSpec::new(
                0,
                0,
                2_000_000_000,
                [42, 46, 52],
                vec![SyntheticObjectSpec::new(
                    ObjectClass::Person,
                    SyntheticColor::Red,
                    [0.15, 0.15, 0.45, 0.85],
                )],
            ),
            SyntheticFragmentSpec::new(
                1,
                2_000_000_000,
                2_000_000_000,
                [42, 46, 52],
                vec![SyntheticObjectSpec::new(
                    ObjectClass::Vehicle,
                    SyntheticColor::White,
                    [0.50, 0.35, 0.90, 0.80],
                )],
            ),
        ],
    )
    .expect("generate synthetic block");

    let coalesced = coalesce_fragment_ranges(block.fragment_plans()).expect("coalesce");
    assert_eq!(coalesced.len(), 1);

    let init_sig = "1a".repeat(32);
    let media_sig = "2b".repeat(32);
    let init_etag = "\"etag-presign-init-1\"";
    let media_etag = "\"etag-presign-media-1\"";

    struct ObservedPresignedRequest {
        _path: String,
        _query: String,
        _range: Option<String>,
        _if_match: Option<String>,
    }

    // Loopback S3 object server that enforces pre-signed query signature, Range, If-Match,
    // versionId, and zero Authorization header.
    let s3_listener = TcpListener::bind("127.0.0.1:0").expect("bind presigned S3 peer");
    let s3_addr = s3_listener.local_addr().expect("s3 local_addr");
    let observed_s3_reqs: Arc<Mutex<Vec<ObservedPresignedRequest>>> =
        Arc::new(Mutex::new(Vec::new()));
    let observed_sink = Arc::clone(&observed_s3_reqs);
    let init_payload = block.init_mp4().to_vec();
    let media_payload = block.media_m4s().to_vec();
    let expected_init_sig = init_sig.clone();
    let expected_media_sig = media_sig.clone();

    let s3_thread = std::thread::spawn(move || {
        for _ in 0..2 {
            let (mut sock, _) = s3_listener.accept().expect("accept presigned GET");
            let mut reader = BufReader::new(sock.try_clone().expect("clone"));
            let mut req_line = String::new();
            reader.read_line(&mut req_line).expect("read req line");
            let parts: Vec<&str> = req_line.split_whitespace().collect();
            assert_eq!(parts.first().copied(), Some("GET"));
            let target = parts[1];
            let (path, query) = target.split_once('?').expect("query string required");

            let mut hdrs = HashMap::new();
            loop {
                let mut line = String::new();
                reader.read_line(&mut line).expect("read hdr");
                let trimmed = line.trim();
                if trimmed.is_empty() {
                    break;
                }
                if let Some((k, v)) = trimmed.split_once(':') {
                    hdrs.insert(k.trim().to_ascii_lowercase(), v.trim().to_string());
                }
            }

            assert!(
                !hdrs.contains_key("authorization"),
                "pre-signed GET must not send Authorization header"
            );
            assert!(query.contains("X-Amz-Algorithm=AWS4-HMAC-SHA256"));
            assert!(query.contains("X-Amz-SignedHeaders=host"));
            assert!(query.contains("X-Amz-Expires=300"));

            let range_hdr = hdrs.get("range").cloned();
            let if_match_hdr = hdrs.get("if-match").cloned();
            observed_sink.lock().push(ObservedPresignedRequest {
                _path: path.to_string(),
                _query: query.to_string(),
                _range: range_hdr.clone(),
                _if_match: if_match_hdr.clone(),
            });

            let (full_bytes, expected_etag, expected_sig, expected_ver) =
                if path.ends_with("/init.mp4") {
                    (
                        &init_payload,
                        init_etag,
                        expected_init_sig.as_str(),
                        "ver-init-1",
                    )
                } else {
                    (
                        &media_payload,
                        media_etag,
                        expected_media_sig.as_str(),
                        "ver-media-1",
                    )
                };

            assert!(
                query.contains(&format!("X-Amz-Signature={expected_sig}")),
                "missing expected X-Amz-Signature in {query}"
            );
            assert!(
                query.contains(&format!("versionId={expected_ver}")),
                "missing expected versionId in {query}"
            );
            assert_eq!(if_match_hdr.as_deref(), Some(expected_etag));

            let spec = range_hdr
                .as_deref()
                .and_then(|r| r.strip_prefix("bytes="))
                .expect("Range header required");
            let (f_str, l_str) = spec.split_once('-').expect("first-last");
            let first: usize = f_str.parse().expect("first");
            let last: usize = l_str.parse().expect("last");
            let slice = &full_bytes[first..=last];
            let resp = format!(
                "HTTP/1.1 206 Partial Content\r\nETag: {expected_etag}\r\nContent-Range: bytes {first}-{last}/{}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                full_bytes.len(),
                slice.len()
            );
            sock.write_all(resp.as_bytes()).expect("write 206 headers");
            sock.write_all(slice).expect("write 206 body");
        }
    });

    let init_presigned_url = format!(
        "http://{s3_addr}/synthetic-archive/recordings/v1/st-1/blk-1/init.mp4?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=test-reader-id%2F20261117%2Fexample-1%2Fs3%2Faws4_request&X-Amz-Date=20261117T120000Z&X-Amz-Expires=300&X-Amz-SignedHeaders=host&versionId=ver-init-1&X-Amz-Signature={init_sig}"
    );
    let media_presigned_url = format!(
        "http://{s3_addr}/synthetic-archive/recordings/v1/st-1/blk-1/media.m4s?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=test-reader-id%2F20261117%2Fexample-1%2Fs3%2Faws4_request&X-Amz-Date=20261117T120000Z&X-Amz-Expires=300&X-Amz-SignedHeaders=host&versionId=ver-media-1&X-Amz-Signature={media_sig}"
    );

    let job_id = "00000000-0000-7000-8000-000000000811";
    let entry_id = "00000000-0000-7000-8000-000000000611";
    let wire_json = serde_json::json!({
        "schema_version": 1,
        "backing": "archive",
        "source": "archive",
        "job_id": job_id,
        "catalog_entry_id": entry_id,
        "camera_source_id": "00000000-0000-4000-8000-000000000101",
        "stream_profile_id": "00000000-0000-4000-8000-000000000201",
        "storage_id": "st-1",
        "block_key": "blk-1",
        "descriptor_sha256": block.descriptor_sha256(),
        "init_sha256": block.init_plan().sha256(),
        "ttl_seconds": 300,
        "expires_at": "2026-11-17T12:05:00Z",
        "init": {
            "object_name": "init.mp4",
            "offset": 0,
            "first": 0,
            "last": block.init_mp4().len() - 1,
            "length": block.init_mp4().len(),
            "sha256": block.init_plan().sha256(),
            "key": "recordings/v1/st-1/blk-1/init.mp4",
            "etag": init_etag,
            "version_id": "ver-init-1",
            "presigned_url": init_presigned_url
        },
        "media": {
            "object_name": "media.m4s",
            "key": "recordings/v1/st-1/blk-1/media.m4s",
            "length": block.media_m4s().len(),
            "sha256": block.media_sha256(),
            "etag": media_etag,
            "version_id": "ver-media-1",
            "presigned_url": media_presigned_url
        },
        "fragments": block.fragment_plans(),
        "coalesced_ranges": coalesced,
        "archive": {
            "binding_id": "00000000-0000-4000-8000-000000000401",
            "provider": "s3_compatible",
            "endpoint": format!("http://{s3_addr}"),
            "region": "example-1",
            "bucket": "synthetic-archive",
            "namespace": "recordings/v1",
            "required_encryption": "sse_s3_aes256",
            "init_key": "recordings/v1/st-1/blk-1/init.mp4",
            "init_etag": init_etag,
            "init_presigned_url": init_presigned_url,
            "media_key": "recordings/v1/st-1/blk-1/media.m4s",
            "media_etag": media_etag,
            "media_presigned_url": media_presigned_url
        },
        "grant": {
            "grant_id": "00000000-0000-4000-8000-000000000701",
            "grant_type": "camera_archive_credential",
            "role": "reader",
            "purpose": "camera_archive_read",
            "secret_ref": "secret:network_credential:00000000-0000-4000-8000-000000000501",
            "allowed_schemes": ["http"],
            "allowed_hosts": ["127.0.0.1"],
            "allowed_ports": [s3_addr.port()],
            "allowed_paths": ["/synthetic-archive/recordings/v1/*"],
            "allowed_methods": ["HEAD", "GET"],
            "expires_at": "2026-11-17T12:05:00Z"
        },
        "credential": {
            "reference": "secret:network_credential:00000000-0000-4000-8000-000000000501",
            "generation": 1,
            "role": "reader",
            "secret_id": "00000000-0000-4000-8000-000000000501"
        }
    });
    let wire_bytes = serde_json::to_vec(&wire_json).expect("serialize wire json");

    // Serve exact wire JSON over loopback POST /v1/media/workers/read-grants.
    let cp_listener = TcpListener::bind("127.0.0.1:0").expect("bind mock CP");
    let cp_addr = cp_listener.local_addr().expect("cp addr");
    let cp_thread = std::thread::spawn(move || {
        let (mut sock, _) = cp_listener.accept().expect("accept CP");
        let mut reader = BufReader::new(sock.try_clone().expect("clone"));
        let mut content_len = 0usize;
        loop {
            let mut line = String::new();
            reader.read_line(&mut line).expect("hdr");
            let trimmed = line.trim();
            if trimmed.is_empty() {
                break;
            }
            if let Some((k, v)) = trimmed.split_once(':')
                && k.trim().eq_ignore_ascii_case("content-length")
            {
                content_len = v.trim().parse().unwrap_or(0);
            }
        }
        let mut req_body = vec![0u8; content_len];
        reader.read_exact(&mut req_body).expect("read body");

        let http_resp = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            wire_bytes.len()
        );
        sock.write_all(http_resp.as_bytes()).expect("write CP hdrs");
        sock.write_all(&wire_bytes).expect("write CP json");
    });

    let grant_client = HttpControlPlaneGrantClient::new(
        format!("http://{cp_addr}"),
        WorkerAuthCredentials::new(
            "synthetic-media-worker-bearer-token-32bytes-0002",
            "00000000-0000-4000-8000-000000000001",
            "1",
        ),
        Duration::from_secs(5),
    );
    let grant_req = ReadGrantRequest::new(job_id, entry_id, block.descriptor_sha256());
    let GrantResolution::Admitted(plan) = grant_client
        .acquire_read_grant(&grant_req)
        .await
        .expect("wire JSON with both backing and source must deserialize cleanly")
    else {
        panic!("expected Admitted grant resolution");
    };
    cp_thread.join().expect("join CP server");

    // Confirm zero S3 secret key material exists on the deserialized plan AND pre-signed URLs
    // are redacted in both Debug and Serialize!
    assert!(
        !plan
            .credential()
            .expect("redacted credential")
            .has_key_material()
    );
    assert!(plan.credential().unwrap().access_key_id().is_none());
    assert!(plan.credential().unwrap().secret_access_key().is_none());

    let plan_debug = format!("{plan:?}");
    let plan_serialized = serde_json::to_string(&plan).expect("serialize plan");
    for sensitive in [&init_sig, &media_sig, "test-reader-id", "X-Amz-Signature"] {
        assert!(
            !plan_debug.contains(sensitive),
            "Debug leaked pre-signed signature material '{sensitive}': {plan_debug}"
        );
        assert!(
            !plan_serialized.contains(sensitive),
            "Serialize leaked pre-signed signature material '{sensitive}': {plan_serialized}"
        );
    }

    // Fetch and SHA-256-verify coalesced CMAF fragments using zero S3 credentials!
    let reader = LongshoreArchiveReader::new(2, Duration::from_secs(10));
    let verified = reader
        .fetch_archive_plan(&plan)
        .await
        .expect("pre-signed zero-secret ranged GET + SHA-256 verification must succeed");
    s3_thread.join().expect("join presigned S3 peer");

    assert_eq!(verified.init_bytes(), block.init_mp4());
    assert_eq!(verified.fragments().len(), 2);
    assert_eq!(
        observed_s3_reqs.lock().len(),
        2,
        "expected 1 init GET + 1 coalesced media GET"
    );

    // Scope enforcement: pre-signed URL pointing outside allowed_hosts / allowed_paths must fail closed!
    let mut bad_host_json = wire_json.clone();
    let rogue_url = format!(
        "https://untrusted.example.invalid/synthetic-archive/recordings/v1/st-1/blk-1/init.mp4?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=test-reader-id%2F20261117%2Fexample-1%2Fs3%2Faws4_request&X-Amz-Date=20261117T120000Z&X-Amz-Expires=300&X-Amz-SignedHeaders=host&versionId=ver-init-1&X-Amz-Signature={init_sig}"
    );
    bad_host_json["init"]["presigned_url"] = serde_json::Value::String(rogue_url.clone());
    bad_host_json["archive"]["init_presigned_url"] = serde_json::Value::String(rogue_url);
    let bad_host_plan: ReadGrantPlan =
        serde_json::from_value(bad_host_json).expect("deserialize rogue plan");
    let host_err = reader
        .fetch_archive_plan(&bad_host_plan)
        .await
        .expect_err("rogue pre-signed host outside BrokerGrantScope must fail closed");
    assert!(matches!(
        host_err.kind(),
        MediaWorkerErrorKind::Integrity(err)
            if matches!(err.kind(), IntegrityErrorKind::GrantScopeViolation(_))
    ));

    // Disagreement between `backing` and `source` must fail deserialization!
    let mut mismatched_source = wire_json;
    mismatched_source["backing"] = serde_json::Value::String("local".to_string());
    assert!(serde_json::from_value::<ReadGrantPlan>(mismatched_source).is_err());
}

#[tokio::test]
async fn range_coalescing_caps_at_4_mib_and_longshore_s3_verifies_sha256_before_parse() {
    // 1. Verify range coalescing bounds (`<= 4 MiB` per GET, `<= 256 KiB` gap).
    let two_mib = 2 * 1024 * 1024;
    let sha_a = "aa".repeat(32);
    let sha_b = "bb".repeat(32);
    let sha_c = "cc".repeat(32);
    let sha_d = "dd".repeat(32);

    let fragments = vec![
        // Fragment 0 (2 MiB at offset 0) + Fragment 1 (1.5 MiB after 64 KiB gap) = 3.5625 MiB <= 4 MiB -> merged!
        FragmentSlicePlan::new(0, 0, two_mib, 0, 2_000_000_000, sha_a),
        FragmentSlicePlan::new(
            1,
            two_mib + 65_536,
            1_572_864,
            2_000_000_000,
            2_000_000_000,
            sha_b,
        ),
        // Fragment 2 (1 MiB contiguous) would push chunk above 4 MiB -> starts second coalesced GET!
        FragmentSlicePlan::new(
            2,
            two_mib + 65_536 + 1_572_864,
            1_048_576,
            4_000_000_000,
            2_000_000_000,
            sha_c,
        ),
        // Fragment 3 separated by 512 KiB (> 256 KiB max gap) -> starts third coalesced GET!
        FragmentSlicePlan::new(
            3,
            two_mib + 65_536 + 1_572_864 + 1_048_576 + 524_288,
            131_072,
            6_000_000_000,
            2_000_000_000,
            sha_d,
        ),
    ];

    let coalesced = coalesce_fragment_ranges(&fragments).expect("coalesce valid ranges");
    assert_eq!(coalesced.len(), 3);
    assert_eq!(coalesced[0].fragment_sequences(), &[0, 1]);
    assert!(coalesced[0].length() <= MAX_COALESCED_RANGE_BYTES);
    assert_eq!(coalesced[1].fragment_sequences(), &[2]);
    assert_eq!(coalesced[2].fragment_sequences(), &[3]);

    // Registered pool bound check matches 64 MiB safety ceiling.
    assert!(
        longshore_registered_pool_bytes(2, 4 * 1024 * 1024, true)
            <= MAX_LONGSHORE_REGISTERED_POOL_BYTES
    );

    // 2. Generate synthetic CMAF block and serve over a real loopback S3 HTTP/1.1 peer to `longshore_s3`.
    let block = generate_synthetic_cmaf_block(
        160,
        120,
        90_000,
        &[
            SyntheticFragmentSpec::new(
                0,
                0,
                2_000_000_000,
                [44, 48, 54],
                vec![SyntheticObjectSpec::new(
                    ObjectClass::Person,
                    SyntheticColor::Red,
                    [0.15, 0.15, 0.40, 0.85],
                )],
            ),
            SyntheticFragmentSpec::new(
                1,
                2_000_000_000,
                2_000_000_000,
                [44, 48, 54],
                vec![SyntheticObjectSpec::new(
                    ObjectClass::Package,
                    SyntheticColor::Yellow,
                    [0.55, 0.45, 0.85, 0.80],
                )],
            ),
        ],
    )
    .expect("generate synthetic block");

    let (s3_addr, s3_requests, stop_s3) = spawn_loopback_s3_peer(
        "synthetic-archive",
        HashMap::from([
            (
                "recordings/v1/st-1/blk-1/init.mp4".to_string(),
                (block.init_mp4().to_vec(), "\"etag-init-1\"".to_string()),
            ),
            (
                "recordings/v1/st-1/blk-1/media.m4s".to_string(),
                (block.media_m4s().to_vec(), "\"etag-media-1\"".to_string()),
            ),
        ]),
    );

    let plan = build_test_archive_plan(&block, s3_addr);
    let reader = LongshoreArchiveReader::new(1, Duration::from_secs(10));
    let verified = reader
        .fetch_archive_plan(&plan)
        .await
        .expect("longshore_s3 ranged fetch with matching SHA-256 digests should succeed");
    assert_eq!(verified.init_bytes(), block.init_mp4());
    assert_eq!(verified.fragments().len(), 2);

    // Confirm both fragments were fetched in ONE coalesced `Range: bytes=0-...` S3 GET!
    {
        let reqs = s3_requests.lock();
        let media_gets: Vec<_> = reqs
            .iter()
            .filter(|(path, _, _)| path.ends_with("/media.m4s"))
            .collect();
        assert_eq!(
            media_gets.len(),
            1,
            "two adjacent fragments must coalesce into 1 S3 GET"
        );
        assert_eq!(
            media_gets[0].1.as_deref(),
            Some(format!("bytes=0-{}", block.media_m4s().len() - 1).as_str())
        );
        #[cfg(target_os = "linux")]
        assert!(
            media_gets[0].2.starts_with("AWS4-HMAC-SHA256 "),
            "expected SigV4 header from longshore_s3"
        );
    }

    // 3. Tamper `init.mp4` on S3 -> rejected with `IntegrityErrorKind::DigestMismatch` on `init.mp4`!
    stop_s3.store(true, std::sync::atomic::Ordering::Release);
    let mut tampered_init = block.init_mp4().to_vec();
    tampered_init[0] ^= 0xff;
    let (bad_init_addr, _, stop_bad_init) = spawn_loopback_s3_peer(
        "synthetic-archive",
        HashMap::from([
            (
                "recordings/v1/st-1/blk-1/init.mp4".to_string(),
                (tampered_init, "\"etag-init-1\"".to_string()),
            ),
            (
                "recordings/v1/st-1/blk-1/media.m4s".to_string(),
                (block.media_m4s().to_vec(), "\"etag-media-1\"".to_string()),
            ),
        ]),
    );
    let bad_init_plan = build_test_archive_plan(&block, bad_init_addr);
    let init_err = reader
        .fetch_archive_plan(&bad_init_plan)
        .await
        .expect_err("tampered init.mp4 must fail SHA-256 verification");
    assert!(matches!(
        init_err.kind(),
        MediaWorkerErrorKind::Integrity(err)
            if matches!(err.kind(), IntegrityErrorKind::DigestMismatch { target, .. } if target == "init.mp4")
    ));
    stop_bad_init.store(true, std::sync::atomic::Ordering::Release);

    // 4. Tamper fragment 1 inside `media.m4s` -> rejected with `IntegrityErrorKind::DigestMismatch` on `fragment:1`!
    let mut tampered_media = block.media_m4s().to_vec();
    let frag1_offset = block.fragment_plans()[1].offset() as usize;
    tampered_media[frag1_offset + 12] ^= 0x55;
    let (bad_frag_addr, _, stop_bad_frag) = spawn_loopback_s3_peer(
        "synthetic-archive",
        HashMap::from([
            (
                "recordings/v1/st-1/blk-1/init.mp4".to_string(),
                (block.init_mp4().to_vec(), "\"etag-init-1\"".to_string()),
            ),
            (
                "recordings/v1/st-1/blk-1/media.m4s".to_string(),
                (tampered_media, "\"etag-media-1\"".to_string()),
            ),
        ]),
    );
    let bad_frag_plan = build_test_archive_plan(&block, bad_frag_addr);
    let frag_err = reader
        .fetch_archive_plan(&bad_frag_plan)
        .await
        .expect_err("tampered media.m4s fragment must fail SHA-256 verification");
    assert!(matches!(
        frag_err.kind(),
        MediaWorkerErrorKind::Integrity(err)
            if matches!(err.kind(), IntegrityErrorKind::DigestMismatch { target, .. } if target == "fragment:1")
    ));
    stop_bad_frag.store(true, std::sync::atomic::Ordering::Release);

    // 5. Verify local NVR `analysis_read` reader sends required pool isolation headers and verifies SHA-256.
    let (nvr_addr, nvr_pool_headers) = spawn_loopback_nvr_server(&block, "blk-local-1");
    let local_plan = ReadGrantPlan::from_local_spec(LocalPlanSpec {
        job_id: "00000000-0000-7000-8000-000000000802".to_string(),
        catalog_entry_id: "00000000-0000-7000-8000-000000000602".to_string(),
        camera_source_id: "00000000-0000-4000-8000-000000000101".to_string(),
        stream_profile_id: "00000000-0000-4000-8000-000000000201".to_string(),
        storage_id: "00000000-0000-4000-8000-000000000301".to_string(),
        block_key: "blk-local-1".to_string(),
        descriptor_sha256: block.descriptor_sha256().to_string(),
        init: block
            .init_plan()
            .clone()
            .with_local_path("/v1/blocks/blk-local-1/init"),
        fragments: block
            .fragment_plans()
            .iter()
            .map(|f| {
                f.clone()
                    .with_local_path(format!("/v1/blocks/blk-local-1/fragments/{}", f.sequence()))
            })
            .collect(),
        coalesced_ranges: Vec::new(),
        local: LocalGrantTarget::new(
            Some("serviceradar-nvr-0".to_string()),
            "00000000-0000-4000-8000-000000000301",
            "blk-local-1",
        )
        .with_endpoint(format!("http://{nvr_addr}")),
    });
    assert_eq!(local_plan.source(), BackingSource::Local);

    let nvr_reader = NvrAnalysisReader::default();
    let local_verified = nvr_reader
        .fetch_local_plan(&local_plan)
        .await
        .expect("NVR local analysis_read fetch should succeed");
    assert_eq!(local_verified.fragments().len(), 2);
    let recorded_pools = nvr_pool_headers.lock().clone();
    assert_eq!(recorded_pools.len(), 3);
    assert!(recorded_pools.iter().all(|h| h == "analysis_read"));
}

#[tokio::test]
async fn synthetic_cmaf_two_stage_pipeline_enforces_wpi_publish_before_ack_and_semantic_ranking() {
    // End-to-end test across BOTH 768-d (`siglip-b16-384`) and 512-d (`mobileclip-s2`) models!
    for (model_id, dim) in [("siglip-b16-384", 768usize), ("mobileclip-s2", 512usize)] {
        let models = ModelPinConfig::new("rtdetr-r18", "2026.1", model_id, "2026.1", dim);
        let cfg = WorkerConfig::cpu_explicit_default().with_models(models.clone());

        // Fragment 0: Wide-angle synthetic scene containing BOTH:
        //   - "person" in "red" garment at [0.10, 0.16, 0.26, 0.86]
        //   - "vehicle" in "white" body at [0.48, 0.36, 0.88, 0.78]
        // Fragment 1: Empty static parking lot scene (emits 1 `:scene` embedding).
        // Fragment 2: Unchanged empty static scene (`< 2%` delta -> `scene_suppressed == true`!).
        let block = generate_synthetic_cmaf_block(
            320,
            180,
            90_000,
            &[
                SyntheticFragmentSpec::new(
                    0,
                    0,
                    2_000_000_000,
                    [46, 50, 56],
                    vec![
                        SyntheticObjectSpec::new(
                            ObjectClass::Person,
                            SyntheticColor::Red,
                            [0.10, 0.16, 0.26, 0.86],
                        ),
                        SyntheticObjectSpec::new(
                            ObjectClass::Vehicle,
                            SyntheticColor::White,
                            [0.48, 0.36, 0.88, 0.78],
                        ),
                    ],
                ),
                SyntheticFragmentSpec::new(1, 2_000_000_000, 2_000_000_000, [46, 50, 56], vec![]),
                SyntheticFragmentSpec::new(2, 4_000_000_000, 2_000_000_000, [46, 50, 56], vec![]),
            ],
        )
        .expect("generate synthetic 3-fragment block");

        let events: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
        let published: Arc<Mutex<Vec<(String, VisualIndexResultEnvelope)>>> =
            Arc::new(Mutex::new(Vec::new()));

        let job = VisualIndexJobEnvelope::new(
            "01933b40-0000-7000-8000-000000000021",
            "00000000-0000-4000-8000-000000000011",
            "00000000-0000-4000-8000-000000000007",
            "00000000-0000-4000-8000-000000000008",
            block.descriptor_sha256(),
            &models,
        );

        let grant_client = DelayedMockGrantClient {
            resolution: GrantResolution::Admitted(Box::new(build_in_memory_local_plan(
                &job, &block,
            ))),
            delay: Duration::from_millis(35),
        };
        let store = InMemoryVerifiedStore {
            block: block.clone(),
        };
        let publisher = RecordingPublisher {
            events: Arc::clone(&events),
            published: Arc::clone(&published),
            fail_publish: false,
        };
        let metrics = Arc::new(WorkerMetrics::new());
        let processor =
            VisualIndexProcessor::new(&cfg, grant_client, store, publisher, Arc::clone(&metrics))
                .with_keyframe_decoder(Arc::new(SyntheticRasterKeyframeDecoder))
                .with_wpi_interval(Duration::from_millis(10));

        let delivery = Arc::new(RecordingDelivery {
            payload: serde_json::to_vec(&job).expect("job json"),
            events: Arc::clone(&events),
        });

        let outcome = processor
            .process_delivery(delivery)
            .await
            .expect("synthetic job should succeed");
        let envelope = outcome
            .completed_envelope()
            .expect("expected Completed outcome");

        // 1. Verify WPI -> publish_result -> ack strict ordering!
        let call_order = events.lock().clone();
        assert!(
            call_order.iter().any(|e| e == "wpi"),
            "expected at least one WPI progress heartbeat in {call_order:?}"
        );
        let pub_pos = call_order
            .iter()
            .position(|e| e == "publish_result")
            .expect("publish_result called");
        let ack_pos = call_order
            .iter()
            .position(|e| e == "ack")
            .expect("ack called");
        assert!(
            pub_pos < ack_pos,
            "media.results.visual_index.v1 publish MUST confirm BEFORE job ACK: {call_order:?}"
        );

        // 2. Verify exact `VisualIndexResultProjector.ingest_result/2` JSON schema!
        let raw_json: serde_json::Value =
            serde_json::to_value(envelope).expect("serialize result envelope");
        assert_eq!(raw_json["schema"], VISUAL_INDEX_RESULTS_SUBJECT);
        assert_eq!(raw_json["schema_version"], 1);
        assert_eq!(raw_json["job_id"], job.job_id());
        assert_eq!(raw_json["catalog_entry_id"], job.catalog_entry_id());
        assert_eq!(raw_json["descriptor_sha256"], block.descriptor_sha256());
        assert_eq!(raw_json["embedder_model_id"], model_id);
        assert_eq!(raw_json["embedding_dim"], dim);
        assert_eq!(envelope.frames().len(), 3);

        // Fragment 1 is empty (not suppressed); Fragment 2 is unchanged empty (`scene_suppressed == true`).
        assert!(!envelope.frames()[1].scene_suppressed());
        assert_eq!(envelope.frames()[1].embeddings().len(), 1);
        assert!(envelope.frames()[2].scene_suppressed());
        assert_eq!(envelope.frames()[2].embeddings().len(), 0);

        // Fragment 0 has 1 `:scene` + 2 `:crop` embeddings (`person` in `red`, `vehicle` in `white`).
        let f0 = &envelope.frames()[0];
        assert_eq!(f0.detections().len(), 2);
        assert_eq!(f0.embeddings().len(), 3);

        let scene_emb = &f0.embeddings()[0];
        assert_eq!(scene_emb.region_kind(), "scene");
        assert_eq!(scene_emb.region_index(), 0);
        assert!(scene_emb.object_class().is_none());
        assert!(scene_emb.confidence().is_none());
        assert!(scene_emb.bbox().is_none());

        for emb in f0.embeddings() {
            assert_eq!(emb.embedding().len(), dim);
            let norm: f32 = emb.embedding().iter().map(|v| v * v).sum::<f32>().sqrt();
            assert!(
                (norm - 1.0).abs() < 1e-5,
                "embedding must be L2-normalized, got norm {norm}"
            );
            if emb.region_kind() == "crop" {
                let [x1, y1, x2, y2] = emb.bbox().expect("crop bbox required");
                assert!(0.0 <= x1 && x1 < x2 && x2 <= 1.0);
                assert!(0.0 <= y1 && y1 < y2 && y2 <= 1.0);
            }
        }

        // 3. Semantic ranking verification:
        //    - "person in red dress" ranks the red-person crop #1 with cosine similarity > 0.85!
        //    - "white cargo van" ranks the white-vehicle crop #1 with cosine similarity > 0.85!
        let all_candidates: Vec<&crate::EmbeddingPayload> = envelope
            .frames()
            .iter()
            .flat_map(|f| f.embeddings().iter())
            .collect();

        let red_query_vec =
            embed_query_text("person in red dress", &models).expect("embed red person query");
        let mut red_ranked: Vec<(f32, &crate::EmbeddingPayload)> = all_candidates
            .iter()
            .map(|e| (cosine_similarity(&red_query_vec, e.embedding()), *e))
            .collect();
        red_ranked.sort_by(|a, b| b.0.total_cmp(&a.0));

        let (top_red_score, top_red_hit) = red_ranked[0];
        assert_eq!(top_red_hit.region_kind(), "crop");
        assert_eq!(top_red_hit.object_class(), Some("person"));
        assert!(
            top_red_hit.dominant_colors().iter().any(|c| c == "red"),
            "expected 'red' dominant color on top hit, got {:?}",
            top_red_hit.dominant_colors()
        );
        assert!(
            top_red_score > 0.85,
            "expected cosine similarity > 0.85 for 'person in red dress' ({model_id}), got {top_red_score}"
        );
        assert!(
            top_red_score > red_ranked[1].0 + 0.25,
            "red person crop ({top_red_score}) must cleanly beat runner-up ({})",
            red_ranked[1].0
        );

        let van_query_vec =
            embed_query_text("white cargo van", &models).expect("embed white van query");
        let mut van_ranked: Vec<(f32, &crate::EmbeddingPayload)> = all_candidates
            .iter()
            .map(|e| (cosine_similarity(&van_query_vec, e.embedding()), *e))
            .collect();
        van_ranked.sort_by(|a, b| b.0.total_cmp(&a.0));

        let (top_van_score, top_van_hit) = van_ranked[0];
        assert_eq!(top_van_hit.region_kind(), "crop");
        assert_eq!(top_van_hit.object_class(), Some("vehicle"));
        assert!(top_van_hit.dominant_colors().iter().any(|c| c == "white"));
        assert!(
            top_van_score > 0.85,
            "expected cosine similarity > 0.85 for 'white cargo van' ({model_id}), got {top_van_score}"
        );

        // 4. Verify publish failure NEVER ACKs the source job message (`nak` instead)!
        let fail_events: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
        let fail_proc = VisualIndexProcessor::new(
            &cfg,
            DelayedMockGrantClient {
                resolution: GrantResolution::Admitted(Box::new(build_in_memory_local_plan(
                    &job, &block,
                ))),
                delay: Duration::ZERO,
            },
            InMemoryVerifiedStore {
                block: block.clone(),
            },
            RecordingPublisher {
                events: Arc::clone(&fail_events),
                published: Arc::new(Mutex::new(Vec::new())),
                fail_publish: true,
            },
            Arc::new(WorkerMetrics::new()),
        )
        .with_keyframe_decoder(Arc::new(SyntheticRasterKeyframeDecoder));
        let fail_delivery = Arc::new(RecordingDelivery {
            payload: serde_json::to_vec(&job).expect("job json"),
            events: Arc::clone(&fail_events),
        });
        let pub_err = fail_proc
            .process_delivery(fail_delivery)
            .await
            .expect_err("failed result publish must return Err");
        log_worker_error(&pub_err);
        let fail_log = fail_events.lock().clone();
        assert!(
            !fail_log.iter().any(|e| e == "ack"),
            "failed publish MUST NOT ACK job"
        );
        assert!(
            fail_log.iter().any(|e| e == "nak"),
            "failed publish MUST NAK job"
        );

        // 5. Verify `410 Gone` ACKs immediately without publishing any result!
        let gone_events: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
        let gone_metrics = Arc::new(WorkerMetrics::new());
        let gone_proc = VisualIndexProcessor::new(
            &cfg,
            DelayedMockGrantClient {
                resolution: GrantResolution::Gone,
                delay: Duration::ZERO,
            },
            InMemoryVerifiedStore {
                block: block.clone(),
            },
            RecordingPublisher {
                events: Arc::clone(&gone_events),
                published: Arc::new(Mutex::new(Vec::new())),
                fail_publish: false,
            },
            Arc::clone(&gone_metrics),
        );
        let gone_delivery = Arc::new(RecordingDelivery {
            payload: serde_json::to_vec(&job).expect("job json"),
            events: Arc::clone(&gone_events),
        });
        let gone_out = gone_proc
            .process_delivery(gone_delivery)
            .await
            .expect("410 Gone is a clean skip");
        assert_eq!(gone_out, JobOutcome::Gone);
        assert_eq!(gone_metrics.jobs_gone_count(), 1);
        assert_eq!(gone_events.lock().as_slice(), &["ack"]);
    }
}

#[tokio::test]
async fn undecodable_keyframes_are_recorded_and_the_rest_of_the_block_is_still_indexed() {
    // Fragment 0: a real H.264 IDR. Fragment 1: the generator's SRIDR1 raster keyframe, which
    // the production decoder must refuse rather than recognise by its magic bytes.
    // Fragment 2: the real IDR with its slice cut in half.
    let (width, height) = (128usize, 96usize);
    let annex_b = encode_idr(
        rusty_h264_encoder::EncoderConfig::baseline(width, height),
        &pattern(width, height),
    );
    let nals = annex_b_nals(&annex_b);
    let slice = nals_of_type(&nals, 5)[0];
    let raster_block = generate_synthetic_cmaf_block(
        width as u32,
        height as u32,
        90_000,
        &[SyntheticFragmentSpec::new(
            0,
            0,
            2_000_000_000,
            [40, 44, 50],
            vec![],
        )],
    )
    .expect("synthetic raster block");
    let fragments = vec![
        (
            0,
            0,
            2_000_000_000,
            build_fragment_m4s(0, 0, 2_000_000_000, 90_000, &[slice]),
        ),
        (
            1,
            2_000_000_000,
            2_000_000_000,
            raster_block
                .fragment_slice_bytes(0)
                .expect("raster fragment")
                .to_vec(),
        ),
        (
            2,
            4_000_000_000,
            2_000_000_000,
            build_fragment_m4s(
                2,
                4_000_000_000,
                2_000_000_000,
                90_000,
                &[&slice[..slice.len() / 2]],
            ),
        ),
    ];
    let init = build_init_mp4(
        width as u32,
        height as u32,
        90_000,
        b"avc1",
        &avcc_box(&nals_of_type(&nals, 7), &nals_of_type(&nals, 8)),
    );
    let block = assemble_cmaf_block(width as u32, height as u32, 90_000, init, fragments)
        .expect("assemble block");

    let (envelope, metrics, events) =
        index_test_block(block, Arc::new(crate::DefaultKeyframeDecoder::new())).await;

    assert_eq!(
        envelope
            .frames()
            .iter()
            .map(|f| f.fragment_sequence())
            .collect::<Vec<_>>(),
        vec![0]
    );
    let undecodable: Vec<(u32, &str, &str)> = envelope
        .undecodable_keyframes()
        .iter()
        .map(|k| (k.fragment_sequence(), k.reason(), k.codec()))
        .collect();
    assert_eq!(
        undecodable,
        vec![
            (1, "malformed_bitstream", "h264"),
            (2, "malformed_bitstream", "h264")
        ]
    );
    assert_eq!(metrics.keyframes_decoded_count(), 1);
    assert_eq!(
        metrics.keyframes_undecodable_count("malformed_bitstream"),
        2
    );
    let wire = serde_json::to_value(&envelope).expect("serialize envelope");
    assert_eq!(
        wire["undecodable_keyframes"][0],
        serde_json::json!({"fragment_sequence": 1, "reason": "malformed_bitstream", "codec": "h264"})
    );
    assert!(
        events.lock().iter().any(|e| e == "ack"),
        "job must be ACKed"
    );
}

async fn index_test_block(
    block: crate::SyntheticCmafBlock,
    decoder: Arc<dyn KeyframeDecoder>,
) -> (
    VisualIndexResultEnvelope,
    Arc<WorkerMetrics>,
    Arc<Mutex<Vec<String>>>,
) {
    let models = ModelPinConfig::default();
    let cfg = WorkerConfig::cpu_explicit_default().with_models(models.clone());
    let job = VisualIndexJobEnvelope::new(
        "01933b40-0000-7000-8000-000000000031",
        "00000000-0000-4000-8000-000000000031",
        "00000000-0000-4000-8000-000000000007",
        "00000000-0000-4000-8000-000000000008",
        block.descriptor_sha256(),
        &models,
    );
    let events: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
    let metrics = Arc::new(WorkerMetrics::new());
    let processor = VisualIndexProcessor::new(
        &cfg,
        DelayedMockGrantClient {
            resolution: GrantResolution::Admitted(Box::new(build_in_memory_local_plan(
                &job, &block,
            ))),
            delay: Duration::ZERO,
        },
        InMemoryVerifiedStore {
            block: block.clone(),
        },
        RecordingPublisher {
            events: Arc::clone(&events),
            published: Arc::new(Mutex::new(Vec::new())),
            fail_publish: false,
        },
        Arc::clone(&metrics),
    );
    let processor = processor.with_keyframe_decoder(decoder);
    let outcome = processor
        .process_delivery(Arc::new(RecordingDelivery {
            payload: serde_json::to_vec(&job).expect("job json"),
            events: Arc::clone(&events),
        }))
        .await
        .expect("a block with some undecodable keyframes still completes");
    let envelope = outcome.completed_envelope().expect("completed envelope");

    (envelope.clone(), metrics, events)
}

#[tokio::test]
async fn verified_oversized_recordings_publish_every_refusal_before_ack() {
    for (width, height) in [(4097, 64), (64, 4097)] {
        let init = build_init_mp4(
            width,
            height,
            90_000,
            b"avc1",
            &avcc_box(&[&[0x67]], &[&[0x68]]),
        );
        let fragments =
            (0..2).map(|seq| (seq, 0, 1, build_fragment_m4s(seq, 0, 1, 90_000, &[&[0x65]])));
        let block = assemble_cmaf_block(width, height, 90_000, init, fragments).unwrap();
        let (result, metrics, events) =
            index_test_block(block, Arc::new(crate::DefaultKeyframeDecoder::new())).await;
        assert_eq!(events.lock().as_slice(), ["publish_result", "ack"]);
        assert!(result.frames().is_empty());
        let reasons: Vec<_> = result
            .undecodable_keyframes()
            .iter()
            .map(|k| (k.fragment_sequence(), k.reason()))
            .collect();
        assert_eq!(reasons, [(0, "limit_exceeded"), (1, "limit_exceeded")]);
        assert_eq!(metrics.keyframes_undecodable_count("limit_exceeded"), 2);
    }
}

#[tokio::test]
async fn refused_first_sample_preserves_descriptor_or_container_origin_for_tracks() {
    use std::io::{Seek, SeekFrom};
    let duration = 2_000_000_000;
    let start = 5_000_000_000;
    let object = SyntheticObjectSpec::new(
        ObjectClass::Person,
        SyntheticColor::Red,
        [0.1, 0.16, 0.26, 0.86],
    );
    let source = generate_synthetic_cmaf_block(
        128,
        96,
        90_000,
        &[
            SyntheticFragmentSpec::new(
                1,
                start + duration,
                duration,
                [40, 44, 50],
                vec![object.clone()],
            ),
            SyntheticFragmentSpec::new(
                2,
                start + 2 * duration,
                duration,
                [40, 44, 50],
                vec![object],
            ),
        ],
    )
    .unwrap();
    let aud: &[u8] = &[0x09, 0x10];
    let mut nals = vec![aud; 4096];
    nals.push(&[0x65]);
    let excessive = build_fragment_m4s(0, start, duration, 90_000, &nals);
    let mut bad_size = build_fragment_m4s(0, start, duration, 90_000, &[&[0x65]]);
    let trun = bad_size.windows(4).position(|tag| tag == b"trun").unwrap();
    bad_size[trun + 20..trun + 24].copy_from_slice(&128u32.to_be_bytes());
    let mut non_sync = build_fragment_m4s(0, start, duration, 90_000, &[&[0x65]]);
    non_sync[trun + 12..trun + 16].copy_from_slice(&0x0001_0000u32.to_be_bytes());
    let _outside_capture =
        tracing::subscriber::set_default(tracing::subscriber::NoSubscriber::new());
    for (descriptor_origin, first, last, first_reason, last_reason) in [
        (
            0,
            excessive.clone(),
            vec![1, 2, 3],
            "limit_exceeded",
            "invalid_container",
        ),
        (
            start,
            build_fragment_m4s(0, 0, duration, 90_000, &nals),
            vec![1, 2, 3],
            "limit_exceeded",
            "invalid_container",
        ),
        (
            0,
            bad_size,
            excessive.clone(),
            "invalid_container",
            "limit_exceeded",
        ),
        (
            0,
            non_sync,
            excessive,
            "invalid_container",
            "limit_exceeded",
        ),
    ] {
        let fragments = vec![
            (0, descriptor_origin, duration, first),
            (
                1,
                start + duration,
                duration,
                source.fragment_slice_bytes(0).unwrap().to_vec(),
            ),
            (
                2,
                start + 2 * duration,
                duration,
                source.fragment_slice_bytes(1).unwrap().to_vec(),
            ),
            (3, start + 3 * duration, duration, last),
        ];
        let block =
            assemble_cmaf_block(128, 96, 90_000, source.init_mp4().to_vec(), fragments).unwrap();
        let mut log = tempfile::tempfile().unwrap();
        let subscriber = tracing_subscriber::fmt()
            .without_time()
            .with_ansi(false)
            .with_max_level(tracing::Level::DEBUG)
            .with_writer(log.try_clone().unwrap())
            .finish();
        let _subscriber = tracing::subscriber::set_default(subscriber);
        let (result, metrics, _) =
            index_test_block(block, Arc::new(SyntheticRasterKeyframeDecoder)).await;
        let reasons: Vec<_> = result
            .undecodable_keyframes()
            .iter()
            .map(|k| (k.fragment_sequence(), k.reason()))
            .collect();
        assert_eq!(reasons, [(0, first_reason), (3, last_reason)]);
        assert_eq!(metrics.keyframes_undecodable_count("limit_exceeded"), 1);
        assert_eq!(metrics.keyframes_undecodable_count("invalid_container"), 1);
        assert_eq!(result.tracks().len(), 1);
        assert_eq!(result.tracks()[0].first_seen_offset_ms(), 2000);
        assert_eq!(result.tracks()[0].last_seen_offset_ms(), 4000);
        log.seek(SeekFrom::Start(0)).unwrap();
        let mut output = String::new();
        log.read_to_string(&mut output).unwrap();
        let summaries: Vec<_> = output
            .lines()
            .filter(|line| line.contains("keyframe decode summary"))
            .collect();
        assert_eq!(
            summaries.len(),
            1,
            "descriptor origin {descriptor_origin}, log {output:?}"
        );
        assert!(summaries[0].contains("DEBUG"));
        assert!(summaries[0].contains(r#""invalid_container": 1"#));
        assert!(summaries[0].contains(r#""limit_exceeded": 1"#));
        assert!(
            !output
                .lines()
                .any(|line| line.contains("WARN") && line.contains("keyframe"))
        );
    }
}

#[tokio::test]
async fn interactive_text_embed_responder_completes_under_50ms_while_all_index_slots_are_saturated()
{
    let models = ModelPinConfig::default(); // siglip-b16-384, 2026.1, 768-d
    let cfg = WorkerConfig::default()
        .with_execution_provider(ExecutionProvider::Cuda)
        .with_concurrency(2, 4)
        .with_models(models.clone());
    let metrics = Arc::new(WorkerMetrics::new());

    let (entered_tx, mut entered_rx) = tokio::sync::mpsc::unbounded_channel();
    let release = Arc::new((std::sync::Mutex::new(false), std::sync::Condvar::new()));

    let block = generate_synthetic_cmaf_block(
        64,
        64,
        90_000,
        &[SyntheticFragmentSpec::new(
            0,
            0,
            2_000_000_000,
            [40, 44, 50],
            vec![],
        )],
    )
    .expect("tiny synthetic block");
    let job = VisualIndexJobEnvelope::new(
        "01933b40-0000-7000-8000-000000000099",
        "00000000-0000-4000-8000-000000000099",
        "00000000-0000-4000-8000-000000000007",
        "00000000-0000-4000-8000-000000000008",
        block.descriptor_sha256(),
        &models,
    );

    let processor = VisualIndexProcessor::new(
        &cfg,
        DelayedMockGrantClient {
            resolution: GrantResolution::Admitted(Box::new(build_in_memory_local_plan(
                &job, &block,
            ))),
            delay: Duration::ZERO,
        },
        InMemoryVerifiedStore {
            block: block.clone(),
        },
        RecordingPublisher {
            events: Arc::new(Mutex::new(Vec::new())),
            published: Arc::new(Mutex::new(Vec::new())),
            fail_publish: false,
        },
        Arc::clone(&metrics),
    )
    .with_keyframe_decoder(Arc::new(BlockingDecoder {
        entered: entered_tx,
        release: Arc::clone(&release),
    }));

    let mut index_handles = Vec::new();
    for _ in 0..2 {
        let proc_clone = processor.clone();
        let deliv = Arc::new(RecordingDelivery {
            payload: serde_json::to_vec(&job).expect("job json"),
            events: Arc::new(Mutex::new(Vec::new())),
        });
        index_handles.push(tokio::spawn(async move {
            proc_clone.process_delivery(deliv).await
        }));
    }

    // Wait until BOTH index_concurrency permits are deterministically held busy (`available_permits == 0`).
    for _ in 0..2 {
        tokio::time::timeout(Duration::from_secs(5), entered_rx.recv())
            .await
            .expect("decode started")
            .expect("decoder alive");
    }
    assert_eq!(processor.index_semaphore().available_permits(), 0);
    assert_eq!(metrics.inflight_index_jobs_value(), 2);

    // Exercise the reserved interactive NATS responder over a real loopback NATS wire connection
    // while `index_semaphore` has 0 available permits!
    let (nats_addr, nats_server) = spawn_loopback_nats_rpc_broker().await;
    let worker_nats = async_nats::connect(format!("nats://{nats_addr}"))
        .await
        .expect("worker connect to loopback NATS");
    let caller_nats = async_nats::connect(format!("nats://{nats_addr}"))
        .await
        .expect("caller connect to loopback NATS");

    let text_service = TextEmbedService::new(models.clone(), 4, Arc::clone(&metrics));
    let (shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);
    let _responder =
        spawn_nats_text_embed_responder(worker_nats.clone(), text_service, shutdown_rx)
            .await
            .expect("spawn text-embed responder");
    worker_nats.flush().await.expect("flush worker sub");

    let subject = text_embed_rpc_subject(&models);
    assert_eq!(
        subject,
        "media.rpc.visual_text_embed.v1.siglip-b16-384.2026.1"
    );

    let rpc_req =
        TextEmbedRpcRequest::new("person in red dress", "siglip-b16-384", "2026.1", 768, 250);
    let payload = serde_json::to_vec(&rpc_req).expect("rpc json");

    let t0 = Instant::now();
    let reply_msg = tokio::time::timeout(
        Duration::from_millis(250),
        caller_nats.request(subject, payload.into()),
    )
    .await
    .expect("RPC must not time out while index jobs are saturated")
    .expect("NATS request succeeded");
    let elapsed = t0.elapsed();

    assert!(
        elapsed < Duration::from_millis(50),
        "interactive text_embed RPC took {elapsed:?} (>= 50 ms) while index slots were busy!"
    );

    let decoded_resp: TextEmbedRpcResponse =
        serde_json::from_slice(&reply_msg.payload).expect("decode RPC response");
    assert_eq!(decoded_resp.status(), "ok");
    let vec = decoded_resp.embedding().expect("768-d embedding present");
    assert_eq!(vec.len(), 768);
    let norm: f32 = vec.iter().map(|v| v * v).sum::<f32>().sqrt();
    assert!((norm - 1.0).abs() < 1e-5);

    // Release blocked backfill jobs and tear down cleanly.
    *release.0.lock().unwrap() = true;
    release.1.notify_all();
    for h in index_handles {
        let _ = h.await.expect("join index job").expect("index job ok");
    }
    let _ = shutdown_tx.send(true);
    nats_server.abort();
}

// ============================================================================
// Synthetic Test Helpers (loopback S3, NVR, NATS wire peers, and mock traits)
// ============================================================================

fn build_test_archive_plan(
    block: &crate::SyntheticCmafBlock,
    s3_addr: SocketAddr,
) -> ReadGrantPlan {
    let coalesced = coalesce_fragment_ranges(block.fragment_plans()).expect("coalesce");
    let init = block.init_plan().clone().with_archive_object(
        "recordings/v1/st-1/blk-1/init.mp4",
        Some("\"etag-init-1\"".to_string()),
        None,
    );
    let media = ArchiveMediaObjectPlan::new(
        "recordings/v1/st-1/blk-1/media.m4s",
        block.media_m4s().len() as u64,
        block.media_sha256(),
        Some("\"etag-media-1\"".to_string()),
        None,
    );
    let archive = ArchiveGrantTarget::new(
        format!("http://{s3_addr}"),
        "example-1",
        "synthetic-archive",
        "recordings/v1/st-1/blk-1/init.mp4",
        "recordings/v1/st-1/blk-1/media.m4s",
    )
    .with_etags(
        Some("\"etag-init-1\"".to_string()),
        Some("\"etag-media-1\"".to_string()),
    );
    let grant = BrokerGrantScope::reader_only(
        vec!["http".to_string()],
        vec!["127.0.0.1".to_string()],
        vec![s3_addr.port()],
        vec!["/synthetic-archive/recordings/v1/*".to_string()],
    );
    let creds = EphemeralS3Credentials::new(
        "SYNTHETICREADERKEY01",
        "synthetic-reader-secret-access-key-00001",
        None,
    );

    ReadGrantPlan::from_archive_spec(ArchivePlanSpec {
        job_id: "00000000-0000-7000-8000-000000000801".to_string(),
        catalog_entry_id: "00000000-0000-7000-8000-000000000601".to_string(),
        camera_source_id: "00000000-0000-4000-8000-000000000101".to_string(),
        stream_profile_id: "00000000-0000-4000-8000-000000000201".to_string(),
        storage_id: "st-1".to_string(),
        block_key: "blk-1".to_string(),
        descriptor_sha256: block.descriptor_sha256().to_string(),
        init,
        media,
        fragments: block.fragment_plans().to_vec(),
        coalesced_ranges: coalesced,
        archive,
        grant,
        credential: Some(creds),
    })
}

fn build_in_memory_local_plan(
    job: &VisualIndexJobEnvelope,
    block: &crate::SyntheticCmafBlock,
) -> ReadGrantPlan {
    ReadGrantPlan::from_local_spec(LocalPlanSpec {
        job_id: job.job_id().to_string(),
        catalog_entry_id: job.catalog_entry_id().to_string(),
        camera_source_id: job.camera_source_id().to_string(),
        stream_profile_id: job.stream_profile_id().to_string(),
        storage_id: "00000000-0000-4000-8000-000000000301".to_string(),
        block_key: "22".repeat(32),
        descriptor_sha256: block.descriptor_sha256().to_string(),
        init: block.init_plan().clone(),
        fragments: block.fragment_plans().to_vec(),
        coalesced_ranges: coalesce_fragment_ranges(block.fragment_plans()).expect("coalesce"),
        local: LocalGrantTarget::new(
            Some("serviceradar-nvr-0".to_string()),
            "00000000-0000-4000-8000-000000000301",
            "22".repeat(32),
        ),
    })
}

type RecordedS3Requests = Arc<Mutex<Vec<(String, Option<String>, String)>>>;

fn spawn_loopback_s3_peer(
    bucket: &str,
    objects: HashMap<String, (Vec<u8>, String)>,
) -> (
    SocketAddr,
    RecordedS3Requests,
    Arc<std::sync::atomic::AtomicBool>,
) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind loopback S3");
    let addr = listener.local_addr().expect("s3 local_addr");
    let recorded = Arc::new(Mutex::new(Vec::new()));
    let recorded_sink = Arc::clone(&recorded);
    let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let stop_flag = Arc::clone(&stop);
    let bucket_prefix = format!("/{bucket}/");
    let objects = Arc::new(objects);

    std::thread::spawn(move || {
        while !stop_flag.load(std::sync::atomic::Ordering::Acquire) {
            let Ok((sock, _)) = listener.accept() else {
                break;
            };
            let objs = Arc::clone(&objects);
            let sink = Arc::clone(&recorded_sink);
            let prefix = bucket_prefix.clone();
            std::thread::spawn(move || {
                serve_s3_connection(sock, &prefix, &objs, &sink);
            });
        }
    });

    (addr, recorded, stop)
}

fn serve_s3_connection(
    mut sock: std::net::TcpStream,
    bucket_prefix: &str,
    objects: &HashMap<String, (Vec<u8>, String)>,
    sink: &Mutex<Vec<(String, Option<String>, String)>>,
) {
    let mut reader = BufReader::new(match sock.try_clone() {
        Ok(c) => c,
        Err(_) => return,
    });

    loop {
        let mut req_line = String::new();
        if reader.read_line(&mut req_line).unwrap_or(0) == 0 {
            break;
        }
        let parts: Vec<&str> = req_line.split_whitespace().collect();
        if parts.len() < 2 {
            break;
        }
        let raw_path = parts[1].split('?').next().unwrap_or(parts[1]).to_string();

        let mut headers = HashMap::new();
        loop {
            let mut line = String::new();
            if reader.read_line(&mut line).unwrap_or(0) == 0 {
                return;
            }
            let trimmed = line.trim();
            if trimmed.is_empty() {
                break;
            }
            if let Some((k, v)) = trimmed.split_once(':') {
                headers.insert(k.trim().to_ascii_lowercase(), v.trim().to_string());
            }
        }

        let range_hdr = headers.get("range").cloned();
        let auth_hdr = headers.get("authorization").cloned().unwrap_or_default();
        sink.lock()
            .push((raw_path.clone(), range_hdr.clone(), auth_hdr));

        let key = raw_path.strip_prefix(bucket_prefix).unwrap_or(&raw_path);
        let Some((full_bytes, etag)) = objects.get(key) else {
            let _ = sock.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
            continue;
        };

        if let Some(if_match) = headers.get("if-match")
            && if_match != etag
        {
            let _ =
                sock.write_all(b"HTTP/1.1 412 Precondition Failed\r\nContent-Length: 0\r\n\r\n");
            continue;
        }

        if let Some(range_val) = range_hdr
            && let Some(spec) = range_val.strip_prefix("bytes=")
            && let Some((f_str, l_str)) = spec.split_once('-')
            && let (Ok(first), Ok(last)) = (f_str.parse::<usize>(), l_str.parse::<usize>())
            && last < full_bytes.len()
        {
            let slice = &full_bytes[first..=last];
            let hdr = format!(
                "HTTP/1.1 206 Partial Content\r\nETag: {etag}\r\nContent-Range: bytes {first}-{last}/{}\r\nContent-Length: {}\r\n\r\n",
                full_bytes.len(),
                slice.len()
            );
            let _ = sock.write_all(hdr.as_bytes());
            let _ = sock.write_all(slice);
        } else {
            let hdr = format!(
                "HTTP/1.1 200 OK\r\nETag: {etag}\r\nContent-Length: {}\r\n\r\n",
                full_bytes.len()
            );
            let _ = sock.write_all(hdr.as_bytes());
            let _ = sock.write_all(full_bytes);
        }
    }
}

fn spawn_loopback_nvr_server(
    block: &crate::SyntheticCmafBlock,
    block_key: &str,
) -> (SocketAddr, Arc<Mutex<Vec<String>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind mock NVR");
    let addr = listener.local_addr().expect("nvr addr");
    let pools = Arc::new(Mutex::new(Vec::new()));
    let pools_sink = Arc::clone(&pools);
    let init_bytes = block.init_mp4().to_vec();
    let frag0 = block.fragment_slice_bytes(0).unwrap().to_vec();
    let frag1 = block.fragment_slice_bytes(1).unwrap().to_vec();
    let bkey = block_key.to_string();

    std::thread::spawn(move || {
        for _ in 0..3 {
            let Ok((mut sock, _)) = listener.accept() else {
                break;
            };
            let mut reader = BufReader::new(sock.try_clone().expect("clone"));
            let mut req_line = String::new();
            reader.read_line(&mut req_line).expect("req line");
            let path = req_line.split_whitespace().nth(1).unwrap_or("").to_string();

            let mut pool_val = String::new();
            loop {
                let mut line = String::new();
                reader.read_line(&mut line).expect("hdr");
                let trimmed = line.trim();
                if trimmed.is_empty() {
                    break;
                }
                if let Some((k, v)) = trimmed.split_once(':')
                    && k.trim().eq_ignore_ascii_case("x-serviceradar-read-pool")
                {
                    pool_val = v.trim().to_string();
                }
            }
            pools_sink.lock().push(pool_val);

            let payload = if path == format!("/v1/blocks/{bkey}/init") {
                &init_bytes
            } else if path == format!("/v1/blocks/{bkey}/fragments/0") {
                &frag0
            } else {
                &frag1
            };
            let hdr = format!(
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                payload.len()
            );
            sock.write_all(hdr.as_bytes()).expect("write hdr");
            sock.write_all(payload).expect("write body");
        }
    });

    (addr, pools)
}

async fn spawn_loopback_nats_rpc_broker() -> (SocketAddr, tokio::task::JoinHandle<()>) {
    use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader as TokioBufReader};

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind loopback NATS");
    let addr = listener.local_addr().expect("nats addr");

    #[derive(Clone)]
    struct SubEntry {
        subject: String,
        sid: String,
        tx: tokio::sync::mpsc::UnboundedSender<Vec<u8>>,
    }

    let subs: Arc<Mutex<Vec<SubEntry>>> = Arc::new(Mutex::new(Vec::new()));

    let handle = tokio::spawn(async move {
        loop {
            let Ok((socket, _)) = listener.accept().await else {
                break;
            };
            let subs_ref = Arc::clone(&subs);
            tokio::spawn(async move {
                let (read_half, mut write_half) = socket.into_split();
                let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<Vec<u8>>();

                let info = format!(
                    "INFO {{\"server_id\":\"synthetic-nats\",\"version\":\"2.10.0\",\"proto\":1,\"host\":\"127.0.0.1\",\"port\":{},\"max_payload\":1048576,\"headers\":true}}\r\n",
                    addr.port()
                );
                if write_half.write_all(info.as_bytes()).await.is_err() {
                    return;
                }

                tokio::spawn(async move {
                    while let Some(frame) = rx.recv().await {
                        if write_half.write_all(&frame).await.is_err() {
                            break;
                        }
                    }
                });

                let mut reader = TokioBufReader::new(read_half);
                loop {
                    let mut line = String::new();
                    if reader.read_line(&mut line).await.unwrap_or(0) == 0 {
                        break;
                    }
                    let parts: Vec<&str> = line.split_whitespace().collect();
                    match parts.first().copied() {
                        Some("PING") => {
                            let _ = tx.send(b"PONG\r\n".to_vec());
                        }
                        Some("SUB") if parts.len() >= 3 => {
                            let subject = parts[1].to_string();
                            let sid = (*parts.last().unwrap()).to_string();
                            subs_ref.lock().push(SubEntry {
                                subject,
                                sid,
                                tx: tx.clone(),
                            });
                        }
                        Some("PUB") if parts.len() >= 3 => {
                            let subject = parts[1].to_string();
                            let (reply_to, len_str) = if parts.len() == 4 {
                                (Some(parts[2].to_string()), parts[3])
                            } else {
                                (None, parts[2])
                            };
                            let len: usize = len_str.parse().unwrap_or(0);
                            let mut body = vec![0u8; len + 2];
                            if reader.read_exact(&mut body).await.is_err() {
                                break;
                            }
                            let payload = &body[..len];

                            let targets: Vec<SubEntry> = subs_ref
                                .lock()
                                .iter()
                                .filter(|s| nats_subject_matches(&s.subject, &subject))
                                .cloned()
                                .collect();
                            for sub in targets {
                                let msg_hdr = match &reply_to {
                                    Some(rep) => {
                                        format!("MSG {subject} {} {rep} {len}\r\n", sub.sid)
                                    }
                                    None => format!("MSG {subject} {} {len}\r\n", sub.sid),
                                };
                                let mut frame = Vec::with_capacity(msg_hdr.len() + len + 2);
                                frame.extend_from_slice(msg_hdr.as_bytes());
                                frame.extend_from_slice(payload);
                                frame.extend_from_slice(b"\r\n");
                                let _ = sub.tx.send(frame);
                            }
                        }
                        _ => {}
                    }
                }
            });
        }
    });

    (addr, handle)
}

fn nats_subject_matches(pattern: &str, subject: &str) -> bool {
    if pattern == subject {
        return true;
    }
    if let Some(prefix) = pattern.strip_suffix(".>") {
        return subject.starts_with(prefix);
    }
    if let Some(prefix) = pattern.strip_suffix(".*")
        && let Some(rest) = subject.strip_prefix(prefix)
    {
        return rest.starts_with('.') && !rest[1..].contains('.');
    }
    false
}

struct DelayedMockGrantClient {
    resolution: GrantResolution,
    delay: Duration,
}

impl GrantClient for DelayedMockGrantClient {
    async fn acquire_read_grant(
        &self,
        _request: &ReadGrantRequest,
    ) -> Result<GrantResolution, MediaWorkerError> {
        if !self.delay.is_zero() {
            tokio::time::sleep(self.delay).await;
        }
        Ok(self.resolution.clone())
    }
}

struct BlockingDecoder {
    entered: tokio::sync::mpsc::UnboundedSender<()>,
    release: Arc<(std::sync::Mutex<bool>, std::sync::Condvar)>,
}

impl KeyframeDecoder for BlockingDecoder {
    fn decode_keyframe(
        &self,
        init: &ParsedInitSegment,
        fragment: &ParsedMediaFragment,
    ) -> Result<RgbFrame, KeyframeDecodeError> {
        self.entered.send(()).unwrap();
        let (lock, wake) = &*self.release;
        let (released, _) = wake
            .wait_timeout_while(lock.lock().unwrap(), Duration::from_secs(5), |done| !*done)
            .unwrap();
        assert!(*released, "RPC must finish while decoding is in progress");
        SyntheticRasterKeyframeDecoder.decode_keyframe(init, fragment)
    }
}

struct InMemoryVerifiedStore {
    block: crate::SyntheticCmafBlock,
}

impl FragmentStore for InMemoryVerifiedStore {
    async fn fetch_verified_block(
        &self,
        plan: &ReadGrantPlan,
    ) -> Result<VerifiedKeyframeBlock, MediaWorkerError> {
        let mut raw = Vec::new();
        for (idx, frag_meta) in plan.fragments().iter().enumerate() {
            let slice = self
                .block
                .fragment_slice_bytes(idx)
                .expect("fragment slice")
                .to_vec();
            raw.push((frag_meta.clone(), slice));
        }
        VerifiedKeyframeBlock::from_unverified(
            self.block.init_mp4().to_vec(),
            plan.init_sha256(),
            raw,
        )
        .map_err(MediaWorkerError::from)
    }
}

struct RecordingDelivery {
    payload: Vec<u8>,
    events: Arc<Mutex<Vec<String>>>,
}

impl JobDelivery for RecordingDelivery {
    fn payload(&self) -> &[u8] {
        &self.payload
    }

    async fn send_in_progress(&self) -> Result<(), MediaWorkerError> {
        self.events.lock().push("wpi".to_string());
        Ok(())
    }

    async fn ack_completed(&self) -> Result<(), MediaWorkerError> {
        self.events.lock().push("ack".to_string());
        Ok(())
    }

    async fn nak_failed(&self) -> Result<(), MediaWorkerError> {
        self.events.lock().push("nak".to_string());
        Ok(())
    }
}

struct RecordingPublisher {
    events: Arc<Mutex<Vec<String>>>,
    published: Arc<Mutex<Vec<(String, VisualIndexResultEnvelope)>>>,
    fail_publish: bool,
}

impl ResultPublisher for RecordingPublisher {
    async fn publish_visual_result(
        &self,
        msg_id: &str,
        envelope: &VisualIndexResultEnvelope,
    ) -> Result<(), MediaWorkerError> {
        if self.fail_publish {
            self.events.lock().push("publish_failed".to_string());
            return Err(MediaWorkerError::nats_error(
                "simulated JetStream publish failure",
            ));
        }
        self.events.lock().push("publish_result".to_string());
        self.published
            .lock()
            .push((msg_id.to_string(), envelope.clone()));
        Ok(())
    }

    async fn publish_telemetry_snapshot(
        &self,
        _payload_json: &[u8],
    ) -> Result<(), MediaWorkerError> {
        Ok(())
    }
}
