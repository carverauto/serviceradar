defmodule ServiceRadar.AgentConfig.DependencyDispatcher do
  @moduledoc """
  Dispatches agent config updates from cataloged resource notifications.
  """

  alias Ash.Notifier.Notification
  alias ServiceRadar.AgentConfig.ConfigServer
  alias ServiceRadar.AgentConfig.DependencyCatalog
  alias ServiceRadar.Edge.AgentCommandBus

  require Logger

  @doc "Dispatches cataloged config side effects asynchronously."
  @spec dispatch_async(Notification.t(), keyword()) :: :ok
  def dispatch_async(notification, opts \\ []) do
    Task.start(fn -> dispatch(notification, opts) end)
    :ok
  end

  @doc "Dispatches cataloged config side effects for a notification."
  @spec dispatch(Notification.t(), keyword()) :: :ok
  def dispatch(notification, opts \\ []) do
    notification
    |> DependencyCatalog.for_notification()
    |> Enum.each(&dispatch_entry(&1, notification.data, opts))

    :ok
  end

  defp dispatch_entry(entry, record, opts) do
    command_bus = Keyword.get(opts, :command_bus, AgentCommandBus)
    config_server = Keyword.get(opts, :config_server, ConfigServer)
    affected_agents = DependencyCatalog.affected_agents(entry, record)

    case entry.dispatch do
      :push_affected_agents ->
        push_affected_agents(command_bus, entry.config_type, affected_agents)

      :push_config_for_type ->
        command_bus.push_config_for_type(entry.config_type)

      :invalidate_config_type ->
        config_server.invalidate(entry.config_type)
    end
  end

  defp push_affected_agents(command_bus, config_type, :all_online) do
    command_bus.push_config_for_type(config_type)
  end

  defp push_affected_agents(command_bus, _config_type, agent_ids) when is_list(agent_ids) do
    agent_ids
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.each(fn agent_id ->
      case command_bus.push_config(agent_id) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.debug("Failed to push catalog-driven config to #{agent_id}: #{inspect(reason)}")
      end
    end)
  end
end
