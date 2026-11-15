defmodule ServiceRadar.NetworkDiscovery.MapperJobSNMPCredentialBackfillWorker do
  @moduledoc """
  One-off backfill of mapper jobs' SNMP credentials, enqueued once by migration
  `20261115170000_add_mapper_job_snmp_credential`
  (`decouple-mapper-discovery-credential`).

  Before that change a mapper job had no SNMP credential of its own. For every
  address without a per-device credential the compiler used, per agent:

  1. the credential of the device hosting the agent, resolved the way SNMP
     polling resolves it (device override, matching monitoring rule, targeting
     profile, default profile); else
  2. the first enabled SNMP monitoring rule scoped to the agent or partition,
     whatever its target query; else
  3. the credential of the profile flagged `is_default`.

  For each job the migration marked, this worker replays that chain for every
  agent the job compiles for: its assigned agent, or every agent registered in
  its partition (the persisted, non-superseded agent rows, with each row's
  `device_uid`). An agent-assigned job whose agent has no row, or a partition
  with no registered agent, fails the job so Oban retries it. When every agent
  resolves the same credential, the job is bound to a reusable credential that
  reproduces it:

  * the source's own reusable credential, when referencing it from the job
    yields the same mapper credential;
  * else, when the source is a profile or device override holding inline
    material, that material promoted to a reusable credential, with the source
    rebound to it so one copy serves both;
  * else a reusable copy of the resolved credential, for a source whose
    credential depends on fields stored on the source record.

  A job whose agents disagree, or resolve nothing, is left without a credential
  and shows as missing one. Either way its mark is cleared and it is never
  revisited, so an operator's later choice is never overwritten. A read or write
  failure leaves the job marked and fails the run, so Oban retries it.

  `plan/0` reports what `run/0` would do without writing anything; from a
  release, `bin/serviceradar_core eval
  'ServiceRadar.NetworkDiscovery.MapperJobSNMPCredentialBackfillWorker.plan() |> IO.inspect()'`.
  The worker, and with it the legacy chain, can be deleted once every
  deployment has run it.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 20

  import Ash.Expr

  alias Ash.Error.Invalid
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Inventory.DeviceSNMPCredential
  alias ServiceRadar.NetworkDiscovery.MapperJob
  alias ServiceRadar.Repo
  alias ServiceRadar.SNMPProfiles.CredentialResolver
  alias ServiceRadar.SNMPProfiles.ReusableCredential
  alias ServiceRadar.SNMPProfiles.SNMPProfile

  require Ash.Query
  require Logger

  @type outcome ::
          :not_needed
          | {:bind, :existing | :promote | :copy}
          | {:bound, String.t(), :existing | :promoted | :copied}
          | {:unbound, :no_legacy_credential | :agents_disagree | :not_reproducible}
          | {:error, term()}

  @type entry :: %{job_id: String.t(), job_name: String.t(), outcome: outcome()}

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case run() do
      {:ok, report} ->
        Logger.info("Mapper job SNMP credential backfill finished: #{inspect(summarize(report))}")
        :ok

      {:error, report} ->
        Logger.warning(
          "Mapper job SNMP credential backfill incomplete: #{inspect(summarize(report))}"
        )

        {:error, :mapper_job_snmp_credential_backfill_incomplete}
    end
  end

  @doc "What `run/0` would do for each marked job, without writing anything."
  @spec plan() :: {:ok, [entry()]} | {:error, [entry()] | term()}
  def plan, do: process(false)

  @doc "Binds every marked job and clears its mark."
  @spec run() :: {:ok, [entry()]} | {:error, [entry()] | term()}
  def run, do: process(true)

  defp process(apply?) do
    actor = SystemActor.system(:mapper_job_snmp_credential_backfill)

    with {:ok, jobs} <- marked_jobs(actor),
         {:ok, agents} <- registered_agents(jobs, actor) do
      report =
        Enum.map(jobs, fn job ->
          %{
            job_id: to_string(job.id),
            job_name: job.name,
            outcome: process_job(job, agents, actor, apply?)
          }
        end)

      if Enum.any?(report, &match?(%{outcome: {:error, _}}, &1)),
        do: {:error, report},
        else: {:ok, report}
    end
  end

  defp marked_jobs(actor) do
    MapperJob
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(snmp_credential_backfill_pending == true)
    |> Ash.Query.sort(name: :asc)
    |> Ash.read(actor: actor)
  end

  # Agents are read only when a partition-assigned job needs them. These are the
  # persisted rows, not the live registry, which is empty until gateways sync
  # after boot. An agent's partition is the one AgentAssignment validates jobs
  # against.
  defp registered_agents(jobs, actor) do
    if Enum.any?(jobs, &(needs_binding?(&1) and is_nil(&1.agent_id))) do
      Agent
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.select([:uid, :device_uid, :metadata, :status])
      |> Ash.read(actor: actor)
    else
      {:ok, []}
    end
  end

  defp needs_binding?(job),
    do: job.discovery_mode in [:snmp, :snmp_api] and is_nil(job.snmp_credential_secret_id)

  defp process_job(job, agents, actor, apply?) do
    if needs_binding?(job) do
      with {:ok, contexts} <- agent_contexts(job, agents, actor),
           {:ok, decision} <- legacy_decision(job, contexts, actor) do
        apply_decision(job, decision, actor, apply?)
      end
    else
      finish(job, nil, :not_needed, actor, apply?)
    end
  end

  defp agent_contexts(%{agent_id: agent_id} = job, _agents, actor) when is_binary(agent_id) do
    case Agent.get_by_uid(agent_id, actor: actor) do
      {:ok, %Agent{device_uid: device_uid}} -> {:ok, [{agent_id, job.partition, device_uid}]}
      {:ok, nil} -> {:error, {:agent_not_registered, agent_id}}
      {:error, %Invalid{}} -> {:error, {:agent_not_registered, agent_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Without the agents the job compiled for, the old chain cannot be replayed:
  # that is a failure to retry, not an agreed absence of a credential.
  defp agent_contexts(job, agents, _actor) do
    # A superseded agent row stays behind with its partition, but it never
    # receives mapper config, so its credentials never reached the job.
    case Enum.filter(agents, &(&1.status != :superseded and agent_partition(&1) == job.partition)) do
      [] -> {:error, {:no_registered_agents, job.partition}}
      matching -> {:ok, Enum.map(matching, &{&1.uid, job.partition, &1.device_uid})}
    end
  end

  defp agent_partition(agent), do: Map.get(agent.metadata || %{}, "partition_id") || "default"

  # Each agent context yields the mapper credential the pre-change compile
  # delivered, or nil. One read failure fails the job.
  defp legacy_decision(job, contexts, actor) do
    contexts
    |> Enum.reduce_while({:ok, []}, fn context, {:ok, acc} ->
      case legacy_resolution(job, context, actor) do
        {:ok, resolution} -> {:cont, {:ok, [resolution | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, resolutions} -> {:ok, agree(Enum.reverse(resolutions))}
      error -> error
    end
  end

  defp agree([%{encoded: encoded} = first | rest]) do
    cond do
      encoded == %{} -> {:unbound, :no_legacy_credential}
      Enum.all?(rest, &(&1.encoded == encoded)) -> {:bind, first}
      true -> {:unbound, :agents_disagree}
    end
  end

  defp legacy_resolution(job, {agent_id, partition, device_uid}, actor) do
    scope = [agent_id: agent_id, partition: partition]

    host =
      case CredentialResolver.resolve_for_device(device_uid, actor, scope) do
        {:ok, %{credential: credential} = resolution} when is_map(credential) ->
          {:ok, resolution}

        {:ok, _no_credential} ->
          :none

        {:error, reason} ->
          if CredentialResolver.credential_read_failure?(reason),
            do: {:error, reason},
            else: :none
      end

    case host do
      {:ok, resolution} -> encode(resolution)
      :none -> legacy_default(job, scope, actor)
      {:error, reason} -> {:error, reason}
    end
  end

  # The removed `CredentialResolver.resolve_default/2`: the first rule scoped to
  # the agent or partition, whatever its target query, else the default profile.
  defp legacy_default(job, scope, actor) do
    with {:ok, rules} <- monitoring_rules(scope, actor) do
      case rules do
        [rule | _] when is_binary(rule.secret_id) ->
          %{version: rule_version(rule), credential_secret_id: rule.secret_id, id: rule.id}
          |> CredentialResolver.build_credential(actor, backfill_audit(job))
          |> resolution_from(rule)

        _no_usable_rule ->
          default_profile_resolution(job, actor)
      end
    end
  end

  defp monitoring_rules(scope, actor) do
    scope
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Enum.map(fn
      {:agent_id, value} -> {:agent, value}
      {:partition, value} -> {:partition, value}
    end)
    |> Enum.reduce_while({:ok, []}, fn {scope_type, value}, {:ok, acc} ->
      case NetworkCredentialRule.list_enabled_for_scope("snmp", scope_type, value, actor: actor) do
        {:ok, rules} -> {:cont, {:ok, acc ++ rules}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rules} ->
        {:ok, Enum.filter(rules, &(to_string(&1.purpose || "") in ["", "snmp_monitoring"]))}

      error ->
        error
    end
  end

  defp rule_version(rule), do: if(to_string(rule.auth_method) == "v3", do: :v3, else: :v2c)

  defp default_profile_resolution(job, actor) do
    case SNMPProfile
         |> Ash.Query.for_read(:get_default, %{})
         |> Ash.read_one(actor: actor) do
      {:ok, nil} ->
        {:ok, %{encoded: %{}}}

      {:ok, profile} ->
        profile
        |> CredentialResolver.build_credential(actor, backfill_audit(job))
        |> resolution_from(profile)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolution_from({:error, reason}, _source) do
    if CredentialResolver.credential_read_failure?(reason),
      do: {:error, reason},
      else: {:ok, %{encoded: %{}}}
  end

  defp resolution_from(credential, source) when is_map(credential),
    do: encode(%{credential: credential, source_record: source})

  defp resolution_from(_none, _source), do: {:ok, %{encoded: %{}}}

  # The pre-change compile delivered `to_mapper_credentials/1` of the resolved
  # credential; one it could not encode failed that compile, and one with
  # neither community nor username was skipped for the bare v2c fallback, so
  # both count as no credential.
  defp encode(%{credential: credential, source_record: source}) do
    case CredentialResolver.to_mapper_credentials(credential) do
      {:ok, encoded} ->
        if usable?(encoded),
          do: {:ok, %{encoded: encoded, credential: credential, source_record: source}},
          else: {:ok, %{encoded: %{}}}

      _ ->
        {:ok, %{encoded: %{}}}
    end
  end

  defp usable?(encoded), do: Enum.any?(["community", "username"], &present?(Map.get(encoded, &1)))

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp apply_decision(job, {:unbound, _reason} = outcome, actor, apply?),
    do: finish(job, nil, outcome, actor, apply?)

  defp apply_decision(job, {:bind, resolution}, actor, apply?) do
    secret_id = source_secret_id(resolution.source_record)

    with {:ok, reproduces?} <- reproduces?(job, secret_id, resolution.encoded, actor) do
      how =
        cond do
          reproduces? -> :existing
          is_nil(secret_id) and inline_source?(resolution.source_record) -> :promote
          true -> :copy
        end

      if apply?, do: bind(job, how, secret_id, resolution, actor), else: {:bind, how}
    end
  end

  defp bind(job, :existing, secret_id, _resolution, actor),
    do: finish(job, secret_id, {:bound, secret_id, :existing}, actor, true)

  # Creating the credential, rebinding its source and binding the job commit
  # together. A retry after a failure therefore finds the source still inline
  # and promotes it once, never leaving two copies of one credential.
  defp bind(job, how, _secret_id, resolution, actor) do
    fn ->
      with {:ok, secret} <- create_credential(job, how, resolution, actor),
           {:ok, true} <- reproduces?(job, secret.id, resolution.encoded, actor),
           :ok <- maybe_rebind_source(how, resolution.source_record, secret.id, actor) do
        outcome = if how == :promote, do: :promoted, else: :copied

        case finish(job, secret.id, {:bound, secret.id, outcome}, actor, true) do
          {:error, reason} -> Repo.rollback(reason)
          bound -> bound
        end
      else
        {:ok, false} -> Repo.rollback(:not_reproducible)
        {:error, reason} -> Repo.rollback(reason)
      end
    end
    |> Repo.transaction()
    |> case do
      {:ok, outcome} -> outcome
      {:error, :not_reproducible} -> finish(job, nil, {:unbound, :not_reproducible}, actor, true)
      {:error, reason} -> {:error, reason}
    end
  end

  defp reproduces?(_job, nil, _encoded, _actor), do: {:ok, false}

  defp reproduces?(job, secret_id, encoded, actor) do
    case CredentialResolver.build_credential(
           %{version: nil, credential_secret_id: secret_id},
           actor,
           backfill_audit(job)
         ) do
      {:error, reason} ->
        if CredentialResolver.credential_read_failure?(reason),
          do: {:error, reason},
          else: {:ok, false}

      credential when is_map(credential) ->
        {:ok, CredentialResolver.to_mapper_credentials(credential) == {:ok, encoded}}

      _none ->
        {:ok, false}
    end
  end

  defp source_secret_id(%NetworkCredentialRule{secret_id: id}), do: id
  defp source_secret_id(%{credential_secret_id: id}) when is_binary(id), do: id
  defp source_secret_id(_source), do: nil

  defp inline_source?(%SNMPProfile{}), do: true
  defp inline_source?(%DeviceSNMPCredential{}), do: true
  defp inline_source?(_source), do: false

  defp create_credential(job, how, %{credential: credential}, actor) do
    {name, description} =
      case how do
        :promote ->
          {"#{job.name} SNMP credential",
           "Promoted from inline SNMP material when mapper jobs gained their own SNMP credential"}

        :copy ->
          {"#{job.name} SNMP discovery credential",
           "Copied from the SNMP credential mapper discovery used before jobs gained their own"}
      end

    ReusableCredential.create(credential.version, name, credential_fields(credential),
      description: description,
      actor: actor
    )
  end

  # A community credential has only its community string; an SNMPv3 credential
  # carries its level explicitly, so the copy keeps the level the old compile
  # delivered instead of re-inferring it.
  defp credential_fields(%{version: version} = credential) when version in [:v1, :v2c],
    do: Map.take(credential, [:community])

  defp credential_fields(credential),
    do:
      Map.take(credential, [
        :username,
        :security_level,
        :auth_protocol,
        :auth_password,
        :priv_protocol,
        :priv_password
      ])

  defp maybe_rebind_source(:promote, source, secret_id, actor) do
    source
    |> Ash.Changeset.for_update(:update, %{credential_secret_id: secret_id}, actor: actor)
    |> Ash.update(actor: actor)
    |> case do
      {:ok, _source} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_rebind_source(_how, _source, _secret_id, _actor), do: :ok

  defp finish(job, secret_id, outcome, actor, true) do
    params = if secret_id, do: %{snmp_credential_secret_id: secret_id}, else: %{}

    # Compare-and-set against the credential this run read. A job changed since
    # (an operator bound or cleared it) records no decision: it stays marked and
    # fails the run, so the retry re-reads it.
    job
    |> Ash.Changeset.for_update(:complete_snmp_credential_backfill, params, actor: actor)
    |> Ash.Changeset.filter(unchanged_since_read(job))
    |> Ash.update(actor: actor)
    |> case do
      {:ok, _job} ->
        outcome

      {:error, %Invalid{errors: [%Ash.Error.Changes.StaleRecord{} | _]}} ->
        {:error, :changed_since_read}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finish(_job, _secret_id, outcome, _actor, false), do: outcome

  defp unchanged_since_read(%{snmp_credential_secret_id: nil}),
    do: expr(snmp_credential_backfill_pending == true and is_nil(snmp_credential_secret_id))

  defp unchanged_since_read(%{snmp_credential_secret_id: secret_id}),
    do: expr(snmp_credential_backfill_pending == true and snmp_credential_secret_id == ^secret_id)

  defp backfill_audit(job) do
    [
      consumer_id: "mapper_job:#{job.id}",
      target_kind: "mapper_job",
      target_id: to_string(job.id),
      purpose: "mapper_discovery_backfill"
    ]
  end

  defp summarize(report) when is_list(report),
    do: Enum.frequencies_by(report, &outcome_kind(&1.outcome))

  defp summarize(other), do: other

  defp outcome_kind({kind, _}), do: kind
  defp outcome_kind({kind, _, how}), do: {kind, how}
  defp outcome_kind(kind), do: kind
end
