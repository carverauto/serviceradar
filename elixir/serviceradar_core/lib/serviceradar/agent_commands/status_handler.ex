defmodule ServiceRadar.AgentCommands.StatusHandler do
  @moduledoc """
  Persists agent command ack/progress/result updates into AgentCommand records.
  """

  use GenServer

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentCommands.PubSub
  alias ServiceRadar.ControlRepo
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
    persist_progress(data, state.actor)
    safe_maybe_ingest_mtr_result(data)
    AgentReleaseManager.handle_command_progress(data, actor: state.actor)
    {:noreply, state}
  end

  def handle_info({:command_result, data}, state) do
    persist_result(data, state.actor)
    safe_maybe_ingest_mtr_result(data)
    AgentReleaseManager.handle_command_result(data, actor: state.actor)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp persist_ack(%{command_id: command_id} = data, _actor) do
    command_id_text = normalize_command_id(command_id)

    if command_id_text do
      control_query(
        """
        UPDATE platform.agent_commands
        SET
          status = 'acknowledged',
          acknowledged_at = COALESCE(acknowledged_at, now() AT TIME ZONE 'utc'),
          message = $2,
          updated_at = now() AT TIME ZONE 'utc'
        WHERE command_id = $1::text::uuid
          AND status IN ('queued', 'sent')
        """,
        [command_id_text, Map.get(data, :message)],
        "acknowledge command",
        command_id_text
      )
    end
  end

  defp persist_progress(%{command_id: command_id} = data, _actor) do
    command_id_text = normalize_command_id(command_id)

    if command_id_text do
      control_query(
        """
        UPDATE platform.agent_commands
        SET
          status = CASE
            WHEN status IN ('queued', 'sent', 'acknowledged') THEN 'running'
            ELSE status
          END,
          started_at = CASE
            WHEN status IN ('queued', 'sent', 'acknowledged')
              THEN COALESCE(started_at, now() AT TIME ZONE 'utc')
            ELSE started_at
          END,
          last_progress_at = now() AT TIME ZONE 'utc',
          message = $2,
          progress_percent = $3,
          progress_payload = $4::jsonb,
          updated_at = now() AT TIME ZONE 'utc'
        WHERE command_id = $1::text::uuid
          AND status IN ('queued', 'sent', 'acknowledged', 'running')
        """,
        [
          command_id_text,
          Map.get(data, :message),
          Map.get(data, :progress_percent),
          json_param(Map.get(data, :payload))
        ],
        "persist command progress",
        command_id_text
      )
    end
  end

  defp persist_result(%{command_id: command_id} = data, _actor) do
    command_id_text = normalize_command_id(command_id)

    if command_id_text do
      success? = Map.get(data, :success) == true

      control_query(
        """
        UPDATE platform.agent_commands
        SET
          status = $2,
          completed_at = COALESCE(completed_at, now() AT TIME ZONE 'utc'),
          message = $3,
          result_payload = $4::jsonb,
          failure_reason = $5,
          updated_at = now() AT TIME ZONE 'utc'
        WHERE command_id = $1::text::uuid
          AND status NOT IN ('completed', 'failed', 'expired', 'canceled', 'offline')
        """,
        [
          command_id_text,
          if(success?, do: "completed", else: "failed"),
          Map.get(data, :message),
          json_param(Map.get(data, :payload)),
          if(success?, do: nil, else: Map.get(data, :failure_reason) || "command_failed")
        ],
        "persist command result",
        command_id_text
      )
    end
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

  defp safe_maybe_ingest_mtr_result(data) do
    maybe_ingest_mtr_result(data)
  rescue
    exception ->
      Logger.warning(
        "AgentCommandStatusHandler: failed to ingest MTR command update",
        command_id: map_get_any(data, [:command_id, "command_id"], nil),
        command_type: map_get_any(data, [:command_type, "command_type"], nil),
        reason: Exception.format(:error, exception, __STACKTRACE__)
      )

      :ok
  catch
    kind, reason ->
      Logger.warning(
        "AgentCommandStatusHandler: failed to ingest MTR command update",
        command_id: map_get_any(data, [:command_id, "command_id"], nil),
        command_type: map_get_any(data, [:command_type, "command_type"], nil),
        reason: Exception.format(kind, reason, __STACKTRACE__)
      )

      :ok
  end

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
    command_id_text = normalize_command_id(command_id)

    rows =
      updates
      |> Enum.map(&bulk_target_update_row/1)
      |> Enum.reject(&is_nil/1)

    if rows != [] and not is_nil(command_id_text) do
      case control_repo().query(
             """
             WITH updates AS (
               SELECT
                 $1::text AS command_id,
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
               command_id::uuid,
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
             [command_id_text, rows]
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

  defp normalize_command_id(nil), do: nil

  defp normalize_command_id(command_id) do
    case Ecto.UUID.cast(command_id) do
      {:ok, uuid} ->
        uuid

      :error ->
        case Ecto.UUID.load(command_id) do
          {:ok, uuid} -> uuid
          :error -> nil
        end
    end
  end

  defp control_query(sql, params, action, command_id) do
    case control_repo().query(sql, params) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.warning("AgentCommandStatusHandler: failed to #{action}",
          command_id: command_id,
          reason: inspect(reason)
        )

        :ok
    end
  end

  defp control_repo do
    if Process.whereis(ControlRepo) do
      ControlRepo
    else
      Repo
    end
  end

  defp json_param(nil), do: nil
  defp json_param(value), do: value

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
