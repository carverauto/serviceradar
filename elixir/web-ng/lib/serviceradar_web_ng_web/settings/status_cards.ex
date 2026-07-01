defmodule ServiceRadarWebNGWeb.Settings.StatusCards do
  @moduledoc """
  Resolves the **contextual** status-card strip for the catalog Settings shell.

  `for_view/1` picks a card set appropriate to the active page, resolving from
  the view → its parent-group → its category, so cluster-health cards never leak
  onto a Network or Edge page. When a page renders its own metric cards
  (`has_own_stats: true`, e.g. Cluster Status with its Oban queue table) the whole
  strip is suppressed (`:suppressed`).

  Every metric is computed independently and fails soft to `nil`, so a single
  unavailable source degrades only its own card to `"—"` (see
  `ServiceRadarWebNGWeb.Settings.Shell`, which renders a `nil` value as an em
  dash). Metrics without a cheap local source are intentionally rendered as `nil`
  cards: the card *titles* still communicate the page context, and real values
  populate wherever a source is available.
  """

  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.Repo
  alias ServiceRadarWebNGWeb.Stats

  @rpc_timeout 1_000
  @stream_timeout 1_500

  @type card :: %{title: String.t(), value: term() | nil}

  @doc """
  The contextual status cards for a view, or `:suppressed` when the page renders
  its own metrics.
  """
  @spec for_view(map() | nil) :: :suppressed | [card()]
  def for_view(%{has_own_stats: true}), do: :suppressed
  def for_view(%{} = view), do: cards(context_for(view))
  def for_view(_), do: []

  # Resolve a card-set context from the view. Audit-flavoured views get an audit
  # set; otherwise resolve by parent-group, then by category.
  defp context_for(%{id: id}) when id in [:audit_trail, :lockouts, :history], do: :audit
  defp context_for(%{parent_group: :sys_cluster}), do: :cluster
  defp context_for(%{parent_group: :sys_security}), do: :users
  defp context_for(%{parent_group: :sys_alerts}), do: :alerts
  defp context_for(%{category: :network_services}), do: :network
  defp context_for(%{category: :edge_ops}), do: :edge
  defp context_for(_), do: :cluster

  defp cards(:cluster) do
    [
      %{title: "Cluster health", value: cluster_health()},
      %{title: "Connected agents", value: connected_agents()},
      %{title: "Pending jobs", value: pending_jobs()},
      %{title: "Active alerts", value: active_alerts()}
    ]
  end

  defp cards(:users) do
    [
      %{title: "Total users", value: nil},
      %{title: "Active (30d)", value: nil},
      %{title: "Active sessions", value: nil},
      %{title: "API keys", value: nil}
    ]
  end

  defp cards(:audit) do
    [
      %{title: "Audit events (24h)", value: nil},
      %{title: "Config changes", value: nil}
    ]
  end

  defp cards(:alerts) do
    [
      %{title: "Active alerts", value: active_alerts()},
      %{title: "Pending jobs", value: pending_jobs()}
    ]
  end

  defp cards(:network) do
    [
      %{title: "Discovered devices", value: nil},
      %{title: "Active sweeps", value: nil}
    ]
  end

  defp cards(:edge) do
    agents = connected_agents()

    [
      %{title: "Total agents", value: agents},
      %{title: "Online", value: agents},
      %{title: "Add-ons", value: nil},
      %{title: "Latest release", value: nil}
    ]
  end

  # ---------------------------------------------------------------------------
  # Metric resolvers — each never raises; degrades to nil.
  # ---------------------------------------------------------------------------

  defp cluster_health do
    status = ServiceRadar.Cluster.ClusterStatus.get_status()
    if status.enabled, do: "Active", else: "Standalone"
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp connected_agents do
    [Node.self() | Node.list()]
    |> Task.async_stream(
      fn node ->
        case :rpc.call(node, ServiceRadar.AgentTracker, :list_agents, [], @rpc_timeout) do
          agents when is_list(agents) -> agents
          _ -> []
        end
      end,
      timeout: @stream_timeout,
      on_timeout: :kill_task,
      max_concurrency: 4
    )
    |> Enum.flat_map(fn
      {:ok, agents} -> agents
      _ -> []
    end)
    |> Enum.map(&agent_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> length()
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp agent_id(agent) do
    id = Map.get(agent, :agent_id) || Map.get(agent, "agent_id")
    if is_binary(id) and id != "", do: id
  end

  defp pending_jobs do
    query =
      from(j in Oban.Job,
        where: j.state in ["available", "scheduled", "retryable"],
        select: count(j.id)
      )

    Repo.one(query) || 0
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp active_alerts do
    summary = Stats.alerts_summary()
    (summary[:pending] || 0) + (summary[:escalated] || 0)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end
end
