defmodule ServiceRadarNVRClient do
  @moduledoc """
  Sends one finite, already-authorized H264 capture to one installed NVR endpoint,
  asks that endpoint to archive one sealed local block, reads one sealed
  block's canonical descriptor, queries member status, block states and ledger
  pages, or reads one sealed block's initialization bytes or a fragment for
  playback.

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

  `block_descriptor/3`, `status/2`, `lookup_blocks/3`, `block_page/4` and
  `read_block/6` are reads with no effect on the NVR, so they can be repeated
  freely. `read_block/6` talks to the NVR's separate read listener, so its
  configuration carries the read-purpose token and client certificate rather
  than the ingest ones.
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

  @doc """
  Asks the NVR to tombstone and unlink sealed block `block_id`
  (`POST /v1/blocks/<block_id>/reclaim` on the ingest listener).

  The request binds `version` (1), `storage_id`, `recovery_generation`,
  `operation_id` and `expected_descriptor_sha256`. Returns
  `{:ok, %{storage_id: uuid, block_id: id, operation_id: uuid, status: :reclaimed, reclaimed_at_ms: ms}}`
  on 200, `{:error, {:reclaim_status, status, error}}` for a non-200 answer,
  `{:error, :outcome_unknown}` when the response was lost or malformed, and
  `{:error, :invalid_reclaim_request}` before connecting for invalid arguments.
  """
  def reclaim_block(config, block_id, request, timeout_ms \\ 30_000)

  def reclaim_block(%Config{} = config, block_id, request, timeout_ms) when timeout_ms in 1..300_000 do
    with :ok <- Config.validate(config),
         {:ok, body} <- Wire.reclaim_request(block_id, request) do
      finish = &json_result(&1, &2, :reclaim_status, fn bytes -> Wire.reclaim_receipt(bytes, block_id, request) end)
      content_type = "application/vnd.serviceradar.nvr-reclaim.v1+json"
      path = "/v1/blocks/" <> block_id <> "/reclaim"
      bounded(timeout_ms, &HTTP.post_json(config, path, content_type, body, finish, &1, &2))
    end
  end

  def reclaim_block(_, _, _, _), do: {:error, :invalid_reclaim_request}

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

  @doc """
  Reads the member's status (`GET /v1/status` on the ingest listener).

  Returns `{:ok, status}` with `:storage_id`, `:recovery` (`%{state: :ready |
  :closed, generation: uuid}`), `:inventory` (`:ready`, `:rebuilding`,
  `:mismatch` or `:unavailable`), `:capacity` (measurements, nil unless the
  ledger is ready or mismatched), `:max_sessions`, `:archive_busy` and
  `:release`. A non-200 answer is `{:error, {:member_status, status, error}}`, a
  malformed one `{:error, :invalid_response}`, and a lost or late one
  `{:error, :unavailable}`. Compare `:storage_id` with the member's configured
  storage before trusting anything else.
  """
  def status(config, timeout_ms \\ 10_000)

  def status(%Config{} = config, timeout_ms) when timeout_ms in 1..300_000 do
    with :ok <- Config.validate(config) do
      finish = &json_result(&1, &2, :member_status, fn body -> Wire.member_status(body) end)
      member_call(timeout_ms, &HTTP.get_json(config, "/v1/status", finish, &1, &2))
    end
  end

  def status(_, _), do: {:error, :invalid_status_request}

  @doc """
  Reports the local state of up to 50 blocks (`POST /v1/blocks/lookup` on the
  ingest listener), for a coordinator resolving its own blocks.

  Returns `{:ok, %{storage_id: uuid, blocks: [entry]}}` with one entry per
  requested ID, in order: `:block_id`, `:state` (`:sealed`, `:incomplete`,
  `:unresolved`, `:reclaimed` or `:absent`), `:writing` (an admitted writer
  holds it now), `:bytes` (charged on disk; nil when absent, reclaimed or
  unmeasurable), `:descriptor_sha256` (exactly when sealed) and `:reason`
  (exactly when unresolved). The state comes from the block's journal, not its
  media: fetch the descriptor before freezing a sealed block. `:absent` means
  no directory and no tombstone, and is not proof the block never existed.
  Errors: `{:error, {:lookup_status, status, error}}` for a non-200 answer
  (503 is a busy read pool or a closed recovery gate),
  `{:error, :invalid_response}`, `{:error, :unavailable}`, and
  `{:error, :invalid_lookup_request}` before connecting.
  """
  def lookup_blocks(config, block_ids, timeout_ms \\ 15_000)

  def lookup_blocks(%Config{} = config, block_ids, timeout_ms) when timeout_ms in 1..300_000 do
    with :ok <- Config.validate(config),
         {:ok, body} <- Wire.lookup_request(block_ids) do
      finish = &json_result(&1, &2, :lookup_status, fn bytes -> Wire.lookup(bytes, block_ids) end)
      content_type = "application/vnd.serviceradar.nvr-lookup.v1+json"
      member_call(timeout_ms, &HTTP.post_json(config, "/v1/blocks/lookup", content_type, body, finish, &1, &2))
    end
  end

  def lookup_blocks(_, _, _), do: {:error, :invalid_lookup_request}

  @doc """
  Reads one page of the member's block ledger (`GET /v1/blocks?after=&limit=` on
  the ingest listener), for a reconciler walking the volume.

  Returns `{:ok, %{storage_id: uuid, blocks: [entry], next_after: id | nil}}`:
  up to `limit` (1..100) blocks after `after_id` (nil from the start), ascending,
  each as in `lookup_blocks/3`. Pass `next_after` back as `after_id`; nil means
  the walk is complete. Blocks created behind the cursor appear on the next walk.
  `{:error, {:inventory_status, 503, %{"error" => "inventory_rebuilding"}}}`
  while the member builds its ledger; other errors as in `lookup_blocks/3`.
  """
  def block_page(config, after_id, limit \\ 100, timeout_ms \\ 15_000)

  def block_page(%Config{} = config, after_id, limit, timeout_ms)
      when limit in 1..100 and timeout_ms in 1..300_000 and (is_nil(after_id) or is_binary(after_id)) do
    with :ok <- Config.validate(config),
         {:ok, path} <- page_path(after_id, limit) do
      finish = &json_result(&1, &2, :inventory_status, fn bytes -> Wire.block_page(bytes, after_id, limit) end)
      member_call(timeout_ms, &HTTP.get_json(config, path, finish, &1, &2))
    end
  end

  def block_page(_, _, _, _), do: {:error, :invalid_inventory_request}

  defp page_path(nil, limit), do: {:ok, "/v1/blocks?limit=" <> Integer.to_string(limit)}

  defp page_path(after_id, limit) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, after_id),
      do: {:ok, "/v1/blocks?after=" <> after_id <> "&limit=" <> Integer.to_string(limit)},
      else: {:error, :invalid_inventory_request}
  end

  defp json_result(200, body, _tag, decode), do: decode.(body)
  defp json_result(status, body, tag, _decode) when is_integer(status), do: {:error, {tag, status, Wire.error_body(body)}}
  defp json_result(_status, _body, _tag, _decode), do: {:error, :outcome_unknown}

  defp member_call(timeout_ms, operation) do
    case bounded(timeout_ms, operation) do
      {:error, :outcome_unknown} -> {:error, :unavailable}
      result -> result
    end
  end

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
