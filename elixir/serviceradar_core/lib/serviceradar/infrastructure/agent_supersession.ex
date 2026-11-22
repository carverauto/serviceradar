defmodule ServiceRadar.Infrastructure.AgentSupersession do
  @moduledoc """
  Replaces an agent identity when a host checks in under a new uid.

  Two rows are the same host only when they share a `device_uid`. A shared
  address or hostname is not identity: hosts behind one NAT address stay
  independent. An identity that is still heartbeating (connected or degraded,
  and seen within the StateMonitor agent timeout) is left in place.

  The check-in path records that decision immediately. `sweep/1` is the hourly
  backfill for a replacement that enrolled while the previous identity still
  looked live, and for rows that were already quiet when this rule shipped.
  """

  import Ash.Expr

  alias Ash.Page.Keyset
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.AgentReleaseTarget
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Infrastructure.StateMonitor
  alias ServiceRadar.Inventory.Identity.DecisionLog
  alias ServiceRadar.NetworkDiscovery.MapperJob
  alias ServiceRadar.SweepJobs.AgentAssignment
  alias ServiceRadar.SweepJobs.SweepGroup

  require Ash.Query
  require Logger

  @sweep_page 500
  @source "agent_supersession"
  @terminal_release_target_statuses [:healthy, :failed, :rolled_back, :canceled]

  @type sweep_result :: %{superseded: non_neg_integer()}

  @doc """
  Supersedes quiet identities that share a device with a more recently seen
  identity. The most recently seen identity is the keeper, even when it too has
  gone quiet. Running it again supersedes nothing.

  Also reconciles any lingering assignments or active release targets left on
  identities that were previously marked `:superseded`.
  """
  @spec sweep(keyword()) :: {:ok, sweep_result()} | {:error, term()}
  def sweep(opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:agent_supersession))
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, agents} <- load_active_agents(actor) do
      superseded =
        agents
        |> Enum.group_by(& &1.device_uid)
        |> Enum.reduce(0, fn {_device_uid, group}, count ->
          count + supersede_quiet_siblings(group, actor, now)
        end)

      reconcile_superseded_assignments(actor)

      {:ok, %{superseded: superseded}}
    end
  end

  @doc """
  On check-in of `agent_id` onto `device_uid`, supersede every other identity
  on that device that is no longer live. Live identities are kept and the
  decision is recorded either way.

  Returns the agents that were superseded. Assignment handoff and release-target
  cancellation run for each superseded agent as part of marking it superseded.
  A failed read or update is logged and does not fail the check-in.
  """
  @spec on_check_in(String.t(), String.t() | nil, map()) :: [Agent.t()]
  def on_check_in(agent_id, device_uid, actor)
      when is_binary(agent_id) and is_binary(device_uid) do
    now = DateTime.utc_now()

    case siblings(device_uid, agent_id, actor) do
      {:ok, agents} ->
        Enum.flat_map(agents, &decide_sibling(&1, agent_id, device_uid, actor, now))

      {:error, reason} ->
        Logger.warning(
          "Failed to look up sibling agents for #{agent_id} on #{device_uid}: #{inspect(reason)}"
        )

        []
    end
  end

  def on_check_in(_agent_id, _device_uid, _actor), do: []

  @doc """
  Called when an agent transitions to `:disconnected` (e.g. heartbeat timeout).

  If another identity on the same `device_uid` is currently live, supersede the
  disconnected identity immediately and hand off its active assignments instead
  of waiting for the hourly `sweep/1` pass.
  """
  @spec on_agent_disconnected(Agent.t(), map(), keyword()) :: {:ok, Agent.t()} | :noop
  def on_agent_disconnected(agent, actor, opts \\ [])

  def on_agent_disconnected(
        %Agent{uid: uid, device_uid: device_uid, superseded_at: nil} = agent,
        actor,
        opts
      )
      when is_binary(device_uid) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    case siblings(device_uid, uid, actor) do
      {:ok, sibling_agents} ->
        case Enum.filter(sibling_agents, &live?(&1, now)) do
          [] ->
            :noop

          live_siblings ->
            replacement = keeper(live_siblings)

            case mark_superseded(agent, replacement.uid, actor, "older_identity_on_device") do
              {:ok, updated} -> {:ok, updated}
              :error -> :noop
            end
        end

      {:error, reason} ->
        Logger.warning(
          "Failed to look up sibling agents for disconnected agent #{uid} on #{device_uid}: #{inspect(reason)}"
        )

        :noop
    end
  end

  def on_agent_disconnected(_agent, _actor, _opts), do: :noop

  @doc """
  Returns a superseded identity to `:connected` and records the revival.

  This is the only path that leaves `:superseded`. The connected-registration
  upsert refuses a superseded row.
  """
  @spec revive(Agent.t(), map()) :: {:ok, Agent.t()} | {:error, term()}
  def revive(%Agent{status: :superseded} = agent, actor) do
    case agent
         |> Ash.Changeset.for_update(:revive_superseded, %{})
         |> Ash.update(actor: actor) do
      {:ok, revived} ->
        record(revived.device_uid, revived.uid, "superseded_agent_reconnected", %{})
        {:ok, revived}

      {:error, reason} = error ->
        Logger.warning("Failed to revive superseded agent #{agent.uid}: #{inspect(reason)}")
        error
    end
  end

  def revive(%Agent{} = agent, _actor), do: {:ok, agent}

  defp decide_sibling(agent, replacement_uid, device_uid, actor, now) do
    if live?(agent, now) do
      record(device_uid, agent.uid, "live_identity_kept", %{replacement_uid: replacement_uid})
      []
    else
      case mark_superseded(agent, replacement_uid, actor, "reenrolled_under_new_uid") do
        {:ok, updated} -> [updated]
        :error -> []
      end
    end
  end

  defp supersede_quiet_siblings(group, _actor, _now) when length(group) < 2, do: 0

  defp supersede_quiet_siblings(group, actor, now) do
    keeper = keeper(group)

    Enum.reduce(group, 0, fn agent, count ->
      if agent.uid == keeper.uid or live?(agent, now) do
        count
      else
        case mark_superseded(agent, keeper.uid, actor, "older_identity_on_device") do
          {:ok, _updated} -> count + 1
          :error -> count
        end
      end
    end)
  end

  defp mark_superseded(agent, replacement_uid, actor, reason) do
    case agent
         |> Ash.Changeset.for_update(:supersede, %{superseded_by: replacement_uid})
         |> Ash.update(actor: actor) do
      {:ok, updated} ->
        record(agent.device_uid, agent.uid, reason, %{superseded_by: replacement_uid})
        finish_superseded_agent(updated, replacement_uid, actor)
        {:ok, updated}

      {:error, error} ->
        Logger.warning(
          "Failed to supersede agent #{agent.uid} in favor of #{replacement_uid}: #{inspect(error)}"
        )

        :error
    end
  end

  defp finish_superseded_agent(agent, replacement_agent_id, actor) do
    cancel_superseded_release_targets(agent.uid, replacement_agent_id, actor)
    mark_superseded_release_state(agent, actor)
    transfer_superseded_assignments(agent.uid, replacement_agent_id, actor)

    Logger.info("Superseded agent #{agent.uid} in favor of #{replacement_agent_id}")
  end

  defp reconcile_superseded_assignments(actor) do
    case load_superseded_agents(actor) do
      {:ok, []} ->
        :ok

      {:ok, agents} ->
        superseded_by_map = Map.new(agents, &{&1.uid, &1.superseded_by})

        Enum.each(agents, fn agent ->
          replacement_uid = resolve_replacement_uid(agent.uid, superseded_by_map)

          if is_binary(replacement_uid) and replacement_uid != agent.uid do
            cancel_superseded_release_targets(agent.uid, replacement_uid, actor)
            transfer_superseded_assignments(agent.uid, replacement_uid, actor)
          end
        end)

      {:error, reason} ->
        Logger.warning(
          "Failed to load superseded agents for assignment reconciliation: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp resolve_replacement_uid(uid, superseded_by_map),
    do: resolve_replacement_uid(uid, superseded_by_map, MapSet.new())

  defp resolve_replacement_uid(uid, superseded_by_map, visited) do
    case Map.get(superseded_by_map, uid) do
      next when is_binary(next) and next != "" ->
        if MapSet.member?(visited, next) do
          uid
        else
          resolve_replacement_uid(next, superseded_by_map, MapSet.put(visited, uid))
        end

      _ ->
        uid
    end
  end

  defp load_superseded_agents(actor), do: load_superseded_agents(actor, nil, [])

  defp load_superseded_agents(actor, after_uid, acc) do
    case Ash.read(superseded_agent_query(actor, after_uid), actor: actor) do
      {:ok, %Keyset{results: results}} ->
        continue_superseded_agents(actor, results, acc)

      {:ok, results} when is_list(results) ->
        continue_superseded_agents(actor, results, acc)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp continue_superseded_agents(_actor, [], acc), do: {:ok, acc}

  defp continue_superseded_agents(actor, results, acc) do
    acc = acc ++ results

    if length(results) < @sweep_page do
      {:ok, acc}
    else
      load_superseded_agents(actor, List.last(results).uid, acc)
    end
  end

  defp superseded_agent_query(actor, after_uid) do
    query =
      Agent
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(expr(status == :superseded and not is_nil(superseded_by)))
      |> Ash.Query.sort(uid: :asc)
      |> Ash.Query.limit(@sweep_page)

    if is_binary(after_uid) do
      Ash.Query.filter(query, expr(uid > ^after_uid))
    else
      query
    end
  end

  defp mark_superseded_release_state(agent, actor) do
    _ =
      agent
      |> Ash.Changeset.for_update(:update_release_status, %{
        release_rollout_state: :canceled,
        last_update_at: DateTime.utc_now(),
        last_update_error: "agent_superseded"
      })
      |> Ash.update(actor: actor)

    :ok
  end

  defp cancel_superseded_release_targets(agent_id, replacement_agent_id, actor) do
    AgentReleaseTarget
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(
      expr(agent_id == ^agent_id and status not in ^@terminal_release_target_statuses)
    )
    |> Ash.read(actor: actor)
    |> case do
      {:ok, targets} ->
        Enum.each(targets, fn target ->
          _ =
            AgentReleaseTarget.set_status(
              target,
              %{
                status: :canceled,
                last_status_message: "superseded by #{replacement_agent_id}",
                last_error: "agent_superseded",
                completed_at: DateTime.utc_now()
              },
              actor: actor
            )
        end)

      {:error, reason} ->
        Logger.warning(
          "Failed to cancel release targets for superseded agent #{agent_id}: #{inspect(reason)}"
        )
    end
  end

  defp transfer_superseded_assignments(agent_id, replacement_agent_id, actor) do
    Enum.each(
      [
        {:mapper_jobs,
         transfer_agent_assignment(MapperJob, agent_id, replacement_agent_id, actor)},
        {:sweep_groups, transfer_sweep_group_assignments(agent_id, replacement_agent_id, actor)}
      ],
      &log_assignment_transfer(&1, agent_id, replacement_agent_id)
    )
  end

  defp log_assignment_transfer({_label, {:ok, 0}}, _agent_id, _replacement_agent_id), do: :ok

  defp log_assignment_transfer({label, {:ok, count}}, agent_id, replacement_agent_id) do
    Logger.info(
      "Reassigned #{count} #{label} from superseded agent #{agent_id} to #{replacement_agent_id}"
    )
  end

  defp log_assignment_transfer({label, {:error, reason}}, agent_id, replacement_agent_id) do
    Logger.warning(
      "Failed to reassign #{label} from superseded agent #{agent_id} to #{replacement_agent_id}: #{inspect(reason)}"
    )
  end

  defp transfer_agent_assignment(resource, agent_id, replacement_agent_id, actor) do
    query =
      resource
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(agent_id == ^agent_id)

    case Ash.read(query, actor: actor) do
      {:ok, []} ->
        {:ok, 0}

      {:ok, records} ->
        update_agent_assignments(records, replacement_agent_id, actor)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp transfer_sweep_group_assignments(agent_id, replacement_agent_id, actor) do
    query =
      SweepGroup
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(^agent_id in agent_ids)

    case Ash.read(query, actor: actor) do
      {:ok, records} ->
        records
        |> Enum.map(&replace_sweep_group_assignment(&1, agent_id, replacement_agent_id))
        |> update_sweep_group_assignments(actor)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp replace_sweep_group_assignment(group, agent_id, replacement_agent_id) do
    agent_ids =
      group.agent_ids
      |> AgentAssignment.normalize()
      |> Enum.map(fn current_agent_id ->
        if current_agent_id == agent_id, do: replacement_agent_id, else: current_agent_id
      end)
      |> AgentAssignment.normalize()

    {group, agent_ids}
  end

  defp update_agent_assignments(records, replacement_agent_id, actor) do
    records
    |> Enum.reduce_while(0, fn record, count ->
      record
      |> Ash.Changeset.for_update(:update, %{agent_id: replacement_agent_id}, actor: actor)
      |> Ash.update()
      |> case do
        {:ok, _record} -> {:cont, count + 1}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      count -> {:ok, count}
    end
  end

  defp update_sweep_group_assignments(assignments, actor) do
    assignments
    |> Enum.reduce_while(0, fn {group, agent_ids}, count ->
      group
      |> Ash.Changeset.for_update(:update, %{agent_ids: agent_ids}, actor: actor)
      |> Ash.update()
      |> case do
        {:ok, _group} -> {:cont, count + 1}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      count -> {:ok, count}
    end
  end

  # Connected or degraded and seen inside the StateMonitor window. A nil
  # last_seen is not a heartbeat. Anything else (unavailable, disconnected,
  # connecting) has already left the live set.
  defp live?(%Agent{status: status, last_seen_time: %DateTime{} = last_seen}, now)
       when status in [:connected, :degraded] do
    DateTime.diff(now, last_seen, :millisecond) <= StateMonitor.agent_timeout()
  end

  defp live?(%Agent{}, _now), do: false

  # Nil last_seen sorts oldest. Equal timestamps break toward the higher uid so
  # a repeated sweep picks the same keeper.
  defp keeper(agents) do
    Enum.max_by(agents, fn agent -> {seen_sort_key(agent.last_seen_time), agent.uid} end)
  end

  defp seen_sort_key(nil), do: {0, 0}
  defp seen_sort_key(%DateTime{} = time), do: {1, DateTime.to_unix(time, :microsecond)}

  defp siblings(device_uid, agent_id, actor) do
    Agent
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(
      expr(device_uid == ^device_uid and uid != ^agent_id and is_nil(superseded_at))
    )
    |> Ash.read(actor: actor)
  end

  defp load_active_agents(actor), do: load_active_agents(actor, nil, [])

  defp load_active_agents(actor, after_uid, acc) do
    case Ash.read(active_agent_query(actor, after_uid), actor: actor) do
      {:ok, %Keyset{results: results}} ->
        continue_active_agents(actor, results, acc)

      {:ok, results} when is_list(results) ->
        continue_active_agents(actor, results, acc)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp continue_active_agents(_actor, [], acc), do: {:ok, acc}

  defp continue_active_agents(actor, results, acc) do
    acc = acc ++ results

    if length(results) < @sweep_page do
      {:ok, acc}
    else
      load_active_agents(actor, List.last(results).uid, acc)
    end
  end

  defp active_agent_query(actor, after_uid) do
    query =
      Agent
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(expr(not is_nil(device_uid) and is_nil(superseded_at)))
      |> Ash.Query.sort(uid: :asc)
      |> Ash.Query.limit(@sweep_page)

    if is_binary(after_uid) do
      Ash.Query.filter(query, expr(uid > ^after_uid))
    else
      query
    end
  end

  defp record(device_uid, agent_uid, reason, evidence) when is_binary(device_uid) do
    DecisionLog.record(:agent_supersession, reason, [device_uid],
      subject: agent_uid,
      source: @source,
      evidence: evidence
    )
  end

  defp record(_device_uid, _agent_uid, _reason, _evidence), do: :ok
end
