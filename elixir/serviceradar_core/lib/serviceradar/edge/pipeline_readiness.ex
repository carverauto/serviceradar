defmodule ServiceRadar.Edge.PipelineReadiness do
  @moduledoc """
  Why an agent would be off the durable edge-record pipeline: the read-only edge pipeline
  readiness report, and the per-agent edge pipeline conditions it is built from.

  Every condition is derived on read from state core already holds. Nothing here writes, and
  nothing here changes an agent, grant, lease or data path. A ready agent has no condition.

    * `:partition_not_found` - the agent's partition has no partition row, so core issues it
      no standing grant and leases it no sweep. The partition is the authenticated one the
      gateway recorded on the agent (`metadata.partition_id`), else the one its live check-in
      reports, else its device's, else `"default"` (a check-in with no partition is in
      `"default"`). Core never creates a partition from an agent's claim, so the condition
      clears when an operator creates that partition. Detail: `partition`.
    * `:agent_disconnected` - no connected core node's agent tracker has seen the agent within
      the tracker's stale window.
    * `:agent_upgrade_blocked` - the agent release rollout cannot deliver a new agent build to
      the agent. Detail `cause`:
        * `:rollout_paused` - the agent is an unfinished target of a paused rollout;
        * `:no_published_release` - no agent release is published;
        * `:no_release_artifact` - the newest published release (detail `release`) carries no
          enabled artifact for the agent's platform (detail `platform`).

      An agent that runs from a container image (Kubernetes, Docker or another container
      runtime) is upgraded with its image, not by the release rollout, so it is never blocked
      here. A disconnected agent's platform is not known, so it is reported only as
      `:agent_disconnected`.

    * `:spool_unavailable` - spool opening failed or recovery is waiting on required
      authority or capacity. Detail: `error`, plus `health` when the open spool was sampled
      successfully. Unavailability alone does not imply a coverage gap.
    * `:no_live_gateway_on_active_epoch` - the agent is connected through a live
      gateway, an epoch is active, but no installation report within the
      freshness window shows that gateway holding the active epoch, so the
      agent's records cannot be admitted under it. Detail: `epoch`, the active
      epoch number, and `gateway_id`, the agent's live gateway.
    * `:spool_wedged` - allocated coverage gaps block durable delivery. Detail includes
      the bounded gap sequence sample, total gaps, unresolved count/age and byte budget.
    * `:spool_backpressure` - the runtime admission gate paused bulk producers, or the spool
      reached its byte budget or holds more than 1 GiB of unresolved records.
    * `:spool_stuck` - the spool holds unresolved records older than 15 minutes.
    * `:spool_health_unavailable` - the spool opened but its live health read failed.
    * `:agent_upgrade_pending` - the agent runs a build from before the edge-record cutover:
      its last check-in carried no spool status, or it still sends durable data on the retired
      status RPCs, which the gateway refuses and counts in its agent tracker. Detail: `version`,
      and, when the gateway refused retired-source data, `refused_statuses` (count by source
      family) and `last_refused_at`.
    * `:oversized_summary` - the gateway refused status summaries from the agent because they
      exceeded its summary size limit (`ServiceRadarAgentGateway.RetiredStatusSources`). Any
      build can send one, so this says nothing about the agent's version, and the agent's edge
      records still flow; the summaries themselves are not stored. Detail: `count`, the
      refused summaries; `summaries`, each refusing service's largest summary as
      `%{service => %{bytes: bytes, limit: limit}}`; and `last_refused_at`.

  Spool health, pending upgrades and oversized summaries come from the agent's last
  check-in (`metadata.edge_record_spool`, which the gateway records from the hello)
  and the live tracker entry, so they are reported for connected agents only.

  Superseded agent identities are left out: they have been replaced and produce nothing.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentRuntimeMetadata
  alias ServiceRadar.Edge.AgentRelease
  alias ServiceRadar.Edge.AgentReleaseManager
  alias ServiceRadar.Edge.AgentReleaseTarget
  alias ServiceRadar.Edge.ContractRegistry
  alias ServiceRadar.Edge.ContractRegistryTransition
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Infrastructure.Partition

  require Ash.Query

  @default_partition "default"
  # Deployment types the agent reports (`go/pkg/agent/push_loop_deployment.go`) whose binary
  # comes from an image rather than a package the release rollout replaces.
  @image_deployment_types ~w(kubernetes docker container)
  @finished_target_statuses [:healthy, :failed, :rolled_back, :canceled]
  # The gateway's refusal family for a summary over its size limit.
  @oversized_family "oversized_summary"
  @rpc_timeout_ms 5_000
  @max_unresolved_age_seconds 900
  @max_unresolved_bytes 1_073_741_824

  @type reason ::
          :partition_not_found
          | :agent_disconnected
          | :agent_upgrade_blocked
          | :spool_unavailable
          | :unsupported_legacy_storage
          | :no_live_gateway_on_active_epoch
          | :spool_wedged
          | :spool_backpressure
          | :spool_stuck
          | :spool_health_unavailable
          | :agent_upgrade_pending
          | :oversized_summary
  @type condition :: %{reason: reason(), detail: map()}
  @type entry :: %{
          agent_id: String.t(),
          name: String.t() | nil,
          partition: String.t(),
          conditions: [condition(), ...]
        }
  @type facts :: %{
          required(:partitions) => MapSet.t(String.t()),
          required(:runtime) => %{String.t() => map()},
          required(:release) => AgentRelease.t() | nil,
          required(:paused_agent_ids) => MapSet.t(String.t()),
          optional(:active_epoch) => {:ok, map()} | {:error, term()},
          optional(:gateway_epochs) => %{String.t() => MapSet.t(integer())}
        }

  @doc """
  The readiness report: every agent with at least one condition, sorted by agent id. An empty
  list means every agent is ready.
  """
  @spec report() :: {:ok, [entry()]} | {:error, term()}
  def report do
    with {:ok, agents} <- read_agents(),
         {:ok, facts} <- facts() do
      {:ok,
       agents
       |> Enum.map(&entry(&1, facts))
       |> Enum.reject(&(&1.conditions == []))
       |> Enum.sort_by(& &1.agent_id)}
    end
  end

  @doc """
  The installation state the conditions are evaluated against: partition slugs, the live
  agent tracker entries of every connected core node, the newest published agent release, the
  agents waiting in a paused rollout, the active epoch and, while one is active, the epochs each
  gateway's fresh installation report holds. An unreadable node tracker is
  `{:error, :agent_tracker_unavailable}`, not an agent reported as disconnected, and unreadable
  gateway reports are `{:error, :gateway_reports_unavailable}`, not gateways reported as not
  holding the epoch.
  """
  @spec facts() :: {:ok, facts()} | {:error, term()}
  def facts do
    active_epoch = ContractRegistry.active_epoch()

    with {:ok, partitions} <- Ash.read(Partition, actor: actor()),
         {:ok, release} <- newest_release(),
         {:ok, paused} <- paused_agent_ids(),
         {:ok, runtime} <- AgentRuntimeMetadata.runtime_agents(),
         {:ok, gateway_epochs} <- gateway_epochs(active_epoch, DateTime.utc_now()) do
      {:ok,
       %{
         partitions: MapSet.new(partitions, & &1.slug),
         runtime: runtime,
         release: release,
         paused_agent_ids: paused,
         active_epoch: active_epoch,
         gateway_epochs: gateway_epochs
       }}
    end
  end

  # What each gateway holds right now: the epochs of its installation report, when the report
  # is fresh by the transition's window, read from the coordinator, whose table is the one the
  # transition decides activation from.
  defp gateway_epochs({:ok, _active}, now) do
    with {:ok, reports} <- registry_gateway_reports() do
      {:ok,
       reports
       |> ContractRegistryTransition.fresh_reports(now)
       |> Map.new(fn {id, report} -> {id, MapSet.new(report.installed, & &1.epoch)} end)}
    end
  end

  defp gateway_epochs(_no_active_epoch, _now), do: {:ok, %{}}

  defp registry_gateway_reports do
    nodes = [node() | Node.list()]

    nodes
    |> Enum.zip(
      :erpc.multicall(nodes, :erlang, :whereis, [ContractRegistryTransition], @rpc_timeout_ms)
    )
    |> Enum.find_value({:error, :gateway_reports_unavailable}, fn
      {node, {:ok, pid}} when is_pid(pid) -> transition_reports(node)
      _not_the_coordinator -> nil
    end)
  end

  defp transition_reports(node) do
    case :erpc.multicall([node], ContractRegistry, :gateway_reports, [], @rpc_timeout_ms) do
      [{:ok, reports}] when is_list(reports) -> {:ok, reports}
      _unreachable -> {:error, :gateway_reports_unavailable}
    end
  end

  @doc """
  The conditions of one agent under `facts`. The agent's `device` is read for its partition
  when it is loaded.
  """
  @spec conditions(Agent.t(), facts()) :: [condition()]
  def conditions(%Agent{status: :superseded}, _facts), do: []

  def conditions(%Agent{} = agent, facts) do
    runtime = live_runtime(Map.get(facts.runtime, agent.uid))

    partition_conditions(partition(agent, runtime), facts) ++
      connection_conditions(agent, runtime, facts)
  end

  @doc "The partition slug an agent's records are written under (see the moduledoc)."
  @spec partition(Agent.t(), map() | nil) :: String.t()
  def partition(%Agent{} = agent, runtime) do
    recorded_partition(agent) || present(runtime && runtime[:partition]) ||
      device_partition(agent) || @default_partition
  end

  defp entry(agent, facts) do
    runtime = live_runtime(Map.get(facts.runtime, agent.uid))

    %{
      agent_id: agent.uid,
      name: agent.name,
      partition: partition(agent, runtime),
      conditions: conditions(agent, facts)
    }
  end

  defp partition_conditions(partition, facts) do
    if MapSet.member?(facts.partitions, partition) do
      []
    else
      [%{reason: :partition_not_found, detail: %{partition: partition}}]
    end
  end

  defp connection_conditions(_agent, nil, _facts),
    do: [%{reason: :agent_disconnected, detail: %{}}]

  defp connection_conditions(agent, runtime, facts) do
    spool_conditions(agent, runtime) ++
      gateway_conditions(runtime, facts) ++
      if present(runtime[:deployment_type]) in @image_deployment_types do
        []
      else
        upgrade_conditions(agent, runtime, facts)
      end
  end

  # The agent's live gateway holds the active epoch, or its records cannot be
  # admitted under it. Only reported when an epoch is active and the gateway
  # is known; anything else is not attributable to this gateway.
  defp gateway_conditions(runtime, facts) do
    with %{epoch: epoch} <- active_epoch(facts),
         gateway_id when is_binary(gateway_id) <- present(runtime[:gateway_id]),
         false <- holds_epoch?(facts, gateway_id, epoch) do
      [
        %{
          reason: :no_live_gateway_on_active_epoch,
          detail: %{epoch: epoch, gateway_id: gateway_id}
        }
      ]
    else
      _attributed -> []
    end
  end

  defp active_epoch(%{active_epoch: {:ok, %{epoch: epoch}}}), do: %{epoch: epoch}
  defp active_epoch(_facts), do: nil

  defp holds_epoch?(facts, gateway_id, epoch) do
    facts
    |> Map.get(:gateway_epochs, %{})
    |> Map.get(gateway_id, MapSet.new())
    |> MapSet.member?(epoch)
  end

  defp spool_conditions(agent, runtime) do
    refused = refused_detail(runtime)

    upgrade =
      case runtime[:edge_record_spool] || recorded_spool(agent) do
        nil -> [upgrade_pending(agent, refused)]
        spool -> spool_status_conditions(spool) ++ refused_conditions(agent, refused)
      end

    upgrade ++ oversized_conditions(runtime)
  end

  defp refused_conditions(_agent, refused) when map_size(refused) == 0, do: []
  defp refused_conditions(agent, refused), do: [upgrade_pending(agent, refused)]

  defp upgrade_pending(agent, refused),
    do: %{reason: :agent_upgrade_pending, detail: Map.put(refused, :version, agent.version)}

  # Only retired sources say the agent predates the cutover; an oversized summary does not.
  defp refused_detail(runtime) do
    case Map.delete(runtime[:refused_statuses] || %{}, @oversized_family) do
      counts when map_size(counts) > 0 ->
        %{refused_statuses: counts, last_refused_at: runtime[:last_refused_at]}

      _none ->
        %{}
    end
  end

  defp oversized_conditions(runtime) do
    case runtime[:refused_statuses] do
      %{@oversized_family => count} ->
        [
          %{
            reason: :oversized_summary,
            detail: %{
              count: count,
              summaries: runtime[:oversized_summaries] || %{},
              last_refused_at: runtime[:last_refused_at]
            }
          }
        ]

      _none ->
        []
    end
  end

  # The gateway's map, with atom keys until the row is read back from jsonb.
  defp recorded_spool(%Agent{metadata: %{} = metadata}) do
    case Map.get(metadata, "edge_record_spool") || Map.get(metadata, :edge_record_spool) do
      %{} = spool -> spool
      _ -> nil
    end
  end

  defp recorded_spool(_agent), do: nil

  @doc """
  Returns the spool conditions that represent an unhealthy bounded spool on a live agent.
  Unsupported retained flat storage is excluded so it remains visible in the readiness report
  without holding an open spool alert forever.
  """
  @spec spool_alert_conditions(map()) :: [condition()]
  def spool_alert_conditions(%{} = spool) do
    Enum.reject(spool_status_conditions(spool), &(&1.reason == :unsupported_legacy_storage))
  end

  defp spool_status_conditions(spool) do
    if (Map.get(spool, "available") || Map.get(spool, :available)) == true do
      retained =
        if (spool_field(spool, :retained_legacy_bytes) || 0) > 0,
          do: [%{reason: :unsupported_legacy_storage, detail: spool}],
          else: []

      retained ++ spool_health_conditions(spool)
    else
      error = Map.get(spool, "error") || Map.get(spool, :error)
      detail = %{error: present(error)}

      detail =
        if spool_field(spool, :health_available) == true,
          do: Map.put(detail, :health, spool),
          else: detail

      [%{reason: :spool_unavailable, detail: detail}]
    end
  end

  defp spool_health_conditions(spool) do
    cond do
      spool_field(spool, :wedged) == true ->
        [%{reason: :spool_wedged, detail: spool}]

      present(spool_field(spool, :health_error)) ->
        [%{reason: :spool_health_unavailable, detail: spool}]

      spool_backpressured?(spool) ->
        [%{reason: :spool_backpressure, detail: spool}]

      spool_stuck?(spool) ->
        [%{reason: :spool_stuck, detail: spool}]

      true ->
        []
    end
  end

  defp spool_backpressured?(spool) do
    unresolved_bytes = spool_field(spool, :unresolved_bytes)
    bytes_used = spool_field(spool, :bytes_used)
    budget_bytes = spool_field(spool, :budget_bytes)

    spool_field(spool, :admission_paused) == true or
      (is_integer(unresolved_bytes) and unresolved_bytes > @max_unresolved_bytes) or
      (is_integer(bytes_used) and is_integer(budget_bytes) and budget_bytes > 0 and
         bytes_used >= budget_bytes)
  end

  defp spool_stuck?(spool) do
    age = spool_field(spool, :oldest_unresolved_age_seconds)

    spool_field(spool, :oldest_unresolved_age_known) == true and
      is_integer(age) and age > @max_unresolved_age_seconds
  end

  defp spool_field(spool, key), do: Map.get(spool, Atom.to_string(key), Map.get(spool, key))

  defp upgrade_conditions(agent, runtime, facts) do
    cond do
      MapSet.member?(facts.paused_agent_ids, agent.uid) ->
        [blocked(%{cause: :rollout_paused})]

      is_nil(facts.release) ->
        [blocked(%{cause: :no_published_release})]

      true ->
        artifact_conditions(facts.release, present(runtime[:os]), present(runtime[:arch]))
    end
  end

  defp artifact_conditions(release, os, arch) do
    case AgentReleaseManager.artifact_for_platform(release, os, arch) do
      {:ok, _artifact} ->
        []

      {:error, {:no_matching_release_artifact, _os, _arch}} ->
        [
          blocked(%{
            cause: :no_release_artifact,
            release: release.version,
            platform: "#{os || "unknown-os"}/#{arch || "unknown-arch"}"
          })
        ]
    end
  end

  defp blocked(detail), do: %{reason: :agent_upgrade_blocked, detail: detail}

  defp live_runtime(%{active: true} = runtime), do: runtime
  defp live_runtime(_runtime), do: nil

  defp recorded_partition(%Agent{metadata: %{} = metadata}) do
    present(Map.get(metadata, "partition_id") || Map.get(metadata, :partition_id))
  end

  defp recorded_partition(_agent), do: nil

  defp device_partition(%Agent{device: %{partition: partition}}), do: present(partition)
  defp device_partition(_agent), do: nil

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil

  defp read_agents do
    Agent
    |> Ash.Query.filter(status != :superseded)
    |> Ash.Query.load(:device)
    |> Ash.read(actor: actor())
  end

  defp newest_release do
    AgentRelease
    |> Ash.Query.sort(published_at: :desc, inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one(actor: actor())
  end

  defp paused_agent_ids do
    AgentReleaseTarget
    |> Ash.Query.filter(rollout.status == :paused and status not in ^@finished_target_statuses)
    |> Ash.Query.select([:agent_id])
    |> Ash.read(actor: actor())
    |> case do
      {:ok, targets} -> {:ok, MapSet.new(targets, & &1.agent_id)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp actor, do: SystemActor.system(:edge_pipeline_readiness)
end
