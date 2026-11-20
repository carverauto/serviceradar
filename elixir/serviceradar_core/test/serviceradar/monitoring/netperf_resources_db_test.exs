defmodule ServiceRadar.Monitoring.NetperfResourcesDbTest do
  @moduledoc """
  Database-backed tests for NetperfProfile, NetperfResponder, NetperfPolicy,
  and NetperfPolicyResponder Ash resources, check constraints, and RBAC policies.
  """

  use ServiceRadar.DataCase, async: true

  alias Ash.Error.Invalid
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Monitoring.NetperfPolicy
  alias ServiceRadar.Monitoring.NetperfPolicyResponder
  alias ServiceRadar.Monitoring.NetperfProfile
  alias ServiceRadar.Monitoring.NetperfResponder

  @moduletag :requires_app

  defp system_actor, do: SystemActor.system(:netperf_resources_test)

  defp operator_actor do
    %{id: Ash.UUID.generate(), email: "operator@example.test", role: :operator}
  end

  defp viewer_actor do
    %{id: Ash.UUID.generate(), email: "viewer@example.test", role: :viewer}
  end

  defp unique_name(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp create_agent!(uid, actor) do
    Agent
    |> Ash.Changeset.for_create(:register, %{uid: uid}, actor: actor)
    |> Ash.create!()
  end

  describe "NetperfProfile" do
    test "CRUD and RBAC enforcement" do
      operator = operator_actor()
      viewer = viewer_actor()
      name = unique_name("netperf-prof")

      assert {:error, %Ash.Error.Forbidden{}} =
               NetperfProfile
               |> Ash.Changeset.for_create(:create, %{name: name}, actor: viewer)
               |> Ash.create()

      assert {:ok, profile} =
               NetperfProfile
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   name: name,
                   protocol: :udp,
                   direction: :bidirectional,
                   bandwidth_bps: 25_000_000,
                   duration_sec: 10,
                   omit_sec: 2,
                   parallel: 2,
                   packet_length: 1200,
                   interval_seconds: 300
                 },
                 actor: operator
               )
               |> Ash.create()

      assert {:ok, fetched} = NetperfProfile.get_by_id(profile.id, actor: viewer)
      assert fetched.name == name

      assert {:ok, updated} =
               profile
               |> Ash.Changeset.for_update(:update, %{duration_sec: 15, omit_sec: 3},
                 actor: operator
               )
               |> Ash.update()

      assert updated.duration_sec == 15
      assert updated.omit_sec == 3
    end

    test "enforces safety bounds and omit_sec < duration_sec check constraint" do
      operator = operator_actor()

      assert {:error, _} =
               NetperfProfile
               |> Ash.Changeset.for_create(
                 :create,
                 %{name: unique_name("bad-dur"), duration_sec: 31},
                 actor: operator
               )
               |> Ash.create()

      assert {:error, _} =
               NetperfProfile
               |> Ash.Changeset.for_create(
                 :create,
                 %{name: unique_name("bad-omit"), duration_sec: 3, omit_sec: 3},
                 actor: operator
               )
               |> Ash.create()

      assert {:error, _} =
               NetperfProfile
               |> Ash.Changeset.for_create(
                 :create,
                 %{name: unique_name("bad-bw"), bandwidth_bps: 10_000},
                 actor: operator
               )
               |> Ash.create()

      assert {:error, _} =
               NetperfProfile
               |> Ash.Changeset.for_create(
                 :create,
                 %{name: unique_name("bad-interval"), interval_seconds: 30},
                 actor: operator
               )
               |> Ash.create()

      {:ok, valid_profile} =
        NetperfProfile
        |> Ash.Changeset.for_create(
          :create,
          %{name: unique_name("update-omit"), duration_sec: 10, omit_sec: 3},
          actor: operator
        )
        |> Ash.create()

      # Atomic Ash validation catches omit_sec >= duration_sec on partial updates too.
      assert {:error, %Invalid{}} =
               valid_profile
               |> Ash.Changeset.for_update(:update, %{duration_sec: 3}, actor: operator)
               |> Ash.update()

      assert {:error, %Invalid{}} =
               valid_profile
               |> Ash.Changeset.for_update(:update, %{omit_sec: 5, duration_sec: 5},
                 actor: operator
               )
               |> Ash.update()
    end
  end

  describe "NetperfResponder" do
    test "creates responder linked to agent and bumps authority_epoch on disable" do
      sys = system_actor()
      operator = operator_actor()
      uid = unique_name("agent-hub")
      create_agent!(uid, sys)

      assert {:ok, responder} =
               NetperfResponder
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   agent_uid: uid,
                   name: "Hub #{uid}",
                   advertise_address: "198.51.100.5",
                   listen_port: 5199,
                   udp_enabled: true,
                   max_concurrent_sessions: 4,
                   max_total_bandwidth_bps: 1_000_000_000
                 },
                 actor: operator
               )
               |> Ash.create()

      assert responder.authority_epoch == 1
      assert responder.enabled == true

      assert {:ok, disabled} =
               responder
               |> Ash.Changeset.for_update(:disable, %{}, actor: operator)
               |> Ash.update()

      assert disabled.enabled == false
      assert disabled.authority_epoch == 2
    end
  end

  describe "NetperfPolicy and NetperfPolicyResponder" do
    test "validates spoke_selector SRQL and synchronizes responder attachments" do
      sys = system_actor()
      operator = operator_actor()
      uid1 = unique_name("agent-hub-1")
      uid2 = unique_name("agent-hub-2")
      create_agent!(uid1, sys)
      create_agent!(uid2, sys)

      {:ok, profile} =
        NetperfProfile
        |> Ash.Changeset.for_create(:create, %{name: unique_name("prof")}, actor: operator)
        |> Ash.create()

      {:ok, resp1} =
        NetperfResponder
        |> Ash.Changeset.for_create(:create, %{agent_uid: uid1, name: "Hub 1"}, actor: operator)
        |> Ash.create()

      {:ok, resp2} =
        NetperfResponder
        |> Ash.Changeset.for_create(:create, %{agent_uid: uid2, name: "Hub 2"}, actor: operator)
        |> Ash.create()

      # Rejects limit: or wrong entity in srql_query
      assert {:error, _} =
               NetperfPolicy
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   name: unique_name("bad-srql"),
                   profile_id: profile.id,
                   spoke_selector: %{"srql_query" => "in:agents limit:10"}
                 },
                 actor: operator
               )
               |> Ash.create()

      assert {:error, _} =
               NetperfPolicy
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   name: unique_name("bad-entity"),
                   profile_id: profile.id,
                   spoke_selector: %{"srql_query" => "in:alerts"}
                 },
                 actor: operator
               )
               |> Ash.create()

      assert {:error, _} =
               NetperfPolicy
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   name: unique_name("bad-blank-uid"),
                   profile_id: profile.id,
                   spoke_selector: %{"agent_uids" => ["agent-1", "   "]}
                 },
                 actor: operator
               )
               |> Ash.create()

      assert {:ok, policy} =
               NetperfPolicy
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   name: unique_name("good-policy"),
                   mode: :hub_and_spoke,
                   profile_id: profile.id,
                   spoke_selector: %{
                     "partition_id" => "default",
                     "srql_query" => "in:agents status:connected"
                   }
                 },
                 actor: operator
               )
               |> Ash.create()

      assert :ok = NetperfPolicy.sync_responders(policy.id, [resp1.id, resp2.id], actor: operator)

      {:ok, links} = NetperfPolicyResponder.list_for_policy(policy.id, actor: operator)
      assert Enum.sort(Enum.map(links, & &1.responder_id)) == Enum.sort([resp1.id, resp2.id])

      assert :ok = NetperfPolicy.sync_responders(policy.id, [resp2.id], actor: operator)
      {:ok, links_after} = NetperfPolicyResponder.list_for_policy(policy.id, actor: operator)
      assert Enum.map(links_after, & &1.responder_id) == [resp2.id]
    end
  end
end
