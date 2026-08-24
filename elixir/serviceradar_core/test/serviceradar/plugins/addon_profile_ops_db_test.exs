defmodule ServiceRadar.Plugins.AddonProfileOpsDbTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.AddonProfile
  alias ServiceRadar.Plugins.AddonProfileOps

  @moduletag :integration

  defmodule Resolver do
    @moduledoc false

    def resolve([%{entity: entity}], opts) when entity in ["devices", "agents"] do
      agent_uid = Keyword.fetch!(opts, :test_agent_uid)

      {:ok,
       [
         %{
           name: "targets",
           entity: entity,
           query: "in:#{entity}",
           rows: [
             %{
               "uid" => "device-without-netprobe-capability",
               "type_id" => 1,
               "agent_id" => agent_uid,
               "os" => %{"name" => "Linux"},
               "metadata" => %{}
             }
           ]
         }
       ]}
    end
  end

  defmodule Store do
    @moduledoc false

    def list_manual_assignments(_addon_id, _agent_uids, _actor), do: {:ok, []}
    def list_profile_assignments(_profile_id, _actor), do: {:ok, []}
    def create_assignment(_spec, _actor), do: {:error, :unexpected_assignment}
    def update_assignment(_existing, _spec, _actor), do: {:error, :unexpected_assignment}
    def disable_assignment(_assignment, _actor), do: {:error, :unexpected_assignment}
  end

  defmodule FailingResolver do
    @moduledoc false

    def resolve(_inputs, _opts), do: {:error, ["forced resolver failure"]}
  end

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  test "preview and reconcile load the selected package before eligibility checks" do
    actor = SystemActor.system(:addon_profile_ops_db_test)
    unique = System.unique_integer([:positive])
    agent_uid = "agent-without-netprobe-capability-#{unique}"

    {:ok, _agent} =
      Agent
      |> Ash.Changeset.for_create(
        :register_connected,
        %{
          uid: agent_uid,
          name: "Agent without netprobe capability",
          version: "1.4.8",
          capabilities: [],
          host: "127.0.0.1",
          port: 50_051,
          metadata: %{"os" => "linux", "arch" => "amd64"}
        },
        actor: actor
      )
      |> Ash.create()

    {:ok, package} =
      AddonPackage
      |> Ash.Changeset.for_create(
        :create,
        %{
          addon_id: "netprobe-ops-test-#{unique}",
          version: "0.0.#{unique}",
          name: "Netprobe Ops Test",
          artifacts: %{"linux/amd64" => %{}},
          requires: %{
            "base_agent" => ">=1.2.0",
            "platforms" => ["linux"],
            "agent_capabilities" => ["host-network-visibility"],
            "os_capabilities" => ["CAP_BPF"]
          },
          config_schema: %{"type" => "object"}
        },
        actor: actor
      )
      |> Ash.create()

    {:ok, package} =
      package
      |> Ash.Changeset.for_update(
        :approve,
        %{
          approved_capabilities: ["host-network-visibility"],
          approved_by: "system:addon_profile_ops_db_test"
        },
        actor: actor
      )
      |> Ash.update()

    {:ok, profile} =
      AddonProfile
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Netprobe eligibility test #{unique}",
          addon_package_id: package.id,
          target_query: "in:agents",
          enabled: true
        },
        actor: actor
      )
      |> Ash.create()

    opts = [actor: actor, resolver: Resolver, store: Store, test_agent_uid: agent_uid]

    assert {:ok, preview} = AddonProfileOps.preview_by_id(profile.id, opts)
    assert preview.summary.desired_assignments == 0
    assert preview.summary.skip_counts == %{"missing_required_capability" => 1}

    assert {:ok, result} = AddonProfileOps.reconcile_by_id(profile.id, opts)
    assert result.desired_assignments == 0
    assert result.skip_counts == %{"missing_required_capability" => 1}
    assert result.upserted == 0

    {:ok, staged_package} =
      package
      |> Ash.Changeset.for_update(:reimport, %{}, actor: actor)
      |> Ash.update()

    assert staged_package.status == :staged

    assert {:error, ["forced resolver failure"]} =
             AddonProfileOps.reconcile_by_id(profile.id,
               actor: actor,
               resolver: FailingResolver
             )

    assert {:ok, reconciled_profile} = AddonProfile.get_by_id(profile.id, actor: actor)
    assert reconciled_profile.last_reconcile_summary["status"] == "failed"
    assert reconciled_profile.last_reconcile_summary["last_error"] == "forced resolver failure"
    assert %DateTime{} = reconciled_profile.last_reconciled_at
  end
end
