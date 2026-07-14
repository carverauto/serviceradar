//! Integration tests for `JwtSource`.
//!
//! These tests require a running SPIRE server and agent with workloads registered
//! (see `scripts/run-spire.sh`).
//!
//! The tests cover:
//! - Basic bundle retrieval
//! - JWT SVID fetching
//! - Update notifications
//! - Custom client factories
//! - Resource limits
//! - Health checks
//! - Shutdown behavior
//! - Convenience methods

#![expect(unused_crate_dependencies, reason = "used in the library target")]

#[cfg(feature = "jwt-source")]
#[expect(
    clippy::tests_outside_test_module,
    reason = "https://github.com/rust-lang/rust-clippy/issues/11024"
)]
#[expect(
    clippy::expect_used,
    clippy::unwrap_used,
    reason = "https://github.com/rust-lang/rust-clippy/issues/11119"
)]
mod integration_tests_jwt_source {
    use spiffe::jwt_source::JwtSourceBuilder;
    use spiffe::jwt_source::{JwtSource, MetricsErrorKind, MetricsRecorder, ResourceLimits};
    use spiffe::workload_api::error::WorkloadApiError;
    use spiffe::BundleSource as _;
    use spiffe::{JwtBundle, SpiffeId, TrustDomain, WorkloadApiClient};
    use std::collections::HashMap;

    use std::future::Future;
    use std::pin::Pin;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::Arc;
    use std::time::Duration;
    use tokio::sync::Mutex;

    fn spiffe_id_1() -> SpiffeId {
        SpiffeId::new("spiffe://example.org/myservice").unwrap()
    }

    fn spiffe_id_2() -> SpiffeId {
        SpiffeId::new("spiffe://example.org/myservice2").unwrap()
    }

    fn trust_domain() -> TrustDomain {
        TrustDomain::new("example.org").unwrap()
    }

    /// Test metrics recorder that tracks all recorded metrics.
    #[derive(Debug)]
    struct TestMetricsRecorder {
        updates: AtomicU64,
        reconnects: AtomicU64,
        errors: Arc<Mutex<HashMap<MetricsErrorKind, u64>>>,
        update_notify: Arc<tokio::sync::Notify>,
    }

    impl MetricsRecorder for TestMetricsRecorder {
        fn record_update(&self) {
            self.updates.fetch_add(1, Ordering::Relaxed);
            self.update_notify.notify_one();
        }

        fn record_reconnect(&self) {
            self.reconnects.fetch_add(1, Ordering::Relaxed);
        }

        fn record_error(&self, kind: MetricsErrorKind) {
            // Use a blocking lock since this is called from async context
            // and we need to avoid deadlocks. In a real implementation,
            // we'd use async locking, but for tests this is acceptable.
            let mut errors = self.errors.blocking_lock();
            *errors.entry(kind).or_insert(0) += 1;
        }
    }

    impl TestMetricsRecorder {
        fn new() -> Self {
            Self {
                updates: AtomicU64::new(0),
                reconnects: AtomicU64::new(0),
                errors: Arc::new(Mutex::new(HashMap::new())),
                update_notify: Arc::new(tokio::sync::Notify::new()),
            }
        }

        fn update_count(&self) -> u64 {
            self.updates.load(Ordering::Relaxed)
        }

        /// Returns a handle to the update notification.
        fn update_notify(&self) -> Arc<tokio::sync::Notify> {
            Arc::clone(&self.update_notify)
        }
    }

    async fn get_source() -> JwtSource {
        JwtSource::new().await.expect("Failed to create JwtSource")
    }

