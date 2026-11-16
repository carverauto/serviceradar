defmodule ServiceRadar.SNMPProfiles.SNMPTargetCredentialBackfillWorker do
  @moduledoc """
  One-off backfill of explicit SNMP targets' credentials, enqueued once by
  migration `20261116060000_backfill_snmp_target_credentials`
  (`remove-snmp-unbound-host-rule-fallback`).

  Before that change, an explicit target whose host belongs to no device was
  polled with the first enabled SNMP monitoring rule scoped to the compiling
  agent or its partition, whatever that rule's target query. Now no rule applies
  to such a target: it is polled with its own credential or not at all.

  A target with a credential of its own is left alone; it is now polled with
  what was configured for it. A target with none, on a host no device holds,
  was polled only through that rule. This worker binds such a target to the
  rule's reusable credential when every agent compiling the target's profile
  chose a rule with that credential, and the target then resolves to exactly
  the credential the rule delivered. Every other target is left without a
  credential, which the compiler reports. A target that already has a
  credential when the write lands is not changed.

  `plan/0` reports what `run/0` would do without writing anything; from a
  release, `bin/serviceradar_core eval
  'ServiceRadar.SNMPProfiles.SNMPTargetCredentialBackfillWorker.plan() |> IO.inspect()'`.
  The worker can be deleted once every deployment has run it.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 20

  import Ash.Expr

  alias Ash.Error.Invalid
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentConfig.Compilers.SNMPCompiler
  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.SNMPProfiles.CredentialResolver
  alias ServiceRadar.SNMPProfiles.SNMPTarget

  require Ash.Query
  require Logger

  @type outcome ::
          :not_needed
          | {:bind, String.t()}
          | {:bound, String.t()}
          | {:unbound,
             :not_compiled | :no_legacy_credential | :agents_disagree | :not_reproducible}
          | {:error, term()}

  @type entry :: %{target_id: String.t(), target_name: String.t(), outcome: outcome()}

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case run() do
      {:ok, report} ->
        Logger.info("SNMP target credential backfill finished: #{inspect(summarize(report))}")
        :ok

      {:error, report} ->
        Logger.warning(
          "SNMP target credential backfill incomplete: #{inspect(summarize(report))}"
        )

        {:error, :snmp_target_credential_backfill_incomplete}
    end
  end

  @doc "What `run/0` would do for each target without a credential, writing nothing."
  @spec plan() :: {:ok, [entry()]} | {:error, [entry()] | term()}
  def plan, do: process(false)

  @doc "Binds every target the old rule fallback alone kept polling."
  @spec run() :: {:ok, [entry()]} | {:error, [entry()] | term()}
  def run, do: process(true)

  defp process(apply?) do
    actor = SystemActor.system(:snmp_target_credential_backfill)

    with {:ok, targets} <- targets_without_credential(actor),
         {:ok, unbound} <- unbound_target_ids(targets, actor),
         {:ok, agents} <- compiling_agents(unbound, actor) do
      report =
        Enum.map(targets, fn target ->
          %{
            target_id: to_string(target.id),
            target_name: target.name,
            outcome: decide(target, unbound, agents, actor, apply?)
          }
        end)

      if Enum.any?(report, &match?(%{outcome: {:error, _}}, &1)),
        do: {:error, report},
        else: {:ok, report}
    end
  end

  defp targets_without_credential(actor) do
    SNMPTarget
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.sort(name: :asc, id: :asc)
    |> Ash.read(actor: actor)
    |> Page.unwrap()
    |> case do
      {:ok, targets} -> {:ok, Enum.reject(targets, &CredentialResolver.record_has_credential?/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  # The targets whose host belongs to no device: the only ones the old
  # fallback reached.
  defp unbound_target_ids(targets, actor) do
    targets
    |> Enum.filter(&is_binary(&1.host))
    |> Enum.reduce_while({:ok, MapSet.new()}, fn target, {:ok, unbound} ->
      case CredentialResolver.device_uid_for_host(target.host, actor) do
        {:ok, _device_uid} -> {:cont, {:ok, unbound}}
        {:error, :device_not_found} -> {:cont, {:ok, MapSet.put(unbound, target.id)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Each registered agent with the profile it compiles, as the agent config
  # generator selects it: from the device hosting the agent. These are the
  # persisted agent rows, not the live registry, which is empty until gateways
  # sync after boot; a superseded row never receives config. Read only when a
  # target needs them.
  defp compiling_agents(unbound, actor) do
    if MapSet.size(unbound) == 0, do: {:ok, []}, else: read_compiling_agents(actor)
  end

  defp read_compiling_agents(actor) do
    with {:ok, agents} <- registered_agents(actor) do
      agents
      |> Enum.reject(&(&1.status == :superseded))
      |> Enum.reduce_while({:ok, []}, fn agent, {:ok, acc} ->
        case SNMPCompiler.fetch_profile(agent.device_uid, agent.uid, actor) do
          {:ok, %{enabled: true, id: profile_id}} ->
            {:cont, {:ok, [%{agent: agent, profile_id: profile_id} | acc]}}

          {:ok, _no_enabled_profile} ->
            {:cont, {:ok, acc}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    end
  end

  # The agent read is paginated by default; streaming follows the cursor, so no
  # agent past the first page is missed.
  defp registered_agents(actor) do
    {:ok,
     Agent
     |> Ash.Query.for_read(:read, %{}, actor: actor)
     |> Ash.Query.select([:uid, :device_uid, :metadata, :status])
     |> Ash.Query.sort(uid: :asc)
     |> Page.stream!(actor: actor)
     |> Enum.to_list()}
  rescue
    error -> {:error, error}
  end

  # A target on a host that belongs to a device was never reached by the
  # fallback: a rule whose target query selects that device still applies.
  defp decide(target, unbound, agents, actor, apply?) do
    if MapSet.member?(unbound, target.id),
      do: decide_unbound(target, agents, actor, apply?),
      else: :not_needed
  end

  defp decide_unbound(target, agents, actor, apply?) do
    case Enum.filter(agents, &(&1.profile_id == target.snmp_profile_id)) do
      [] ->
        {:unbound, :not_compiled}

      compiling ->
        with {:ok, rules} <- legacy_rules(compiling, actor),
             {:ok, rule} <- agree(rules),
             {:ok, version} <- reproducible_version(target, rule, actor) do
          if apply?,
            do: bind(target, rule.secret_id, version, actor),
            else: {:bind, rule.secret_id}
        end
    end
  end

  # The rule the old fallback took for each agent: the first enabled SNMP
  # monitoring rule scoped to the agent, then to its partition, in priority order.
  defp legacy_rules(compiling, actor) do
    Enum.reduce_while(compiling, {:ok, []}, fn %{agent: agent}, {:ok, acc} ->
      case first_scoped_rule(agent, actor) do
        {:ok, rule} -> {:cont, {:ok, [rule | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp first_scoped_rule(agent, actor) do
    [{:agent, agent.uid}, {:partition, agent_partition(agent)}]
    |> Enum.reject(fn {_type, value} -> value in [nil, ""] end)
    |> Enum.reduce_while({:ok, []}, fn {scope_type, value}, {:ok, acc} ->
      case NetworkCredentialRule.list_enabled_for_scope("snmp", scope_type, value, actor: actor) do
        {:ok, rules} -> {:cont, {:ok, acc ++ rules}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rules} ->
        {:ok, Enum.find(rules, &(to_string(&1.purpose || "") in ["", "snmp_monitoring"]))}

      error ->
        error
    end
  end

  defp agent_partition(agent), do: Map.get(agent.metadata || %{}, "partition_id") || "default"

  # A first rule without a secret delivered no credential.
  defp agree(rules) do
    keys = Enum.map(rules, &rule_key/1)

    cond do
      Enum.all?(keys, &is_nil/1) -> {:unbound, :no_legacy_credential}
      match?([_], Enum.uniq(keys)) -> {:ok, Enum.find(rules, &rule_key/1)}
      true -> {:unbound, :agents_disagree}
    end
  end

  defp rule_key(%{secret_id: secret_id} = rule) when is_binary(secret_id),
    do: {secret_id, rule_version(rule)}

  defp rule_key(_rule), do: nil

  defp rule_version(rule), do: if(to_string(rule.auth_method) == "v3", do: :v3, else: :v2c)

  # The target bound to the rule's credential, with the rule's version, must
  # resolve to the credential the rule delivered; fields stored on the target
  # could otherwise change it.
  defp reproducible_version(target, rule, actor) do
    version = rule_version(rule)
    audit = backfill_audit(target)

    legacy =
      CredentialResolver.build_credential(
        %{version: version, credential_secret_id: rule.secret_id, id: rule.id},
        actor,
        audit
      )

    bound =
      CredentialResolver.build_credential(
        %{target | credential_secret_id: rule.secret_id, version: version},
        actor,
        audit
      )

    cond do
      read_failure(legacy) -> legacy
      read_failure(bound) -> bound
      is_map(legacy) and legacy == bound -> {:ok, version}
      true -> {:unbound, :not_reproducible}
    end
  end

  defp read_failure({:error, reason}), do: CredentialResolver.credential_read_failure?(reason)
  defp read_failure(_credential), do: false

  # Compare-and-set: the write applies only while the target still has no
  # credential, so a credential configured since the read is never replaced.
  defp bind(target, secret_id, version, actor) do
    target
    |> Ash.Changeset.for_update(:update, %{credential_secret_id: secret_id, version: version},
      actor: actor
    )
    |> Ash.Changeset.filter(
      expr(
        is_nil(credential_secret_id) and is_nil(community_encrypted) and
          is_nil(auth_password_encrypted) and (is_nil(username) or username == "")
      )
    )
    |> Ash.update(actor: actor)
    |> case do
      {:ok, _target} -> {:bound, secret_id}
      {:error, %Invalid{errors: [%Ash.Error.Changes.StaleRecord{} | _]}} -> :not_needed
      {:error, reason} -> {:error, reason}
    end
  end

  defp backfill_audit(target) do
    [
      consumer_id: "snmp_target:#{target.id}",
      target_kind: "snmp_target",
      target_id: to_string(target.id),
      purpose: "snmp_target_credential_backfill"
    ]
  end

  defp summarize(report) when is_list(report),
    do: Enum.frequencies_by(report, &outcome_kind(&1.outcome))

  defp summarize(other), do: other

  defp outcome_kind({:unbound, reason}), do: {:unbound, reason}
  defp outcome_kind({kind, _}), do: kind
  defp outcome_kind(kind), do: kind
end
