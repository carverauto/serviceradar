defmodule ServiceRadar.Monitoring.ServiceMonitoringFoundationTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Monitoring.BindingAssignmentCompiler
  alias ServiceRadar.Monitoring.CheckInstance
  alias ServiceRadar.Monitoring.LatestCheckState
  alias ServiceRadar.Monitoring.MonitoredService
  alias ServiceRadar.Monitoring.MonitoredServiceImportBatch
  alias ServiceRadar.Monitoring.MonitoringBinding
  alias ServiceRadar.Monitoring.ServiceGroup
  alias ServiceRadar.Monitoring.ServiceGroupMembership
  alias ServiceRadar.Monitoring.ServiceLevelIndicator
  alias ServiceRadar.Monitoring.ServiceLevelObjective
  alias ServiceRadar.Monitoring.ServiceLevelObjectiveEvaluation
  alias ServiceRadar.Monitoring.ServiceLevelObjectiveRecorder
  alias ServiceRadar.Monitoring.ServiceMonitoringBackfill
  alias ServiceRadar.Observability.PluginResultIngestor
  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Repo
  alias ServiceRadar.Security.AuditHistory
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  @service_permissions MapSet.new([
                         "services.view",
                         "services.create",
                         "services.update",
                         "services.delete",
                         "services.run"
                       ])

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    unique = System.unique_integer([:positive])
    actor = %{id: "operator-#{unique}", role: :operator, permissions: @service_permissions}
    viewer = %{id: "viewer-#{unique}", role: :viewer, permissions: MapSet.new(["services.view"])}

    {:ok, actor: actor, viewer: viewer, unique: unique}
  end

  test "operators can model service groups, bindings, instances, and latest state", %{
    actor: actor,
    unique: unique
  } do
    assert {:ok, service} =
             MonitoredService.create_service(
               %{
                 service_key: "https://example-#{unique}.test",
                 display_name: "Example #{unique}",
                 service_kind: :http,
                 protocol: "https",
                 endpoint_url: "https://example-#{unique}.test/health",
                 host: "example-#{unique}.test",
                 path: "/health",
                 tags: %{"role" => "public-web"}
               },
               actor: actor
             )

    assert service.status == :active

    assert {:ok, disabled_service} =
             service
             |> Ash.Changeset.for_update(:disable, %{}, actor: actor)
             |> Ash.update(actor: actor)

    assert disabled_service.status == :disabled
    assert version_count("monitored_service_versions", service.id) >= 2

    assert {:ok, group} =
             ServiceGroup.create_group(
               %{
                 name: "Public Web #{unique}",
                 slug: "public-web-#{unique}",
                 selection_mode: :explicit
               },
               actor: actor
             )

    assert {:ok, membership} =
             ServiceGroupMembership.add_service(
               %{
                 service_group_id: group.id,
                 monitored_service_id: service.id,
                 source: :explicit
               },
               actor: actor
             )

    assert membership.service_group_id == group.id

    assert {:ok, binding} =
             MonitoringBinding.create_binding(
               %{
                 name: "HTTP availability #{unique}",
                 descriptor_id: "http.availability",
                 descriptor_version: "1.0.0",
                 target_set_type: :service_group,
                 service_group_id: group.id,
                 interval_seconds: 60,
                 timeout_seconds: 5,
                 event_policy: %{"emit_on" => ["status_change"]},
                 alert_policy: %{"promote_after_failures" => 3}
               },
               actor: actor
             )

    assert binding.status == :draft

    assert {:ok, active_binding} =
             binding
             |> Ash.Changeset.for_update(:activate, %{}, actor: actor)
             |> Ash.update(actor: actor)

    assert active_binding.status == :active

    assert {:ok, check_instance} =
             CheckInstance.materialize(
               %{
                 check_key: "binding:#{binding.id}:service:#{service.id}",
                 monitoring_binding_id: binding.id,
                 monitored_service_id: service.id,
                 descriptor_id: "http.availability",
                 descriptor_version: "1.0.0",
                 target_snapshot: %{"url" => service.endpoint_url},
                 event_policy_snapshot: binding.event_policy
               },
               actor: actor
             )

    assert check_instance.status == :active

    observed_at = DateTime.utc_now()

    assert {:ok, state} =
             LatestCheckState.record_state(
               %{
                 check_instance_id: check_instance.id,
                 monitored_service_id: service.id,
                 monitoring_binding_id: binding.id,
                 status: :ok,
                 status_changed_at: observed_at,
                 last_observed_at: observed_at,
                 response_time_ms: 42,
                 summary: "HTTP 200"
               },
               actor: actor
             )

    assert state.status == :ok
    assert state.response_time_ms == 42

    later_observed_at = DateTime.add(observed_at, 60, :second)

    assert {:ok, updated_state} =
             LatestCheckState.record_state(
               %{
                 check_instance_id: check_instance.id,
                 monitored_service_id: service.id,
                 monitoring_binding_id: binding.id,
                 status: :critical,
                 previous_status: :ok,
                 status_changed_at: later_observed_at,
                 last_observed_at: later_observed_at,
                 consecutive_failures: 1,
                 summary: "Timeout"
               },
               actor: actor
             )

    assert updated_state.id == state.id
    assert updated_state.status == :critical
    assert updated_state.previous_status == :ok
  end

  test "bulk import batches have an auditable validation lifecycle", %{
    actor: actor,
    unique: unique
  } do
    assert {:ok, batch} =
             MonitoredServiceImportBatch.create_batch(
               %{
                 source_type: :csv_upload,
                 filename: "services-#{unique}.csv",
                 total_rows: 200,
                 created_by_actor_id: actor.id
               },
               actor: actor
             )

    assert batch.status == :draft

    assert {:ok, validating} =
             batch
             |> Ash.Changeset.for_update(:start_validation, %{}, actor: actor)
             |> Ash.update(actor: actor)

    assert validating.status == :validating

    assert {:ok, validated} =
             validating
             |> Ash.Changeset.for_update(
               :mark_validated,
               %{valid_rows: 198, invalid_rows: 1, duplicate_rows: 1},
               actor: actor
             )
             |> Ash.update(actor: actor)

    assert validated.status == :validated
    assert validated.valid_rows == 198
    assert version_count("monitored_service_import_batch_versions", batch.id) >= 3
  end

  test "service resource create is denied without the create permission", %{
    viewer: viewer,
    unique: unique
  } do
    result =
      MonitoredService
      |> Ash.Changeset.for_create(
        :create,
        %{
          service_key: "denied-#{unique}",
          display_name: "Denied #{unique}",
          service_kind: :http
        },
        actor: viewer
      )
      |> Ash.create(actor: viewer)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  test "monitoring resources are included in the default audit history allow-list" do
    resources = AuditHistory.resources()

    assert MonitoredService in resources
    assert ServiceGroup in resources
    assert MonitoringBinding in resources
    assert CheckInstance in resources
    assert ServiceLevelIndicator in resources
    assert ServiceLevelObjective in resources
    assert ServiceLevelObjectiveEvaluation in resources
    assert MonitoredServiceImportBatch in resources
  end

  test "operators can model SLIs, SLOs, and auditable budget evaluations", %{
    actor: actor,
    unique: unique
  } do
    assert {:ok, group} =
             ServiceGroup.create_group(
               %{
                 name: "SLO Public Web #{unique}",
                 slug: "slo-public-web-#{unique}",
                 selection_mode: :explicit
               },
               actor: actor
             )

    assert {:ok, sli} =
             ServiceLevelIndicator.create_indicator(
               %{
                 sli_key: "availability-#{unique}",
                 name: "Availability #{unique}",
                 sli_type: :availability,
                 source_type: :check_state,
                 measurement_kind: :request,
                 good_statuses: [:ok, :warning]
               },
               actor: actor
             )

    assert sli.status == :draft

    assert {:ok, active_sli} =
             sli
             |> Ash.Changeset.for_update(:activate, %{}, actor: actor)
             |> Ash.update(actor: actor)

    assert active_sli.status == :active
    assert version_count("service_level_indicator_versions", sli.id) >= 2

    assert {:ok, slo} =
             ServiceLevelObjective.create_objective(
               %{
                 slo_key: "public-web-availability-#{unique}",
                 name: "Public Web Availability #{unique}",
                 sli_id: sli.id,
                 target_set_type: :service_group,
                 service_group_id: group.id,
                 slo_kind: :request_based,
                 goal_basis_points: 9_990,
                 compliance_period_type: :rolling,
                 rolling_period_days: 30,
                 owner: "noc",
                 burn_rate_policy: %{
                   "short_window_minutes" => 60,
                   "short_window_threshold" => "14.4"
                 },
                 alert_policy: %{"warn_budget_remaining_below_basis_points" => 2_500}
               },
               actor: actor
             )

    assert slo.goal_basis_points == 9_990
    assert slo.status == :draft

    assert {:ok, active_slo} =
             slo
             |> Ash.Changeset.for_update(:activate, %{}, actor: actor)
             |> Ash.update(actor: actor)

    assert active_slo.status == :active
    assert version_count("service_level_objective_versions", slo.id) >= 2

    period_started_at = ~U[2026-05-01 00:00:00Z]
    period_ended_at = ~U[2026-05-21 00:00:00Z]
    evaluated_at = ~U[2026-05-21 00:05:00Z]

    assert {:ok, evaluation} =
             ServiceLevelObjectiveEvaluation.record_evaluation(
               %{
                 evaluation_key: "slo:#{slo.id}:2026-05-21T00:05:00Z",
                 slo_id: slo.id,
                 period_started_at: period_started_at,
                 period_ended_at: period_ended_at,
                 evaluated_at: evaluated_at,
                 compliance_state: :at_risk,
                 eligible_events: 10_000,
                 good_events: 9_985,
                 bad_events: 15,
                 compliance_basis_points: 9_985,
                 goal_basis_points: 9_990,
                 error_budget_total: 10,
                 error_budget_consumed: 15,
                 error_budget_remaining: -5,
                 budget_remaining_basis_points: -5_000,
                 burn_rate_short: Decimal.new("1.5"),
                 burn_rate_long: Decimal.new("1.1"),
                 severity: :warning,
                 details: %{"reason" => "short-window burn rate threshold crossed"}
               },
               actor: actor
             )

    assert evaluation.compliance_state == :at_risk
    assert evaluation.error_budget_remaining == -5
    assert evaluation.severity == :warning
    assert version_count("service_level_objective_evaluation_versions", evaluation.id) >= 1
  end

  test "SLO goals reject 100 percent targets because they have no error budget", %{
    actor: actor,
    unique: unique
  } do
    assert {:ok, sli} =
             ServiceLevelIndicator.create_indicator(
               %{
                 sli_key: "perfect-target-#{unique}",
                 name: "Perfect Target #{unique}",
                 sli_type: :availability
               },
               actor: actor
             )

    result =
      ServiceLevelObjective.create_objective(
        %{
          slo_key: "perfect-target-#{unique}",
          name: "Perfect Target #{unique}",
          sli_id: sli.id,
          target_set_type: :service_srql,
          target_query: "in:services tag:critical",
          goal_basis_points: 10_000
        },
        actor: actor
      )

    assert {:error, _reason} = result
  end

  test "SLO recorder persists evaluations, refreshes summaries, and emits events", %{
    actor: actor,
    unique: unique
  } do
    assert {:ok, sli} =
             ServiceLevelIndicator.create_indicator(
               %{
                 sli_key: "recorder-availability-#{unique}",
                 name: "Recorder Availability #{unique}",
                 sli_type: :availability
               },
               actor: actor
             )

    assert {:ok, slo} =
             ServiceLevelObjective.create_objective(
               %{
                 slo_key: "recorder-slo-#{unique}",
                 name: "Recorder SLO #{unique}",
                 sli_id: sli.id,
                 target_set_type: :service_srql,
                 target_query: "in:services tag:recorder",
                 slo_kind: :request_based,
                 goal_basis_points: 9_900,
                 alert_policy: %{"warn_budget_remaining_below_basis_points" => 2_500}
               },
               actor: actor
             )

    assert {:ok, evaluation} =
             ServiceLevelObjectiveRecorder.evaluate_and_record(
               slo,
               %{
                 period_started_at: ~U[2026-05-01 00:00:00Z],
                 period_ended_at: ~U[2026-05-21 00:00:00Z],
                 evaluated_at: ~U[2026-05-21 00:05:00Z],
                 eligible_events: 1_000,
                 good_events: 980
               },
               actor: actor
             )

    assert evaluation.compliance_state == :noncompliant
    assert evaluation.event_id

    assert {:ok, updated_slo} = ServiceLevelObjective.get_by_id(slo.id, actor: actor)
    assert updated_slo.last_compliance_state == :noncompliant
    assert updated_slo.last_budget_remaining_basis_points == -10_000
    assert updated_slo.last_evaluated_at == ~U[2026-05-21 00:05:00Z]

    assert %{rows: [[event_family, slo_id, severity, status]]} =
             Repo.query!(
               """
               SELECT
                 unmapped ->> 'event_family',
                 unmapped ->> 'service_level_objective_id',
                 severity,
                 status
               FROM platform.ocsf_events
               WHERE id = $1::uuid
               """,
               [Ecto.UUID.dump!(evaluation.event_id)]
             )

    assert event_family == "slo_evaluation"
    assert slo_id == to_string(slo.id)
    assert severity == "Critical"
    assert status == "Failure"
  end

  test "active bindings compile into check instances and descriptor-aware plugin assignments", %{
    actor: actor,
    unique: unique
  } do
    system_actor = %{id: "system:test-#{unique}", role: :system}
    plugin_id = "http-binding-compiler-#{unique}"

    assert {:ok, _plugin} =
             Plugin
             |> Ash.Changeset.for_create(
               :create,
               %{plugin_id: plugin_id, name: "HTTP Binding Compiler #{unique}"},
               actor: system_actor
             )
             |> Ash.create(actor: system_actor)

    manifest = %{
      "id" => plugin_id,
      "name" => "HTTP Binding Compiler",
      "version" => "0.1.0",
      "entrypoint" => "run_check",
      "outputs" => "serviceradar.plugin_result.v1",
      "capabilities" => ["http_request", "submit_result"],
      "resources" => %{"requested_cpu_ms" => 1000, "requested_memory_mb" => 64},
      "check_descriptors" => [
        %{
          "descriptor_id" => "http.url.availability",
          "version" => "1.0.0",
          "label" => "HTTP URL availability",
          "target_kinds" => ["service"],
          "service_kinds" => ["http"],
          "required_target_fields" => ["endpoint_url"],
          "required_capabilities" => ["http_request", "submit_result"]
        }
      ]
    }

    assert {:ok, package} =
             PluginPackage
             |> Ash.Changeset.for_create(
               :create,
               %{
                 plugin_id: plugin_id,
                 name: "HTTP Binding Compiler",
                 version: "0.1.0",
                 entrypoint: "run_check",
                 outputs: "serviceradar.plugin_result.v1",
                 manifest: manifest,
                 config_schema: %{},
                 signature: %{},
                 source_type: :github,
                 source_commit: "test-#{unique}"
               },
               actor: system_actor
             )
             |> Ash.create(actor: system_actor)

    assert {:ok, approved_package} =
             package
             |> Ash.Changeset.for_update(
               :approve,
               %{approved_capabilities: ["http_request", "submit_result"]},
               actor: system_actor
             )
             |> Ash.update(actor: system_actor)

    assert {:ok, service} =
             MonitoredService.create_service(
               %{
                 service_key: "compiler-http-#{unique}",
                 display_name: "Compiler HTTP #{unique}",
                 service_kind: :http,
                 protocol: "https",
                 endpoint_url: "https://compiler-#{unique}.example.test/health",
                 host: "compiler-#{unique}.example.test",
                 path: "/health"
               },
               actor: actor
             )

    assert {:ok, group} =
             ServiceGroup.create_group(
               %{
                 name: "Compiler Group #{unique}",
                 slug: "compiler-group-#{unique}",
                 selection_mode: :explicit
               },
               actor: actor
             )

    assert {:ok, _membership} =
             ServiceGroupMembership.add_service(
               %{
                 service_group_id: group.id,
                 monitored_service_id: service.id,
                 source: :explicit
               },
               actor: actor
             )

    assert {:ok, binding} =
             MonitoringBinding.create_binding(
               %{
                 name: "Compiler HTTP availability #{unique}",
                 descriptor_id: "http.url.availability",
                 descriptor_version: "1.0.0",
                 plugin_package_id: approved_package.id,
                 target_set_type: :service_group,
                 service_group_id: group.id,
                 agent_scope_type: :agent,
                 agent_scope_value: "agent-compiler-#{unique}",
                 interval_seconds: 60,
                 timeout_seconds: 5,
                 credential_policy: %{
                   "mode" => "brokered",
                   "secret_id" => "018f3f56-1111-7222-8333-123456789abc",
                   "grant_type" => "http_basic",
                   "inject" => %{"type" => "http_basic_auth"},
                   "ttl_seconds" => 120
                 },
                 event_policy: %{"emit_on" => ["status_change"]}
               },
               actor: actor
             )

    assert {:ok, active_binding} =
             binding
             |> Ash.Changeset.for_update(:activate, %{}, actor: actor)
             |> Ash.update(actor: actor)

    grant_issuer = fn attrs, _opts ->
      send(self(), {:monitoring_credential_grant, attrs})

      {:ok,
       attrs
       |> CredentialBrokerGrant.issue_attrs(~U[2026-05-21 17:30:00Z])
       |> Map.put(:id, "grant-#{unique}")}
    end

    assert {:ok, summary} =
             BindingAssignmentCompiler.reconcile_binding(active_binding,
               actor: system_actor,
               generated_at: "2026-05-21T17:30:00Z",
               grant_issuer: grant_issuer
             )

    assert_receive {:monitoring_credential_grant, grant_attrs}
    assert grant_attrs.consumer_kind == :service_monitoring
    assert grant_attrs.consumer_id == active_binding.id
    assert grant_attrs.target_kind == "service"
    assert grant_attrs.target_id == service.id
    assert grant_attrs.agent_id == "agent-compiler-#{unique}"
    assert grant_attrs.allowed_hosts == ["compiler-#{unique}.example.test"]
    assert grant_attrs.allowed_paths == ["/health"]
    assert grant_attrs.ttl_seconds == 120

    assert summary.targets == 1
    assert summary.check_instances == 1
    assert summary.desired_assignments == 1
    assert summary.upserted == 1

    assert {:ok, [check_instance]} =
             CheckInstance.list_by_binding(active_binding.id, actor: actor)

    assert check_instance.monitored_service_id == service.id
    assert check_instance.vantage_id == "agent-compiler-#{unique}"
    assert check_instance.agent_id == nil
    assert check_instance.target_snapshot["endpoint_url"] == service.endpoint_url
    refute Map.has_key?(check_instance.credential_policy_snapshot, "secret_id")
    assert %{"credential_brokers" => [grant]} = check_instance.credential_policy_snapshot
    assert grant["grant_id"] == "grant-#{unique}"

    assert grant["credential_secret_ref"] ==
             "credentialref:network-credential-secret:018f3f56-1111-7222-8333-123456789abc"

    policy_id = "monitoring_binding:#{active_binding.id}"

    assert {:ok, [assignment]} =
             PluginAssignment
             |> Ash.Query.for_read(:read)
             |> Ash.Query.filter(source == :monitoring_binding and policy_id == ^policy_id)
             |> Ash.read(actor: system_actor)

    assert assignment.agent_uid == "agent-compiler-#{unique}"
    assert assignment.plugin_package_id == approved_package.id
    assert assignment.params["schema"] == "serviceradar.plugin_inputs.v1"
    assert [%{"items" => [item]}] = assignment.params["inputs"]
    assert item["check_instance_id"] == check_instance.id
    assert item["descriptor_id"] == "http.url.availability"
    assert item["target"]["endpoint_url"] == service.endpoint_url
    assert item["credential_policy"]["credential_brokers"] == [grant]
  end

  test "target-scoped plugin results update latest check state by check instance", %{
    actor: actor,
    unique: unique
  } do
    assert {:ok, service} =
             MonitoredService.create_service(
               %{
                 service_key: "ingest-http-#{unique}",
                 display_name: "Ingest HTTP #{unique}",
                 service_kind: :http,
                 protocol: "https",
                 endpoint_url: "https://ingest-#{unique}.example.test/health",
                 host: "ingest-#{unique}.example.test",
                 path: "/health"
               },
               actor: actor
             )

    assert {:ok, binding} =
             MonitoringBinding.create_binding(
               %{
                 name: "Ingest HTTP availability #{unique}",
                 descriptor_id: "http.url.availability",
                 descriptor_version: "1.0.0",
                 target_set_type: :explicit_services,
                 target_filters: %{"service_ids" => [service.id]},
                 agent_scope_type: :agent,
                 agent_scope_value: "agent-ingest-#{unique}",
                 event_policy: %{"emit_on" => ["status_change"]}
               },
               actor: actor
             )

    assert {:ok, check_instance} =
             CheckInstance.materialize(
               %{
                 check_key: "ingest:#{unique}:#{service.id}",
                 monitoring_binding_id: binding.id,
                 monitored_service_id: service.id,
                 descriptor_id: "http.url.availability",
                 descriptor_version: "1.0.0",
                 vantage_kind: :agent,
                 vantage_id: "agent-ingest-#{unique}",
                 target_snapshot: %{"endpoint_url" => service.endpoint_url}
               },
               actor: actor
             )

    first_observed_at = ~U[2026-05-21 17:40:00Z]

    assert :ok =
             PluginResultIngestor.ingest(
               %{
                 "status" => "CRITICAL",
                 "summary" => "HTTP timeout",
                 "check_instance_id" => check_instance.id,
                 "response_time_ms" => 120,
                 "api_token" => "plain-api-token",
                 "headers" => %{"authorization" => "Bearer plain-token"},
                 "metrics" => %{"http.status_code" => 504, "password" => "metric-secret"}
               },
               %{
                 agent_id: "agent-ingest-#{unique}",
                 gateway_id: "gateway-ingest",
                 partition: "default",
                 service_name: "HTTP URL",
                 service_type: "plugin",
                 available: false,
                 timestamp: DateTime.to_iso8601(first_observed_at)
               }
             )

    assert {:ok, critical_state} =
             LatestCheckState.get_by_check_instance(check_instance.id, actor: actor)

    assert critical_state.status == :critical
    assert critical_state.previous_status == nil
    assert critical_state.consecutive_failures == 1
    assert critical_state.response_time_ms == 120
    assert critical_state.monitored_service_id == service.id
    assert critical_state.monitoring_binding_id == binding.id
    assert critical_state.summary == "HTTP timeout"
    assert critical_state.metrics["http.status_code"] == 504
    assert critical_state.metrics["password"] == "REDACTED"
    assert get_in(critical_state.details, ["payload", "api_token"]) == "REDACTED"
    assert get_in(critical_state.details, ["payload", "headers", "authorization"]) == "REDACTED"
    refute inspect(critical_state.details) =~ "plain-api-token"
    refute inspect(critical_state.details) =~ "plain-token"
    refute inspect(critical_state.metrics) =~ "metric-secret"

    assert %{rows: [[status_details]]} =
             Repo.query!("""
             SELECT details
             FROM platform.service_status
             WHERE service_name = 'HTTP URL'
               AND message = 'HTTP timeout'
             ORDER BY timestamp DESC
             LIMIT 1
             """)

    refute status_details =~ "plain-api-token"
    refute status_details =~ "plain-token"

    second_observed_at = ~U[2026-05-21 17:41:00Z]

    assert :ok =
             PluginResultIngestor.ingest(
               [
                 %{
                   "status" => "OK",
                   "summary" => "HTTP 200",
                   "check_instance_id" => check_instance.id,
                   "duration_ms" => "32"
                 }
               ],
               %{
                 agent_id: "agent-ingest-#{unique}",
                 gateway_id: "gateway-ingest",
                 partition: "default",
                 service_name: "HTTP URL",
                 service_type: "plugin",
                 available: true,
                 timestamp: DateTime.to_iso8601(second_observed_at)
               }
             )

    assert {:ok, ok_state} =
             LatestCheckState.get_by_check_instance(check_instance.id, actor: actor)

    assert ok_state.id == critical_state.id
    assert ok_state.status == :ok
    assert ok_state.previous_status == :critical
    assert ok_state.consecutive_failures == 0
    assert ok_state.response_time_ms == 32
    assert DateTime.compare(ok_state.status_changed_at, second_observed_at) == :eq
  end

  test "backfill materializes legacy service checks and service identities idempotently", %{
    unique: unique
  } do
    legacy_check_id = Ecto.UUID.generate()
    legacy_check_uuid = Ecto.UUID.dump!(legacy_check_id)
    observed_at = DateTime.truncate(DateTime.utc_now(), :second)

    Repo.query!(
      """
      INSERT INTO platform.service_checks (
        id,
        name,
        check_type,
        target,
        port,
        interval_seconds,
        timeout_seconds,
        retries,
        enabled,
        config,
        warning_threshold_ms,
        critical_threshold_ms,
        last_check_at,
        last_result,
        last_response_time_ms,
        last_error,
        consecutive_failures,
        metadata,
        created_at,
        updated_at
      )
      VALUES (
        $1::uuid,
        $2,
        'http',
        $3,
        443,
        60,
        10,
        3,
        true,
        '{}'::jsonb,
        500,
        1000,
        $4,
        'success',
        42,
        NULL,
        0,
        '{}'::jsonb,
        $4,
        $4
      )
      """,
      [
        legacy_check_uuid,
        "Legacy HTTP #{unique}",
        "https://legacy-#{unique}.example/health",
        observed_at
      ]
    )

    Repo.query!(
      """
      INSERT INTO platform.service_state (
        agent_id,
        gateway_id,
        partition,
        service_type,
        service_name,
        available,
        state,
        message,
        details,
        last_observed_at
      )
      VALUES ($1, $2, 'default', 'plugin', $3, false, 'active', 'timeout', '{"status":"CRITICAL"}', $4)
      ON CONFLICT (agent_id, gateway_id, partition, service_type, service_name) DO UPDATE SET
        available = EXCLUDED.available,
        message = EXCLUDED.message,
        details = EXCLUDED.details,
        last_observed_at = EXCLUDED.last_observed_at,
        state = EXCLUDED.state
      """,
      ["agent-state-#{unique}", "gateway-state-#{unique}", "plugin-http-#{unique}", observed_at]
    )

    Repo.query!(
      """
      INSERT INTO platform.service_status (
        timestamp,
        gateway_id,
        agent_id,
        service_id,
        service_name,
        service_type,
        available,
        message,
        details,
        partition,
        created_at
      )
      VALUES ($1, $2, $3, NULL, $4, 'plugin', true, 'ok', '{"status":"OK"}', 'default', $1)
      """,
      [
        observed_at,
        "gateway-status-#{unique}",
        "agent-status-#{unique}",
        "plugin-status-#{unique}"
      ]
    )

    assert :ok = ServiceMonitoringBackfill.run!()
    assert :ok = ServiceMonitoringBackfill.run!()

    assert %{rows: [[1]]} =
             Repo.query!(
               """
               SELECT count(*)
               FROM platform.check_instances
               WHERE check_key = $1
               """,
               ["legacy:service-check:#{legacy_check_id}"]
             )

    assert %{rows: [["ok", 42]]} =
             Repo.query!(
               """
               SELECT latest.status, latest.response_time_ms
               FROM platform.latest_check_states AS latest
               JOIN platform.check_instances AS check_instance
                 ON check_instance.id = latest.check_instance_id
               WHERE check_instance.check_key = $1
               """,
               ["legacy:service-check:#{legacy_check_id}"]
             )

    assert %{rows: [["critical"]]} =
             Repo.query!(
               """
               SELECT latest.status
               FROM platform.latest_check_states AS latest
               JOIN platform.check_instances AS check_instance
                 ON check_instance.id = latest.check_instance_id
               WHERE check_instance.target_snapshot ->> 'service_name' = $1
               """,
               ["plugin-http-#{unique}"]
             )

    assert %{rows: [["ok"]]} =
             Repo.query!(
               """
               SELECT latest.status
               FROM platform.latest_check_states AS latest
               JOIN platform.check_instances AS check_instance
                 ON check_instance.id = latest.check_instance_id
               WHERE check_instance.target_snapshot ->> 'service_name' = $1
               """,
               ["plugin-status-#{unique}"]
             )
  end

  defp version_count(table, source_id) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM platform.#{table} WHERE version_source_id = $1",
        [Ecto.UUID.dump!(source_id)]
      )

    count
  end
end
