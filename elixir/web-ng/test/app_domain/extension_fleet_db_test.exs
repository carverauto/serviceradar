defmodule ServiceRadarWebNG.ExtensionFleetDbTest do
  use ExUnit.Case, async: false
  use ServiceRadarWebNG.AshTestHelpers

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias ServiceRadar.Plugins.AddonAssignment
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.AddonRollout
  alias ServiceRadar.Plugins.AddonRolloutTarget
  alias ServiceRadar.Plugins.AddonStatus
  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Plugins.AddonFleet
  alias ServiceRadarWebNG.SRQL

  @moduletag :web_ng_shared_fixture_db

  setup do
    :ok = Sandbox.checkout(Repo)
    Sandbox.mode(Repo, {:shared, self()})
    %{scope: %Scope{user: system_actor(), permissions: MapSet.new(["devices.view", "plugins.view"])}}
  end

  test "native fleet queries preserve desired state, health, timestamps and drift", %{scope: scope} do
    now = DateTime.utc_now()
    addon_id = "example-fleet-" <> Ecto.UUID.generate()
    gateway = gateway_fixture()

    package =
      AddonPackage
      |> Ash.Changeset.for_create(
        :create,
        %{
          addon_id: addon_id,
          name: "Example Fleet Add-on",
          version: "1.0.0",
          config_schema: %{"type" => "object"},
          verification_status: "verified"
        },
        actor: system_actor()
      )
      |> Ash.create!()
      |> Ash.Changeset.for_update(:approve, %{}, actor: system_actor())
      |> Ash.update!()

    for {suffix, assigned?, state, version, report_age} <- [
          {"healthy", true, "running", "1.0.0", 0},
          {"stale", true, "running", "1.0.0", 600},
          {"unhealthy", true, "unhealthy", "1.0.0", 0},
          {"unassigned", false, "running", "1.0.0", 0},
          {"drift", true, "running", "0.9.0", 0},
          {"missing", true, nil, nil, 0}
        ] do
      agent = agent_fixture(gateway, %{uid: "#{addon_id}-#{suffix}"})

      SQL.query!(
        Repo,
        "UPDATE platform.ocsf_agents SET status = 'connected', is_healthy = true, last_seen_time = $2 WHERE uid = $1",
        [agent.uid, now]
      )

      if assigned? do
        assignment =
          AddonAssignment
          |> Ash.Changeset.for_create(:create, %{agent_uid: agent.uid, addon_package_id: package.id}, actor: system_actor())
          |> Ash.create!()

        if suffix == "healthy" do
          rollout_attrs = %{
            addon_id: addon_id,
            source_type: :assignment,
            source_id: assignment.id,
            previous_package_id: package.id,
            candidate_package_id: package.id
          }

          rollout =
            AddonRollout
            |> Ash.Changeset.for_create(:create, Map.put(rollout_attrs, :state, :completed), scope: scope)
            |> Ash.create!(scope: scope)

          target_attrs =
            Map.merge(rollout_attrs, %{
              rollout_id: rollout.id,
              assignment_id: assignment.id,
              agent_uid: agent.uid,
              batch_index: 0,
              state: :succeeded
            })

          AddonRolloutTarget
          |> Ash.Changeset.for_create(:create, target_attrs, scope: scope)
          |> Ash.create!(scope: scope)
        end
      end

      if state do
        for observed_state <- if(suffix == "healthy", do: ["unhealthy", state], else: [state]) do
          AddonStatus
          |> Ash.Changeset.for_create(
            :report,
            %{
              agent_uid: agent.uid,
              addon_id: addon_id,
              state: observed_state,
              version: version,
              active: true,
              last_health_at: now,
              reported_at: DateTime.add(now, -report_age)
            },
            actor: system_actor()
          )
          |> Ash.create!()
        end
      end
    end

    other_addon_id = "other-" <> addon_id

    AddonStatus
    |> Ash.Changeset.for_create(
      :report,
      %{
        agent_uid: "#{addon_id}-healthy",
        addon_id: other_addon_id,
        state: "unhealthy",
        version: "2.0.0",
        active: false,
        reported_at: DateTime.add(now, 1)
      },
      scope: scope
    )
    |> Ash.create!(scope: scope)

    assert {:ok, %{"results" => rows}} =
             SRQL.query("in:addon_fleets addon_id:#{addon_id} sort:agent_uid:asc", %{scope: scope})

    by_suffix = Map.new(rows, fn row -> {String.replace_prefix(row["agent_uid"], addon_id <> "-", ""), row} end)
    assert Map.take(by_suffix["healthy"], ~w(category package_status rollout_state update_policy)) == %{
             "category" => "healthy",
             "package_status" => "approved",
             "rollout_state" => "completed",
             "update_policy" => "manual_pin"
           }
    assert by_suffix["healthy"]["assigned_version"] == "1.0.0"
    assert by_suffix["healthy"]["observed_state"] == "running"
    assert by_suffix["healthy"]["observed_version"] == "1.0.0"
    assert by_suffix["healthy"]["last_health_at"] == DateTime.to_iso8601(now)
    assert by_suffix["stale"]["stale"] == true
    assert by_suffix["stale"]["category"] == "unavailable"
    assert by_suffix["unhealthy"]["category"] == "action_required"
    assert by_suffix["unassigned"]["assigned"] == false
    assert by_suffix["unassigned"]["rollout_state"] == nil
    assert by_suffix["unassigned"]["update_policy"] == nil
    assert by_suffix["drift"]["version_drift"] == true
    assert by_suffix["drift"]["observed_version"] == "0.9.0"
    assert by_suffix["missing"]["observed_state"] == nil
    assert by_suffix["missing"]["reported_at"] == nil
    assert by_suffix["missing"]["category"] == "unavailable"

    overview_rows =
      [scope: scope, now: now]
      |> AddonFleet.overview()
      |> Map.fetch!(:rows)
      |> Enum.filter(&(&1.agent_uid == "#{addon_id}-healthy"))
      |> Map.new(&{&1.addon_id, &1})

    assert Map.take(overview_rows[addon_id], [:assigned?, :running_state, :running_version]) == %{
             assigned?: true,
             running_state: "running",
             running_version: "1.0.0"
           }

    assert Map.take(overview_rows[other_addon_id], [:assigned?, :running_state, :running_version]) == %{
             assigned?: false,
             running_state: "unhealthy",
             running_version: "2.0.0"
           }

    assert {:error, :forbidden} =
             SRQL.query("in:addon_fleet addon_id:#{addon_id}", %{
               scope: %Scope{permissions: MapSet.new(["plugins.view"])}
             })

    assert {:ok, %{"results" => [%{"state" => "unhealthy"}]}} =
             SRQL.query("in:addon_status addon_id:#{addon_id} state:unhealthy", %{scope: scope})
  end

  test "WASM queries join exact partitions, redact assignments, and page the scoped read", %{scope: scope} do
    plugin_id = "example-wasm-" <> Ecto.UUID.generate()
    package_id = Ecto.UUID.generate()
    assignment_id = Ecto.UUID.generate()
    now = DateTime.utc_now()
    SQL.query!(Repo, "INSERT INTO platform.plugins (plugin_id, name) VALUES ($1, 'Example WASM')", [plugin_id])

    SQL.query!(
      Repo,
      "INSERT INTO platform.plugin_packages (id, plugin_id, name, version, entrypoint, outputs, status) VALUES ($1::text::uuid, $2, 'Example WASM', '1.0.0', 'run_check', 'serviceradar.plugin_result.v1', 'approved')",
      [package_id, plugin_id]
    )

    # Restore a persisted assignment fixture without fabricating a live control
    # session. The read under test still uses the real scoped Ash resources.
    SQL.query!(
      Repo,
      "INSERT INTO platform.plugin_assignments (id, agent_uid, partition_id, plugin_id, plugin_package_id, enabled, params) VALUES ($1::text::uuid, 'agent-example', 'partition-a', $2, $3::text::uuid, true, $4)",
      [assignment_id, plugin_id, package_id, %{"token" => "synthetic-secret"}]
    )

    for partition <- ["partition-a", "partition-b"] do
      ServiceRadar.Observability.ServiceState
      |> Ash.Changeset.for_create(
        :upsert,
        %{
          agent_id: "agent-example",
          gateway_id: "gateway-example",
          partition: partition,
          service_name: "Example WASM",
          service_type: "plugin",
          available: true,
          last_observed_at: now,
          details: Jason.encode!(%{"plugin_id" => plugin_id, "params" => %{"token" => "synthetic-secret"}})
        },
        actor: system_actor()
      )
      |> Ash.create!()
    end

    query = "in:plugin_fleets plugin_id:#{plugin_id} sort:partition_id:asc limit:1"

    assert {:ok, %{"results" => [assigned], "pagination" => %{"next_cursor" => cursor}}} =
             SRQL.query(query, %{scope: scope})

    assert assigned["partition_id"] == "partition-a"
    assert assigned["assigned"] == true
    assert assigned["category"] == "healthy"
    assert assigned["assigned_version"] == "1.0.0"
    assert assigned["observed_version"] == nil
    refute Jason.encode!(assigned) =~ "synthetic-secret"
    assert is_binary(cursor)

    assert {:ok, %{"results" => [%{"partition_id" => "partition-b", "assigned" => false}]}} =
             SRQL.query(query, %{scope: scope, cursor: cursor})

    assert {:ok, %{payload: payload}} = SRQL.query_arrow(query, %{scope: scope})
    assert byte_size(payload) > 0
    assert {:error, :forbidden} = SRQL.query(query, %{scope: %Scope{permissions: MapSet.new(["devices.view"])}})
  end
end
