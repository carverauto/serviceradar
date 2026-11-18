defmodule ServiceRadar.AgentConfig.Compilers.NetperfCompilerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.AgentConfig.Compilers.NetperfCompiler
  alias ServiceRadar.Edge.AgentConfigGenerator
  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadar.Edge.NetperfPermitSigning

  @test_seed <<7::256>>

  defp test_key, do: IssuerKey.from_seed(@test_seed)

  defp agent_fixture(uid, opts \\ []) do
    %{
      uid: uid,
      device_uid: Keyword.get(opts, :device_uid, "dev-#{uid}"),
      ip: Keyword.get(opts, :ip, "192.0.2.10"),
      host: Keyword.get(opts, :host, "#{uid}.example.net"),
      metadata:
        Keyword.get(opts, :metadata, %{"partition_id" => Keyword.get(opts, :partition, "default")}),
      device: %{
        uid: Keyword.get(opts, :device_uid, "dev-#{uid}"),
        partition: Keyword.get(opts, :partition, "default"),
        tags: Keyword.get(opts, :tags, %{})
      },
      gateway: nil
    }
  end

  defp responder_fixture(uid, opts \\ []) do
    %{
      id: Keyword.get(opts, :id, "resp-#{uid}"),
      agent_uid: uid,
      name: Keyword.get(opts, :name, "Hub #{uid}"),
      enabled: Keyword.get(opts, :enabled, true),
      advertise_address: Keyword.get(opts, :advertise_address),
      listen_port: Keyword.get(opts, :listen_port, 5199),
      udp_enabled: Keyword.get(opts, :udp_enabled, true),
      max_concurrent_sessions: Keyword.get(opts, :max_concurrent_sessions, 4),
      max_total_bandwidth_bps: Keyword.get(opts, :max_total_bandwidth_bps, 1_000_000_000),
      authority_epoch: Keyword.get(opts, :authority_epoch, 2),
      agent: %{
        ip: Keyword.get(opts, :agent_ip, "198.51.100.10"),
        host: Keyword.get(opts, :agent_host, "#{uid}.example.net")
      }
    }
  end

  defp profile_fixture(id \\ "prof-1", overrides \\ %{}) do
    Map.merge(
      %{
        id: id,
        name: "WAN 50M",
        protocol: :tcp,
        direction: :bidirectional,
        bandwidth_bps: 50_000_000,
        duration_sec: 5,
        omit_sec: 1,
        parallel: 2,
        packet_length: 1200,
        interval_seconds: 900
      },
      overrides
    )
  end

  test "compile/3 returns :repo_unavailable when Repo is not running" do
    assert {:error, :repo_unavailable} = NetperfCompiler.compile("default", "agent-01")
  end

  test "hub_and_spoke compiles responder block for hubs and signed targets for matched spokes excluding self" do
    key = test_key()
    now = ~U[2026-11-18 14:00:00Z]

    hub_a =
      responder_fixture("agent-hub-a", advertise_address: "hub-a.example.net", authority_epoch: 3)

    hub_b = responder_fixture("agent-hub-b", advertise_address: nil, agent_ip: "198.51.100.20")
    disabled_hub = responder_fixture("agent-hub-disabled", enabled: false)

    policy = %{
      id: "pol-spoke",
      name: "Branch Spokes",
      enabled: true,
      mode: :hub_and_spoke,
      authority_epoch: 4,
      profile: profile_fixture(),
      spoke_selector: %{
        "partition_id" => "branch-west",
        "tags" => %{"role" => "branch"},
        "agent_uids" => ["agent-spoke-1", "agent-hub-a"]
      },
      responders: [hub_a, hub_b, disabled_hub]
    }

    spoke_agent =
      agent_fixture("agent-spoke-1",
        partition: "branch-west",
        tags: %{"role" => "branch", "env" => "prod"}
      )

    assert {:ok, compiled} =
             NetperfCompiler.compile_inputs(
               spoke_agent,
               [hub_a, hub_b, disabled_hub],
               [policy],
               partition: "branch-west",
               issuer_key: key,
               now: now
             )

    assert compiled["enabled"] == true
    assert compiled["responder"]["enabled"] == false

    assert Enum.map(compiled["targets"], & &1["responder_agent_id"]) == [
             "agent-hub-a",
             "agent-hub-b"
           ]

    [target_a, target_b] = compiled["targets"]
    assert target_a["target_address"] == "hub-a.example.net"
    assert target_b["target_address"] == "198.51.100.20"
    assert target_a["protocol"] == "tcp"
    assert target_a["direction"] == "bidirectional"

    permit_a = NetperfPermitSigning.to_proto(target_a["permit"])
    assert permit_a.sender_agent_id == "agent-spoke-1"
    assert permit_a.responder_agent_id == "agent-hub-a"
    assert permit_a.partition_id == "branch-west"
    assert permit_a.authority_epoch == 3
    assert NetperfPermitSigning.verify(permit_a, key.public_key)

    # Hub A also matches agent_uids/partition/tags, but is excluded from acting as a spoke on the same policy.
    hub_agent =
      agent_fixture("agent-hub-a",
        partition: "branch-west",
        tags: %{"role" => "branch"}
      )

    assert {:ok, hub_compiled} =
             NetperfCompiler.compile_inputs(
               hub_agent,
               [hub_a, hub_b, disabled_hub],
               [policy],
               partition: "branch-west",
               issuer_key: key,
               now: now
             )

    assert hub_compiled["enabled"] == true
    assert hub_compiled["responder"]["enabled"] == true
    assert hub_compiled["responder"]["listen_port"] == 5199
    assert hub_compiled["responder"]["min_authority_epoch"] == 3
    assert permit_a.authority_epoch == hub_compiled["responder"]["min_authority_epoch"]
    assert hub_compiled["targets"] == []
  end

  test "responder epoch bumps fence old permits while policy epoch bumps rotate permit_id and config_version" do
    key = test_key()
    now = ~U[2026-11-18 14:00:00Z]

    hub_epoch_1 =
      responder_fixture("agent-hub-1", advertise_address: "198.51.100.1", authority_epoch: 1)

    hub_epoch_2 =
      responder_fixture("agent-hub-1", advertise_address: "198.51.100.1", authority_epoch: 2)

    hub_agent = agent_fixture("agent-hub-1", partition: "default")
    spoke_agent = agent_fixture("agent-spoke-1", partition: "default")

    policy_v1 = %{
      id: "pol-epoch",
      name: "Epoch Fencing",
      enabled: true,
      mode: :hub_and_spoke,
      authority_epoch: 1,
      profile: profile_fixture(),
      spoke_selector: %{"agent_uids" => ["agent-spoke-1"]},
      responders: [hub_epoch_1]
    }

    policy_v2 = %{policy_v1 | authority_epoch: 2}

    {:ok, spoke_v1} =
      NetperfCompiler.compile_inputs(spoke_agent, [hub_epoch_1], [policy_v1],
        partition: "default",
        issuer_key: key,
        now: now
      )

    {:ok, spoke_policy_v2} =
      NetperfCompiler.compile_inputs(spoke_agent, [hub_epoch_1], [policy_v2],
        partition: "default",
        issuer_key: key,
        now: now
      )

    permit_v1 = NetperfPermitSigning.to_proto(hd(spoke_v1["targets"])["permit"])
    permit_policy_v2 = NetperfPermitSigning.to_proto(hd(spoke_policy_v2["targets"])["permit"])

    assert permit_v1.authority_epoch == 1
    assert permit_policy_v2.authority_epoch == 1
    assert permit_v1.permit_id != permit_policy_v2.permit_id

    assert AgentConfigGenerator.compute_version_hash(%{netperf: spoke_v1}) !=
             AgentConfigGenerator.compute_version_hash(%{netperf: spoke_policy_v2})

    {:ok, hub_after_bump} =
      NetperfCompiler.compile_inputs(
        hub_agent,
        [hub_epoch_2],
        [%{policy_v2 | responders: [hub_epoch_2]}],
        partition: "default",
        issuer_key: key,
        now: now
      )

    min_epoch = hub_after_bump["responder"]["min_authority_epoch"]
    assert min_epoch == 2
    assert permit_v1.authority_epoch < min_epoch
    assert permit_policy_v2.authority_epoch < min_epoch

    {:ok, spoke_after_bump} =
      NetperfCompiler.compile_inputs(
        spoke_agent,
        [hub_epoch_2],
        [%{policy_v2 | responders: [hub_epoch_2]}],
        partition: "default",
        issuer_key: key,
        now: now
      )

    fresh_permit = NetperfPermitSigning.to_proto(hd(spoke_after_bump["targets"])["permit"])
    assert fresh_permit.authority_epoch == min_epoch
  end

  test "hub_mesh compiles pairwise outbound targets excluding self -> self" do
    key = test_key()
    now = ~U[2026-11-18 14:00:00Z]

    hub_1 = responder_fixture("agent-hub-1", advertise_address: "198.51.100.1")
    hub_2 = responder_fixture("agent-hub-2", advertise_address: "198.51.100.2")
    hub_3 = responder_fixture("agent-hub-3", advertise_address: "198.51.100.3")

    mesh_policy = %{
      id: "pol-mesh",
      name: "Core Mesh",
      enabled: true,
      mode: :hub_mesh,
      authority_epoch: 1,
      profile: profile_fixture("prof-udp", %{protocol: :udp, direction: :upload}),
      spoke_selector: %{},
      responders: [hub_1, hub_2, hub_3]
    }

    hub_1_agent = agent_fixture("agent-hub-1", partition: "core")

    assert {:ok, compiled} =
             NetperfCompiler.compile_inputs(
               hub_1_agent,
               [hub_1, hub_2, hub_3],
               [mesh_policy],
               partition: "core",
               issuer_key: key,
               now: now
             )

    assert compiled["responder"]["enabled"] == true

    assert Enum.map(compiled["targets"], & &1["responder_agent_id"]) == [
             "agent-hub-2",
             "agent-hub-3"
           ]
  end

  test "hub_and_spoke evaluates SRQL selectors for in:agents and in:devices via query_page_fn" do
    key = test_key()
    now = ~U[2026-11-18 14:00:00Z]
    hub = responder_fixture("agent-hub-1", advertise_address: "198.51.100.1")

    policy_agents = %{
      id: "pol-agents",
      name: "SRQL Agents",
      enabled: true,
      mode: :hub_and_spoke,
      authority_epoch: 1,
      profile: profile_fixture(),
      spoke_selector: %{"srql_query" => "in:agents status:connected"},
      responders: [hub]
    }

    policy_devices = %{
      id: "pol-devices",
      name: "SRQL Devices",
      enabled: true,
      mode: :hub_and_spoke,
      authority_epoch: 1,
      profile: profile_fixture(),
      spoke_selector: %{"srql_query" => "in:devices type:Router"},
      responders: [hub]
    }

    spoke = agent_fixture("agent-spoke-srql", device_uid: "sr:dev-router-1")

    query_page_fn = fn input_def, acc, fun ->
      case input_def.entity do
        "agents" ->
          {:cont, next} = fun.([%{"uid" => "agent-spoke-srql"}], acc)
          {:ok, next}

        "devices" ->
          {:cont, next} = fun.([%{"uid" => "sr:dev-router-1"}], acc)
          {:ok, next}
      end
    end

    assert {:ok, compiled} =
             NetperfCompiler.compile_inputs(
               spoke,
               [hub],
               [policy_agents, policy_devices],
               partition: "default",
               issuer_key: key,
               now: now,
               query_page_fn: query_page_fn
             )

    assert Enum.map(compiled["targets"], & &1["policy_id"]) == ["pol-agents", "pol-devices"]
  end

  test "same-UTC-day compile_inputs yields identical config_version hash across polls" do
    key = test_key()
    hub = responder_fixture("agent-hub-1", advertise_address: "198.51.100.1")

    policy = %{
      id: "pol-stable",
      name: "Stable",
      enabled: true,
      mode: :hub_and_spoke,
      authority_epoch: 1,
      profile: profile_fixture(),
      spoke_selector: %{"agent_uids" => ["agent-spoke-1"]},
      responders: [hub]
    }

    spoke = agent_fixture("agent-spoke-1")

    {:ok, c1} =
      NetperfCompiler.compile_inputs(spoke, [hub], [policy],
        partition: "default",
        issuer_key: key,
        now: ~U[2026-11-18 02:00:00Z]
      )

    {:ok, c2} =
      NetperfCompiler.compile_inputs(spoke, [hub], [policy],
        partition: "default",
        issuer_key: key,
        now: ~U[2026-11-18 22:00:00Z]
      )

    assert c1 == c2

    assert AgentConfigGenerator.compute_version_hash(%{netperf: c1}) ==
             AgentConfigGenerator.compute_version_hash(%{netperf: c2})
  end
end
