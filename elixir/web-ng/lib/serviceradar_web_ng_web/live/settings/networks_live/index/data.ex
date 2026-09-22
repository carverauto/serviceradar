defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Data do
  @moduledoc false

  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.NetworkDiscovery.MapperJob
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepGroupExecution
  alias ServiceRadar.SweepJobs.SweepProfile
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Live.Settings.NetworksLive.AgentPicker

  require Ash.Query

  def load_sweep_groups(scope) do
    query =
      SweepGroup
      |> Ash.Query.for_read(:read)
      |> Ash.Query.load([:execution_count, executions: latest_execution_query()])

    case Ash.read(query, scope: scope) do
      {:ok, groups} -> groups
      {:error, _} -> []
    end
  end

  def load_sweep_groups_with_summary_agents(scope) do
    groups = load_sweep_groups(scope)
    {groups, load_sweep_group_summary_agents(scope, groups)}
  end

  def load_sweep_group_summary_agents(scope, groups) when is_list(groups) do
    groups
    |> Enum.flat_map(fn
      %{agent_ids: [uid]} when is_binary(uid) -> [uid]
      _group -> []
    end)
    |> Enum.uniq()
    |> Enum.chunk_every(AgentPicker.page_size())
    |> Enum.reduce(%{}, fn uids, agents_by_uid ->
      case load_agents_by_uids(scope, uids) do
        {:ok, agents} -> Map.merge(agents_by_uid, Map.new(agents, &{&1.uid, &1}))
        {:error, _reason} -> agents_by_uid
      end
    end)
  end

  def load_sweep_group(scope, id) do
    case Ash.get(SweepGroup, id,
           scope: scope,
           load: [:execution_count, executions: latest_execution_query()]
         ) do
      {:ok, group} -> group
      {:error, _} -> nil
    end
  end

  defp latest_execution_query do
    SweepGroupExecution
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
  end

  def fetch_sweep_group(scope, id) do
    case load_sweep_group(scope, id) do
      nil -> {:error, :not_found}
      group -> {:ok, group}
    end
  end

  def load_sweep_profiles(scope) do
    case Ash.read(SweepProfile, scope: scope) do
      {:ok, profiles} -> profiles
      {:error, _} -> []
    end
  end

  def load_mapper_agents(scope, selected_uid \\ nil) do
    require Logger

    if can_manage_networks?(scope) do
      result =
        Agent
        |> Ash.Query.for_read(:by_capability, %{capability: "mapper"})
        |> Ash.Query.filter(last_seen_time > ago(30, :minute))
        |> Ash.Query.sort(name: :asc, uid: :asc)
        |> Ash.Query.limit(50)
        |> Ash.read(scope: scope)

      case result do
        {:ok, agents} ->
          agents
          |> Enum.filter(&active_agent?/1)
          |> include_selected_mapper_agent(scope, selected_uid)

        {:error, reason} ->
          Logger.warning("load_mapper_agents: failed to load agents - #{inspect(reason)}")
          include_selected_mapper_agent([], scope, selected_uid)
      end
    else
      []
    end
  end

  def load_agents_by_uids(_scope, []), do: {:ok, []}

  def load_agents_by_uids(scope, uids) when is_list(uids) do
    bounded_uids =
      uids
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.take(AgentPicker.page_size())

    Agent
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(uid in ^bounded_uids)
    |> Ash.Query.load(gateway: [:partition_id])
    |> Ash.read(scope: scope)
    |> case do
      {:ok, agents} -> {:ok, Enum.take(agents, AgentPicker.page_size())}
      {:error, reason} -> {:error, reason}
    end
  end

  def load_agent_by_uid(_scope, uid) when uid in [nil, ""], do: nil

  def load_agent_by_uid(scope, uid) when is_binary(uid) do
    Agent
    |> Ash.Query.for_read(:by_uid, %{uid: uid})
    |> Ash.read_one(scope: scope)
    |> case do
      {:ok, agent} -> agent
      {:error, _reason} -> nil
    end
  end

  defp include_selected_mapper_agent(agents, _scope, selected_uid) when selected_uid in [nil, ""], do: agents

  defp include_selected_mapper_agent(agents, scope, selected_uid) do
    if Enum.any?(agents, &(&1.uid == selected_uid)) do
      agents
    else
      case load_agent_by_uid(scope, selected_uid) do
        nil -> agents
        agent -> [agent | agents]
      end
    end
  end

  def can_manage_networks?(scope) do
    RBAC.can?(scope, "settings.networks.manage")
  end

  def can_enable_banner_grab?(scope) do
    RBAC.can?(scope, "networks.sweeps.banner_grab")
  end

  def active_agent?(%Agent{status: status, last_seen_time: %DateTime{} = last_seen_time})
      when status in [:connected, :degraded, :connecting] do
    DateTime.diff(DateTime.utc_now(), last_seen_time, :minute) <= 30
  end

  def active_agent?(%Agent{last_seen_time: %DateTime{} = last_seen_time}) do
    DateTime.diff(DateTime.utc_now(), last_seen_time, :minute) <= 30
  end

  def active_agent?(_agent), do: false

  def can_run_sweeps?(scope), do: RBAC.can?(scope, "networks.sweeps.run")
  def can_run_discovery?(scope), do: RBAC.can?(scope, "networks.discovery.run")

  def require_run_sweeps(socket) do
    if can_run_sweeps?(socket.assigns.current_scope), do: :ok, else: {:error, :unauthorized}
  end

  def require_run_discovery(socket) do
    if can_run_discovery?(socket.assigns.current_scope), do: :ok, else: {:error, :unauthorized}
  end

  def load_sweep_profile(scope, id) do
    case Ash.get(SweepProfile, id, scope: scope) do
      {:ok, profile} -> profile
      {:error, _} -> nil
    end
  end

  def load_mapper_jobs(scope) do
    query =
      MapperJob
      |> Ash.Query.for_read(:read)
      |> Ash.Query.load([
        :seeds,
        unifi_controllers: [:api_key_present],
        mikrotik_controllers: [:password_present]
      ])

    case Ash.read(query, scope: scope) do
      {:ok, jobs} -> jobs
      {:error, _} -> []
    end
  end

  def load_mapper_job(scope, id) do
    case Ash.get(MapperJob, id, scope: scope) do
      {:ok, job} ->
        case Ash.load(
               job,
               [
                 :seeds,
                 unifi_controllers: [:api_key_present],
                 mikrotik_controllers: [:password_present]
               ],
               scope: scope
             ) do
          {:ok, loaded} -> loaded
          {:error, _} -> job
        end

      {:error, _} ->
        nil
    end
  end

  def count_target_devices(_scope, nil), do: nil
  def count_target_devices(_scope, ""), do: nil

  def count_target_devices(scope, target_query) when is_binary(target_query) do
    srql_module = srql_module()
    query = String.trim(target_query)

    full_query =
      cond do
        query == "" ->
          ~s|in:devices stats:"count() as total"|

        String.starts_with?(query, "in:") ->
          ~s|#{query} stats:"count() as total"|

        true ->
          ~s|in:devices #{query} stats:"count() as total"|
      end

    case srql_module.query(full_query, %{scope: scope}) do
      {:ok, %{"results" => [%{"total" => count} | _]}} when is_integer(count) ->
        count

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  def srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end
end
