defmodule ServiceRadar.Plugins.AddonProfileReconcilerTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Plugins.AddonProfileReconciler

  defmodule ResolverV1 do
    @moduledoc false
    def resolve(_input_defs, _opts) do
      {:ok,
       [
         %{
           name: "targets",
           entity: "devices",
           query: "in:devices hostname:ns*",
           rows: [
             %{"uid" => "sr:device:1", "agent_id" => "agent-a"},
             %{"uid" => "sr:device:2", "agent_uid" => "agent-b"},
             %{"uid" => "sr:device:3"}
           ]
         }
       ]}
    end
  end

  defmodule ResolverV2 do
    @moduledoc false
    def resolve(_input_defs, _opts) do
      {:ok,
       [
         %{
           name: "targets",
           entity: "agents",
           query: "in:agents name:agent-*",
           rows: [%{"uid" => "agent-c"}]
         }
       ]}
    end
  end

  defmodule ResolverEligibility do
    @moduledoc false
    def resolve(_input_defs, _opts) do
      {:ok,
       [
         %{
           name: "targets",
           entity: "devices",
           query: "in:devices",
           rows: [
             agent_row("device-good", "agent-good"),
             agent_row("device-manual", "agent-manual"),
             %{"uid" => "device-without-agent", "hostname" => "ns-missing-agent"},
             agent_row("device-arm", "agent-arm", %{"arch" => "arm64"}),
             agent_row("device-old", "agent-old", %{"agent_version" => "1.1.9"}),
             agent_row("device-missing-cap", "agent-missing-cap", %{"capabilities" => []}),
             agent_row("device-offline", "agent-offline", %{"control_stream_status" => "offline"})
           ]
         }
       ]}
    end

    defp agent_row(device_uid, agent_uid, overrides \\ %{}) do
      Map.merge(
        %{
          "uid" => device_uid,
          "hostname" => device_uid,
          "agent_id" => agent_uid,
          "os" => "linux",
          "arch" => "amd64",
          "agent_version" => "1.2.3",
          "capabilities" => ["endpoint-inventory"],
          "control_stream_status" => "connected"
        },
        overrides
      )
    end
  end

  defmodule ResolverDefaultQuery do
    @moduledoc false

    def resolve([%{entity: "agents", query: "in:agents"}], _opts) do
      {:ok,
       [
         %{
           name: "targets",
           entity: "agents",
           query: "in:agents",
           rows: [
             %{
               "uid" => "agent-good",
               "os" => "linux",
               "arch" => "amd64",
               "agent_version" => "1.2.3",
               "capabilities" => ["endpoint-inventory"]
             }
           ]
         }
       ]}
    end

    def resolve([%{entity: "devices", query: "in:devices"}], _opts) do
      {:ok,
       [
         %{
           name: "targets",
           entity: "devices",
           query: "in:devices",
           rows: [
             %{
               "uid" => "device-good",
               "agent_id" => "agent-good",
               "os" => "linux",
               "arch" => "amd64",
               "agent_version" => "1.2.3",
               "capabilities" => ["endpoint-inventory"]
             }
           ]
         }
       ]}
    end
  end

  defmodule MemoryStore do
    @moduledoc false
    @behaviour AddonProfileReconciler

    def start_link do
      Agent.start_link(fn -> %{assignments: %{}, manual: MapSet.new()} end, name: __MODULE__)
    end

    def stop do
      if Process.whereis(__MODULE__) do
        try do
          Agent.stop(__MODULE__)
        catch
          :exit, _ -> :ok
        end
      end

      :ok
    end

    def put_manual(addon_id, agent_uid) do
      Agent.update(__MODULE__, fn state ->
        update_in(state.manual, &MapSet.put(&1, {addon_id, agent_uid}))
      end)
    end

    @impl true
    def list_profile_assignments(profile_id, _actor) do
      rows =
        Agent.get(__MODULE__, fn state ->
          state.assignments
          |> Map.values()
          |> Enum.filter(&(&1.addon_profile_id == profile_id and &1.source == :profile))
        end)

      {:ok, rows}
    end

    @impl true
    def list_manual_assignments(addon_id, agent_uids, _actor) do
      rows =
        Agent.get(__MODULE__, fn state ->
          agent_uids
          |> Enum.filter(&MapSet.member?(state.manual, {addon_id, &1}))
          |> Enum.map(&%{agent_uid: &1, addon_id: addon_id, source: :manual, enabled: true})
        end)

      {:ok, rows}
    end

    @impl true
    def create_assignment(spec, _actor) do
      record = spec_to_record(spec)
      Agent.update(__MODULE__, &put_in(&1.assignments[record.source_key], record))
      {:ok, record}
    end

    @impl true
    def update_assignment(existing, spec, _actor) do
      record = spec_to_record(spec, existing)
      Agent.update(__MODULE__, &put_in(&1.assignments[record.source_key], record))
      {:ok, record}
    end

    @impl true
    def disable_assignment(existing, _actor) do
      disabled = %{existing | enabled: false, profile_reconcile_status: "stale"}
      Agent.update(__MODULE__, &put_in(&1.assignments[disabled.source_key], disabled))
      {:ok, disabled}
    end

    defp spec_to_record(spec, existing \\ %{}) do
      %{
        id: Map.get(existing, :id, Ecto.UUID.generate()),
        agent_uid: spec.agent_uid,
        addon_id: spec.addon_id,
        addon_package_id: spec.addon_package_id,
        source: :profile,
        source_key: spec.assignment_key,
        addon_profile_id: spec.addon_profile_id,
        enabled: spec.enabled,
        params: spec.params,
        args: spec.args,
        profile_reconcile_status: spec.profile_reconcile_status,
        profile_reconcile_error: spec.profile_reconcile_error,
        profile_last_reconciled_at: spec.profile_last_reconciled_at,
        profile_metadata: spec.profile_metadata
      }
    end
  end

  setup do
    {:ok, _pid} = MemoryStore.start_link()
    on_exit(fn -> MemoryStore.stop() end)
    :ok
  end

  test "reconcile is idempotent, skips manual overrides, and disables stale assignments" do
    profile = %{
      id: Ecto.UUID.generate(),
      name: "PowerDNS servers",
      addon_id: "powerdns",
      addon_package_id: Ecto.UUID.generate(),
      target_query: "in:devices hostname:ns*",
      params: %{"api_url" => "http://127.0.0.1:8081"},
      args: ["--collector"],
      priority: 20,
      enabled: true
    }

    MemoryStore.put_manual("powerdns", "agent-b")

    assert {:ok, first} =
             AddonProfileReconciler.reconcile(profile,
               resolver: ResolverV1,
               store: MemoryStore,
               reconciled_at: ~U[2026-06-09 17:00:00Z]
             )

    assert first.matched_rows == 3
    assert first.target_agents == 2
    assert first.skipped_without_agent == 1
    assert first.skipped_manual_overrides == 1
    assert first.desired_assignments == 1
    assert first.upserted == 1
    assert first.unchanged == 0
    assert first.disabled == 0

    assert {:ok, second} =
             AddonProfileReconciler.reconcile(profile,
               resolver: ResolverV1,
               store: MemoryStore,
               reconciled_at: ~U[2026-06-09 17:00:00Z]
             )

    assert second.upserted == 0
    assert second.unchanged == 1
    assert second.disabled == 0

    assert {:ok, third} =
             AddonProfileReconciler.reconcile(%{profile | target_query: "in:agents name:agent-*"},
               resolver: ResolverV2,
               store: MemoryStore,
               reconciled_at: ~U[2026-06-09 17:01:00Z]
             )

    assert third.target_agents == 1
    assert third.upserted == 1
    assert third.unchanged == 0
    assert third.disabled == 1
  end

  test "preview reports resolved targets and skip reasons" do
    profile = endpoint_inventory_profile()

    MemoryStore.put_manual("endpoint-inventory", "agent-manual")

    assert {:ok, preview} =
             AddonProfileReconciler.preview(profile,
               resolver: ResolverEligibility,
               store: MemoryStore
             )

    assert preview.summary.matched_rows == 7
    assert preview.summary.resolved_devices == 6
    assert preview.summary.resolved_agents == 0
    assert preview.summary.target_agents == 6
    assert preview.summary.eligible_agents == 1
    assert preview.summary.desired_assignments == 1
    assert preview.summary.skipped_without_agent == 1
    assert preview.summary.skipped_manual_overrides == 1

    assert preview.summary.skip_counts == %{
             "disconnected_control_stream" => 1,
             "incompatible_base_agent_version" => 1,
             "manual_override" => 1,
             "missing_required_capability" => 1,
             "no_enrolled_agent" => 1,
             "unsupported_platform" => 1
           }

    assert [%{agent_uid: "agent-good"}] = preview.sample_assignments
    assert [%{agent_uid: "agent-good"} | _] = preview.summary.target_samples

    skipped_reasons = Enum.map(preview.summary.skipped_targets, & &1.reason)

    assert skipped_reasons == [
             "no_enrolled_agent",
             "unsupported_platform",
             "incompatible_base_agent_version",
             "missing_required_capability",
             "disconnected_control_stream",
             "manual_override"
           ]
  end

  test "blank profile target query defaults to all agents" do
    profile = Map.put(endpoint_inventory_profile(), :target_query, " ")

    assert {:ok, result} =
             AddonProfileReconciler.reconcile(profile,
               resolver: ResolverDefaultQuery,
               store: MemoryStore,
               reconciled_at: ~U[2026-06-09 18:00:00Z]
             )

    assert result.matched_rows == 1
    assert result.desired_assignments == 1

    assert result.target_samples == [
             %{
               agent_uid: "agent-good",
               device_uid: nil,
               entity: "agents",
               row: %{
                 "agent_version" => "1.2.3",
                 "arch" => "amd64",
                 "os" => "linux",
                 "uid" => "agent-good"
               },
               row_index: 0
             }
           ]
  end

  test "reconcile preserves assignment-scoped interface seasonal baselines" do
    profile = %{
      id: Ecto.UUID.generate(),
      name: "Anomaly",
      addon_id: "anomaly",
      addon_package_id: Ecto.UUID.generate(),
      target_query: "in:agents name:agent-*",
      params: %{
        "metric_feed" => %{"sources" => ["sysmon", "snmp"]},
        "seasonal_baselines" => %{
          "sr:host-1|cpu.usage_percent" => %{"buckets" => []}
        }
      },
      args: [],
      priority: 20,
      enabled: true
    }

    assert {:ok, first} =
             AddonProfileReconciler.reconcile(profile,
               resolver: ResolverV2,
               store: MemoryStore,
               reconciled_at: ~U[2026-06-09 17:00:00Z]
             )

    assert first.upserted == 1

    {:ok, [assignment]} = MemoryStore.list_profile_assignments(profile.id, nil)

    scoped_params =
      put_in(assignment.params, ["seasonal_baselines", "sr:router-1|ifInOctets|7"], %{
        "encoding" => "compact_168_f32",
        "centers" => [],
        "scales" => [],
        "sample_counts" => []
      })

    updated_assignment = %{assignment | params: scoped_params}
    Agent.update(MemoryStore, &put_in(&1.assignments[assignment.source_key], updated_assignment))

    assert {:ok, second} =
             AddonProfileReconciler.reconcile(
               %{profile | params: Map.put(profile.params, "window_size", 300)},
               resolver: ResolverV2,
               store: MemoryStore,
               reconciled_at: ~U[2026-06-09 17:01:00Z]
             )

    assert second.upserted == 1

    {:ok, [preserved]} = MemoryStore.list_profile_assignments(profile.id, nil)
    baselines = preserved.params["seasonal_baselines"]

    assert Map.has_key?(baselines, "sr:host-1|cpu.usage_percent")
    assert Map.has_key?(baselines, "sr:router-1|ifInOctets|7")
    assert preserved.params["window_size"] == 300
  end

  test "preview reports disabled and unapproved package skip reasons" do
    disabled_profile = Map.put(endpoint_inventory_profile(), :enabled, false)

    assert {:ok, disabled_preview} =
             AddonProfileReconciler.preview(disabled_profile,
               resolver: ResolverDefaultQuery,
               store: MemoryStore
             )

    assert disabled_preview.summary.desired_assignments == 0
    assert disabled_preview.summary.skip_counts == %{"disabled_package_config" => 1}

    revoked_profile = put_in(endpoint_inventory_profile(), [:addon_package, :status], :revoked)

    assert {:ok, revoked_preview} =
             AddonProfileReconciler.preview(revoked_profile,
               resolver: ResolverDefaultQuery,
               store: MemoryStore
             )

    assert revoked_preview.summary.desired_assignments == 0
    assert revoked_preview.summary.skip_counts == %{"revoked_or_unapproved_package" => 1}
  end

  defp endpoint_inventory_profile do
    %{
      id: Ecto.UUID.generate(),
      name: "Endpoint inventory",
      addon_id: "endpoint-inventory",
      addon_package_id: Ecto.UUID.generate(),
      target_query: "in:devices",
      params: %{},
      args: [],
      priority: 10,
      enabled: true,
      addon_package: %{
        status: :approved,
        artifacts: %{"linux/amd64" => %{}},
        requires: %{
          "base_agent" => ">=1.2.0",
          "os_capabilities" => ["endpoint-inventory"]
        }
      }
    }
  end
end
