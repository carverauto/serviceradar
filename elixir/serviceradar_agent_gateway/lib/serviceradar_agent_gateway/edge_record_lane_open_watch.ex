defmodule ServiceRadarAgentGateway.EdgeRecordLaneOpenWatch do
  @moduledoc """
  Reports an `EdgeRecordIngestService.Stream` that ends before its `lane_open_ack` was sent.

  The agent opens a lane and waits for the ack before it sends anything else, so a stream that
  never acks delivers nothing. When the RPC's deadline expires, grpc kills the stream process
  with an exit signal, which skips every `after` clause in it. The report therefore comes from
  this separate process, which monitors the stream process.

  The stream process names the pre-ack step it enters (`phase/3`). The watch keeps the last
  step and what the stream has learned so far: the authenticated agent and, once `lane_open`
  arrived, its lane. If the stream ends before `acked/1`, the watch logs a warning and emits
  `[:serviceradar, :agent_gateway, :edge_record, :lane_open_unacknowledged]` with how long the
  stream waited (`wait_ms`), its `phase`, `agent_id`, `route_profile`, `traffic_class` and exit
  `reason`.

  Phases, in order: `:authenticating`, `:awaiting_lane_open` (no `lane_open` has reached the
  stream yet), `:capability_check`, `:lane_validation`, `:pipeline_lookup`, `:sending_ack`.
  """

  require Logger

  @event [:serviceradar, :agent_gateway, :edge_record, :lane_open_unacknowledged]

  @doc "Starts watching `owner`, the stream process, in its first phase."
  @spec start(pid()) :: pid()
  def start(owner) do
    started = System.monotonic_time(:millisecond)

    spawn(fn ->
      ref = Process.monitor(owner)
      await(ref, started, %{phase: :authenticating, agent_id: nil, route_profile: nil, traffic_class: nil})
    end)
  end

  @doc "Records that the stream entered `phase`, with anything it learned (`agent_id`, lane)."
  @spec phase(pid(), atom(), map()) :: :ok
  def phase(watch, phase, learned \\ %{}) do
    send(watch, {:lane_open_phase, phase, learned})
    :ok
  end

  @doc "The ack was sent: nothing is reported for this stream."
  @spec acked(pid()) :: :ok
  def acked(watch) do
    send(watch, :lane_open_acked)
    :ok
  end

  @doc "The stream returned or raised. Reported only if it had not acked."
  @spec ended(pid()) :: :ok
  def ended(watch) do
    send(watch, :lane_open_stream_ended)
    :ok
  end

  defp await(ref, started, report) do
    receive do
      {:lane_open_phase, phase, learned} ->
        await(ref, started, report |> Map.merge(learned) |> Map.put(:phase, phase))

      :lane_open_acked ->
        Process.demonitor(ref, [:flush])

      :lane_open_stream_ended ->
        Process.demonitor(ref, [:flush])
        report(report, started, :stream_ended)

      {:DOWN, ^ref, :process, _pid, reason} ->
        report(report, started, reason)
    end
  end

  defp report(report, started, reason) do
    wait_ms = System.monotonic_time(:millisecond) - started
    metadata = Map.put(report, :reason, reason)

    Logger.warning(
      "edge record stream ended before lane_open_ack: phase=#{report.phase} " <>
        "agent_id=#{report.agent_id || "unknown"} route_profile=#{report.route_profile || "unknown"} " <>
        "traffic_class=#{report.traffic_class || "unknown"} waited_ms=#{wait_ms} reason=#{inspect(reason, limit: 5)}"
    )

    :telemetry.execute(@event, %{wait_ms: wait_ms}, metadata)
  end
end
