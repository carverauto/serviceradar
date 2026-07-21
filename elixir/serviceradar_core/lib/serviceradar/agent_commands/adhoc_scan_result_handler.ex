defmodule ServiceRadar.AgentCommands.AdhocScanResultHandler do
  @moduledoc """
  Consumes `scan.run_adhoc` command progress/results from the agent command
  bus and:

    * republishes each result row onto JetStream (`scans.results.<scan_run_id>`)
      so results traverse JetStream before the event-writer persists them —
      the command channel is used only for interactive delivery, never as the
      system of record; and
    * advances the owning `ScanRun` lifecycle (running -> completed/partial/
      failed) with a system actor.

  All entry points are self-contained and never raise into the caller
  (`ServiceRadar.AgentCommands.StatusHandler`).
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.NATS.Connection
  alias ServiceRadar.Scans.ScanRun

  require Logger

  @command_type "scan.run_adhoc"
  @subject_prefix "scans.results"

  def handle_command_progress(data) when is_map(data), do: safe(fn -> do_progress(data) end)
  def handle_command_progress(_), do: :ok

  def handle_command_result(data) when is_map(data), do: safe(fn -> do_result(data) end)
  def handle_command_result(_), do: :ok

  defp do_progress(data) do
    if command_type(data) == @command_type do
      payload = get(data, [:payload, "payload"], %{})

      if is_map(payload) do
        publish_rows(payload, data)
        mark_running(payload["scan_run_id"] || payload[:scan_run_id])
      end
    end

    :ok
  end

  defp do_result(data) do
    if command_type(data) == @command_type do
      payload = get(data, [:payload, "payload"], %{})
      success = get(data, [:success, "success"], false) == true

      if is_map(payload) do
        finalize(payload["scan_run_id"] || payload[:scan_run_id], success, payload)
      end
    end

    :ok
  end

  # --- JetStream republish ---

  defp publish_rows(payload, data) do
    scan_run_id = payload["scan_run_id"] || payload[:scan_run_id]
    results = payload["results"] || payload[:results] || []

    if is_binary(scan_run_id) and is_list(results) do
      subject = "#{@subject_prefix}.#{scan_run_id}"
      agent_id = get(data, [:agent_id, "agent_id"], nil)
      gateway_id = get(data, [:gateway_id, "gateway_id"], nil)
      partition = get(data, [:partition, "partition"], nil)

      Enum.each(results, fn row ->
        row
        |> enrich_row(scan_run_id, agent_id, gateway_id, partition)
        |> publish(subject)
      end)
    end

    :ok
  end

  defp enrich_row(row, scan_run_id, agent_id, gateway_id, partition) when is_map(row) do
    row
    |> Map.put("scan_run_id", scan_run_id)
    |> Map.put("agent_id", row["agent_id"] || agent_id)
    |> Map.put("gateway_id", row["gateway_id"] || gateway_id)
    |> Map.put("partition", row["partition"] || partition)
    |> Map.put_new("target_ip", row["target"] || row["target_ip"])
  end

  defp enrich_row(_row, _scan_run_id, _agent_id, _gateway_id, _partition), do: nil

  defp publish(nil, _subject), do: :ok

  defp publish(row, subject) do
    case Jason.encode(row) do
      {:ok, json} -> Connection.publish(subject, json)
      {:error, reason} -> Logger.warning("Ad-hoc scan row encode failed: #{inspect(reason)}")
    end
  end

  # --- ScanRun lifecycle ---

  defp mark_running(scan_run_id) when is_binary(scan_run_id) do
    with_run(scan_run_id, fn run ->
      if run.status == :pending do
        update_run(run, %{status: :running, started_at: DateTime.utc_now()})
      end
    end)
  end

  defp mark_running(_), do: :ok

  defp finalize(scan_run_id, success, payload) when is_binary(scan_run_id) do
    with_run(scan_run_id, fn run ->
      total = payload["total_probes"] || payload[:total_probes] || 0
      completed = payload["completed_probes"] || payload[:completed_probes] || 0

      status =
        cond do
          not success -> :failed
          completed >= total and total > 0 -> :completed
          total == 0 -> :completed
          true -> :partial
        end

      update_run(run, %{
        status: status,
        finished_at: DateTime.utc_now(),
        hosts_up: payload["hosts_up"] || payload[:hosts_up] || run.hosts_up,
        ports_open: payload["ports_open"] || payload[:ports_open] || run.ports_open
      })
    end)
  end

  defp finalize(_, _, _), do: :ok

  defp with_run(scan_run_id, fun) do
    actor = SystemActor.system(:adhoc_scan_status)

    case ScanRun.get(scan_run_id, actor: actor) do
      {:ok, run} when not is_nil(run) -> fun.(run)
      _ -> :ok
    end
  end

  defp update_run(run, attrs) do
    actor = SystemActor.system(:adhoc_scan_status)

    case ScanRun.update_status(run, attrs, actor: actor) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("ScanRun update failed: #{inspect(reason)}")
    end
  end

  # --- helpers ---

  defp command_type(data), do: to_string(get(data, [:command_type, "command_type"], ""))

  defp get(map, keys, default) do
    Enum.reduce_while(keys, default, fn key, acc ->
      case Map.get(map, key) do
        nil -> {:cont, acc}
        value -> {:halt, value}
      end
    end)
  end

  defp safe(fun) do
    fun.()
  rescue
    exception ->
      Logger.warning("AdhocScanResultHandler failed: #{inspect(exception)}")
      :ok
  catch
    kind, reason ->
      Logger.warning("AdhocScanResultHandler crashed: #{inspect({kind, reason})}")
      :ok
  end
end
