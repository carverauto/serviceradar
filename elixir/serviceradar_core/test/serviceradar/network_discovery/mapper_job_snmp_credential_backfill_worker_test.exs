defmodule ServiceRadar.NetworkDiscovery.MapperJobSNMPCredentialBackfillWorkerTest do
  @moduledoc """
  The one-off backfill binds each job the migration marked to the credential the
  pre-upgrade fallback chain resolved, so discovery keeps working without anyone
  re-entering a secret. The expected bindings come from that chain as the
  `decouple-mapper-discovery-credential` design describes it.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentConfig.Compilers.MapperCompiler
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.NetworkDiscovery.MapperJob
  alias ServiceRadar.NetworkDiscovery.MapperJobSNMPCredentialBackfillWorker, as: Backfill
  alias ServiceRadar.Repo
  alias ServiceRadar.SNMPProfiles.SNMPProfile

  require Ash.Query

  @moduletag :integration

  setup do
    ServiceRadar.TestSupport.start_core!()
    %{actor: SystemActor.system(:test), suffix: System.unique_integer([:positive])}
  end

  test "binds the default profile's reusable credential, and plan/0 writes nothing", %{
    actor: actor,
    suffix: suffix
  } do
    partition = "backfill-default-#{suffix}"
    agent_fixture("agent-default-#{suffix}", partition, actor)
    secret = credential_fixture("Default #{suffix}", "default-community", actor)
    profile_fixture("Default #{suffix}", %{credential_secret_id: secret.id}, actor)
    job = marked_job("Default #{suffix}", partition, nil, actor)

    assert {:ok, [%{outcome: {:bind, :existing}}]} = Backfill.plan()
    assert %{snmp_credential_secret_id: nil, snmp_credential_backfill_pending: true} = reload(job)

    assert {:ok, [%{outcome: {:bound, bound_id, :existing}}]} = Backfill.run()
    assert bound_id == secret.id

    assert %{snmp_credential_secret_id: ^bound_id, snmp_credential_backfill_pending: false} =
             reload(job)

    assert compiled_community(partition, nil, job, actor) == "default-community"
  end

  test "promotes inline profile material and rebinds the profile to the same credential", %{
    actor: actor,
    suffix: suffix
  } do
    partition = "backfill-inline-#{suffix}"
    agent_fixture("agent-inline-#{suffix}", partition, actor)
    profile = profile_fixture("Inline #{suffix}", %{community: "inline-community"}, actor)
    job = marked_job("Inline #{suffix}", partition, nil, actor)

    assert {:ok, [%{outcome: {:bound, promoted_id, :promoted}}]} = Backfill.run()

    assert reload(job).snmp_credential_secret_id == promoted_id
    assert Ash.get!(SNMPProfile, profile.id, actor: actor).credential_secret_id == promoted_id
    assert compiled_community(partition, nil, job, actor) == "inline-community"
  end

  test "binds the secret of the agent-scoped monitoring rule the agent fell back on", %{
    actor: actor,
    suffix: suffix
  } do
    partition = "backfill-rule-#{suffix}"
    agent_id = agent_fixture("agent-rule-#{suffix}", partition, actor)
    secret = credential_fixture("Rule #{suffix}", "rule-community", actor)
    rule_fixture("Rule #{suffix}", agent_id, secret.id, actor)
    job = marked_job("Rule #{suffix}", partition, agent_id, actor)

    assert {:ok, [%{outcome: {:bound, bound_id, :existing}}]} = Backfill.run()
    assert bound_id == secret.id
    assert compiled_community(partition, agent_id, job, actor) == "rule-community"
  end

  test "a job whose agents are not registered stays marked for a retry", %{
    actor: actor,
    suffix: suffix
  } do
    job = marked_job("No agents #{suffix}", "backfill-empty-#{suffix}", nil, actor)

    assert {:error, [%{outcome: {:error, {:no_registered_agents, _partition}}}]} = Backfill.run()
    assert reload(job).snmp_credential_backfill_pending
  end

  test "leaves a partition job unbound when its agents fell back on different credentials", %{
    actor: actor,
    suffix: suffix
  } do
    partition = "backfill-split-#{suffix}"

    for {name, community} <- [{"a", "site-a-community"}, {"b", "site-b-community"}] do
      agent_id = agent_fixture("agent-#{name}-#{suffix}", partition, actor)
      secret = credential_fixture("Site #{name} #{suffix}", community, actor)
      rule_fixture("Site #{name} #{suffix}", agent_id, secret.id, actor)
    end

    job = marked_job("Split #{suffix}", partition, nil, actor)

    assert {:ok, [%{outcome: {:unbound, :agents_disagree}}]} = Backfill.run()

    assert %{snmp_credential_secret_id: nil, snmp_credential_backfill_pending: false} =
             reload(job)
  end

  test "a read failure leaves the job marked, and a finished job is never revisited", %{
    actor: actor,
    suffix: suffix
  } do
    partition = "backfill-retry-#{suffix}"
    agent_fixture("agent-retry-#{suffix}", partition, actor)
    secret = credential_fixture("Retry #{suffix}", "retry-community", actor)
    profile_fixture("Retry #{suffix}", %{credential_secret_id: secret.id}, actor)
    job = marked_job("Retry #{suffix}", partition, nil, actor)

    Repo.query!(
      "ALTER TABLE platform.network_credential_secrets RENAME TO _network_credential_secrets_hidden"
    )

    try do
      assert {:error, [%{outcome: {:error, _reason}}]} = Backfill.run()
    after
      Repo.query!(
        "ALTER TABLE platform._network_credential_secrets_hidden RENAME TO network_credential_secrets"
      )
    end

    assert reload(job).snmp_credential_backfill_pending

    assert {:ok, [%{outcome: {:bound, _id, :existing}}]} = Backfill.run()

    # The operator clears the credential on purpose; the backfill leaves it so.
    job
    |> reload()
    |> Ash.Changeset.for_update(:update, %{snmp_credential_secret_id: nil}, actor: actor)
    |> Ash.update!(actor: actor)

    assert {:ok, []} = Backfill.run()
    assert reload(job).snmp_credential_secret_id == nil
  end

  defp marked_job(name, partition, agent_id, actor) do
    job =
      MapperJob
      |> Ash.Changeset.for_create(
        :create,
        %{name: name, partition: partition, agent_id: agent_id, discovery_mode: :snmp},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    # What the migration does to every job that exists when it runs.
    Repo.query!(
      "UPDATE platform.mapper_jobs SET snmp_credential_backfill_pending = true WHERE id = $1",
      [Ecto.UUID.dump!(job.id)]
    )

    job
  end

  defp reload(job) do
    MapperJob
    |> Ash.Query.for_read(:read, %{}, actor: SystemActor.system(:test))
    |> Ash.Query.filter(id == ^job.id)
    |> Ash.Query.select([:snmp_credential_secret_id, :snmp_credential_backfill_pending])
    |> Ash.read_one!(actor: SystemActor.system(:test))
  end

  defp compiled_community(partition, agent_id, job, actor) do
    {:ok, config} = MapperCompiler.compile(partition, agent_id, actor: actor)

    config["scheduled_jobs"]
    |> Enum.find(&(&1["name"] == job.name))
    |> get_in(["credentials", "community"])
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

  defp profile_fixture(name, credential, actor) do
    SNMPProfile
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{name: name, enabled: true, version: :v2c}, credential),
      actor: actor
    )
    |> Ash.create!(actor: actor)
    |> Ash.Changeset.for_update(:set_as_default, %{}, actor: actor)
    |> Ash.update!(actor: actor)
  end

  defp agent_fixture(uid, partition, actor) do
    Agent
    |> Ash.Changeset.for_create(
      :register,
      %{uid: uid, metadata: %{"partition_id" => partition}},
      actor: actor
    )
    |> Ash.create!(actor: actor)

    uid
  end

  defp rule_fixture(name, agent_id, secret_id, actor) do
    NetworkCredentialRule
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: name,
        provider: "snmp",
        auth_method: :community,
        purpose: "snmp_monitoring",
        target_query: "in:devices",
        scope_type: :agent,
        scope_value: agent_id,
        secret_id: secret_id
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end
end
