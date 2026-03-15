defmodule ServiceRadar.AgentCommands.StatusHandler do
  @moduledoc """
  Persists agent command ack/progress/result updates into AgentCommand records.
  """

  use GenServer

  alias Ash.Error.Query.NotFound
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentCommands.PubSub
  alias ServiceRadar.Edge.AgentCommand
  alias ServiceRadar.Observability.MtrMetricsIngestor
  alias ServiceRadar.Observability.MtrPubSub

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

      {:error, %NotFound{}} ->
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

      {:error, %NotFound{}} ->
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

      {:error, %NotFound{}} ->
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

  defp maybe_ingest_mtr_result(data) when is_map(data) do
    command_type = map_get_any(data, [:command_type, "command_type"], "")
    success = map_get_any(data, [:success, "success"], false)

    if to_string(command_type) == "mtr.run" and success == true do
      payload = map_get_any(data, [:payload, "payload"], nil)
      trace = payload_trace(payload)

      if is_map(payload) and is_map(trace),
        do: ingest_mtr_result(data, payload, trace)
    end
  end

  defp maybe_ingest_mtr_result(_data), do: :ok

  defp ingest_mtr_result(data, payload, trace) do
    target = first_target(payload, trace)

    timestamp =
      map_get_any(trace, ["timestamp", :timestamp], nil) ||
        map_get_any(data, [:timestamp, "timestamp"], nil)

    mtr_payload = build_ingest_payload(data, trace, target, timestamp)
    status = build_ingest_status(data)

    case MtrMetricsIngestor.ingest(mtr_payload, status) do
      :ok ->
        _ =
          MtrPubSub.broadcast_ingest(%{
            command_id: Map.get(data, :command_id),
            target: target,
            agent_id: Map.get(data, :agent_id)
          })

        :ok

      {:error, reason} ->
        Logger.warning(
          "AgentCommandStatusHandler: failed to ingest on-demand MTR result: #{inspect(reason)}",
          command_id: Map.get(data, :command_id),
          reason: inspect(reason)
        )
    end
  end

  defp first_target(payload, trace) do
    map_get_any(payload, ["target", :target], nil) ||
      map_get_any(trace, ["target", :target, "target_ip", :target_ip], nil) ||
      ""
  end

  defp build_ingest_payload(data, trace, target, timestamp) do
    %{
      "results" => [
        %{
          "check_id" => map_get_any(data, [:command_id, "command_id"], nil),
          "check_name" => "on-demand",
          "target" => target,
          "available" => map_get_any(trace, ["target_reached", :target_reached], false) == true,
          "trace" => trace,
          "timestamp" => timestamp,
          "error" => nil
        }
      ]
    }
  end

  defp build_ingest_status(data) do
    %{
      agent_id: map_get_any(data, [:agent_id, "agent_id"], nil),
      gateway_id:
        map_get_any(data, [:gateway_id, "gateway_id", :gateway_node, "gateway_node"], nil),
      partition: map_get_any(data, [:partition_id, "partition_id"], nil)
    }
  end

  defp payload_trace(payload) when is_map(payload) do
    case map_get_any(payload, ["trace", :trace], nil) do
      trace when is_map(trace) -> trace
      _ -> nil
    end
  end

  defp payload_trace(_payload), do: nil

  defp map_get_any(map, keys, default) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, default, fn key ->
      case Map.get(map, key) do
        nil -> nil
        value -> value
      end
    end)
  end

  defp map_get_any(_map, _keys, default), do: default
end
