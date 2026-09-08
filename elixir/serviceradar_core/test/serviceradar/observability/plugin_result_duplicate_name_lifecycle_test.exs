defmodule ServiceRadar.Observability.PluginResultDuplicateNameLifecycleTest do
  use ServiceRadar.Observability.PluginResultIngestorTestSupport

  test "an assignment cannot authorize a different labeled plugin with the same name" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [])

    {payload, status, _observed_at} = plugin_result_fixture(assignment?: false)
    _assigned = create_repair_assignment!(status)
    unassigned_package = create_repair_package!(status.service_name)

    labeled_payload = Map.put(payload, "labels", %{"plugin_id" => unassigned_package.plugin_id})

    assert :ok = PluginResultIngestor.ingest(labeled_payload, status)

    assert [[true, "edge plugin completed", _timestamp, "inactive"]] =
             current_state_rows_with_state(status)

    assert length(history_rows(status)) == 1
  end

  test "deactivation and orphan cleanup prefer an explicit plugin id over a shared name" do
    {_payload, status, observed_at} = plugin_result_fixture(assignment?: false)
    assigned = create_repair_assignment!(status)
    unassigned_package = create_repair_package!(status.service_name)

    seed_service_state(status, observed_at,
      available: true,
      message: "same-name unassigned plugin",
      state: "active"
    )

    Repo.query!(
      """
      UPDATE platform.service_state
      SET details = $1
      WHERE agent_id = $2
        AND gateway_id = $3
        AND partition = $4
        AND service_type = $5
        AND service_name = $6
      """,
      [
        Jason.encode!(%{"labels" => %{"plugin_id" => unassigned_package.plugin_id}}),
        status.agent_id,
        status.gateway_id,
        status.partition,
        status.service_type,
        status.service_name
      ]
    )

    assert :ok = ServiceStateRegistry.deactivate_for_assignment(assigned)

    assert [[true, "same-name unassigned plugin", ^observed_at, "active"]] =
             current_state_rows_with_state(status)

    assert {:ok, _count} = ServiceStateRegistry.reconcile_plugin_assignments()

    assert [[true, "same-name unassigned plugin", ^observed_at, "inactive"]] =
             current_state_rows_with_state(status)
  end

  test "assignment upsert preserves an eligible same-name state with another explicit plugin id" do
    {_payload, status, observed_at} = plugin_result_fixture(assignment?: false)
    create_agent(status.agent_id, status.gateway_id)

    target_assignment = create_repair_assignment!(status)
    existing_package = create_repair_package!(status.service_name)
    _existing_assignment = create_repair_assignment_for_package!(status, existing_package)

    seed_service_state(status, observed_at,
      available: true,
      message: "different same-name plugin result",
      state: "inactive"
    )

    existing_details = %{
      "labels" => %{"plugin_id" => existing_package.plugin_id},
      "result_kind" => "real"
    }

    Repo.query!(
      """
      UPDATE platform.service_state
      SET details = $1
      WHERE agent_id = $2
        AND gateway_id = $3
        AND partition = $4
        AND service_type = $5
        AND service_name = $6
      """,
      [
        Jason.encode!(existing_details),
        status.agent_id,
        status.gateway_id,
        status.partition,
        status.service_type,
        status.service_name
      ]
    )

    assert :ok = ServiceStateRegistry.upsert_for_assignment(target_assignment)

    assert [[true, "different same-name plugin result", ^observed_at, "inactive"]] =
             current_state_rows_with_state(status)

    assert Jason.decode!(current_state_details(status)) == existing_details
  end
end
