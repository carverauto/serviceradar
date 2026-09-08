defmodule ServiceRadar.AgentConfig.DependencyDispatcher do
  @moduledoc """
  Dispatches agent config updates from cataloged resource notifications.
  """

  alias Ash.Notifier.Notification
  alias ServiceRadar.AgentConfig.ConfigServer
  alias ServiceRadar.AgentConfig.DependencyCatalog
  alias ServiceRadar.AgentConfig.DependencyDiagnostics
  alias ServiceRadar.Edge.AgentCommandBus

  require Logger

  @task_supervisor ServiceRadar.AgentConfig.DependencyDispatcher.TaskSupervisor

  @doc "Dispatches cataloged config side effects asynchronously."
  @spec dispatch_async(Notification.t(), keyword()) :: :ok
  def dispatch_async(notification, opts \\ []) do
    case Task.Supervisor.start_child(@task_supervisor, fn -> dispatch(notification, opts) end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to start agent config dependency dispatch: #{inspect(reason)}")
    end

    :ok
  end

  @doc "Dispatches cataloged config side effects for a notification."
  @spec dispatch(Notification.t(), keyword()) :: {:ok, [map()]}
  def dispatch(notification, opts \\ []) do
    diagnostics =
      notification
      |> DependencyCatalog.for_notification()
      |> Enum.map(&dispatch_entry(&1, notification, opts))

    {:ok, diagnostics}
  end

  defp dispatch_entry(entry, notification, opts) do
    command_bus = Keyword.get(opts, :command_bus, AgentCommandBus)
    config_server = Keyword.get(opts, :config_server, ConfigServer)
    diagnostics = Keyword.get(opts, :diagnostics, DependencyDiagnostics)
    record = notification.data
    affected_agents = DependencyCatalog.affected_agents(entry, record)
    base_diagnostic = build_diagnostic(entry, notification, affected_agents)

    result =
      case entry.dispatch do
        :push_affected_agents ->
          push_affected_agents(command_bus, entry.config_type, affected_agents)

        :push_config_for_type ->
          command_bus.push_config_for_type(entry.config_type)

        :invalidate_config_type ->
          config_server.invalidate(entry.config_type)
      end

    diagnostic = Map.put(base_diagnostic, :result, normalize_result(result))
    diagnostics.record(diagnostic)
    diagnostic
  end

  defp push_affected_agents(command_bus, config_type, :all_online) do
    command_bus.push_config_for_type(config_type)
  end

  defp push_affected_agents(command_bus, _config_type, agent_ids) when is_list(agent_ids) do
    results =
      agent_ids
      |> normalize_agent_ids()
      |> Enum.map(fn agent_id ->
        result = command_bus.push_config(agent_id)

        case result do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.debug(
              "Failed to push catalog-driven config to #{agent_id}: #{inspect(reason)}"
            )
        end

        {agent_id, result}
      end)

    if Enum.all?(results, fn {_agent_id, result} -> result == :ok end) do
      :ok
    else
      {:error, results}
    end
  end

  defp build_diagnostic(entry, notification, affected_agents) do
    entry
    |> DependencyCatalog.diagnostics(notification.data)
    |> Map.merge(%{
      action_type: notification.action.type,
      affected_agents: affected_agents,
      affected_agent_count: affected_agent_count(affected_agents),
      config_version: nil,
      config_hash: nil
    })
  end

  defp affected_agent_count(:all_online), do: :all_online

  defp affected_agent_count(agent_ids) when is_list(agent_ids),
    do: agent_ids |> normalize_agent_ids() |> length()

  defp normalize_agent_ids(agent_ids) do
    agent_ids
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_result(:ok), do: :ok
  defp normalize_result({:error, reason}), do: {:error, inspect(reason)}
  defp normalize_result(other), do: inspect(other)
end
