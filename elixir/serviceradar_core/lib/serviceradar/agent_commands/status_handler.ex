defmodule ServiceRadar.AgentCommands.StatusHandler do
  @moduledoc """
  Persists agent command ack/progress/result updates into AgentCommand records.
  """

  use GenServer

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentCommands.PubSub
  alias ServiceRadar.Edge.AgentCommand
  alias ServiceRadar.Observability.MtrMetricsIngestor

  require Logger

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    PubSub.subscribe()
    {:ok, Map.put(state, :actor, SystemActor.system(:agent_command_status))}
  end

  @impl true
  def handle_info({:command_ack, data}, state) do
    persist_ack(data, state.actor)
    {:noreply, state}
  end

  def handle_info({:command_progress, data}, state) do
    persist_progress(data, state.actor)
    {:noreply, state}
  end

  def handle_info({:command_result, data}, state) do
    maybe_ingest_mtr_result(data)
    persist_result(data, state.actor)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp persist_ack(%{command_id: command_id} = data, actor) do
    case AgentCommand.get_by_id(command_id, actor: actor) do
      {:ok, command} ->
        if command.status in [:queued, :sent] do
          AgentCommand.acknowledge(command, %{message: Map.get(data, :message)}, actor: actor)
        end

      {:error, %Ash.Error.Query.NotFound{}} ->
        :ok

      {:error, reason} ->
        Logger.warning("AgentCommandStatusHandler: failed to load command ack",
          command_id: command_id,
          reason: inspect(reason)
        )
    end
  end

  defp persist_progress(%{command_id: command_id} = data, actor) do
    case AgentCommand.get_by_id(command_id, actor: actor) do
      {:ok, command} ->
        params = %{
          message: Map.get(data, :message),
          progress_percent: Map.get(data, :progress_percent)
        }

        cond do
          command.status in [:queued, :sent, :acknowledged] ->
            AgentCommand.start(command, params, actor: actor)

          command.status == :running ->
            AgentCommand.update_progress(command, params, actor: actor)

          true ->
            :ok
        end

      {:error, %Ash.Error.Query.NotFound{}} ->
        :ok

      {:error, reason} ->
        Logger.warning("AgentCommandStatusHandler: failed to load command progress",
          command_id: command_id,
          reason: inspect(reason)
        )
    end
  end

  defp persist_result(%{command_id: command_id} = data, actor) do
    case AgentCommand.get_by_id(command_id, actor: actor) do
      {:ok, command} ->
        handle_result(command, data, actor)

      {:error, %Ash.Error.Query.NotFound{}} ->
        :ok

      {:error, reason} ->
        Logger.warning("AgentCommandStatusHandler: failed to load command result",
          command_id: command_id,
          reason: inspect(reason)
        )
    end
  end

  defp handle_result(command, data, actor) do
    if terminal_status?(command.status) do
      :ok
    else
      if Map.get(data, :success) do
        AgentCommand.complete(
          command,
          %{message: Map.get(data, :message), result_payload: Map.get(data, :payload)},
          actor: actor
        )
      else
        AgentCommand.fail(
          command,
          %{
            message: Map.get(data, :message),
            result_payload: Map.get(data, :payload),
            failure_reason: Map.get(data, :failure_reason) || "command_failed"
          },
          actor: actor
        )
      end
    end
  end

  defp terminal_status?(status) do
    status in [:completed, :failed, :expired, :canceled, :offline]
  end

  defp maybe_ingest_mtr_result(%{command_type: "mtr.run", success: true} = data) do
    payload = Map.get(data, :payload)
    trace = payload_trace(payload)

    if is_map(payload) and is_map(trace) do
      target = payload["target"] || trace["target"] || trace["target_ip"] || ""
      timestamp = trace["timestamp"] || Map.get(data, :timestamp)

      mtr_payload = %{
        "results" => [
          %{
            "check_id" => Map.get(data, :command_id),
            "check_name" => "on-demand",
            "target" => target,
            "available" => trace["target_reached"] == true,
            "trace" => trace,
            "timestamp" => timestamp,
            "error" => nil
          }
        ]
      }

      status = %{
        agent_id: Map.get(data, :agent_id),
        gateway_id: Map.get(data, :gateway_id) || Map.get(data, :gateway_node),
        partition: Map.get(data, :partition_id)
      }

      case MtrMetricsIngestor.ingest(mtr_payload, status) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("AgentCommandStatusHandler: failed to ingest on-demand MTR result",
            command_id: Map.get(data, :command_id),
            reason: inspect(reason)
          )
      end
    end
  end

  defp maybe_ingest_mtr_result(_data), do: :ok

  defp payload_trace(%{"trace" => trace}) when is_map(trace), do: trace
  defp payload_trace(_payload), do: nil
end
