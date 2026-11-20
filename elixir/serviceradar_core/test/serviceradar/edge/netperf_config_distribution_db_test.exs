defmodule ServiceRadar.Edge.NetperfConfigDistributionDbTest do
  @moduledoc """
  Database-backed integration tests verifying end-to-end compilation and
  protobuf delivery of `AgentConfigResponse.netperf_config` with Ed25519
  `NetperfPermitV1` verification against `edge_record_trust_document`.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.AgentConfigGenerator
  alias ServiceRadar.Edge.NetperfPermitSigning
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Monitoring.NetperfPolicy
  alias ServiceRadar.Monitoring.NetperfProfile
  alias ServiceRadar.Monitoring.NetperfResponder

  @moduletag :integration

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  defp register_agent!(uid, metadata, actor) do
    Agent
    |> Ash.Changeset.for_create(:register, %{uid: uid, metadata: metadata}, actor: actor)
    |> Ash.create!()
  end

  test "generate_proto_response compiles netperf_config outside config_json and verifies permit against trust doc" do
    actor = SystemActor.system(:netperf_config_dist_test)
    suffix = System.unique_integer([:positive])
    hub_uid = "agent-hub-#{suffix}"
    spoke_uid = "agent-spoke-#{suffix}"

    register_agent!(hub_uid, %{"partition_id" => "default"}, actor)
    register_agent!(spoke_uid, %{"partition_id" => "default"}, actor)

    {:ok, profile} =
      NetperfProfile
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "netperf-prof-#{suffix}",
          protocol: :udp,
          direction: :download,
          bandwidth_bps: 75_000_000,
          duration_sec: 8,
          omit_sec: 1,
          parallel: 2
        },
        actor: actor
      )
      |> Ash.create()

    {:ok, responder} =
      NetperfResponder
      |> Ash.Changeset.for_create(
        :create,
        %{
          agent_uid: hub_uid,
          name: "Hub #{suffix}",
          advertise_address: "198.51.100.42",
          listen_port: 5199,
          udp_enabled: true
        },
        actor: actor
      )
      |> Ash.create()

    {:ok, policy} =
      NetperfPolicy
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "netperf-policy-#{suffix}",
          mode: :hub_and_spoke,
          profile_id: profile.id,
          spoke_selector: %{"agent_uids" => [spoke_uid]}
        },
        actor: actor
      )
      |> Ash.create()

    assert :ok = NetperfPolicy.sync_responders(policy.id, [responder.id], actor: actor)

    proto_spoke = AgentConfigGenerator.generate_proto_response(spoke_uid, "default")

    assert %Monitoring.AgentConfigResponse{netperf_config: %Netperf.V1.NetperfConfig{} = nc} =
             proto_spoke

    assert nc.responder.enabled == false
    assert [target] = nc.targets
    assert target.responder_agent_id == hub_uid
    assert target.target_address == "198.51.100.42"
    assert target.target_port == 5199
    assert target.protocol == :NETPERF_PROTOCOL_UDP
    assert target.direction == :NETPERF_DIRECTION_DOWNLOAD

    # Verify config_json omits netperf payload (typed proto only).
    decoded_json = Jason.decode!(proto_spoke.config_json)
    refute Map.has_key?(decoded_json, "netperf")

    # Verify permit signature against RecordTrust keys delivered on the same response,
    # and assert RecordTrust purposes remain strictly ["production", "source", "delivery"].
    trust_doc = Jason.decode!(proto_spoke.edge_record_trust_document)
    [key_entry | _] = trust_doc["keys"]
    assert key_entry["purposes"] == ["production", "source", "delivery"]

    public_key = Base.decode64!(key_entry["public_key"])
    assert NetperfPermitSigning.verify(target.permit, public_key)

    proto_hub = AgentConfigGenerator.generate_proto_response(hub_uid, "default")
    assert proto_hub.netperf_config.responder.enabled == true
    assert proto_hub.netperf_config.responder.advertise_address == "198.51.100.42"
    assert proto_hub.netperf_config.targets == []

    # Subsequent poll with same config_version returns :not_modified.
    assert :not_modified =
             AgentConfigGenerator.get_config_if_changed(
               spoke_uid,
               "default",
               proto_spoke.config_version
             )
  end
end
