defmodule ServiceRadar.Infrastructure.AgentSupersessionTest do
  @moduledoc """
  A host that re-enrolls under a different agent uid supersedes its previous identity
  (#4456): the old row leaves `in:agents` and add-on rollout targeting, stays queryable
  for history, and every decision about it is recorded.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.Source, as: CameraSource
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Edge.AgentGatewaySync
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Infrastructure.AgentSupersession
  alias ServiceRadar.Infrastructure.StateMonitor
  alias ServiceRadar.Inventory.IdentityDecision
  alias ServiceRadar.NetworkDiscovery.MapperJob
  alias ServiceRadar.Observability.SRQLRunner
  alias ServiceRadar.Plugins.AddonAssignment
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.AddonProfile
  alias ServiceRadar.Plugins.AddonRolloutCoordinator
  alias ServiceRadar.Plugins.AddonRolloutTarget
  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.TestSupport.CredentialIntegrationFixtures

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

    test "transfers sweep groups and mapper jobs when superseding a quiet identity",
         %{uniq: uniq, actor: actor} do
      %{old: old_uid, new: new_uid} = reenroll!(uniq, actor, old_state: :live)

      sweep_group = create_sweep_group!(uniq, old_uid, actor)
      mapper_job = create_mapper_job!(uniq, old_uid, actor)

      went_quiet!(old_uid)

      assert {:ok, %{superseded: superseded}} = AgentSupersession.sweep(actor: actor)
      assert superseded >= 1

      assert agent!(old_uid, actor).status == :superseded
      assert agent!(old_uid, actor).superseded_by == new_uid
      assert Ash.get!(SweepGroup, sweep_group.id, actor: actor).agent_ids == [new_uid]
      assert Ash.get!(MapperJob, mapper_job.id, actor: actor).agent_id == new_uid
    end

    test "reconciles lingering assignments left on an already-superseded identity",
         %{uniq: uniq, actor: actor} do
      %{old: old_uid, new: new_uid, device: device_uid} = reenroll!(uniq, actor, old_state: :live)

      sweep_group = create_sweep_group!(uniq, old_uid, actor)
      mapper_job = create_mapper_job!(uniq, old_uid, actor)
      credential_rule = create_agent_credential_rule!(uniq, old_uid, actor)
      enabled_package = create_approved_plugin_package!(uniq, actor)
      disabled_package = create_approved_plugin_package!("#{uniq}-disabled", actor)
      enabled_assignment_id = insert_manual_plugin_assignment!(old_uid, enabled_package, true)
      disabled_assignment_id = insert_manual_plugin_assignment!(old_uid, disabled_package, false)
      camera_source = create_camera_source!(uniq, device_uid, old_uid, actor)

      # Simulate an agent that was marked superseded before assignment handoff ran.
      {:ok, _} =
        old_uid
        |> agent!(actor)
        |> Ash.Changeset.for_update(:supersede, %{superseded_by: new_uid})
        |> Ash.update(actor: actor)

      assert Ash.get!(SweepGroup, sweep_group.id, actor: actor).agent_ids == [old_uid]
      assert Ash.get!(MapperJob, mapper_job.id, actor: actor).agent_id == old_uid

      assert Ash.get!(NetworkCredentialRule, credential_rule.id, actor: actor).scope_value ==
               old_uid

      assert Ash.get!(PluginAssignment, enabled_assignment_id, actor: actor).agent_uid == old_uid
      assert Ash.get!(PluginAssignment, disabled_assignment_id, actor: actor).agent_uid == old_uid
      assert Ash.get!(CameraSource, camera_source.id, actor: actor).assigned_agent_id == old_uid

      assert {:ok, _} = AgentSupersession.sweep(actor: actor)

      assert Ash.get!(SweepGroup, sweep_group.id, actor: actor).agent_ids == [new_uid]
      assert Ash.get!(MapperJob, mapper_job.id, actor: actor).agent_id == new_uid

      assert Ash.get!(NetworkCredentialRule, credential_rule.id, actor: actor).scope_value ==
               new_uid

      assert Ash.get!(PluginAssignment, enabled_assignment_id, actor: actor).agent_uid == new_uid
      assert Ash.get!(PluginAssignment, disabled_assignment_id, actor: actor).agent_uid == old_uid
      assert Ash.get!(CameraSource, camera_source.id, actor: actor).assigned_agent_id == new_uid
    end

    test "reconciles lingering assignments across a multi-hop supersession chain",
         %{uniq: uniq, actor: actor} do
      ip = test_ip(uniq)
      host_mac = mac(uniq, 0)
      old_uid = "agent-chain-a-#{uniq}"
      mid_uid = "agent-chain-b-#{uniq}"
      new_uid = "agent-chain-c-#{uniq}"

      device_uid = enroll!(old_uid, ip, "chain-#{uniq}", host_mac)
      assert ^device_uid = enroll!(mid_uid, ip, "chain-#{uniq}", host_mac)
      assert ^device_uid = enroll!(new_uid, ip, "chain-#{uniq}", host_mac)

      sweep_group = create_sweep_group!(uniq, old_uid, actor)
      mapper_job = create_mapper_job!(uniq, old_uid, actor)

      {:ok, _} =
        old_uid
        |> agent!(actor)
        |> Ash.Changeset.for_update(:supersede, %{superseded_by: mid_uid})
        |> Ash.update(actor: actor)

      {:ok, _} =
        mid_uid
        |> agent!(actor)
        |> Ash.Changeset.for_update(:supersede, %{superseded_by: new_uid})
        |> Ash.update(actor: actor)

      assert {:ok, _} = AgentSupersession.sweep(actor: actor)

      assert Ash.get!(SweepGroup, sweep_group.id, actor: actor).agent_ids == [new_uid]
      assert Ash.get!(MapperJob, mapper_job.id, actor: actor).agent_id == new_uid
    end
  end

  describe "StateMonitor.check_agents/1" do
    test "supersedes a timed-out identity and transfers its assignments when a live replacement exists",
         %{uniq: uniq, actor: actor} do
      %{old: old_uid, new: new_uid, device: device_uid} = reenroll!(uniq, actor, old_state: :live)

      sweep_group = create_sweep_group!(uniq, old_uid, actor)
      mapper_job = create_mapper_job!(uniq, old_uid, actor)
      credential_rule = create_agent_credential_rule!(uniq, old_uid, actor)
      plugin_package = create_approved_plugin_package!(uniq, actor)
      enabled_assignment_id = insert_manual_plugin_assignment!(old_uid, plugin_package, true)
      camera_source = create_camera_source!(uniq, device_uid, old_uid, actor)

      went_quiet!(old_uid)

      assert StateMonitor.check_agents(actor: actor) >= 1

      old = agent!(old_uid, actor)
      assert old.status == :superseded
      assert old.superseded_by == new_uid
      assert %DateTime{} = old.superseded_at
      assert agent!(new_uid, actor).status == :connected
      assert decision?(device_uid, "older_identity_on_device", old_uid, actor)

      assert Ash.get!(SweepGroup, sweep_group.id, actor: actor).agent_ids == [new_uid]
      assert Ash.get!(MapperJob, mapper_job.id, actor: actor).agent_id == new_uid

      assert Ash.get!(NetworkCredentialRule, credential_rule.id, actor: actor).scope_value ==
               new_uid

      assert Ash.get!(PluginAssignment, enabled_assignment_id, actor: actor).agent_uid == new_uid
      assert Ash.get!(CameraSource, camera_source.id, actor: actor).assigned_agent_id == new_uid
    end

    test "skips conflicting manual plugin assignment without blocking other handoffs",
         %{uniq: uniq, actor: actor} do
      %{old: old_uid, new: new_uid, device: device_uid} = reenroll!(uniq, actor, old_state: :live)

      plugin_package = create_approved_plugin_package!(uniq, actor)
      old_assignment_id = insert_manual_plugin_assignment!(old_uid, plugin_package, true)
      _existing_new_id = insert_manual_plugin_assignment!(new_uid, plugin_package, true)
      camera_source = create_camera_source!(uniq, device_uid, old_uid, actor)
      credential_rule = create_agent_credential_rule!(uniq, old_uid, actor)

      went_quiet!(old_uid)

      assert StateMonitor.check_agents(actor: actor) >= 1

      assert agent!(old_uid, actor).status == :superseded
      assert Ash.get!(PluginAssignment, old_assignment_id, actor: actor).agent_uid == old_uid
      assert Ash.get!(CameraSource, camera_source.id, actor: actor).assigned_agent_id == new_uid

      assert Ash.get!(NetworkCredentialRule, credential_rule.id, actor: actor).scope_value ==
               new_uid
    end

    test "transitions a timed-out solo identity to disconnected without superseding it",
         %{uniq: uniq, actor: actor} do
      ip = test_ip(uniq)
      uid = "agent-monitor-solo-#{uniq}"
      _device_uid = enroll!(uid, ip, "monitor-solo-#{uniq}", mac(uniq, 0))

      went_quiet!(uid)

      assert StateMonitor.check_agents(actor: actor) >= 1

      agent = agent!(uid, actor)
      assert agent.status == :disconnected
      assert is_nil(agent.superseded_by)
    end
  end

  describe "on_agent_disconnected/2" do
    test "supersedes a disconnected identity and transfers assignments when a live replacement exists",
         %{uniq: uniq, actor: actor} do
      %{old: old_uid, new: new_uid, device: device_uid} = reenroll!(uniq, actor, old_state: :live)

      sweep_group = create_sweep_group!(uniq, old_uid, actor)
      mapper_job = create_mapper_job!(uniq, old_uid, actor)

      {:ok, disconnected} =
        old_uid
        |> agent!(actor)
        |> Ash.Changeset.for_update(:lose_connection, %{})
        |> Ash.update(actor: actor)

      assert {:ok, superseded} = AgentSupersession.on_agent_disconnected(disconnected, actor)
      assert superseded.status == :superseded
      assert superseded.superseded_by == new_uid
      assert decision?(device_uid, "older_identity_on_device", old_uid, actor)

      assert Ash.get!(SweepGroup, sweep_group.id, actor: actor).agent_ids == [new_uid]
      assert Ash.get!(MapperJob, mapper_job.id, actor: actor).agent_id == new_uid
    end

    test "leaves a disconnected identity alone when no live sibling exists",
         %{uniq: uniq, actor: actor} do
      ip = test_ip(uniq)
      uid = "agent-solo-#{uniq}"
      _device_uid = enroll!(uid, ip, "solo-#{uniq}", mac(uniq, 0))

      {:ok, disconnected} =
        uid
        |> agent!(actor)
        |> Ash.Changeset.for_update(:lose_connection, %{})
        |> Ash.update(actor: actor)

      assert :noop = AgentSupersession.on_agent_disconnected(disconnected, actor)
      assert agent!(uid, actor).status == :disconnected
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
      [DateTime.shift(DateTime.utc_now(), day: -1), agent_uid]
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

  defp create_sweep_group!(uniq, agent_uid, actor) do
    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "supersession-sweep-#{uniq}",
          partition: "default",
          agent_ids: [agent_uid],
          target_query: "in:devices",
          static_targets: [test_ip(uniq)],
          ports: [],
          sweep_modes: ["icmp"]
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    group
  end

  defp create_mapper_job!(uniq, agent_uid, actor) do
    {:ok, job} =
      MapperJob
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "supersession-mapper-#{uniq}",
          partition: "default",
          agent_id: agent_uid,
          discovery_mode: :snmp_api,
          discovery_type: :full,
          options: %{}
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    job
  end

  defp create_agent_credential_rule!(uniq, agent_uid, actor) do
    secret = CredentialIntegrationFixtures.secret!(actor: actor)

    {:ok, rule} =
      NetworkCredentialRule.create_rule(
        %{
          name: "supersession-rule-#{uniq}",
          provider: "example-network",
          auth_method: "api_token",
          purpose: "inventory",
          target_query: "in:devices",
          scope_type: :agent,
          scope_value: agent_uid,
          secret_id: secret.id
        },
        actor: actor
      )

    rule
  end

  defp create_approved_plugin_package!(uniq, actor) do
    plugin_id = "supersession-plugin-#{uniq}"

    Plugin
    |> Ash.Changeset.for_create(
      :create,
      %{
        plugin_id: plugin_id,
        name: "Supersession Plugin #{uniq}",
        description: "Synthetic plugin for agent supersession handoff tests"
      },
      actor: actor
    )
    |> Ash.create!()

    PluginPackage
    |> Ash.Changeset.for_create(
      :create,
      %{
        plugin_id: plugin_id,
        name: "Supersession Plugin #{uniq}",
        version: "1.0.0",
        entrypoint: "run_check",
        runtime: "wasi-preview1",
        outputs: "serviceradar.plugin_result.v1",
        manifest: %{
          "id" => plugin_id,
          "name" => "Supersession Plugin #{uniq}",
          "version" => "1.0.0",
          "entrypoint" => "run_check",
          "runtime" => "wasi-preview1",
          "outputs" => "serviceradar.plugin_result.v1",
          "capabilities" => ["submit_result"],
          "resources" => %{"requested_memory_mb" => 32, "requested_cpu_ms" => 100}
        },
        config_schema: %{},
        display_contract: %{},
        content_hash: "sha256:#{plugin_id}:1.0.0",
        signature: %{},
        source_type: :upload
      },
      actor: actor
    )
    |> Ash.create!()
    |> Ash.Changeset.for_update(:approve, %{approved_by: "system:agent_supersession_test"},
      actor: actor
    )
    |> Ash.update!()
  end

  defp insert_manual_plugin_assignment!(agent_uid, plugin_package, enabled) do
    id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO platform.plugin_assignments
        (id, agent_uid, partition_id, plugin_package_id, plugin_id, source, enabled)
      VALUES ($1::text::uuid, $2, 'default', $3::text::uuid, $4, 'manual', $5)
      """,
      [id, agent_uid, to_string(plugin_package.id), plugin_package.plugin_id, enabled]
    )

    id
  end

  defp create_camera_source!(uniq, device_uid, agent_uid, actor) do
    {:ok, source} =
      CameraSource.create_source(
        %{
          device_uid: device_uid,
          vendor: "example-camera",
          vendor_camera_id: "cam-#{uniq}",
          display_name: "Example Camera #{uniq}",
          assigned_agent_id: agent_uid
        },
        actor: actor
      )

    source
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