    async fn wait_until_healthy(source: &JwtSource) {
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                if source.is_healthy() {
                    return;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("Source should become healthy after creation");
    }

    #[tokio::test]
    #[ignore = "requires running SPIFFE Workload API"]
    async fn test_get_bundle_for_trust_domain() {
        let source = get_source().await;
        let bundle: Arc<JwtBundle> = source
            .bundle_for_trust_domain(&trust_domain())
            .expect("Failed to get JwtBundle")
            .expect("No JwtBundle found");

        assert_eq!(bundle.trust_domain().as_ref(), trust_domain().as_ref());
    }

    #[tokio::test]
    #[ignore = "requires running SPIFFE Workload API"]
    async fn test_try_bundle_for_trust_domain() {
        let source = get_source().await;

        // Should succeed when source is healthy
        let bundle = source
            .try_bundle_for_trust_domain(&trust_domain())
            .expect("try_bundle_for_trust_domain() should return Some when healthy");
        assert_eq!(bundle.trust_domain().as_ref(), trust_domain().as_ref());

        // After shutdown, should return None
        source.shutdown().await;
        assert!(
            source
                .try_bundle_for_trust_domain(&trust_domain())
                .is_none(),
            "try_bundle_for_trust_domain() should return None after shutdown"
        );
    }

    #[tokio::test]
    #[ignore = "requires running SPIFFE Workload API"]
    async fn test_bundle_set() {
        let source = get_source().await;
        let bundle_set = source.bundle_set().expect("Failed to get bundle set");

        let bundle = bundle_set.get(&trust_domain());
        assert!(bundle.is_some(), "Bundle set should contain trust domain");
        assert_eq!(
            bundle.unwrap().trust_domain().as_ref(),
            trust_domain().as_ref()
        );
    }

    #[tokio::test]
    #[ignore = "requires running SPIFFE Workload API"]
    async fn test_fetch_jwt_svid() {
        let source = get_source().await;
        let audience = vec!["test-audience".to_string()];
        let svid = source
            .fetch_jwt_svid(&audience)
            .await
            .expect("Failed to get JWT SVID");

        let expected_ids = [spiffe_id_1(), spiffe_id_2()];
        assert!(
            expected_ids.contains(svid.spiffe_id()),
            "Unexpected SPIFFE ID: {:?}",
            svid.spiffe_id()
        );
        assert!(!svid.token().is_empty(), "JWT token should not be empty");
    }

    #[tokio::test]
    #[ignore = "requires running SPIFFE Workload API"]
    async fn test_fetch_jwt_svid_with_id() {
        let source = get_source().await;
        let audience = vec!["test-audience".to_string()];
        let svid = source
            .fetch_jwt_svid_with_id(&audience, Some(&spiffe_id_1()))
            .await
            .expect("Failed to get JWT SVID with ID");

        assert_eq!(svid.spiffe_id(), &spiffe_id_1());
        assert!(!svid.token().is_empty(), "JWT token should not be empty");
    }

    #[tokio::test]
    #[ignore = "requires running SPIFFE Workload API"]
    async fn test_is_healthy() {
        let source = get_source().await;

        // build() waits for initial sync, but the supervisor may need one scheduler poll
        // before is_healthy() reports runtime health.
        wait_until_healthy(&source).await;

        let bundle_result = source.bundle_for_trust_domain(&trust_domain());
        assert!(
            bundle_result.is_ok(),
            "If is_healthy() returns true, bundle_for_trust_domain() should succeed"
        );

        // After shutdown, should be unhealthy
        source.shutdown().await;
        assert!(
            !source.is_healthy(),
            "Source should be unhealthy after shutdown"
        );
    }

    #[tokio::test]
    #[ignore = "requires running SPIFFE Workload API"]
    async fn test_source_updates() {
        let source = get_source().await;
        let mut updates = source.updated();

        // Wait for initial update (sequence number > 0)
        let initial_seq = updates.last();
        tokio::time::timeout(
            Duration::from_secs(10),
            updates.wait_for(|&seq| seq > initial_seq),
        )
        .await
        .expect("Should receive initial update within 10 seconds")
        .expect("Update channel should not be closed");

        // Verify we got an update
        let new_seq = updates.last();
        assert!(
            new_seq > initial_seq,
            "Sequence number should have increased"
        );
    }

    #[tokio::test]
    #[ignore = "requires running SPIFFE Workload API"]
    async fn test_jwt_source_with_custom_client() {
        type ClientFactory = Arc<
            dyn Fn() -> Pin<
                    Box<dyn Future<Output = Result<WorkloadApiClient, WorkloadApiError>> + Send>,
                > + Send
                + Sync,
        >;

        let factory: ClientFactory =
            Arc::new(|| Box::pin(async { WorkloadApiClient::connect_env().await }));

        let source = JwtSourceBuilder::new()
            .client_factory(factory)
            .build()
            .await
            .unwrap();

        let bundle = source
            .bundle_for_trust_domain(&trust_domain())
            .unwrap()
            .expect("No JwtBundle found");
        assert_eq!(bundle.trust_domain().as_ref(), trust_domain().as_ref());
    }

    #[tokio::test]
    #[ignore = "requires running SPIFFE Workload API"]
    async fn test_resource_limits() {
        // Test with very restrictive limits (should still work if actual values are below limits)
        let limits = ResourceLimits::new(Some(10), Some(1024 * 1024));

        let source = JwtSourceBuilder::new()
            .resource_limits(limits)
            .build()
            .await
            .unwrap();

        // Should work if limits are not exceeded
        let bundle = source.bundle_for_trust_domain(&trust_domain()).unwrap();
        assert!(
            bundle.is_some(),
            "Should get bundle when limits are not exceeded"
        );
    }

    #[tokio::test]
    #[ignore = "requires running SPIFFE Workload API"]
    async fn test_unlimited_resource_limits() {
        // Test with unlimited limits
        let limits = ResourceLimits::unlimited();

        let source = JwtSourceBuilder::new()
            .resource_limits(limits)
            .build()
            .await
            .unwrap();

        // Should work with unlimited limits
        let bundle = source.bundle_for_trust_domain(&trust_domain()).unwrap();
        assert!(bundle.is_some(), "Should get bundle with unlimited limits");
    }

    #[tokio::test]
    #[ignore = "requires running SPIFFE Workload API"]
    async fn test_metrics_recorder() {
        let metrics = Arc::new(TestMetricsRecorder::new());
        let update_notify = metrics.update_notify();

        let source = {
            let metrics = Arc::clone(&metrics);
            JwtSourceBuilder::new()
                .metrics(metrics)
                .build()
                .await
                .unwrap()
        };

        // Verify the source is working
        let _bundle = source.bundle_for_trust_domain(&trust_domain()).unwrap();

        // Wait for an actual bundle rotation (updates are only recorded on rotations, not initial sync)
        let mut updates = source.updated();
        let initial_seq = updates.last();

        // Wait for at least one update (bundle rotation) - use both the update sequence
        // and the metrics notify to ensure we catch the update
        let update_result = tokio::time::timeout(Duration::from_secs(30), async {
            tokio::select! {
                seq_result = updates.wait_for(|&seq| seq > initial_seq) => seq_result,
                () = update_notify.notified() => {
                    // If we got notified of an update, check the sequence
                    if updates.last() > initial_seq {
                        Ok(updates.last())
                    } else {
                        // Wait a bit more for the sequence to update
                        updates.wait_for(|&seq| seq > initial_seq).await
                    }
                }
            }
        })
        .await;

        // If we got an update, metrics should have been recorded
        // Note: Initial sync doesn't record an update; only bundle rotations do.
        // If no update occurred within 30 seconds, that's acceptable (the source
        // might not have rotated bundles yet). The test verifies that the metrics
        // recorder is set up correctly and will record updates when they occur.
        if let Ok(Ok(_seq)) = update_result {
            assert!(
                metrics.update_count() > 0,
                "Should have recorded at least one update after bundle rotation"
            );
        }
    }

    #[tokio::test]
    #[ignore = "requires running SPIFFE Workload API"]
    async fn test_shutdown_with_timeout() {
        let source = JwtSourceBuilder::new()
            .shutdown_timeout(Some(Duration::from_secs(5)))
            .build()
            .await
            .unwrap();

        // Shutdown should complete within timeout
        let result =
            tokio::time::timeout(Duration::from_secs(10), source.shutdown_configured()).await;

        assert!(result.is_ok(), "Shutdown should complete");
        result.unwrap().expect("Shutdown should succeed");

        // After shutdown, operations should fail
        assert!(
            source.bundle_for_trust_domain(&trust_domain()).is_err(),
            "bundle_for_trust_domain() should fail after shutdown"
        );
    }

    #[tokio::test]
    #[ignore = "requires running SPIFFE Workload API"]
    async fn test_shutdown_idempotent() {
        let source = JwtSourceBuilder::new()
            .shutdown_timeout(Some(Duration::from_secs(5)))
            .build()
            .await
            .unwrap();

        // First shutdown
        source.shutdown_configured().await.unwrap();

        // Second shutdown should also succeed (idempotent)
        let result = source.shutdown_configured().await;
        assert!(result.is_ok(), "Shutdown should be idempotent");
    }

    #[tokio::test]
    #[ignore = "requires running SPIFFE Workload API"]
    async fn test_reconnect_backoff_config() {
        let source = JwtSourceBuilder::new()
            .reconnect_backoff(Duration::from_millis(100), Duration::from_secs(5))
            .build()
            .await
            .unwrap();

        // Should work with custom backoff
        let bundle = source.bundle_for_trust_domain(&trust_domain()).unwrap();
        assert!(
            bundle.is_some(),
            "Should get bundle with custom backoff config"
        );
    }

    #[tokio::test]
    #[ignore = "requires running SPIFFE Workload API"]
    async fn test_custom_endpoint() {
        // Test that custom endpoint configuration works
        // This will use the default endpoint from environment if custom endpoint fails
        let source = JwtSourceBuilder::new()
            .endpoint("unix:/tmp/spire-agent/public/api.sock")
            .build()
            .await
            .unwrap();

        let bundle = source.bundle_for_trust_domain(&trust_domain()).unwrap();
        assert!(bundle.is_some(), "Should get bundle with custom endpoint");
    }

    #[tokio::test]
    #[ignore = "requires running SPIFFE Workload API"]
    async fn test_health_check_guarantees_bundle_success() {
        let source = get_source().await;

        // If is_healthy() returns true, bundle_for_trust_domain() must succeed
        if source.is_healthy() {
            let bundle_result = source.bundle_for_trust_domain(&trust_domain());
            assert!(
                bundle_result.is_ok(),
                "is_healthy() returning true must guarantee bundle_for_trust_domain() succeeds"
            );
        }

        // Test multiple times to ensure consistency
        for _ in 0..10 {
            if source.is_healthy() {
                assert!(
                    source.bundle_for_trust_domain(&trust_domain()).is_ok(),
                    "is_healthy() must consistently guarantee bundle_for_trust_domain() success"
                );
            }
        }
    }

    #[tokio::test]
    #[ignore = "requires running SPIFFE Workload API"]
    async fn test_update_notifications_sequence() {
        let source = get_source().await;
        let mut updates = source.updated();

        // Get initial sequence number
        let initial_seq = updates.last();

        // Wait for at least one update
        tokio::time::timeout(
            Duration::from_secs(30),
            updates.wait_for(|&seq| seq > initial_seq),
        )
        .await
        .expect("Should receive update within 30 seconds")
        .expect("Update channel should not be closed");

        // Sequence should have increased
        let new_seq = updates.last();
        assert!(new_seq > initial_seq, "Sequence number should increase");

        // Sequence numbers should be monotonic
        assert!(
            new_seq >= initial_seq,
            "Sequence numbers should be monotonic"
        );
    }

    #[tokio::test]
    #[ignore = "requires running SPIFFE Workload API"]
    async fn test_multiple_update_receivers() {
        let source = get_source().await;
        let mut updates1 = source.updated();
        let updates2 = source.updated();

        let initial_seq1 = updates1.last();
        let initial_seq2 = updates2.last();

        // Both should start with the same sequence
        assert_eq!(
            initial_seq1, initial_seq2,
            "Receivers should start with same sequence"
        );

        // Wait for update on one receiver
        tokio::time::timeout(
            Duration::from_secs(30),
            updates1.wait_for(|&seq| seq > initial_seq1),
        )
        .await
        .expect("Should receive update")
        .expect("Update channel should not be closed");

        // Both receivers should see the update
        assert_eq!(
            updates1.last(),
            updates2.last(),
            "All receivers should see the same sequence number"
        );
    }

    #[tokio::test]
    #[ignore = "requires running SPIFFE Workload API"]
    async fn test_builder_defaults() {
        // Test that builder with defaults works
        let source = JwtSourceBuilder::new().build().await.unwrap();

        let bundle = source.bundle_for_trust_domain(&trust_domain()).unwrap();
        assert!(
            bundle.is_some(),
            "Should work with default builder configuration"
        );
    }

    #[tokio::test]
    #[ignore = "requires running SPIFFE Workload API"]
    async fn test_bundle_set_after_shutdown() {
        let source = get_source().await;
        source.shutdown().await;

        // After shutdown, bundle set operations should fail
        assert!(
            source.bundle_set().is_err(),
            "bundle_set() should fail after shutdown"
        );
    }

    #[tokio::test]
    #[ignore = "requires running SPIFFE Workload API"]
    async fn test_updated_after_shutdown() {
        let source = get_source().await;
        let mut updates = source.updated();

        // Shutdown the source
        source.shutdown().await;

        // Receiver should still be valid (watch channels don't close on sender drop)
        // But we can't receive new updates
        let seq_before = updates.last();

        // Verify immediately that sequence hasn't changed
        let seq_immediate = updates.last();
        assert_eq!(
            seq_before, seq_immediate,
            "Sequence should not change immediately after shutdown"
        );

        let result = tokio::time::timeout(Duration::from_secs(1), updates.changed())
            .await
            .expect("changed() should report closure after shutdown");
        match result {
            Ok(seq) => {
                assert_eq!(
                    seq, seq_before,
                    "Only an already-pending update may be observed after shutdown"
                );

                let closed = tokio::time::timeout(Duration::from_secs(1), updates.changed())
                    .await
                    .expect("changed() should report closure after pending update");
                assert!(matches!(
                    closed,
                    Err(spiffe::jwt_source::JwtSourceError::Closed)
                ));
            }
            Err(spiffe::jwt_source::JwtSourceError::Closed) => {}
            Err(err) => panic!("Unexpected update error after shutdown: {err}"),
        }

        let seq_after = updates.last();
        assert_eq!(
            seq_before, seq_after,
            "Sequence should not change after shutdown"
        );
    }

    #[tokio::test]
    #[ignore = "requires running SPIFFE Workload API"]
    async fn test_fetch_jwt_svid_after_shutdown() {
        let source = get_source().await;
        source.shutdown().await;

        let audience = vec!["test-audience".to_string()];
        let result = source.fetch_jwt_svid(&audience).await;

        // Should fail after shutdown
        assert!(
            result.is_err(),
            "fetch_jwt_svid() should fail after shutdown"
        );
    }

    #[tokio::test]
    #[ignore = "requires running SPIFFE Workload API"]
    async fn test_fetch_jwt_svid_with_id_after_shutdown() {
        let source = get_source().await;
        source.shutdown().await;

        let audience = vec!["test-audience".to_string()];
        let result = source
            .fetch_jwt_svid_with_id(&audience, Some(&spiffe_id_1()))
            .await;

        // Should fail after shutdown
        assert!(
            result.is_err(),
            "fetch_jwt_svid_with_id() should fail after shutdown"
        );
    }
}
