defmodule ServiceRadar.Monitoring.ServiceMonitoringFoundationTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Monitoring.CheckInstance
  alias ServiceRadar.Monitoring.LatestCheckState
  alias ServiceRadar.Monitoring.MonitoredService
  alias ServiceRadar.Monitoring.MonitoredServiceImportBatch
  alias ServiceRadar.Monitoring.MonitoringBinding
  alias ServiceRadar.Monitoring.ServiceGroup
  alias ServiceRadar.Monitoring.ServiceGroupMembership
  alias ServiceRadar.Repo
  alias ServiceRadar.Security.AuditHistory
  alias ServiceRadar.TestSupport

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
    assert MonitoredServiceImportBatch in resources
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
