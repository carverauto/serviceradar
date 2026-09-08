defmodule ServiceRadar.Observability.PluginResultAssignmentLifecycleTest do
  use ServiceRadar.Observability.PluginResultIngestorTestSupport

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.ServiceState
  alias ServiceRadar.Observability.ServiceStateRegistry.PluginState

  require Ash.Query

  test "a delayed result is retained in history without reactivating a disabled assignment" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [])

    {payload, status, observed_at} = plugin_result_fixture(assignment?: false)
    assignment = create_repair_assignment!(status)

    assert :ok = PluginResultIngestor.ingest(payload, status)

    assert [[true, "edge plugin completed", first_state_at, "active"]] =
             current_state_rows_with_state(status)

    disabled_assignment =
      assignment
      |> Ash.Changeset.for_update(:update, %{enabled: false}, actor: system_actor())
      |> Ash.update!(domain: ServiceRadar.Plugins)

    assert :ok = ServiceStateRegistry.deactivate_for_assignment(disabled_assignment)

    assert [[true, "edge plugin completed", ^first_state_at, "inactive"]] =
             current_state_rows_with_state(status)

    delayed_at = DateTime.add(observed_at, 1, :second)

    delayed_payload = %{
      payload
      | "observed_at" => DateTime.to_iso8601(delayed_at),
        "status" => "CRITICAL",
        "summary" => "late failure after disable"
    }

    assert :ok = PluginResultIngestor.ingest(delayed_payload, status)

    assert [[false, "late failure after disable", _delayed_state_at, "inactive"]] =
             current_state_rows_with_state(status)

    assert Enum.any?(history_rows(status), fn [_timestamp, _available, message, details] ->
             reported_at =
               details
               |> Jason.decode!()
               |> get_in(["_serviceradar_plugin_result", "observation_timestamp"])

             reported_at == DateTime.to_iso8601(delayed_at) and
               message == "late failure after disable"
           end)

    state =
      ServiceState
      |> Ash.Query.filter(
        agent_id == ^status.agent_id and gateway_id == ^status.gateway_id and
          partition == ^status.partition and service_type == ^status.service_type and
          service_name == ^status.service_name
      )
      |> Ash.read_one!(actor: system_actor(), domain: ServiceRadar.Observability)

    assert {:ok, [], [{:broadcast_update, ^state}]} =
             PluginState.prepare_upsert_side_effects(
               state,
               %{available: true, state: "inactive"},
               system_actor(),
               true
             )
  end

  test "bulk plugin statuses enforce assignment eligibility" do
    {payload, status, observed_at} = plugin_result_fixture(assignment?: false)

    bulk_status =
      Map.merge(status, %{
        available: true,
        message: payload,
        details: payload,
        timestamp: observed_at
      })

    assert :ok = ServiceStateRegistry.bulk_upsert_from_statuses([bulk_status])

    assert [[true, "edge plugin completed", ^observed_at, "inactive"]] =
             current_state_rows_with_state(status)
  end

  test "an older ineligible status deactivates a newer active orphan" do
    {payload, status, observed_at} = plugin_result_fixture(assignment?: false)
    newer_at = DateTime.add(observed_at, 10, :second)

    seed_service_state(status, newer_at,
      available: true,
      message: "newer orphan result",
      state: "active"
    )

    older_status =
      Map.merge(status, %{
        available: true,
        message: payload,
        details: payload,
        timestamp: observed_at
      })

    assert :ok = ServiceStateRegistry.upsert_from_status_strict(older_status)

    assert [[true, "newer orphan result", ^newer_at, "inactive"]] =
             current_state_rows_with_state(status)
  end

  test "deactivating an old package version preserves a newer eligible assignment" do
    {_payload, status, observed_at} = plugin_result_fixture(assignment?: false)
    plugin_id = "versioned-plugin-#{System.unique_integer([:positive])}"

    old_package =
      create_repair_package!(status.service_name,
        plugin_id: plugin_id,
        version: "1.0.0"
      )

    new_package =
      create_repair_package!(status.service_name,
        plugin_id: plugin_id,
        version: "2.0.0",
        create_plugin?: false
      )

    old_assignment =
      create_repair_assignment_for_package!(status, old_package, enabled: false)

    _new_assignment = create_repair_assignment_for_package!(status, new_package)

    seed_service_state(status, observed_at,
      available: true,
      message: "version two result",
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
        Jason.encode!(%{"labels" => %{"plugin_id" => plugin_id}}),
        status.agent_id,
        status.gateway_id,
        status.partition,
        status.service_type,
        status.service_name
      ]
    )

    assert :ok = ServiceStateRegistry.deactivate_for_assignment(old_assignment)

    assert [[true, "version two result", ^observed_at, "active"]] =
             current_state_rows_with_state(status)
  end

  defp system_actor, do: SystemActor.system(:plugin_result_assignment_lifecycle_test)
end
