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

    delayed_at = DateTime.shift(observed_at, second: 1)

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
    newer_at = DateTime.shift(observed_at, second: 10)

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

  test "reconcile keeps a plugin state active only while its package still submits results" do
    for {capabilities, expected_state} <- [
          {["submit_result", "action-only:v1"], "inactive"},
          {["submit_result", "action-only:v1", "action-result-ingest:v1"], "active"}
        ] do
      {_payload, status, observed_at} = plugin_result_fixture(assignment?: false)
      package = create_repair_package!(status.service_name, capabilities: capabilities)
      _assignment = create_repair_assignment_for_package!(status, package)

      seed_service_state(status, observed_at,
        available: false,
        message: "result from before the package became action-only",
        state: "active"
      )

      assert {:ok, _count} = ServiceStateRegistry.reconcile_plugin_assignments()

      assert {^capabilities, [[false, _message, ^observed_at, ^expected_state]]} =
               {capabilities, current_state_rows_with_state(status)}
    end
  end

  test "coexisting assignments of one plugin keep separate state and history" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [])

    {payload, status, observed_at} = plugin_result_fixture(assignment?: false)
    create_agent(status.agent_id, status.gateway_id)
    package = create_repair_package!(status.service_name)
    suffix = System.unique_integer([:positive])

    primary =
      create_repair_assignment_for_package!(status, package,
        source: :policy,
        source_key: "coexist-primary-#{suffix}",
        policy_id: "network-credential-rule:rule-primary-#{suffix}:inventory"
      )

    secondary =
      create_repair_assignment_for_package!(status, package,
        source: :policy,
        source_key: "coexist-secondary-#{suffix}",
        policy_id: "network-credential-rule:rule-secondary-#{suffix}:inventory"
      )

    force_assignment_seniority!(primary, secondary, observed_at)

    secondary_name = "#{status.service_name}##{secondary.id}"
    secondary_status = %{status | service_name: secondary_name}

    assert :ok = ServiceStateRegistry.upsert_for_assignment(primary)
    assert :ok = ServiceStateRegistry.upsert_for_assignment(secondary)

    assert state_names(status) == MapSet.new([status.service_name, secondary_name])

    # The agent reports both instances under the bare package name; core
    # separates them from the host-stamped provenance.
    assert :ok =
             PluginResultIngestor.ingest(
               payload,
               provenance_status(status, primary, package)
             )

    secondary_at = DateTime.shift(observed_at, second: 1)

    secondary_payload = %{
      payload
      | "observed_at" => DateTime.to_iso8601(secondary_at),
        "status" => "CRITICAL",
        "summary" => "secondary instance failing"
    }

    assert :ok =
             PluginResultIngestor.ingest(
               secondary_payload,
               provenance_status(status, secondary, package)
             )

    assert [[true, "edge plugin completed", _primary_at, "active"]] =
             current_state_rows_with_state(status)

    assert [[false, "secondary instance failing", _secondary_state_at, "active"]] =
             current_state_rows_with_state(secondary_status)

    assert Enum.any?(history_rows(status), fn [_t, _a, message, _d] ->
             message == "edge plugin completed"
           end)

    assert Enum.any?(history_rows(secondary_status), fn [_t, _a, message, _d] ->
             message == "secondary instance failing"
           end)

    refute Enum.any?(history_rows(status), fn [_t, _a, message, _d] ->
             message == "secondary instance failing"
           end)

    disabled_secondary =
      secondary
      |> Ash.Changeset.for_update(:update, %{enabled: false}, actor: system_actor())
      |> Ash.update!(domain: ServiceRadar.Plugins)

    assert :ok = ServiceStateRegistry.deactivate_for_assignment(disabled_secondary)

    assert [[true, "edge plugin completed", _primary_at, "active"]] =
             current_state_rows_with_state(status)

    assert [[false, "secondary instance failing", _secondary_state_at, "inactive"]] =
             current_state_rows_with_state(secondary_status)

    delayed_at = DateTime.shift(observed_at, second: 2)

    delayed_payload = %{
      secondary_payload
      | "observed_at" => DateTime.to_iso8601(delayed_at),
        "summary" => "secondary late result"
    }

    assert :ok =
             PluginResultIngestor.ingest(
               delayed_payload,
               provenance_status(status, secondary, package)
             )

    assert [[false, "secondary late result", _delayed_at, "inactive"]] =
             current_state_rows_with_state(secondary_status)

    assert [[true, "edge plugin completed", _primary_at, "active"]] =
             current_state_rows_with_state(status)
  end

  test "replacement state survives predecessor evidence across gateways and delayed results" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [])

    for snapshot_state <- ["active", "inactive"], change_gateway? <- [false, true] do
      {payload, status, _observed_at} = plugin_result_fixture(assignment?: false)
      create_agent(status.agent_id, status.gateway_id)
      package = create_repair_package!(status.service_name)
      original = create_repair_assignment_for_package!(status, package)

      assert :ok =
               PluginResultIngestor.ingest(payload, provenance_status(status, original, package))

      disabled =
        original
        |> Ash.Changeset.for_update(:update, %{enabled: false}, actor: system_actor())
        |> Ash.update!(domain: ServiceRadar.Plugins)

      if snapshot_state == "inactive" do
        assert :ok = ServiceStateRegistry.deactivate_for_assignment(disabled)
      end

      assert [[true, "edge plugin completed", _at, ^snapshot_state]] =
               current_state_rows_with_state(status)

      replacement_status =
        if change_gateway? do
          gateway_id = status.gateway_id <> "-replacement"

          ServiceRadar.Infrastructure.Gateway
          |> Ash.Changeset.for_create(:register, %{id: gateway_id}, actor: system_actor())
          |> Ash.create!(domain: ServiceRadar.Infrastructure)

          {:ok, agent} =
            ServiceRadar.Infrastructure.Agent.get_by_uid(status.agent_id, actor: system_actor())

          agent
          |> Ash.Changeset.for_update(:gateway_sync, %{gateway_id: gateway_id}, actor: system_actor())
          |> Ash.update!(domain: ServiceRadar.Infrastructure)

          %{status | gateway_id: gateway_id}
        else
          status
        end

      replacement = create_repair_assignment_for_package!(replacement_status, package)
      assert :ok = ServiceStateRegistry.upsert_for_assignment(replacement)

      assert [[false, "plugin assignment pending result", _at, "active"]] =
               current_state_rows_with_state(replacement_status)

      assert Jason.decode!(current_state_details(replacement_status))["assignment_id"] == replacement.id

      if change_gateway? do
        assert [[true, "edge plugin completed", _at, "inactive"]] =
                 current_state_rows_with_state(status)
      end

      for phase <- ["pending", "reported"] do
        observed_at =
          DateTime.utc_now()
          |> DateTime.shift(second: if(phase == "pending", do: 2, else: 4))
          |> DateTime.truncate(:microsecond)

        if phase == "reported" do
          replacement_payload =
            Map.merge(payload, %{
              "observed_at" => DateTime.to_iso8601(observed_at),
              "summary" => "replacement result"
            })

          assert :ok =
                   PluginResultIngestor.ingest(
                     replacement_payload,
                     provenance_status(replacement_status, replacement, package)
                   )

          assert [[true, "replacement result", _at, "active"]] =
                   current_state_rows_with_state(replacement_status)
        end

        before_late_result = current_state_rows_with_state(replacement_status)
        late_message = "disabled predecessor after " <> phase

        late_payload =
          Map.merge(payload, %{
            "observed_at" => DateTime.to_iso8601(DateTime.shift(observed_at, second: 1)),
            "summary" => late_message,
            "status" => "CRITICAL"
          })

        assert :ok =
                 PluginResultIngestor.ingest(late_payload, provenance_status(status, original, package))

        assert current_state_rows_with_state(replacement_status) == before_late_result

        assert Enum.any?(history_rows(status), fn [_at, available, message, _details] ->
                 available == false and message == late_message
               end)
      end
    end
  end

  test "a sole assignment keeps the package service name" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [])

    {payload, status, _observed_at} = plugin_result_fixture(assignment?: false)
    create_agent(status.agent_id, status.gateway_id)
    package = create_repair_package!(status.service_name)
    assignment = create_repair_assignment_for_package!(status, package)

    assert :ok = ServiceStateRegistry.upsert_for_assignment(assignment)

    assert :ok =
             PluginResultIngestor.ingest(
               payload,
               provenance_status(status, assignment, package)
             )

    assert state_names(status) == MapSet.new([status.service_name])

    assert [[true, "edge plugin completed", _at, "active"]] =
             current_state_rows_with_state(status)
  end

  defp provenance_status(status, assignment, package) do
    Map.put(status, :plugin_provenance, %{
      assignment_id: to_string(assignment.id),
      plugin_id: package.plugin_id,
      plugin_package_id: to_string(package.id),
      plugin_version: package.version
    })
  end

  defp state_names(status) do
    MapSet.new(
      Repo.query!(
        """
        SELECT DISTINCT service_name
        FROM platform.service_state
        WHERE agent_id = $1 AND service_type = 'plugin'
        """,
        [status.agent_id]
      ).rows,
      fn [name] -> name end
    )
  end

  # Seniority is inserted_at order; pin it so the test does not depend on
  # the two creates landing in different microseconds.
  defp force_assignment_seniority!(primary, secondary, observed_at) do
    Repo.query!(
      "UPDATE platform.plugin_assignments SET inserted_at = $1 WHERE id = ($2::text)::uuid",
      [DateTime.shift(observed_at, minute: -2), to_string(primary.id)]
    )

    Repo.query!(
      "UPDATE platform.plugin_assignments SET inserted_at = $1 WHERE id = ($2::text)::uuid",
      [DateTime.shift(observed_at, minute: -1), to_string(secondary.id)]
    )
  end

  defp system_actor, do: SystemActor.system(:plugin_result_assignment_lifecycle_test)
end
