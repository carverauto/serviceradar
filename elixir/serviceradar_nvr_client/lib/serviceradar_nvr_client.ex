defmodule ServiceRadarNVRClient do
  @moduledoc """
  Sends one finite, already-authorized H264 capture to one installed NVR endpoint,
  asks that endpoint to archive one sealed local block, reads one sealed
  block's canonical descriptor, or reads one sealed block's initialization bytes
  or a fragment for playback.

  The lazy enumerable yields maps containing `payload`, `sequence`, `pts` and
  `dts`. It runs in a separate, bounded process: do not pass a caller-owned socket
  or mailbox as an enumerable. The coordinator must supply source/writer
  authority and aggregate admission before calling this API. This client does
  not acquire leases, open cameras, select a replica or register playback.

  A normal enumerable completion requests sealing. A raised error, invalid unit,
  caller loss or deadline aborts the connection without the end marker. Once a
  request starts, failure may leave retained blocks: there is no retry or failover.
  `:outcome_unknown` requires discovery at the original NVR, not a new capture.

  The client checks for an answer before sending each chunk. A non-200 answer
  read completely before the end marker went out returns
  `{:error, {:ingest_refused, status}}`: the NVR refused the unfinished stream
  and cannot have sealed its final block, whose journal it keeps unsealed. A
  non-200 answer after the end marker returns `{:error, {:ingest_status, status}}`
  and does not rule out a seal. A 200 before the end marker, or an answer that
  is lost or cut short, is `:outcome_unknown`.

  `archive_block/4` sends one small JSON request that carries a bucket
  credential. No returned error contains that credential.

  `block_descriptor/3` and `read_block/6` are reads with no effect on the NVR,
  so they can be repeated freely. `read_block/6` talks to the NVR's separate
  read listener, so its configuration carries the read-purpose token and
  client certificate rather than the ingest ones.
  """

  alias ServiceRadarNVRClient.Config
  alias ServiceRadarNVRClient.HTTP
  alias ServiceRadarNVRClient.Wire

  def send_recording(config, header, units, timeout_ms \\ 30_000)

  def send_recording(%Config{} = config, header, units, timeout_ms) when timeout_ms in 1..300_000 do
    with :ok <- Config.validate(config),
         {:ok, bytes} <- Wire.header(header) do
      bounded(timeout_ms, &HTTP.send_recording(config, header, bytes, units, &1, &2))
    end
  end

  def send_recording(_, _, _, _), do: {:error, :invalid_ingest_request}

  @doc """
  Asks the NVR to copy sealed block `block_id` to the request's destination.

  Returns `{:ok, receipt}` with the NVR's decoded archive receipt,
  `{:error, {:archive_status, status, error}}` when the NVR answered with a
  non-200 status (`error` is its decoded JSON object, or `%{}` when the body is
  not one), or `{:error, :outcome_unknown}` when the response was lost or
  malformed. An invalid block id, request or configuration is refused before
  connecting.
  """
  def archive_block(config, block_id, request, timeout_ms \\ 120_000)

  def archive_block(%Config{} = config, block_id, request, timeout_ms) when timeout_ms in 1..300_000 do
    with :ok <- Config.validate(config),
         {:ok, body} <- Wire.archive_request(block_id, request) do
      bounded(timeout_ms, &HTTP.archive_block(config, block_id, request, body, &1, &2))
    end
  end

  def archive_block(_, _, _, _), do: {:error, :invalid_archive_request}

  def descriptor_timeout_ms, do: 15_000

  @doc """
  Reads the canonical v1 descriptor of sealed block `block_id`.

  Returns `{:ok, descriptor}` with the decoded string-keyed descriptor only when
  the 200 body is a valid descriptor whose canonical encoding is exactly the
  bytes received and whose identity derives `block_id`, so its SHA-256 is the
  digest of the NVR's bytes. A 200 body that fails any of those checks is
  `{:error, :invalid_descriptor_response}`. A non-200 answer is
  `{:error, {:descriptor_status, status, error}}`, with `error` decoded as for
  `archive_block/4`. A lost, truncated or late answer is
  `{:error, :descriptor_unavailable}`. An invalid block id or configuration is
  refused before connecting.
  """
  def block_descriptor(config, block_id, timeout_ms \\ descriptor_timeout_ms())

  def block_descriptor(%Config{} = config, block_id, timeout_ms) when timeout_ms in 1..300_000 do
    with :ok <- Config.validate(config),
         :ok <- Wire.block_id(block_id) do
      case bounded(timeout_ms, &HTTP.block_descriptor(config, block_id, &1, &2)) do
        {:error, :outcome_unknown} -> {:error, :descriptor_unavailable}
        result -> result
      end
    end
  end

  def block_descriptor(_, _, _), do: {:error, :invalid_descriptor_request}

  @doc """
  Reads the initialization bytes (`:init`) or one fragment (`{:fragment, sequence}`)
  of sealed block `block_id` from an NVR read listener, for playback.

  `descriptor_sha256` is the SHA-256 of the block's frozen canonical descriptor:
  the NVR refuses to answer unless its block has exactly that descriptor.
  `expected` is `%{length: bytes, sha256: hex}` for the selected object, from the
  same descriptor; at most 1 MiB for init and 4 MiB for a fragment.
  `{:ok, bytes}` is returned only when the body's length and SHA-256 equal
  `expected`; a body longer than `expected` (or 32 KiB, whichever is larger) is
  not read to the end and counts as unavailable.

  Errors are typed for the caller's copy resolution:
  `{:error, :not_found}` (404: no such block or fragment),
  `{:error, :integrity_mismatch}` (409: the local copy is not the cataloged
  block or its bytes fail their digest, or the answer differs from `expected`),
  `{:error, :unavailable}` (503, transport failure, or no complete answer by the
  deadline), `{:error, {:read_status, status, error}}` for any other answer, and
  `{:error, :invalid_read_request}` before connecting for invalid arguments.
  The default total timeout is 10000 ms (1 through 300000). The read changes
  nothing on the NVR.
  """
  def read_block(config, block_id, descriptor_sha256, selector, expected, timeout_ms \\ 10_000)

  def read_block(%Config{} = config, block_id, descriptor_sha256, selector, expected, timeout_ms)
      when timeout_ms in 1..300_000 do
    with :ok <- Config.validate(config),
         {:ok, path} <- Wire.read_request(block_id, descriptor_sha256, selector, expected) do
      case bounded(timeout_ms, &HTTP.read_media(config, path, expected, &1, &2)) do
        {:error, :outcome_unknown} -> {:error, :unavailable}
        result -> result
      end
    end
  end

  def read_block(_, _, _, _, _, _), do: {:error, :invalid_read_request}

  defp bounded(timeout_ms, operation) do
    caller = self()
    reply = :erlang.alias([:reply])
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    {pid, monitor} =
      spawn_monitor(fn ->
        {:ok, timer} = :timer.exit_after(timeout_ms, :kill)
        owner = Process.monitor(caller)

        try do
          send(reply, {reply, operation.(deadline, owner)})
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
