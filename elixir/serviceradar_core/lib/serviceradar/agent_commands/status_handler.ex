defmodule ServiceRadar.AgentCommands.StatusHandler do
  @moduledoc """
  Persists agent command ack/progress/result updates into AgentCommand records.
  """

  use GenServer

  alias Ash.Error.Query.NotFound
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentCommands.PubSub
  alias ServiceRadar.Edge.AgentCommand
  alias ServiceRadar.Edge.AgentReleaseManager
  alias ServiceRadar.Observability.MtrMetricsIngestor
  alias ServiceRadar.Observability.MtrPubSub
  alias ServiceRadar.Repo

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
    AgentReleaseManager.handle_command_ack(data, actor: state.actor)
    {:noreply, state}
  end

  def handle_info({:command_progress, data}, state) do
    maybe_ingest_mtr_result(data)
    persist_progress(data, state.actor)
    AgentReleaseManager.handle_command_progress(data, actor: state.actor)
    {:noreply, state}
  end

  def handle_info({:command_result, data}, state) do
    maybe_ingest_mtr_result(data)
    persist_result(data, state.actor)
    AgentReleaseManager.handle_command_result(data, actor: state.actor)
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
          progress_percent: Map.get(data, :progress_percent),
          progress_payload: Map.get(data, :payload)
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
    payload = map_get_any(data, [:payload, "payload"], nil)

    cond do
      to_string(command_type) == "mtr.run" and success == true ->
        trace = payload_trace(payload)

        if is_map(payload) and is_map(trace),
          do: ingest_mtr_result(data, payload, trace)

      to_string(command_type) == "mtr.bulk_run" and is_map(payload) ->
        ingest_bulk_mtr_progress(payload, data)

      true ->
        :ok
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

  defp ingest_bulk_mtr_progress(payload, data) when is_map(payload) do
    updates =
      payload
      |> map_get_any(["target_updates", :target_updates], [])
      |> List.wrap()
      |> Enum.filter(&is_map/1)

    command_id = map_get_any(data, [:command_id, "command_id"], nil)
    persist_bulk_target_updates(command_id, updates)
    ingest_bulk_target_traces(command_id, data, updates)
  end

  defp ingest_bulk_mtr_progress(_payload, _data), do: :ok

  defp ingest_bulk_target_traces(nil, _data, _updates), do: :ok
  defp ingest_bulk_target_traces(_command_id, _data, []), do: :ok

  defp ingest_bulk_target_traces(command_id, data, updates) when is_list(updates) do
    results =
      updates
      |> Enum.map(&bulk_ingest_result(command_id, data, &1))
      |> Enum.reject(&is_nil/1)

    if results != [] do
      status_payload = build_ingest_status(data)

      case MtrMetricsIngestor.ingest(%{"results" => results}, status_payload) do
        :ok ->
          Enum.each(results, fn result ->
            _ =
              MtrPubSub.broadcast_ingest(%{
                command_id: command_id,
                target: result["target"],
                agent_id: Map.get(data, :agent_id)
              })
          end)

        {:error, reason} ->
          Logger.warning(
            "AgentCommandStatusHandler: failed to ingest bulk MTR results",
            command_id: command_id,
            reason: inspect(reason),
            target_count: length(results)
          )
      end
    end
  end

  defp bulk_ingest_result(command_id, data, update) when is_map(update) do
    trace = map_get_any(update, ["trace", :trace], nil)
    target = map_get_any(update, ["target", :target], "")
    status = normalize_bulk_target_status(map_get_any(update, ["status", :status], "queued"))

    if status == "completed" and is_map(trace) and target != "" do
      timestamp =
        map_get_any(trace, ["timestamp", :timestamp], nil) ||
          map_get_any(data, [:timestamp, "timestamp"], nil)

      %{
        "check_id" => "#{command_id}:#{target}",
        "check_name" => "bulk-mtr",
        "target" => target,
        "available" => map_get_any(trace, ["target_reached", :target_reached], false) == true,
        "trace" => trace,
        "timestamp" => timestamp,
        "error" => nil,
        "device_id" => map_get_any(data, [:command_id, "command_id"], nil)
      }
    end
  end

  defp bulk_ingest_result(_command_id, _data, _update), do: nil

  defp persist_bulk_target_updates(nil, _updates), do: :ok
  defp persist_bulk_target_updates(_command_id, []), do: :ok

  defp persist_bulk_target_updates(command_id, updates) when is_list(updates) do
    rows =
      updates
      |> Enum.map(&bulk_target_update_row/1)
      |> Enum.reject(&is_nil/1)

    if rows != [] do
      case Repo.query(
             """
             WITH updates AS (
               SELECT
                 $1::uuid AS command_id,
                 x.target::text AS target,
                 x.status::text AS status,
                 x.error::text AS error,
                 x.result_payload::jsonb AS result_payload,
                 COALESCE(x.attempt_count, 1)::integer AS attempt_count,
                 CASE WHEN x.status = 'running' THEN now() AT TIME ZONE 'utc' END AS started_at,
                 CASE
                   WHEN x.status IN ('completed', 'failed', 'canceled', 'timed_out')
                     THEN now() AT TIME ZONE 'utc'
                 END AS completed_at
               FROM jsonb_to_recordset($2::jsonb) AS x(
                 target text,
                 status text,
                 error text,
                 result_payload jsonb,
                 attempt_count integer
               )
               WHERE x.target IS NOT NULL AND btrim(x.target) <> ''
             )
             INSERT INTO platform.mtr_bulk_job_targets (
               command_id,
               target,
               status,
               error,
               result_payload,
               attempt_count,
               started_at,
               completed_at,
               inserted_at,
               updated_at
             )
             SELECT
               command_id,
               target,
               status,
               error,
               result_payload,
               attempt_count,
               started_at,
               completed_at,
               now() AT TIME ZONE 'utc',
               now() AT TIME ZONE 'utc'
             FROM updates
             ON CONFLICT (command_id, target)
             DO UPDATE SET
               status = EXCLUDED.status,
               error = EXCLUDED.error,
               result_payload = COALESCE(EXCLUDED.result_payload, platform.mtr_bulk_job_targets.result_payload),
               attempt_count = GREATEST(platform.mtr_bulk_job_targets.attempt_count, EXCLUDED.attempt_count),
               started_at = COALESCE(platform.mtr_bulk_job_targets.started_at, EXCLUDED.started_at),
               completed_at = COALESCE(EXCLUDED.completed_at, platform.mtr_bulk_job_targets.completed_at),
               updated_at = now() AT TIME ZONE 'utc'
             """,
             [command_id, Jason.encode!(rows)]
           ) do
        {:ok, _result} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "AgentCommandStatusHandler: failed to persist bulk MTR target updates",
            command_id: command_id,
            reason: inspect(reason),
            target_count: length(rows)
          )
      end
    end
  end

  defp bulk_target_update_row(update) when is_map(update) do
    target =
      update
      |> map_get_any(["target", :target], nil)
      |> to_string_or_nil()

    if is_nil(target) or target == "" do
      nil
    else
      %{
        target: target,
        status: normalize_bulk_target_status(map_get_any(update, ["status", :status], "queued")),
        error: map_get_any(update, ["error", :error], nil),
        result_payload: map_get_any(update, ["result_payload", :result_payload], nil),
        attempt_count: map_get_any(update, ["attempt_count", :attempt_count], 1)
      }
    end
  end

  defp bulk_target_update_row(_update), do: nil

  defp normalize_bulk_target_status(value) do
    value =
      value
      |> to_string()
      |> String.trim()
      |> String.downcase()

    if value in ["queued", "running", "completed", "failed", "canceled", "timed_out"] do
      value
    else
      "queued"
    end
  end

  defp map_get_any(map, keys, default) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, default, fn key ->
      case Map.get(map, key) do
        nil -> nil
        value -> value
      end
    end)
  end

  defp map_get_any(_map, _keys, default), do: default

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value), do: to_string(value)
end
