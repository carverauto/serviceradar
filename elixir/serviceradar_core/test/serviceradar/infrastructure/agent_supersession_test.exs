defmodule ServiceRadar.Infrastructure.AgentSupersessionTest do
  @moduledoc """
  A host that re-enrolls under a different agent uid supersedes its previous identity
  (#4456): the old row leaves `in:agents` and add-on rollout targeting, stays queryable
  for history, and every decision about it is recorded.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.AgentGatewaySync
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Infrastructure.AgentSupersession
  alias ServiceRadar.Inventory.IdentityDecision
  alias ServiceRadar.Observability.SRQLRunner
  alias ServiceRadar.Plugins.AddonAssignment
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.AddonProfile
  alias ServiceRadar.Plugins.AddonRolloutCoordinator
  alias ServiceRadar.Plugins.AddonRolloutTarget
  alias ServiceRadar.Repo

  require Ash.Query

  @moduletag :integration

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    uniq = System.unique_integer([:positive, :monotonic])
    {:ok, uniq: uniq, actor: SystemActor.system(:agent_supersession_test)}
  end

  describe "re-enrollment under a new agent uid" do
    test "supersedes the previous identity and drops it from in:agents and rollout targets",
         %{uniq: uniq, actor: actor} do
      %{old: old_uid, new: new_uid, device: device_uid} = reenroll!(uniq, actor, old_state: :gone)

      old = agent!(old_uid, actor)
      new = agent!(new_uid, actor)

      assert old.status == :superseded
      assert old.superseded_by == new_uid
      assert %DateTime{} = old.superseded_at
      assert old.device_uid == device_uid
      assert new.status == :connected

      assert decision?(device_uid, "reenrolled_under_new_uid", old_uid, actor)

      # in:agents leaves the superseded identity out; it stays queryable for history.
      assert srql_uids("in:agents uid:\"#{old_uid}\"") == []
      assert srql_uids("in:agents uid:\"#{new_uid}\"") == [new_uid]
      assert srql_uids("in:agents uid:\"#{old_uid}\" include_deleted:true") == [old_uid]
      assert srql_uids("in:agents status:superseded superseded_by:\"#{new_uid}\"") == [old_uid]

      # A profile whose assignments still name the old identity does not target it.
      %{profile: profile, candidate: candidate} =
        profile_with_assignments!(uniq, [old_uid, new_uid], actor)

      assert {:ok, rollout} =
               AddonRolloutCoordinator.start(profile, candidate, actor: actor, trigger: :manual)

      assert rollout_target_uids(rollout.id, actor) == [new_uid]
    end

    test "keeps an identity on the same device that is still reporting, and says so",
         %{uniq: uniq, actor: actor} do
      %{old: old_uid, new: new_uid, device: device_uid} = reenroll!(uniq, actor, old_state: :live)

      assert agent!(old_uid, actor).status == :connected
      assert agent!(new_uid, actor).status == :connected
      assert decision?(device_uid, "live_identity_kept", old_uid, actor)
      assert srql_uids("in:agents uid:\"#{old_uid}\"") == [old_uid]
    end

    test "does not supersede an agent on another device that shares the address",
         %{uniq: uniq, actor: actor} do
      shared_ip = test_ip(uniq)
      other_uid = "agent-nat-a-#{uniq}"
      agent_uid = "agent-nat-b-#{uniq}"

      enroll!(other_uid, shared_ip, "nat-a-#{uniq}", mac(uniq, 1))
      went_quiet!(other_uid)
      enroll!(agent_uid, shared_ip, "nat-b-#{uniq}", mac(uniq, 2))

      other = agent!(other_uid, actor)
      refute other.device_uid == agent!(agent_uid, actor).device_uid
      refute other.status == :superseded
    end
  end

  describe "a superseded identity that reports in again" do
    test "is revived explicitly and the revival is recorded", %{uniq: uniq, actor: actor} do
      %{old: old_uid, new: new_uid, device: device_uid} = reenroll!(uniq, actor, old_state: :gone)
      assert agent!(old_uid, actor).status == :superseded

      # The generic upsert refuses to bring the row back behind the decision log's back.
      assert {:error, _} =
               Agent
               |> Ash.Changeset.for_create(:register_connected, %{uid: old_uid})
               |> Ash.create(actor: actor)

      assert agent!(old_uid, actor).status == :superseded

      assert :ok = AgentGatewaySync.heartbeat_agent(old_uid, %{})

      revived = agent!(old_uid, actor)
      assert revived.status == :connected
      assert is_nil(revived.superseded_by)
      assert is_nil(revived.superseded_at)
      assert decision?(device_uid, "superseded_agent_reconnected", old_uid, actor)
      assert srql_uids("in:agents uid:\"#{old_uid}\"") == [old_uid]
      assert agent!(new_uid, actor).status == :connected
    end
  end

  describe "sweep/1" do
    test "supersedes an identity that went quiet after its replacement enrolled, once",
         %{uniq: uniq, actor: actor} do
      # The replacement enrolled while the old identity still looked live, so it was kept.
      %{old: old_uid, new: new_uid, device: device_uid} = reenroll!(uniq, actor, old_state: :live)
      assert agent!(old_uid, actor).status == :connected

      went_quiet!(old_uid)

      assert {:ok, %{superseded: superseded}} = AgentSupersession.sweep(actor: actor)
      assert superseded >= 1

      old = agent!(old_uid, actor)
      assert old.status == :superseded
      assert old.superseded_by == new_uid
      assert agent!(new_uid, actor).status == :connected
      assert decision?(device_uid, "older_identity_on_device", old_uid, actor)

      assert {:ok, %{superseded: 0}} = AgentSupersession.sweep(actor: actor)
    end

    test "leaves two identities on one device alone while both report",
         %{uniq: uniq, actor: actor} do
      %{old: old_uid, new: new_uid} = reenroll!(uniq, actor, old_state: :live)

      assert {:ok, _} = AgentSupersession.sweep(actor: actor)

      assert agent!(old_uid, actor).status == :connected
      assert agent!(new_uid, actor).status == :connected
    end
  end

  # Enrolls `old`, then enrolls `new` on the same host (the host MAC makes it the same
  # device). `old_state: :gone` retires the old identity first, the way the stale-agent
  # pruner leaves a host that stopped reporting; `:live` leaves it reporting.
  defp reenroll!(uniq, actor, old_state: old_state) do
    ip = test_ip(uniq)
    old_uid = "agent-old-#{uniq}"
    new_uid = "agent-new-#{uniq}"
    host_mac = mac(uniq, 0)

    device_uid = enroll!(old_uid, ip, "host-#{uniq}", host_mac)

    if old_state == :gone do
      {:ok, _} =
        old_uid
        |> agent!(actor)
        |> Ash.Changeset.for_update(:mark_unavailable, %{})
        |> Ash.update(actor: actor)

      went_quiet!(old_uid)
    end

    assert ^device_uid = enroll!(new_uid, ip, "host-#{uniq}", host_mac)
    %{old: old_uid, new: new_uid, device: device_uid}
  end

  defp enroll!(agent_uid, ip, hostname, host_mac) do
    :ok =
      AgentGatewaySync.upsert_agent(agent_uid, %{
        host: ip,
        version: "1.4.23",
        capabilities: ["sysmon"],
        metadata: %{"os" => "linux", "arch" => "amd64"}
      })

    {:ok, device_uid} =
      AgentGatewaySync.ensure_device_for_agent(agent_uid, %{
        hostname: hostname,
        source_ip: ip,
        partition: "default",
        capabilities: ["sysmon"],
        host_macs: [host_mac]
      })

    device_uid
  end

  # No heartbeat for a day: past the StateMonitor's agent timeout.
  defp went_quiet!(agent_uid) do
    Repo.query!(
      "UPDATE platform.ocsf_agents SET last_seen_time = $1 WHERE uid = $2",
      [DateTime.add(DateTime.utc_now(), -86_400, :second), agent_uid]
    )
  end

  defp agent!(uid, actor) do
    {:ok, agent} = Agent.get_by_uid(uid, actor: actor)
    agent
  end

  defp decision?(device_uid, reason, agent_uid, actor) do
    device_uid
    |> IdentityDecision.for_device!(actor: actor)
    |> Enum.any?(
      &(&1.decision_kind == :agent_supersession and &1.reason == reason and
          &1.subject == agent_uid)
    )
  end

  defp srql_uids(query) do
    {:ok, rows} = SRQLRunner.query(query)
    Enum.map(rows, &(Map.get(&1, "uid") || Map.get(&1, :uid)))
  end

  defp profile_with_assignments!(uniq, agent_uids, actor) do
    addon_id = "supersession-addon-#{uniq}"
    current = approved_package!(addon_id, "1.0.0", actor)
    candidate = approved_package!(addon_id, "1.1.0", actor)

    {:ok, profile} =
      AddonProfile
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Supersession profile #{uniq}",
          addon_package_id: current.id,
          target_query: "in:agents"
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    for uid <- agent_uids do
      {:ok, _assignment} =
        AddonAssignment
        |> Ash.Changeset.for_create(
          :create,
          %{
            agent_uid: uid,
            addon_package_id: current.id,
            source: :profile,
            source_key: "#{profile.id}:#{uid}",
            addon_profile_id: profile.id
          },
          actor: actor
        )
        |> Ash.create(actor: actor)
    end

    %{profile: profile, candidate: candidate}
  end

  defp approved_package!(addon_id, version, actor) do
    {:ok, package} =
      AddonPackage
      |> Ash.Changeset.for_create(
        :create,
        %{
          addon_id: addon_id,
          version: version,
          name: "Supersession package #{version}",
          source_type: :first_party,
          source_oci_ref: "registry.example/#{addon_id}:#{version}",
          source_oci_digest: "sha256:#{version}",
          verification_status: "verified",
          artifacts: %{
            "linux/amd64" => %{
              "object_key" => "addons/#{addon_id}/#{version}",
              "sha256" => "artifact-#{version}"
            }
          },
          requires: %{"platforms" => ["linux"]},
          config_schema: %{"type" => "object"}
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, package} =
      package
      |> Ash.Changeset.for_update(
        :approve,
        %{approved_capabilities: [], approved_by: "system:agent_supersession_test"},
        actor: actor
      )
      |> Ash.update(actor: actor)

    package
  end

  defp rollout_target_uids(rollout_id, actor) do
    AddonRolloutTarget
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(rollout_id == ^rollout_id)
    |> Ash.read!(actor: actor)
    |> Enum.map(& &1.agent_uid)
    |> Enum.sort()
  end

  # 198.18.0.0/15 (benchmarking range), unique per test run.
  defp test_ip(uniq) do
    n = rem(uniq, 512 * 250)
    net = div(n, 250)
    "198.#{18 + div(net, 256)}.#{rem(net, 256)}.#{rem(n, 250) + 1}"
  end

  # 00:00:5e:00:53:00/24 is the documentation MAC range; `slot` separates hosts in a test.
  defp mac(uniq, slot) do
    last = rem(uniq * 3 + slot, 256)
    "00:00:5e:00:53:" <> String.pad_leading(Integer.to_string(last, 16), 2, "0")
  end
end
