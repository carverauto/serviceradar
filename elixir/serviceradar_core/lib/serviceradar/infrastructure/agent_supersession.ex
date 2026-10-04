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

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Infrastructure.StateMonitor
  alias ServiceRadar.Inventory.Identity.DecisionLog

  require Ash.Query
  require Logger

  @sweep_page 500
  @source "agent_supersession"

  @type sweep_result :: %{superseded: non_neg_integer()}

  @doc """
  Supersedes quiet identities that share a device with a more recently seen
  identity. The most recently seen identity is the keeper, even when it too has
  gone quiet. Running it again supersedes nothing.
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

      {:ok, %{superseded: superseded}}
    end
  end

  @doc """
  On check-in of `agent_id` onto `device_uid`, supersede every other identity
  on that device that is no longer live. Live identities are kept and the
  decision is recorded either way.

  Returns the agents that were superseded, so the caller can move assignments
  off them. A failed read or update is logged and does not fail the check-in.
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
        {:ok, updated}

      {:error, error} ->
        Logger.warning(
          "Failed to supersede agent #{agent.uid} in favor of #{replacement_uid}: #{inspect(error)}"
        )

        :error
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
      {:ok, %Ash.Page.Keyset{results: results}} ->
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
