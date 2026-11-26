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
    HEADER_MEDIA_WORKER_GENERATION, HttpControlPlaneGrantClient, InferenceBackendKind,
    IntegrityErrorKind, JobDelivery, JobOutcome, LocalGrantTarget, LocalPlanSpec,
    LongshoreArchiveReader, MAX_COALESCED_RANGE_BYTES, MAX_LONGSHORE_REGISTERED_POOL_BYTES,
    MediaWorkerError, MediaWorkerErrorKind, ModelPinConfig, NvrAnalysisReader, ObjectClass,
    OrtRuntimeProbeResult, ReadGrantPlan, ReadGrantRequest, ReadinessState, ResultPublisher,
    SyntheticColor, SyntheticFragmentSpec, SyntheticObjectSpec, TextEmbedRpcRequest,
    TextEmbedRpcResponse, VISUAL_INDEX_RESULTS_SUBJECT, VerifiedKeyframeBlock,
    VisualIndexJobEnvelope, VisualIndexProcessor, VisualIndexResultEnvelope, WorkerAuthCredentials,
    WorkerConfig, WorkerMetrics, coalesce_fragment_ranges, cosine_similarity, embed_query_text,
    generate_synthetic_cmaf_block, longshore_registered_pool_bytes, serve_http_probes,
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
    let admit_cuda_backend = |cfg: &WorkerConfig, observation| {
        let info = crate::InferenceBackendInfo::new(
            InferenceBackendKind::Candle,
            "cuda:0",
            cfg.models().embedding_dim(),
            "synthetic",
            false,
        )
        .with_dtype(crate::InferencePrecision::F16);
        let backend = crate::candle_tests::RecordingBackend::new(cfg.models(), info);
        crate::verify_startup_capabilities_with_backend(
            cfg,
            &StaticGpuProbe(observation),
            Arc::new(backend),
        )
    };
    let cuda_cfg = WorkerConfig::default().with_execution_provider(ExecutionProvider::Cuda);
    let err = admit_cuda_backend(&cuda_cfg, GpuEnvironmentObservation::no_gpu())
        .expect_err("CUDA provider without hardware must fail closed");
    assert!(matches!(
        err.kind(),
        CapabilityErrorKind::GpuUnavailable(reason) if reason.contains("found 0")
    ));

    for provider in [ExecutionProvider::Cuda, ExecutionProvider::Tensorrt] {
        let cfg = WorkerConfig::default().with_execution_provider(provider);
        for available in [false, true] {
            let probe = StaticGpuProbe(GpuEnvironmentObservation::new(
                1,
                false,
                false,
                None,
                Some(16_384),
                OrtRuntimeProbeResult::synthetic("1.20.1", available, available),
            ));
            let stub_config = cfg.clone().with_backend_kind(InferenceBackendKind::Stub);
            let err = verify_startup_capabilities(&stub_config, &probe)
                .expect_err("GPU provider must refuse the CPU stub");
            assert!(
                matches!(err.kind(), CapabilityErrorKind::GpuUnavailable(reason)
                if reason.contains("cpu_explicit"))
            );
            let stub = Arc::new(crate::DeterministicStubBackend::new(cfg.models().clone()));
            let err = crate::verify_startup_capabilities_with_backend(&cfg, &probe, stub)
                .expect_err("an injected CPU stub must also fail GPU admission");
            assert!(matches!(err.kind(), CapabilityErrorKind::GpuUnavailable(_)));
        }
    }

    // 3. CUDA succeeds when GPU + VRAM are verified, and classifies physical / MIG / time_sliced.
    let cuda_only_obs = GpuEnvironmentObservation::new(
        1,
        false,
        false,
        Some("565.57.01".to_string()),
        Some(24_576),
        OrtRuntimeProbeResult::synthetic("1.20.1", true, false),
    );
    let phys_manifest = admit_cuda_backend(&cuda_cfg, cuda_only_obs)
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
    let trt_cfg = WorkerConfig::default().with_execution_provider(ExecutionProvider::Tensorrt);
    let trt_err = admit_cuda_backend(&trt_cfg, mig_obs.clone())
        .expect_err("an installed TensorRT EP cannot execute a Candle forward pass");
    assert!(
        matches!(trt_err.kind(), CapabilityErrorKind::GpuUnavailable(reason)
        if reason.contains("tensorrt") && reason.contains("Candle"))
    );
    let mig_manifest = admit_cuda_backend(&cuda_cfg, mig_obs)
        .expect("verified CUDA MIG capability should succeed");
    assert_eq!(mig_manifest.gpu_sharing_mode(), GpuSharingMode::Mig);

    let ts_obs = GpuEnvironmentObservation::new(
        1,
        false,
        true,
        Some("565.57.01".to_string()),
        Some(8_192),
        OrtRuntimeProbeResult::synthetic("1.20.1", true, false),
    );
    let ts_manifest = admit_cuda_backend(&cuda_cfg, ts_obs)
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

    let cpu_cfg = WorkerConfig::cpu_explicit_default()
        .with_backend_kind(InferenceBackendKind::Stub)
        .with_models(pinned_models);
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
        &WorkerConfig::cpu_explicit_default().with_backend_kind(InferenceBackendKind::Stub),
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
        let models = ModelPinConfig::new("yolox-s", "2026.1", model_id, "2026.1", dim);
        let cfg = WorkerConfig::cpu_explicit_default()
            .with_backend_kind(InferenceBackendKind::Stub)
            .with_models(models.clone());

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
        let backend = crate::build_inference_backend(&cfg).expect("configured CPU stub");
        let processor = VisualIndexProcessor::with_backend(
            &cfg,
            Arc::clone(&backend),
            grant_client,
            store,
            publisher,
            Arc::clone(&metrics),
        )
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

        // Bounded JFIF JPEG keyframe thumbnails:
        // - block_thumbnail_jpeg_b64 is present (from detected frame 0) and valid JFIF <= 48 KiB
        // - frame 0 omits thumbnail_jpeg_b64 so block_thumbnail_jpeg_b64 is not duplicated
        // - non-suppressed distinct frame 1 carries valid JFIF thumbnail_jpeg_b64 <= 48 KiB
        // - static suppressed frame 2 omits thumbnail_jpeg_b64 in both struct and JSON
        use base64::Engine as _;
        let block_b64 = envelope
            .block_thumbnail_jpeg_b64()
            .expect("block_thumbnail_jpeg_b64 present on indexed block");
        let block_jpeg = base64::engine::general_purpose::STANDARD
            .decode(block_b64)
            .expect("valid base64 block thumbnail");
        assert!(block_jpeg.starts_with(&[0xFF, 0xD8]));
        assert!(block_jpeg.ends_with(&[0xFF, 0xD9]));
        assert!(block_jpeg.len() <= crate::MAX_THUMBNAIL_JPEG_BYTES);
        assert_eq!(
            raw_json["block_thumbnail_jpeg_b64"].as_str(),
            Some(block_b64)
        );

        assert!(envelope.frames()[0].thumbnail_jpeg_b64().is_none());
        assert!(raw_json["frames"][0].get("thumbnail_jpeg_b64").is_none());

        let f1_b64 = envelope.frames()[1]
            .thumbnail_jpeg_b64()
            .expect("non-suppressed distinct frame should carry thumbnail_jpeg_b64");
        assert_ne!(f1_b64, block_b64);
        let f1_jpeg = base64::engine::general_purpose::STANDARD
            .decode(f1_b64)
            .expect("valid base64 frame thumbnail");
        assert!(f1_jpeg.starts_with(&[0xFF, 0xD8]));
        assert!(f1_jpeg.ends_with(&[0xFF, 0xD9]));
        assert!(f1_jpeg.len() <= crate::MAX_THUMBNAIL_JPEG_BYTES);

        assert!(envelope.frames()[2].thumbnail_jpeg_b64().is_none());
        assert!(raw_json["frames"][2].get("thumbnail_jpeg_b64").is_none());

        assert!(!envelope.tracks().is_empty());
        if let Some(tracks_json) = raw_json["tracks"].as_array() {
            for track_json in tracks_json {
                assert!(track_json.get("thumbnail_jpeg_b64").is_none());
            }
        }

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
        let fail_proc = VisualIndexProcessor::with_backend(
            &cfg,
            Arc::clone(&backend),
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
        let gone_proc = VisualIndexProcessor::with_backend(
            &cfg,
            Arc::clone(&backend),
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
async fn sixty_four_keyframe_block_with_continuous_detections_stays_under_nats_max_payload() {
    use base64::Engine as _;
    use std::sync::atomic::{AtomicU32, Ordering};

    const KEYFRAME_COUNT: usize = 64;
    const NATS_MAX_PAYLOAD_BYTES: usize = 1024 * 1024;
    const VEHICLE_PEAK_FRAME: usize = 10;
    const PERSON_PEAK_FRAME: usize = 28;

    struct HighEntropyFrameDecoder {
        next_idx: AtomicU32,
    }

    impl KeyframeDecoder for HighEntropyFrameDecoder {
        fn decode_keyframe(
            &self,
            _init: &ParsedInitSegment,
            _fragment: &ParsedMediaFragment,
        ) -> Result<RgbFrame, KeyframeDecodeError> {
            let idx = self.next_idx.fetch_add(1, Ordering::SeqCst);
            let width = 480u32;
            let height = 270u32;
            let mut pixels = vec![0u8; (width as usize) * (height as usize) * 3];
            let mut state = 0x9E37_79B9u32 ^ idx.wrapping_mul(0x85EB_CA6B);
            for byte in &mut pixels {
                state ^= state << 13;
                state ^= state >> 17;
                state ^= state << 5;
                *byte = (state & 0xFF) as u8;
            }
            pixels[0] = idx as u8;
            RgbFrame::from_rgb8(width, height, pixels)
                .map_err(|err| KeyframeDecodeError::malformed_bitstream(err.to_string()))
        }
    }

    struct ContinuousDetectionBackend {
        dim: usize,
        scene_vec: Vec<f32>,
        vehicle_vec: Vec<f32>,
        person_vec: Vec<f32>,
    }

    impl ContinuousDetectionBackend {
        fn new(dim: usize) -> Self {
            let dense_unit = |phase: usize| -> Vec<f32> {
                let raw: Vec<f32> = (0..dim)
                    .map(|i| {
                        let v = ((i + phase * 17) % 19) as f32 - 9.0;
                        if v == 0.0 { 0.5 } else { v }
                    })
                    .collect();
                let norm = raw.iter().map(|x| x * x).sum::<f32>().sqrt();
                raw.into_iter().map(|x| x / norm).collect()
            };
            Self {
                dim,
                scene_vec: dense_unit(1),
                vehicle_vec: dense_unit(2),
                person_vec: dense_unit(5),
            }
        }
    }

    impl crate::InferenceBackend for ContinuousDetectionBackend {
        fn info(&self) -> crate::InferenceBackendInfo {
            crate::InferenceBackendInfo::new(
                InferenceBackendKind::Stub,
                "cpu",
                self.dim,
                "test",
                true,
            )
        }

        fn detect_objects(
            &self,
            frame: &RgbFrame,
            _min_confidence: f32,
        ) -> Result<Vec<crate::RawDetection>, MediaWorkerError> {
            let idx = usize::from(frame.pixel_at(0, 0)[0]);
            // Advance the vehicle slightly each frame so its track displaces >= 2.5% across the
            // clip (representing a moving vehicle rather than a parked stationary vehicle).
            let dx = (idx as f32) * 0.002;
            let vehicle = if idx == VEHICLE_PEAK_FRAME {
                crate::RawDetection::new(
                    ObjectClass::Vehicle,
                    0.97,
                    [0.36 + dx, 0.38, 0.76 + dx, 0.80],
                )
            } else {
                crate::RawDetection::new(
                    ObjectClass::Vehicle,
                    0.88,
                    [0.38 + dx, 0.40, 0.73 + dx, 0.78],
                )
            };
            let mut dets = vec![vehicle];
            if (20..=35).contains(&idx) {
                let person = if idx == PERSON_PEAK_FRAME {
                    crate::RawDetection::new(ObjectClass::Person, 0.96, [0.14, 0.14, 0.38, 0.86])
                } else {
                    crate::RawDetection::new(ObjectClass::Person, 0.82, [0.18, 0.22, 0.32, 0.74])
                };
                dets.push(person);
            }
            Ok(dets)
        }

        fn encode_annotated_images(
            &self,
            regions: &[(&RgbFrame, Option<ObjectClass>, &[String])],
        ) -> Result<Vec<Vec<f32>>, MediaWorkerError> {
            Ok(regions
                .iter()
                .map(|(_, cls, _)| match cls {
                    None => self.scene_vec.clone(),
                    Some(ObjectClass::Vehicle) => self.vehicle_vec.clone(),
                    Some(_) => self.person_vec.clone(),
                })
                .collect())
        }

        fn encode_images(&self, images: &[&RgbFrame]) -> Result<Vec<Vec<f32>>, MediaWorkerError> {
            Ok(vec![self.scene_vec.clone(); images.len()])
        }

        fn encode_text(&self, _text: &str) -> Result<Vec<f32>, MediaWorkerError> {
            Ok(self.scene_vec.clone())
        }
    }

    let duration = 1_000_000_000u64;
    let init = build_init_mp4(480, 270, 90_000, b"avc1", &avcc_box(&[], &[]));
    let fragments = (0..KEYFRAME_COUNT as u32).map(|seq| {
        let start = u64::from(seq) * duration;
        (
            seq,
            start,
            duration,
            build_fragment_m4s(seq, start, duration, 90_000, &[&[0x65]]),
        )
    });
    let block = assemble_cmaf_block(480, 270, 90_000, init, fragments)
        .expect("assemble 64-keyframe synthetic block");
    let models = ModelPinConfig::default();

    for tracker_mode in [crate::TrackerMode::ByteTrack, crate::TrackerMode::BotSort] {
        let cfg = WorkerConfig::cpu_explicit_default()
            .with_backend_kind(InferenceBackendKind::Stub)
            .with_models(models.clone())
            .with_tracker_mode(tracker_mode)
            .with_dedup_track_crops(true);
        let job = VisualIndexJobEnvelope::new(
            "01933b40-0000-7000-8000-000000000064",
            "00000000-0000-4000-8000-000000000064",
            "00000000-0000-4000-8000-000000000007",
            "00000000-0000-4000-8000-000000000008",
            block.descriptor_sha256(),
            &models,
        );
        let events: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
        let backend: Arc<dyn crate::InferenceBackend> =
            Arc::new(ContinuousDetectionBackend::new(models.embedding_dim()));
        let processor = VisualIndexProcessor::with_backend(
            &cfg,
            backend,
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
            Arc::new(WorkerMetrics::new()),
        )
        .with_keyframe_decoder(Arc::new(HighEntropyFrameDecoder {
            next_idx: AtomicU32::new(0),
        }));

        let outcome = processor
            .process_delivery(Arc::new(RecordingDelivery {
                payload: serde_json::to_vec(&job).expect("job json"),
                events: Arc::clone(&events),
            }))
            .await
            .expect("64-keyframe continuous-detection block should succeed");
        let envelope = outcome
            .completed_envelope()
            .expect("expected Completed outcome");

        assert_eq!(envelope.frames().len(), KEYFRAME_COUNT);
        assert!(envelope.frames().iter().all(|f| !f.scene_suppressed()));
        assert_eq!(envelope.tracks().len(), 2);

        let block_b64 = envelope
            .block_thumbnail_jpeg_b64()
            .expect("block_thumbnail_jpeg_b64 must be present");
        let block_jpeg = base64::engine::general_purpose::STANDARD
            .decode(block_b64)
            .expect("decode block JPEG");
        assert!(block_jpeg.starts_with(&[0xFF, 0xD8]));
        assert!(block_jpeg.ends_with(&[0xFF, 0xD9]));
        assert!(block_jpeg.len() <= crate::MAX_THUMBNAIL_JPEG_BYTES);
        assert!(
            block_jpeg.len() >= 16 * 1024,
            "high-entropy 480x270 frame should produce substantial JPEG (>= 16 KiB), got {} bytes",
            block_jpeg.len()
        );

        let mut total_thumb_b64_bytes = block_b64.len();
        let mut attached_frame_thumbs = 0usize;
        for frame in envelope.frames() {
            if let Some(b64) = frame.thumbnail_jpeg_b64() {
                assert_ne!(
                    b64, block_b64,
                    "block_thumbnail_jpeg_b64 must not be duplicated into frames for {tracker_mode:?}"
                );
                attached_frame_thumbs += 1;
                total_thumb_b64_bytes += b64.len();
                let jpeg = base64::engine::general_purpose::STANDARD
                    .decode(b64)
                    .expect("decode frame JPEG");
                assert!(jpeg.starts_with(&[0xFF, 0xD8]));
                assert!(jpeg.ends_with(&[0xFF, 0xD9]));
                assert!(jpeg.len() <= crate::MAX_THUMBNAIL_JPEG_BYTES);
            }
        }
        assert!(
            (2..KEYFRAME_COUNT).contains(&attached_frame_thumbs),
            "expected budgeted subset of frame thumbnails for {tracker_mode:?}, got {attached_frame_thumbs}/{KEYFRAME_COUNT}"
        );
        assert!(
            envelope.frames()[VEHICLE_PEAK_FRAME]
                .thumbnail_jpeg_b64()
                .is_some(),
            "parked vehicle peak keyframe should be prioritized for {tracker_mode:?}"
        );
        assert!(
            envelope.frames()[PERSON_PEAK_FRAME]
                .thumbnail_jpeg_b64()
                .is_none(),
            "block thumbnail frame (person peak) must not be duplicated into frames for {tracker_mode:?}"
        );
        assert!(
            total_thumb_b64_bytes <= crate::MAX_ENVELOPE_THUMBNAIL_B64_BYTES,
            "total base64 thumbnail bytes {total_thumb_b64_bytes} exceeded budget {} for {tracker_mode:?}",
            crate::MAX_ENVELOPE_THUMBNAIL_B64_BYTES
        );

        let serialized = serde_json::to_vec(envelope).expect("serialize 64-keyframe envelope");
        assert!(
            serialized.len() <= crate::MAX_RESULT_ENVELOPE_JSON_BYTES,
            "serialized 64-keyframe envelope ({} bytes) must stay within {} byte ceiling for {tracker_mode:?}",
            serialized.len(),
            crate::MAX_RESULT_ENVELOPE_JSON_BYTES
        );
        assert!(
            serialized.len() < NATS_MAX_PAYLOAD_BYTES,
            "serialized 64-keyframe envelope ({} bytes) must stay under 1 MiB NATS max_payload for {tracker_mode:?}",
            serialized.len()
        );

        let raw_json: serde_json::Value =
            serde_json::from_slice(&serialized).expect("parse serialized envelope JSON");
        for track_json in raw_json["tracks"].as_array().expect("tracks array") {
            assert!(
                track_json.get("thumbnail_jpeg_b64").is_none(),
                "TrackSummaryPayload must not carry duplicate thumbnail_jpeg_b64"
            );
        }
    }
}

#[tokio::test]
async fn large_base_envelope_trims_thumbnails_to_stay_within_960_kib_ceiling() {
    use base64::Engine as _;
    use std::sync::atomic::{AtomicU32, Ordering};

    struct TexturedDecoder {
        next_idx: AtomicU32,
    }

    impl KeyframeDecoder for TexturedDecoder {
        fn decode_keyframe(
            &self,
            _init: &ParsedInitSegment,
            _fragment: &ParsedMediaFragment,
        ) -> Result<RgbFrame, KeyframeDecodeError> {
            let idx = self.next_idx.fetch_add(1, Ordering::SeqCst);
            let width = 480u32;
            let height = 270u32;
            let mut pixels = vec![0u8; (width as usize) * (height as usize) * 3];
            let mut state = 0x517C_C1B7u32 ^ idx.wrapping_mul(0x27D4_EB2D);
            for byte in &mut pixels {
                state ^= state << 13;
                state ^= state >> 17;
                state ^= state << 5;
                *byte = (state & 0xFF) as u8;
            }
            pixels[0] = (idx & 0xFF) as u8;
            RgbFrame::from_rgb8(width, height, pixels)
                .map_err(|err| KeyframeDecodeError::malformed_bitstream(err.to_string()))
        }
    }

    struct DenseEmbeddingBackend {
        dim: usize,
        scene_vec: Vec<f32>,
        crop_vec: Vec<f32>,
    }

    impl DenseEmbeddingBackend {
        fn new(dim: usize) -> Self {
            let dense_unit = |phase: usize| -> Vec<f32> {
                let raw: Vec<f32> = (0..dim)
                    .map(|i| {
                        let v = ((i + phase * 13) % 23) as f32 - 11.0;
                        if v == 0.0 { 0.375 } else { v }
                    })
                    .collect();
                let norm = raw.iter().map(|x| x * x).sum::<f32>().sqrt();
                raw.into_iter().map(|x| x / norm).collect()
            };
            Self {
                dim,
                scene_vec: dense_unit(3),
                crop_vec: dense_unit(7),
            }
        }
    }

    impl crate::InferenceBackend for DenseEmbeddingBackend {
        fn info(&self) -> crate::InferenceBackendInfo {
            crate::InferenceBackendInfo::new(
                InferenceBackendKind::Stub,
                "cpu",
                self.dim,
                "test",
                true,
            )
        }

        fn detect_objects(
            &self,
            frame: &RgbFrame,
            _min_confidence: f32,
        ) -> Result<Vec<crate::RawDetection>, MediaWorkerError> {
            let idx = usize::from(frame.pixel_at(0, 0)[0]);
            let conf = if idx == 5 { 0.98 } else { 0.86 };
            let dx = (idx as f32) * 0.004;
            Ok(vec![crate::RawDetection::new(
                ObjectClass::Vehicle,
                conf,
                [0.25 + dx, 0.35, 0.65 + dx, 0.78],
            )])
        }

        fn encode_annotated_images(
            &self,
            regions: &[(&RgbFrame, Option<ObjectClass>, &[String])],
        ) -> Result<Vec<Vec<f32>>, MediaWorkerError> {
            Ok(regions
                .iter()
                .map(|(_, cls, _)| match cls {
                    None => self.scene_vec.clone(),
                    Some(_) => self.crop_vec.clone(),
                })
                .collect())
        }

        fn encode_images(&self, images: &[&RgbFrame]) -> Result<Vec<Vec<f32>>, MediaWorkerError> {
            Ok(vec![self.scene_vec.clone(); images.len()])
        }

        fn encode_text(&self, _text: &str) -> Result<Vec<f32>, MediaWorkerError> {
            Ok(self.scene_vec.clone())
        }
    }

    let run_block = |keyframe_count: usize| async move {
        let duration = 1_000_000_000u64;
        let init = build_init_mp4(480, 270, 90_000, b"avc1", &avcc_box(&[], &[]));
        let fragments = (0..keyframe_count as u32).map(|seq| {
            let start = u64::from(seq) * duration;
            (
                seq,
                start,
                duration,
                build_fragment_m4s(seq, start, duration, 90_000, &[&[0x65]]),
            )
        });
        let block = assemble_cmaf_block(480, 270, 90_000, init, fragments)
            .expect("assemble large synthetic block");
        let models = ModelPinConfig::default();
        let cfg = WorkerConfig::cpu_explicit_default()
            .with_backend_kind(InferenceBackendKind::Stub)
            .with_models(models.clone())
            .with_tracker_mode(crate::TrackerMode::ByteTrack)
            .with_dedup_track_crops(true);
        let job = VisualIndexJobEnvelope::new(
            "01933b40-0000-7000-8000-000000000084",
            "00000000-0000-4000-8000-000000000084",
            "00000000-0000-4000-8000-000000000007",
            "00000000-0000-4000-8000-000000000008",
            block.descriptor_sha256(),
            &models,
        );
        let events: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
        let backend: Arc<dyn crate::InferenceBackend> =
            Arc::new(DenseEmbeddingBackend::new(models.embedding_dim()));
        let processor = VisualIndexProcessor::with_backend(
            &cfg,
            backend,
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
            Arc::new(WorkerMetrics::new()),
        )
        .with_keyframe_decoder(Arc::new(TexturedDecoder {
            next_idx: AtomicU32::new(0),
        }));

        let outcome = processor
            .process_delivery(Arc::new(RecordingDelivery {
                payload: serde_json::to_vec(&job).expect("job json"),
                events: Arc::clone(&events),
            }))
            .await
            .expect("large block should succeed");
        outcome
            .completed_envelope()
            .expect("expected Completed outcome")
            .clone()
    };

    let strip_thumbs_len = |envelope: &VisualIndexResultEnvelope| -> usize {
        let mut val = serde_json::to_value(envelope).expect("envelope to value");
        if let Some(obj) = val.as_object_mut() {
            obj.remove("block_thumbnail_jpeg_b64");
        }
        if let Some(frames) = val["frames"].as_array_mut() {
            for frame in frames {
                if let Some(obj) = frame.as_object_mut() {
                    obj.remove("thumbnail_jpeg_b64");
                }
            }
        }
        let stripped: VisualIndexResultEnvelope =
            serde_json::from_value(val).expect("deserialize stripped envelope");
        serde_json::to_vec(&stripped)
            .expect("serialize stripped envelope")
            .len()
    };

    // ~750 KiB base envelope: block thumbnail fits and frame thumbnails are trimmed to <= 960 KiB.
    let envelope_750k = run_block(84).await;
    let base_750k = strip_thumbs_len(&envelope_750k);
    assert!(
        (700 * 1024..=820 * 1024).contains(&base_750k),
        "expected ~750 KiB base envelope without thumbnails, got {base_750k} bytes"
    );
    let serialized_750k = serde_json::to_vec(&envelope_750k).expect("serialize 750k envelope");
    assert!(
        serialized_750k.len() <= crate::MAX_RESULT_ENVELOPE_JSON_BYTES,
        "serialized envelope ({} bytes) exceeded 960 KiB ceiling ({})",
        serialized_750k.len(),
        crate::MAX_RESULT_ENVELOPE_JSON_BYTES
    );
    let block_b64 = envelope_750k
        .block_thumbnail_jpeg_b64()
        .expect("block thumbnail must fit within ~210 KiB remaining headroom");
    let block_jpeg = base64::engine::general_purpose::STANDARD
        .decode(block_b64)
        .expect("decode block JPEG");
    assert!(block_jpeg.starts_with(&[0xFF, 0xD8]) && block_jpeg.ends_with(&[0xFF, 0xD9]));
    let frame_thumb_bytes: usize = envelope_750k
        .frames()
        .iter()
        .filter_map(|f| f.thumbnail_jpeg_b64())
        .map(str::len)
        .sum();
    let total_thumb_bytes = block_b64.len() + frame_thumb_bytes;
    assert!(
        total_thumb_bytes < crate::MAX_ENVELOPE_THUMBNAIL_B64_BYTES,
        "expected headroom trimming below 384 KiB static cap, got {total_thumb_bytes} bytes"
    );
    assert!(
        envelope_750k
            .frames()
            .iter()
            .all(|f| f.thumbnail_jpeg_b64() != Some(block_b64)),
        "block thumbnail must not be duplicated into any frame"
    );

    // ~940 KiB base envelope: even base + block thumbnail exceeds 960 KiB, so all thumbnails drop.
    let envelope_940k = run_block(98).await;
    let base_940k = strip_thumbs_len(&envelope_940k);
    assert!(
        (915 * 1024..=crate::MAX_RESULT_ENVELOPE_JSON_BYTES).contains(&base_940k),
        "expected ~940 KiB base envelope without thumbnails, got {base_940k} bytes"
    );
    assert!(
        envelope_940k.block_thumbnail_jpeg_b64().is_none(),
        "block thumbnail must be dropped when base + block exceeds 960 KiB"
    );
    assert!(
        envelope_940k
            .frames()
            .iter()
            .all(|f| f.thumbnail_jpeg_b64().is_none()),
        "frame thumbnails must all be dropped when block thumbnail does not fit"
    );
    let serialized_940k = serde_json::to_vec(&envelope_940k).expect("serialize 940k envelope");
    assert!(
        serialized_940k.len() <= crate::MAX_RESULT_ENVELOPE_JSON_BYTES,
        "serialized 940k envelope ({} bytes) exceeded 960 KiB ceiling",
        serialized_940k.len()
    );
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

    let (envelope, metrics, events) = index_test_block(block, None).await;

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
    assert_exported_refusals(&metrics, "malformed_bitstream", 2);
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

fn assert_exported_refusals(metrics: &WorkerMetrics, reason: &str, count: u64) {
    let sample = format!(
        r#"serviceradar_media_worker_keyframes_undecodable_total{{reason="{reason}"}} {count}"#
    );
    let output = metrics.render_prometheus_text().unwrap();
    assert!(
        output.lines().any(|line| line == sample),
        "missing sample {sample} in {output}"
    );
}

async fn index_test_block(
    block: crate::SyntheticCmafBlock,
    decoder: Option<Arc<dyn KeyframeDecoder>>,
) -> (
    VisualIndexResultEnvelope,
    Arc<WorkerMetrics>,
    Arc<Mutex<Vec<String>>>,
) {
    let models = ModelPinConfig::default();
    let cfg = WorkerConfig::cpu_explicit_default()
        .with_backend_kind(InferenceBackendKind::Stub)
        .with_models(models.clone());
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
    let backend = crate::build_inference_backend(&cfg).expect("configured CPU stub");
    let processor = VisualIndexProcessor::with_backend(
        &cfg,
        Arc::clone(&backend),
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
    let processor = match decoder {
        Some(decoder) => processor.with_keyframe_decoder(decoder),
        None => processor,
    };
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
async fn verified_invalid_init_publishes_a_refusal_for_each_sample_before_ack() {
    let stream = encode_idr(
        rusty_h264_encoder::EncoderConfig::baseline(16, 16),
        &pattern(16, 16),
    );
    let nals = annex_b_nals(&stream);
    let (sps, pps) = (nals_of_type(&nals, 7)[0], nals_of_type(&nals, 8)[0]);
    let mut short_sps = avcc_box(&[&[0x67]], &[]);
    short_sps[14..16].copy_from_slice(&32u16.to_be_bytes());
    let mut missing_pps = avcc_box(&[], &[]);
    *missing_pps.last_mut().unwrap() = 1;
    for (init, codec) in [
        (
            build_init_mp4(16, 16, 90_000, b"avc1", &avcc_box(&[&sps[..5]], &[pps])),
            "h264",
        ),
        (
            build_init_mp4(16, 16, 90_000, b"avc3", &avcc_box(&[sps], &[&pps[..2]])),
            "h264",
        ),
        (
            build_init_mp4(
                16,
                16,
                90_000,
                b"avc3",
                &avcc_box(&[&[0x67, 0x42, 0, 0, 3]], &[pps]),
            ),
            "h264",
        ),
        (
            build_init_mp4(
                16,
                16,
                90_000,
                b"avc3",
                &avcc_box(&[sps], &[&[0x68, 0xc0, 0, 0, 3]]),
            ),
            "h264",
        ),
        (build_init_mp4(16, 16, 90_000, b"avc1", &short_sps), "h264"),
        (
            build_init_mp4(16, 16, 90_000, b"avc3", &missing_pps),
            "h264",
        ),
        (build_init_mp4(16, 16, 90_000, b"hvc1", &[]), "hevc"),
        (vec![0; 3], "unknown"),
    ] {
        let idr = nals_of_type(&nals, 5)[0];
        let fragments = (0..2).map(|seq| {
            (
                seq,
                0,
                1,
                build_fragment_m4s(seq, 0, 1, 90_000, &[sps, pps, idr]),
            )
        });
        let block = assemble_cmaf_block(16, 16, 90_000, init, fragments).unwrap();
        let (result, metrics, events) = index_test_block(block, None).await;
        let refusals: Vec<_> = result
            .undecodable_keyframes()
            .iter()
            .map(|k| (k.fragment_sequence(), k.reason(), k.codec()))
            .collect();
        assert_eq!(
            refusals,
            [
                (0, "invalid_container", codec),
                (1, "invalid_container", codec)
            ]
        );
        assert!(result.frames().is_empty());
        assert!(result.tracks().is_empty());
        assert_exported_refusals(&metrics, "invalid_container", 2);
        assert_eq!(events.lock().as_slice(), ["publish_result", "ack"]);
    }
}

#[tokio::test]
async fn verified_oversized_recordings_publish_every_refusal_before_ack() {
    let stream = encode_idr(
        rusty_h264_encoder::EncoderConfig::baseline(16, 16),
        &pattern(16, 16),
    );
    let nals = annex_b_nals(&stream);
    for (width, height) in [(4097, 64), (64, 4097)] {
        let init = build_init_mp4(
            width,
            height,
            90_000,
            b"avc1",
            &avcc_box(&nals_of_type(&nals, 7), &nals_of_type(&nals, 8)),
        );
        let fragments =
            (0..2).map(|seq| (seq, 0, 1, build_fragment_m4s(seq, 0, 1, 90_000, &[&[0x65]])));
        let block = assemble_cmaf_block(width, height, 90_000, init, fragments).unwrap();
        let (result, metrics, events) = index_test_block(block, None).await;
        assert_eq!(events.lock().as_slice(), ["publish_result", "ack"]);
        assert!(result.frames().is_empty());
        let reasons: Vec<_> = result
            .undecodable_keyframes()
            .iter()
            .map(|k| (k.fragment_sequence(), k.reason()))
            .collect();
        assert_eq!(reasons, [(0, "limit_exceeded"), (1, "limit_exceeded")]);
        assert_exported_refusals(&metrics, "limit_exceeded", 2);
    }
}

#[tokio::test]
async fn refused_samples_expire_tracks_without_publishing_frames() {
    let duration = 1_000_000_000;
    let specs: Vec<_> = [0, 1, 33, 34]
        .into_iter()
        .map(|seq| {
            SyntheticFragmentSpec::new(
                seq,
                u64::from(seq) * duration,
                duration,
                [40, 44, 50],
                vec![SyntheticObjectSpec::new(
                    ObjectClass::Person,
                    SyntheticColor::Red,
                    [0.1, 0.16, 0.26, 0.86],
                )],
            )
        })
        .collect();
    let source = generate_synthetic_cmaf_block(128, 96, 90_000, &specs).unwrap();
    let mut decoded = 0;
    let fragments = (0..=34).map(|seq| {
        let start = u64::from(seq) * duration;
        let bytes = if (2..33).contains(&seq) {
            build_fragment_m4s(seq, start, duration, 90_000, &[&[0x65]])
        } else {
            let bytes = source.fragment_slice_bytes(decoded).unwrap().to_vec();
            decoded += 1;
            bytes
        };
        (seq, start, duration, bytes)
    });
    let block =
        assemble_cmaf_block(128, 96, 90_000, source.init_mp4().to_vec(), fragments).unwrap();
    let (result, _, _) =
        index_test_block(block, Some(Arc::new(SyntheticRasterKeyframeDecoder))).await;
    assert_eq!(result.undecodable_keyframes().len(), 31);
    assert_eq!(
        result
            .frames()
            .iter()
            .map(|f| f.fragment_sequence())
            .collect::<Vec<_>>(),
        [0, 1, 33, 34]
    );
    let tracks = result.tracks();
    assert_eq!(tracks.len(), 2);
    assert_ne!(tracks[0].track_id(), tracks[1].track_id());
    for (track, start) in tracks.iter().zip([0, 33_000]) {
        assert_eq!(track.first_seen_offset_ms(), start);
        assert_eq!(track.last_seen_offset_ms(), start + 1_000);
        assert_eq!(track.dwell_ms(), 1_000);
        assert_eq!(track.frame_count(), 2);
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
            index_test_block(block, Some(Arc::new(SyntheticRasterKeyframeDecoder))).await;
        let reasons: Vec<_> = result
            .undecodable_keyframes()
            .iter()
            .map(|k| (k.fragment_sequence(), k.reason()))
            .collect();
        assert_eq!(reasons, [(0, first_reason), (3, last_reason)]);
        assert_exported_refusals(&metrics, "limit_exceeded", 1);
        assert_exported_refusals(&metrics, "invalid_container", 1);
        assert_eq!(result.tracks().len(), 1);
        assert_eq!(result.tracks()[0].first_seen_offset_ms(), 2000);
        assert_eq!(result.tracks()[0].last_seen_offset_ms(), 4000);
        log.seek(SeekFrom::Start(0)).unwrap();
        let mut output = String::new();
        log.read_to_string(&mut output).unwrap();
        assert_eq!(
            output.matches("decoding synthetic raster keyframe").count(),
            2,
            "{output}"
        );
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
        assert!(!output.contains("WARN"), "{output}");
    }
}

#[tokio::test]
async fn interactive_text_embed_responder_completes_under_50ms_while_all_index_slots_are_saturated()
{
    let models = ModelPinConfig::default(); // siglip-b16-384, 2026.1, 768-d
    let cfg = WorkerConfig::cpu_explicit_default()
        .with_backend_kind(InferenceBackendKind::Stub)
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

    let (worker, _) = crate::load_and_admit_worker(cfg.clone())
        .await
        .expect("admit CPU stub");
    let processor = VisualIndexProcessor::with_backend(
        &cfg,
        Arc::clone(&worker.backend),
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

    let (shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);
    let _responder = crate::worker::spawn_nats_text_embed_responder(
        worker_nats.clone(),
        &worker,
        Arc::clone(&metrics),
        shutdown_rx,
    )
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

#[tokio::test]
async fn readiness_stays_503_until_text_embed_rpc_responder_is_warmed_up_and_subscribed() {
    let models = ModelPinConfig::default();
    let cfg = WorkerConfig::cpu_explicit_default()
        .with_backend_kind(InferenceBackendKind::Stub)
        .with_models(models.clone());
    let metrics = Arc::new(WorkerMetrics::new());
    let readiness = ReadinessState::not_ready(
        "connecting to NATS and subscribing text-embed RPC",
        Arc::clone(&metrics),
    );
    let (shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);
    let probe_addr = serve_http_probes(
        SocketAddr::from(([127, 0, 0, 1], 0)),
        readiness.clone(),
        shutdown_rx.clone(),
    )
    .await
    .expect("serve_http_probes");

    let (worker, manifest) = crate::load_and_admit_worker(cfg)
        .await
        .expect("load_and_admit_worker");

    // Before NATS RPC subscription completes, /readyz MUST still return 503.
    let before_status = tokio::task::spawn_blocking(move || {
        ureq::config::Config::builder()
            .http_status_as_error(false)
            .build()
            .new_agent()
            .get(&format!("http://{probe_addr}/readyz"))
            .call()
            .expect("GET /readyz before subscribe")
            .status()
            .as_u16()
    })
    .await
    .expect("join /readyz before subscribe");
    assert_eq!(before_status, 503);
    assert!(!readiness.is_ready());

    // Subscribe and warm up on loopback NATS, then mark ready.
    let (nats_addr, nats_server) = spawn_loopback_nats_rpc_broker().await;
    let worker_nats = async_nats::connect(format!("nats://{nats_addr}"))
        .await
        .expect("worker connect loopback NATS");
    let caller_nats = async_nats::connect(format!("nats://{nats_addr}"))
        .await
        .expect("caller connect loopback NATS");

    let _responder = crate::worker::spawn_nats_text_embed_responder(
        worker_nats,
        &worker,
        Arc::clone(&metrics),
        shutdown_rx,
    )
    .await
    .expect("spawn_nats_text_embed_responder");

    readiness.mark_ready(manifest);
    assert!(readiness.is_ready());

    let after_status = tokio::task::spawn_blocking(move || {
        ureq::config::Config::builder()
            .http_status_as_error(false)
            .build()
            .new_agent()
            .get(&format!("http://{probe_addr}/readyz"))
            .call()
            .expect("GET /readyz after subscribe")
            .status()
            .as_u16()
    })
    .await
    .expect("join /readyz after subscribe");
    assert_eq!(after_status, 200);

    // Once /readyz is 200, a live text-embed RPC succeeds immediately.
    let subject = text_embed_rpc_subject(&models);
    let rpc_req =
        TextEmbedRpcRequest::new("person at front door", "siglip-b16-384", "2026.1", 768, 250);
    let reply = tokio::time::timeout(
        Duration::from_millis(250),
        caller_nats.request(
            subject,
            serde_json::to_vec(&rpc_req).expect("req json").into(),
        ),
    )
    .await
    .expect("RPC within 250ms")
    .expect("NATS reply");
    let decoded: TextEmbedRpcResponse =
        serde_json::from_slice(&reply.payload).expect("decode RPC response");
    assert_eq!(decoded.status(), "ok");
    assert_eq!(decoded.embedding().map(<[f32]>::len), Some(768));

    let _ = shutdown_tx.send(true);
    nats_server.abort();
}

#[tokio::test]
async fn text_embed_warmup_allows_2000ms_admission_while_live_rpc_remains_clamped_at_250ms() {
    struct SlowEncodeTextBackend {
        delay: Duration,
        vec: Vec<f32>,
    }

    impl crate::InferenceBackend for SlowEncodeTextBackend {
        fn info(&self) -> crate::InferenceBackendInfo {
            crate::InferenceBackendInfo::new(
                InferenceBackendKind::Stub,
                "cpu",
                self.vec.len(),
                "slow-test",
                true,
            )
        }

        fn detect_objects(
            &self,
            _frame: &RgbFrame,
            _min_confidence: f32,
        ) -> Result<Vec<crate::RawDetection>, MediaWorkerError> {
            Ok(Vec::new())
        }

        fn encode_images(&self, images: &[&RgbFrame]) -> Result<Vec<Vec<f32>>, MediaWorkerError> {
            Ok(vec![self.vec.clone(); images.len()])
        }

        fn encode_text(&self, _text: &str) -> Result<Vec<f32>, MediaWorkerError> {
            std::thread::sleep(self.delay);
            Ok(self.vec.clone())
        }
    }

    let models = ModelPinConfig::default();
    let mut vec = vec![0.0f32; models.embedding_dim()];
    vec[0] = 1.0;
    let backend: Arc<dyn crate::InferenceBackend> = Arc::new(SlowEncodeTextBackend {
        delay: Duration::from_millis(350),
        vec,
    });
    let service = crate::worker::TextEmbedService::new(
        models.clone(),
        backend,
        2,
        Arc::new(WorkerMetrics::new()),
    );

    // Admission warmup uses 2_000 ms deadline, so a 350 ms CPU encode_text succeeds.
    service
        .warmup_rpc()
        .await
        .expect("warmup_rpc must allow up to 2_000 ms for CPU startup");

    // Live interactive RPCs remain clamped to 10..=250 ms even if caller asks for 2_000 ms.
    let live_req = TextEmbedRpcRequest::new(
        "person at front door",
        models.embedder_model_id(),
        models.embedder_model_version(),
        models.embedding_dim(),
        2_000,
    );
    assert_eq!(live_req.deadline_ms(), 250);
    let payload = serde_json::to_vec(&live_req).expect("serialize live request");
    let live_resp = service.handle_rpc_payload(&payload).await;
    assert_eq!(live_resp.status(), "error");
    assert_eq!(
        live_resp.error_reason(),
        Some("text_embed_execution_failed")
    );
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
    let expected_query = format!("descriptor_sha256={}", block.descriptor_sha256());

    std::thread::spawn(move || {
        for _ in 0..3 {
            let Ok((mut sock, _)) = listener.accept() else {
                break;
            };
            let mut reader = BufReader::new(sock.try_clone().expect("clone"));
            let mut req_line = String::new();
            reader.read_line(&mut req_line).expect("req line");
            let raw_target = req_line.split_whitespace().nth(1).unwrap_or("").to_string();
            let (path, query) = raw_target.split_once('?').unwrap_or((&raw_target, ""));
            assert_eq!(
                query, expected_query,
                "NVR analysis_read request must pass ?descriptor_sha256=<hex>"
            );

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

    async fn publish_vantage_result(
        &self,
        _msg_id: &str,
        _envelope: &serviceradar_media_core::VantageResultEnvelope,
    ) -> Result<(), MediaWorkerError> {
        Ok(())
    }

    async fn publish_telemetry_snapshot(
        &self,
        _payload_json: &[u8],
    ) -> Result<(), MediaWorkerError> {
        Ok(())
    }
}
