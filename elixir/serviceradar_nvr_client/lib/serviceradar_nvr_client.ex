defmodule ServiceRadarNVRClient do
  @moduledoc """
  Sends one finite, already-authorized H264 capture to one installed NVR endpoint.

  The lazy enumerable yields maps containing `payload`, `sequence`, `pts` and
  `dts`. It runs in a separate, bounded process: do not pass a caller-owned socket
  or mailbox as an enumerable. The coordinator must supply source/writer
  authority and aggregate admission before calling this API. This client does
  not acquire leases, open cameras, select a replica or register playback.

  A normal enumerable completion requests sealing. A raised error, invalid unit,
  caller loss or deadline aborts the connection without the end marker. Once a
  request starts, failure may leave retained blocks: there is no retry or failover.
  `:outcome_unknown` requires discovery at the original NVR, not a new capture.
  """

  alias ServiceRadarNVRClient.Config
  alias ServiceRadarNVRClient.HTTP
  alias ServiceRadarNVRClient.Wire

  def send_recording(config, header, units, timeout_ms \\ 30_000)

  def send_recording(%Config{} = config, header, units, timeout_ms) when timeout_ms in 1..300_000 do
    with :ok <- Config.validate(config),
         {:ok, bytes} <- Wire.header(header) do
      caller = self()
      reply = :erlang.alias([:reply])
      deadline = System.monotonic_time(:millisecond) + timeout_ms

      {pid, monitor} =
        spawn_monitor(fn ->
          {:ok, timer} = :timer.exit_after(timeout_ms, :kill)
          owner = Process.monitor(caller)

          try do
            send(reply, {reply, HTTP.send_recording(config, header, bytes, units, deadline, owner)})
          after
            :timer.cancel(timer)
          end
        end)

      try do
        receive do
          {^reply, result} -> result
          {:DOWN, ^monitor, :process, ^pid, _} -> {:error, :outcome_unknown}
        after
          timeout_ms -> {:error, :outcome_unknown}
        end
      after
        :erlang.unalias(reply)
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
      end
    end
  end

  def send_recording(_, _, _, _), do: {:error, :invalid_ingest_request}
end
