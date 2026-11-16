defmodule ServiceRadar.SNMPProfiles.SNMPTargetCredentialBackfillWorkerTest do
  @moduledoc """
  The one-off backfill keeps polling the explicit targets that, before
  `remove-snmp-unbound-host-rule-fallback`, had a credential only through the
  first SNMP monitoring rule scoped to the compiling agent. The expected
  bindings come from that fallback as the change's design describes it.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentConfig.Compilers.SNMPCompiler
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.SNMPProfiles.SNMPOIDConfig
  alias ServiceRadar.SNMPProfiles.SNMPProfile
  alias ServiceRadar.SNMPProfiles.SNMPTarget
  alias ServiceRadar.SNMPProfiles.SNMPTargetCredentialBackfillWorker, as: Backfill

  @moduletag :integration

  setup do
    ServiceRadar.TestSupport.start_core!()
    %{actor: SystemActor.system(:test), suffix: System.unique_integer([:positive])}
  end

  test "binds a target only the fallback kept polling, and plan/0 writes nothing", %{
    actor: actor,
    suffix: suffix
  } do
    agent_id = agent_fixture("agent-bind-#{suffix}", actor)
    secret = credential_fixture("Fallback #{suffix}", "fallback-community", actor)
    rule_fixture("Fallback #{suffix}", agent_id, secret.id, actor)
    profile = profile_fixture("Bind #{suffix}", [agent_id], actor)

    target =
      target_fixture(profile, "Unbound", ServiceRadar.TestSupport.unique_device_ip(), actor)

    secret_id = secret.id

    assert {:ok, [%{outcome: {:bind, ^secret_id}}]} = Backfill.plan()
    assert reload(target).credential_secret_id == nil
    assert compiled_targets(profile, agent_id, actor) == []

    assert {:ok, [%{outcome: {:bound, ^secret_id}}]} = Backfill.run()
    assert reload(target).credential_secret_id == secret_id

    assert [%{"community" => "fallback-community"}] =
             compiled_targets(profile, agent_id, actor)

    assert {:ok, []} = Backfill.run()
  end

  test "binds nothing when the agents compiling the profile chose different rules", %{
    actor: actor,
    suffix: suffix
  } do
    agents =
      for name <- ["a", "b"] do
        agent_id = agent_fixture("agent-#{name}-#{suffix}", actor)
        secret = credential_fixture("Rule #{name} #{suffix}", "#{name}-community", actor)
        rule_fixture("Rule #{name} #{suffix}", agent_id, secret.id, actor)
        agent_id
      end

    profile = profile_fixture("Disagree #{suffix}", agents, actor)

    target =
      target_fixture(profile, "Unbound", ServiceRadar.TestSupport.unique_device_ip(), actor)

    assert {:ok, [%{outcome: {:unbound, :agents_disagree}}]} = Backfill.run()
    assert reload(target).credential_secret_id == nil
  end

  test "leaves a target alone when its own credential or its host's device decides it", %{
    actor: actor,
    suffix: suffix
  } do
    agent_id = agent_fixture("agent-keep-#{suffix}", actor)
    secret = credential_fixture("Keep #{suffix}", "rule-community", actor)
    rule_fixture("Keep #{suffix}", agent_id, secret.id, actor)
    profile = profile_fixture("Keep #{suffix}", [agent_id], actor)

    own =
      target_fixture(profile, "Own", ServiceRadar.TestSupport.unique_device_ip(), actor, %{
        community: "own-community"
      })

    host = ServiceRadar.TestSupport.unique_device_ip()

    Device
    |> Ash.Changeset.for_create(:create, %{
      uid: "sr:" <> Ecto.UUID.generate(),
      hostname: "host01-#{suffix}.example.com",
      ip: host
    })
    |> Ash.create!(actor: actor)

    bound = target_fixture(profile, "Bound", host, actor)
    bound_id = to_string(bound.id)

    assert {:ok, [%{target_id: ^bound_id, outcome: :not_needed}]} = Backfill.run()
    assert reload(bound).credential_secret_id == nil
    assert reload(own).credential_secret_id == nil
  end

  defp compiled_targets(profile, agent_id, actor) do
    {:ok, config} = SNMPCompiler.compile_profile(profile, actor, agent_id: agent_id)
    config["targets"]
  end

  defp reload(target), do: Ash.get!(SNMPTarget, target.id, actor: SystemActor.system(:test))

  defp agent_fixture(uid, actor) do
    Agent
    |> Ash.Changeset.for_create(
      :register,
      %{uid: uid, metadata: %{"partition_id" => "default"}},
      actor: actor
    )
    |> Ash.create!(actor: actor)

    uid
  end

  defp credential_fixture(name, community, actor) do
    NetworkCredentialSecret
    |> Ash.Changeset.for_create(
      :create,
      %{name: name, provider: "snmp", credential_kind: :opaque, secret_payload: community},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  # Written for one device, so its target query selects none of the targets.
  defp rule_fixture(name, agent_id, secret_id, actor) do
    NetworkCredentialRule
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: name,
        provider: "snmp",
        auth_method: :community,
        purpose: "snmp_monitoring",
        target_query: ~s(in:devices hostname:"elsewhere.example.com"),
        scope_type: :agent,
        scope_value: agent_id,
        secret_id: secret_id
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp profile_fixture(name, agent_ids, actor) do
    SNMPProfile
    |> Ash.Changeset.for_create(
      :create,
      %{name: name, enabled: true, version: :v2c, agent_ids: agent_ids},
      actor: actor
    )
    |> Ash.create!(actor: actor)
    |> Ash.Changeset.for_update(:set_as_default, %{}, actor: actor)
    |> Ash.update!(actor: actor)
  end

  defp target_fixture(profile, name, host, actor, attrs \\ %{}) do
    target =
      SNMPTarget
      |> Ash.Changeset.for_create(
        :create,
        Map.merge(
          %{snmp_profile_id: profile.id, name: name, host: host, port: 161, version: :v2c},
          attrs
        ),
        actor: actor
      )
      |> Ash.create!(actor: actor)

    SNMPOIDConfig
    |> Ash.Changeset.for_create(
      :create,
      %{snmp_target_id: target.id, oid: ".1.3.6.1.2.1.1.3.0", name: "sysUpTime"},
      actor: actor
    )
    |> Ash.create!(actor: actor)

    target
  end
end
