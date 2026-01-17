## 1. Create SystemActor Module
- [x] 1.1 Create `lib/serviceradar/actors/system_actor.ex` with `for_tenant/2` and `platform/1` functions.
- [x] 1.2 Add unit tests for SystemActor module in `test/serviceradar/actors/system_actor_test.exs`.
- [x] 1.3 Document SystemActor usage pattern in module docs.

## 2. Update Authorization Policies
- [x] 2.1 Add `:system` role recognition to base authorization policies.
- [x] 2.2-2.8 Update all resource policies with `:system` role bypass.
- [x] 2.9 Verify all tenant-scoped resources have consistent `:system` role bypass.
- [x] 2.10 **SIMPLIFIED**: Removed redundant `tenant_id == ^actor(:tenant_id)` checks from
      schema-isolated resources. PostgreSQL schema isolation already enforces tenant boundaries.
      Only `TenantMembership` (public schema with `global?: true`) retains the tenant_id check.

      Schema-isolated resources now use simple bypass:
      ```elixir
      bypass always() do
        authorize_if actor_attribute_equals(:role, :system)
      end
      ```

      Resources updated (37 total): HealthEvent, Alert, Gateway, Checker, Agent, ServiceCheck,
      Device, PollJob, Partition, SweepGroup, StatefulAlertRule, ZenRule, EdgeSite,
      CollectorPackage, NatsLeafServer, SweepProfile, SweepGroupExecution, SweepHostResult,
      ConfigTemplate, ConfigVersion, ConfigInstance, ZenRuleTemplate, StatefulAlertRuleHistory,
      StatefulAlertRuleState, Log, StatefulAlertRuleTemplate, LogPromotionRuleTemplate,
      LogPromotionRule, OcsfEvent, PollingSchedule, DeviceGroup, TenantCA, OnboardingPackage,
      NatsCredential, IntegrationSource, User, ApiToken

## 3. Fix High-Risk GenServers
- [x] 3.1 Convert `state_monitor.ex` to use SystemActor.
- [x] 3.2 Convert `zen_rule_sync.ex` to use SystemActor.
- [x] 3.3 Convert `health_tracker.ex` to use SystemActor.
- [x] 3.4 Convert `config_server.ex` to use SystemActor.

## 4. Fix High-Risk Oban Workers
- [x] 4.1 Convert `sweep_monitor_worker.ex` to use SystemActor.
- [x] 4.2 Convert `stateful_alert_cleanup_worker.ex` to use SystemActor.
- [x] 4.3 Convert `provision_leaf_worker.ex` to use SystemActor.
- [x] 4.4 Convert `provision_collector_worker.ex` to use SystemActor.
- [x] 4.5 Convert `create_account_worker.ex` to use SystemActor.

## 5. Fix High-Risk Engine/Compiler Files
- [x] 5.1 Convert `stateful_alert_engine.ex` to use SystemActor (9 instances).
- [x] 5.2 Convert `sweep_compiler.ex` to use shared SystemActor (3 instances).
- [x] 5.3 Convert `sync_config_generator.ex` to use SystemActor (3 instances).
- [x] 5.4 Convert `log_promotion.ex` to use SystemActor (1 instance).

## 6. Fix Edge/Onboarding Files
- [x] 6.1 Convert `agent_gateway_sync.ex` to use SystemActor.
- [x] 6.2 Convert `onboarding_packages.ex` to use SystemActor.
- [x] 6.3 Convert `edge_site.ex` to use SystemActor.
- [x] 6.4 Convert `nats_leaf_server.ex` to use SystemActor.
- [x] 6.5 Convert `collector_package.ex` to use SystemActor.
- [x] 6.6 Convert `tenant_resolver.ex` to use SystemActor.
- [x] 6.7 Convert `platform_service_certificates.ex` to use SystemActor.
- [x] 6.8 Convert `tenant_ca/generator.ex` to use SystemActor.

## 7. Fix Seeder Files
- [x] 7.1 Convert `template_seeder.ex` to use SystemActor.platform.
- [x] 7.2 Convert `zen_rule_seeder.ex` to use SystemActor.platform.
- [x] 7.3 Convert `rule_seeder.ex` to use SystemActor.platform.

## 8. Fix Bootstrap/Identity Files
- [x] 8.1 Convert `platform_tenant_bootstrap.ex` to use SystemActor.platform.
- [x] 8.2 Convert `operator_bootstrap.ex` to use SystemActor.platform.
- [x] 8.3 Convert `tenant.ex` action helpers to use SystemActor.platform.
- [x] 8.4 Convert `send_magic_link_email.ex` to use SystemActor.platform.

## 9. Fix Remaining Files
- [x] 9.1 Convert `device.ex` (actor module) to use SystemActor.
- [x] 9.2 Convert `sync_ingestor_queue.ex` to use SystemActor.
- [x] 9.3 Convert `event_publisher.ex` to use SystemActor.
- [x] 9.4 Convert `internal_log_publisher.ex` to use SystemActor.
- [x] 9.5 Convert `onboarding_writer.ex` to use SystemActor.
- [x] 9.6 Convert `sync_log_writer.ex` to use SystemActor.
- [x] 9.7 Convert `health_event.ex` to use SystemActor.
- [x] 9.8 Convert `agent_registry.ex` to use SystemActor.platform (cross-tenant query).
- [x] 9.9 Convert `tenant_registry_loader.ex` to use SystemActor.platform.
- [x] 9.10 Convert `tenant_queues.ex` to use SystemActor.platform (reads all tenants).
- [x] 9.11 Convert `integration_source.ex` to use SystemActor.
- [x] 9.12 Convert `nats_platform_token.ex` to use SystemActor.platform.
- [x] 9.13 Convert `config_version.ex` to use SystemActor. (N/A - was already handled via create_version_history.ex)
- [x] 9.14 Convert `create_version_history.ex` change to use SystemActor.
- [x] 9.15 Convert `unique_platform_tenant.ex` validation to use SystemActor.platform.

## 10. Regression Prevention
- [x] 10.1 Create custom Credo check for `authorize?: false` usage.
- [x] 10.2 Add Credo check to CI pipeline.
- [x] 10.3 Document SystemActor pattern in developer guide / CLAUDE.md.

## 11. Verification
- [ ] 11.1 Run full test suite to verify no regressions.
- [x] 11.2 Verify zero instances of `authorize?: false` in `lib/` (grep check) - Only 4 remain, all in comments/documentation.
- [ ] 11.3 Manual testing of key workflows (sweep monitoring, alert engine, onboarding).
