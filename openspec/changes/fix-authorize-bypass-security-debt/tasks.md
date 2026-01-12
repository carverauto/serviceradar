## 1. Create SystemActor Module
- [x] 1.1 Create `lib/serviceradar/actors/system_actor.ex` with `for_tenant/2` and `platform/1` functions.
- [ ] 1.2 Add unit tests for SystemActor module in `test/serviceradar/actors/system_actor_test.exs`.
- [x] 1.3 Document SystemActor usage pattern in module docs.

## 2. Update Authorization Policies
- [ ] 2.1 Add `:system` role recognition to base authorization policies.
- [ ] 2.2 Update Gateway resource policies to allow `:system` role with tenant_id match.
- [ ] 2.3 Update Agent resource policies to allow `:system` role with tenant_id match.
- [ ] 2.4 Update Checker resource policies to allow `:system` role with tenant_id match.
- [ ] 2.5 Update SweepGroup resource policies to allow `:system` role with tenant_id match.
- [ ] 2.6 Update Device resource policies to allow `:system` role with tenant_id match.
- [ ] 2.7 Update Alert resource policies to allow `:system` role with tenant_id match.
- [ ] 2.8 Update ZenRule resource policies to allow `:system` role with tenant_id match.
- [ ] 2.9 Verify all tenant-scoped resources have consistent `:system` role bypass.

## 3. Fix High-Risk GenServers
- [x] 3.1 Convert `state_monitor.ex` to use SystemActor.
- [x] 3.2 Convert `zen_rule_sync.ex` to use SystemActor.
- [x] 3.3 Convert `health_tracker.ex` to use SystemActor.
- [ ] 3.4 Convert `config_server.ex` to use SystemActor.

## 4. Fix High-Risk Oban Workers
- [x] 4.1 Convert `sweep_monitor_worker.ex` to use SystemActor.
- [x] 4.2 Convert `stateful_alert_cleanup_worker.ex` to use SystemActor.
- [ ] 4.3 Convert `provision_leaf_worker.ex` to use SystemActor.
- [ ] 4.4 Convert `provision_collector_worker.ex` to use SystemActor.
- [ ] 4.5 Convert `create_account_worker.ex` to use SystemActor.

## 5. Fix High-Risk Engine/Compiler Files
- [ ] 5.1 Convert `stateful_alert_engine.ex` to use SystemActor (10 instances).
- [ ] 5.2 Convert `sweep_compiler.ex` to use shared SystemActor (already has pattern, standardize).
- [ ] 5.3 Convert `sync_config_generator.ex` to use SystemActor.
- [ ] 5.4 Convert `log_promotion.ex` to use SystemActor.

## 6. Fix Edge/Onboarding Files
- [ ] 6.1 Convert `agent_gateway_sync.ex` to use SystemActor.
- [ ] 6.2 Convert `onboarding_packages.ex` to use SystemActor.
- [ ] 6.3 Convert `edge_site.ex` to use SystemActor.
- [ ] 6.4 Convert `nats_leaf_server.ex` to use SystemActor.
- [ ] 6.5 Convert `collector_package.ex` to use SystemActor.
- [ ] 6.6 Convert `tenant_resolver.ex` to use SystemActor.
- [ ] 6.7 Convert `platform_service_certificates.ex` to use SystemActor.

## 7. Fix Seeder Files
- [ ] 7.1 Convert `template_seeder.ex` to use SystemActor.platform.
- [ ] 7.2 Convert `zen_rule_seeder.ex` to use SystemActor.platform.
- [ ] 7.3 Convert `rule_seeder.ex` to use SystemActor.platform.

## 8. Fix Bootstrap/Identity Files
- [ ] 8.1 Convert `platform_tenant_bootstrap.ex` to use SystemActor.platform.
- [ ] 8.2 Convert `operator_bootstrap.ex` to use SystemActor.platform.
- [ ] 8.3 Convert `tenant.ex` action helpers to use SystemActor.platform.
- [ ] 8.4 Convert `send_magic_link_email.ex` to use SystemActor.platform.

## 9. Fix Remaining Files
- [ ] 9.1 Convert `device.ex` (actor module) to use SystemActor.
- [ ] 9.2 Convert `sync_ingestor_queue.ex` to use SystemActor.
- [ ] 9.3 Convert `event_publisher.ex` to use SystemActor.
- [ ] 9.4 Convert `internal_log_publisher.ex` to use SystemActor.
- [ ] 9.5 Convert `onboarding_writer.ex` to use SystemActor.
- [ ] 9.6 Convert `sync_log_writer.ex` to use SystemActor.
- [ ] 9.7 Convert `health_event.ex` to use SystemActor.
- [ ] 9.8 Convert `agent_registry.ex` to use SystemActor.platform (cross-tenant query).
- [ ] 9.9 Convert `tenant_registry_loader.ex` to use SystemActor.platform.
- [ ] 9.10 Convert `tenant_queues.ex` to use SystemActor.platform (reads all tenants).
- [ ] 9.11 Convert `integration_source.ex` to use SystemActor.
- [ ] 9.12 Convert `nats_platform_token.ex` to use SystemActor.platform.
- [ ] 9.13 Convert `config_version.ex` to use SystemActor.
- [ ] 9.14 Convert `create_version_history.ex` change to use SystemActor.
- [ ] 9.15 Convert `unique_platform_tenant.ex` validation to use SystemActor.platform.

## 10. Regression Prevention
- [ ] 10.1 Create custom Credo check for `authorize?: false` usage.
- [ ] 10.2 Add Credo check to CI pipeline.
- [ ] 10.3 Document SystemActor pattern in developer guide / CLAUDE.md.

## 11. Verification
- [ ] 11.1 Run full test suite to verify no regressions.
- [ ] 11.2 Verify zero instances of `authorize?: false` in `lib/` (grep check).
- [ ] 11.3 Manual testing of key workflows (sweep monitoring, alert engine, onboarding).
