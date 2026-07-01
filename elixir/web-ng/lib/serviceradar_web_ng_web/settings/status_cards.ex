defmodule ServiceRadarWebNGWeb.Settings.StatusCards do
  @moduledoc """
  Loads the four metrics shown in the catalog shell's status-card strip
  (cluster health, connected agents, pending jobs, active alerts).

  It reuses the same sources the Cluster Status page already loads
  (`ServiceRadar.Cluster.ClusterStatus`, `ServiceRadar.AgentTracker`, `Oban.Job`
  via the shared repo, and `ServiceRadarWebNGWeb.Stats.alerts_summary/0`). Every
  metric is computed independently and fails soft to `nil`, so a single
  unavailable source degrades only its own card to `"—"` (see
  `ServiceRadarWebNGWeb.Settings.Shell` which renders `nil` as an em dash).
  """

  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.Repo
  alias ServiceRadarWebNGWeb.Stats

  @rpc_timeout 1_000
  @stream_timeout 1_500

  @type t :: %{
          cluster_health: String.t() | nil,
          connected_agents: non_neg_integer() | nil,
          pending_jobs: non_neg_integer() | nil,
          active_alerts: non_neg_integer() | nil
        }

  @doc """
  Compute the status-card metrics. Never raises: each field degrades to `nil`.
  """
  @spec load() :: t()
  def load do
    %{
      cluster_health: cluster_health(),
      connected_agents: connected_agents(),
      pending_jobs: pending_jobs(),
      active_alerts: active_alerts()
    }
  end

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
