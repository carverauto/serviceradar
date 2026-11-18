defmodule ServiceRadarWebNGWeb.Settings.NetperfLive.Data do
  @moduledoc """
  Database and runtime data loaders for `Settings.NetperfLive.Index`.

  All database queries pass `scope: scope` and are invoked only from connected
  LiveView lifecycle paths.
  """

  import Ash.Expr

  alias ServiceRadar.Edge.AgentCommand
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Monitoring.NetperfPolicy
  alias ServiceRadar.Monitoring.NetperfProfile
  alias ServiceRadar.Monitoring.NetperfResponder
  alias ServiceRadarWebNG.Dashboards

  require Ash.Query

  @netperf_command_type "netperf.run"

  @spec load_all(map(), keyword()) :: map()
  def load_all(scope, opts \\ []) do
    online_sessions = list_online_sessions(opts)

    online_agent_ids =
      online_sessions
      |> Enum.map(&session_agent_id/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    netperf_agent_ids =
      online_sessions
      |> Enum.filter(fn session -> "netperf" in List.wrap(Map.get(session, :capabilities)) end)
      |> Enum.map(&session_agent_id/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    %{
      policies: load_policies(scope),
      responders: load_responders(scope),
      profiles: load_profiles(scope),
      agents: load_agents(scope),
      recent_runs: load_recent_runs(scope),
      online_agent_ids: online_agent_ids,
      netperf_agent_ids: netperf_agent_ids,
      dashboard_route: network_performance_dashboard_route(scope)
    }
  end

  @spec load_policies(map()) :: [NetperfPolicy.t()]
  def load_policies(scope) do
    NetperfPolicy
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.load([:profile, :responders])
    |> Ash.Query.sort(name: :asc)
    |> Ash.read(scope: scope)
    |> unwrap_results()
  end

  @spec load_responders(map()) :: [NetperfResponder.t()]
  def load_responders(scope) do
    NetperfResponder
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.load([:agent])
    |> Ash.Query.sort(name: :asc)
    |> Ash.read(scope: scope)
    |> unwrap_results()
  end

  @spec load_profiles(map()) :: [NetperfProfile.t()]
  def load_profiles(scope) do
    NetperfProfile
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.sort(name: :asc)
    |> Ash.read(scope: scope)
    |> unwrap_results()
  end

  @spec load_agents(map()) :: [Agent.t()]
  def load_agents(scope) do
    Agent
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.sort(uid: :asc)
    |> Ash.Query.limit(250)
    |> Ash.read(scope: scope)
    |> unwrap_results()
  end

  @spec load_recent_runs(map(), pos_integer()) :: [AgentCommand.t()]
  def load_recent_runs(scope, limit \\ 20) do
    AgentCommand
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(expr(command_type == @netperf_command_type))
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.read(scope: scope)
    |> unwrap_results()
  end

  @spec get_command(String.t(), map()) :: AgentCommand.t() | nil
  def get_command(command_id, scope) when is_binary(command_id) do
    case AgentCommand.get_by_id(command_id, scope: scope) do
      {:ok, command} -> command
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def get_command(_, _), do: nil

  @spec resolve_responder_address(map()) :: String.t() | nil
  def resolve_responder_address(responder) when is_map(responder) do
    agent = Map.get(responder, :agent)

    first_nonempty([
      Map.get(responder, :advertise_address),
      agent && Map.get(agent, :ip),
      agent && Map.get(agent, :host)
    ])
  end

  def resolve_responder_address(_), do: nil

  @spec network_performance_dashboard_route(map()) :: String.t() | nil
  def network_performance_dashboard_route(scope) do
    case Dashboards.get_enabled_instance_by_slug("network-performance", scope: scope) do
      {:ok, _instance} -> "/dashboards/network-performance"
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp list_online_sessions(opts) do
    case Keyword.get(opts, :list_online_agents_fn) do
      fun when is_function(fun, 0) -> fun.()
      _ -> AgentCommandBus.list_online_agents()
    end
  rescue
    _ -> []
  end

  defp session_agent_id(session) when is_map(session) do
    Map.get(session, :agent_id) || Map.get(session, "agent_id")
  end

  defp session_agent_id(_), do: nil

  defp unwrap_results({:ok, %Ash.Page.Keyset{results: results}}), do: results
  defp unwrap_results({:ok, results}) when is_list(results), do: results
  defp unwrap_results(_), do: []

  defp first_nonempty(values) do
    Enum.find_value(values, fn
      v when is_binary(v) ->
        trimmed = String.trim(v)
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end)
  end
end
