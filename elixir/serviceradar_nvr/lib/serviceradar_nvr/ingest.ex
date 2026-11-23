defmodule ServiceRadarNVR.Ingest do
  @moduledoc """
  Finite, authenticated H264 input. A successful response reports local seals only.

  One HTTP/1 request owns one producer and one recording worker. The connection
  deadline survives caller loss. Broken or incomplete bodies cancel the worker
  and preserve its journal; only an explicit end marker followed by HTTP EOF can
  request a seal. There is no automatic retry, takeover or storage initialization.

  The same authenticated listener accepts `POST /v1/blocks/<block_id>/archive`,
  which copies one sealed block to the request's bucket through
  `ServiceRadarNVR.Archive` under its own 120-second deadline, and
  `GET /v1/blocks/<block_id>/descriptor`, which answers the canonical v1
  descriptor bytes of one verified sealed block (`ServiceRadarNVR.block_descriptor/1`,
  run in the shared read pool). Core freezes exactly those bytes when it
  catalogs the block. The read verifies the whole sealed block first; it is
  404 `block_not_found` for an ID that names no retained block, 409
  `block_not_sealed` for a block with no seal that verifies, and 503
  `descriptor_unavailable` when the read pool or recovery state refuses it.

  It also answers three observations for Core's coordinators: `GET /v1/status`
  (`ServiceRadarNVR.MemberStatus`), `POST /v1/blocks/lookup` for up to 50 block
  IDs and `GET /v1/blocks?after=&limit=` pages of the block ledger
  (`ServiceRadarNVR.block_states/1` and `block_page/2`), and accepts
  `POST /v1/blocks/<block_id>/reclaim` (`ServiceRadarNVR.Reclaim`, 30-second
  deadline) to tombstone and unlink one verified sealed block. Lookups and
  pages run in the shared read pool and report journal state, not verified
  media. See `docs/nvr-ingest.md`, "Member status and block state" and "Local
  block reclaim".
  """
  @behaviour Plug

  import Plug.Conn

  alias ServiceRadarNVR.Archive
  alias ServiceRadarNVR.Blocks
  alias ServiceRadarNVR.IngestStream
  alias ServiceRadarNVR.ListenerConfig
  alias ServiceRadarNVR.MemberStatus
  alias ServiceRadarNVR.Reclaim
  alias ServiceRadarRecording.Inbox
  alias ServiceRadarRecordingControl.RecoveryGate

  require Logger

  @archive_request_bytes 8192
  @reclaim_request_bytes 8192
  # The read pool retires an admitted read after 10 s and its caller after 11 s.
  @read_deadline_ms 15_000
  @lookup_request_bytes 8192

  @impl true
  def init(config), do: config

  @impl true
  def call(conn, config) do
    {:ok, timer} = :timer.exit_after(deadline_ms(conn, config), :kill)

    try do
      if ListenerConfig.authorized?(conn, config.ingest),
        do: route(conn, config),
        else: respond(conn, 401, %{error: "unauthorized"})
    catch
      :exit, _ -> respond(conn, 503, %{error: "ingest_unavailable"})
    after
      :timer.cancel(timer)
    end
  end

  defp route(%{method: "POST", path_info: ["v1", "recordings", "ingest"]} = conn, config) do
    with ["application/vnd.serviceradar.nvr-ingest.v1"] <- get_req_header(conn, "content-type"),
         :ok <- RecoveryGate.check(config.recovery_gate),
         {:ok, identity, clock, stream} <- IngestStream.header(IngestStream.new(conn), config),
         {:ok, worker, inbox} <- ServiceRadarNVR.start_recording(identity, clock) do
      try do
        case consume(stream, worker, inbox, []) do
          {:ok, blocks, conn} ->
            case RecoveryGate.check(config.recovery_gate) do
              :ok ->
                respond(conn, 200, %{version: 1, status: "sealed_local", storage_id: config.storage_id, block_ids: blocks})

              _ ->
                respond(conn, 503, %{error: "ingest_unavailable"})
            end

          outcome ->
            Logger.warning("NVR ingest incomplete: #{inspect(refusal(worker, outcome), limit: 5, printable_limit: 120)}")
            respond(conn, 422, %{error: "ingest_incomplete"})
        end
      after
        Inbox.cancel(inbox)
        if Process.alive?(worker), do: stop(worker)
      end
    else
      {:error, :invalid_ingest_header} -> respond(conn, 400, %{error: "invalid_ingest_header"})
      {:error, _} -> respond(conn, 503, %{error: "ingest_unavailable"})
      _ -> respond(conn, 400, %{error: "invalid_request"})
    end
  end

  defp route(%{method: "POST", path_info: ["v1", "blocks", block_id, "archive"]} = conn, config) do
    with ["application/vnd.serviceradar.nvr-archive.v1+json"] <- get_req_header(conn, "content-type"),
         {:ok, body, conn} <-
           read_body(conn, length: @archive_request_bytes, read_length: @archive_request_bytes, read_timeout: 5_000) do
      {status, result} = Archive.run(config, block_id, body)
      respond(conn, status, result)
    else
      {:more, _partial, conn} -> respond(conn, 400, %{error: "invalid_archive_request"})
      _ -> respond(conn, 400, %{error: "invalid_archive_request"})
    end
  end

  defp route(%{method: "POST", path_info: ["v1", "blocks", block_id, "reclaim"]} = conn, config) do
    with ["application/vnd.serviceradar.nvr-reclaim.v1+json"] <- get_req_header(conn, "content-type"),
         {:ok, body, conn} <-
           read_body(conn, length: @reclaim_request_bytes, read_length: @reclaim_request_bytes, read_timeout: 5_000) do
      case Reclaim.run(config, block_id, body) do
        {503, %{error: error}} -> unavailable(conn, error)
        {status, result} -> respond(conn, status, result)
      end
    else
      {:more, _partial, conn} -> respond(conn, 400, %{error: "invalid_reclaim_request"})
      _ -> respond(conn, 400, %{error: "invalid_reclaim_request"})
    end
  end

  defp route(%{method: "GET", path_info: ["v1", "blocks", block_id, "descriptor"]} = conn, _config) do
    case ServiceRadarNVR.block_descriptor(block_id) do
      {:ok, descriptor} -> respond(conn, 200, descriptor)
      {:error, reason} -> descriptor_refusal(conn, Blocks.read_error(reason, :descriptor))
    end
  end

  defp route(%{method: "GET", path_info: ["v1", "status"]} = conn, config) do
    respond(conn, 200, MemberStatus.report(config))
  end

  defp route(%{method: "POST", path_info: ["v1", "blocks", "lookup"]} = conn, config) do
    with ["application/vnd.serviceradar.nvr-lookup.v1+json"] <- get_req_header(conn, "content-type"),
         {:ok, body, conn} <-
           read_body(conn, length: @lookup_request_bytes, read_length: @lookup_request_bytes, read_timeout: 5_000),
         {:ok, %{"block_ids" => ids} = request} when map_size(request) == 1 and is_list(ids) <- Jason.decode(body) do
      case ServiceRadarNVR.block_states(ids) do
        {:ok, blocks} -> respond(conn, 200, block_list(config, blocks))
        {:error, :invalid_block_id} -> respond(conn, 400, %{error: "invalid_lookup_request"})
        {:error, _} -> unavailable(conn, "lookup_unavailable")
      end
    else
      {:more, _partial, conn} -> respond(conn, 400, %{error: "invalid_lookup_request"})
      _ -> respond(conn, 400, %{error: "invalid_lookup_request"})
    end
  end

  defp route(%{method: "GET", path_info: ["v1", "blocks"]} = conn, config) do
    conn = fetch_query_params(conn)

    with {:ok, after_id, limit} <- page_request(conn.query_params),
         {:ok, blocks} <- ServiceRadarNVR.block_page(after_id, limit) do
      next_after = if length(blocks) == limit, do: List.last(blocks).block_id
      respond(conn, 200, Map.put(block_list(config, blocks), :next_after, next_after))
    else
      :invalid -> respond(conn, 400, %{error: "invalid_inventory_request"})
      {:error, :invalid_block_id} -> respond(conn, 400, %{error: "invalid_inventory_request"})
      {:error, :nvr_inventory_rebuilding} -> unavailable(conn, "inventory_rebuilding")
      {:error, _} -> unavailable(conn, "inventory_unavailable")
    end
  end

  defp route(conn, _config), do: respond(conn, 404, %{error: "not_found"})

  defp page_request(params) do
    with true <- Map.keys(params) -- ["after", "limit"] == [],
         {:ok, limit} <- page_limit(Map.get(params, "limit", "100")),
         after_id = Map.get(params, "after"),
         true <- is_nil(after_id) or is_binary(after_id) do
      {:ok, after_id, limit}
    else
      _ -> :invalid
    end
  end

  defp page_limit(value) when is_binary(value) do
    if Regex.match?(~r/\A[1-9][0-9]{0,2}\z/, value) and String.to_integer(value) <= 100,
      do: {:ok, String.to_integer(value)},
      else: :invalid
  end

  defp page_limit(_value), do: :invalid

  defp block_list(config, blocks) do
    %{version: 1, storage_id: config.storage_id, blocks: Enum.map(blocks, &block_entry/1)}
  end

  defp block_entry(block) do
    %{block_id: block.block_id, state: Atom.to_string(block.state), writing: block.writing, bytes: block.bytes}
    |> put_present(:descriptor_sha256, block.descriptor_sha256)
    |> put_present(:reason, block.reason && Atom.to_string(block.reason))
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp unavailable(conn, error) do
    conn
    |> put_resp_header("retry-after", "1")
    |> respond(503, %{error: error})
  end

  defp descriptor_refusal(conn, :block_not_found), do: respond(conn, 404, %{error: "block_not_found"})
  defp descriptor_refusal(conn, :block_not_sealed), do: respond(conn, 409, %{error: "block_not_sealed"})
  defp descriptor_refusal(conn, _class), do: respond(conn, 503, %{error: "descriptor_unavailable"})

  # The archive, reclaim and read routes have their own deadlines; ingest
  # keeps the recording one.
  defp deadline_ms(%{path_info: ["v1", "blocks", _block_id, "archive"]}, _config), do: Archive.request_timeout_ms()
  defp deadline_ms(%{path_info: ["v1", "blocks", _block_id, "reclaim"]}, _config), do: Reclaim.request_timeout_ms()
  defp deadline_ms(%{path_info: ["v1", "blocks", _block_id, "descriptor"]}, _config), do: @read_deadline_ms
  defp deadline_ms(%{path_info: ["v1", "blocks", "lookup"]}, _config), do: @read_deadline_ms
  defp deadline_ms(%{path_info: ["v1", "blocks"]}, _config), do: @read_deadline_ms
  defp deadline_ms(%{path_info: ["v1", "status"]}, _config), do: @read_deadline_ms
  defp deadline_ms(_conn, config), do: config.max_duration_ms

  defp consume(stream, worker, inbox, blocks) do
    case IngestStream.next(stream) do
      {:ok, unit, stream} ->
        with :ok <- Inbox.offer(inbox, Map.put(unit, :media_ingest_id, inbox.media_ingest_id)),
             %{last_sequence: sequence} when sequence == unit.sequence <- admitted_status(worker, inbox),
             {:ok, blocks} <- completed_blocks(worker, blocks) do
          consume(stream, worker, inbox, blocks)
        end

      {:done, stream} ->
        :ok = Inbox.finish(inbox)
        await_seal(worker, inbox, stream.conn, blocks)

      error ->
        error
    end
  end

  # Status is ordered behind the offered frame from this same producer. Network
  # backpressure waits here, outside the shared camera/live-view pipeline.
  defp admitted_status(worker, inbox) do
    ServiceRadarNVR.status(worker, Inbox.remaining_ms(inbox))
  catch
    :exit, _ -> {:error, :recording_stopped}
  end

  defp completed_blocks(worker, blocks) do
    receive do
      {:nvr_block_sealed, ^worker, %{snapshot: snapshot}} ->
        if length(blocks) < 255,
          do: completed_blocks(worker, [Path.basename(snapshot.directory) | blocks]),
          else: {:error, :too_many_blocks}

      {:nvr_recording, ^worker, result} ->
        result
    after
      0 -> {:ok, blocks}
    end
  end

  defp await_seal(worker, inbox, conn, blocks) do
    receive do
      {:nvr_block_sealed, ^worker, %{snapshot: snapshot}} when length(blocks) < 255 ->
        await_seal(worker, inbox, conn, [Path.basename(snapshot.directory) | blocks])

      {:nvr_block_sealed, ^worker, _receipt} ->
        {:error, :too_many_blocks}

      {:nvr_recording, ^worker, {:ok, %{snapshot: snapshot}}} ->
        {:ok, Enum.reverse([Path.basename(snapshot.directory) | blocks]), conn}

      {:nvr_recording, ^worker, {:error, _} = error} ->
        error
    after
      Inbox.remaining_ms(inbox) -> {:error, :seal_timeout}
    end
  end

  # The writer's own reason, when it reported one, explains the refusal better
  # than the status call that failed because the writer had already stopped.
  defp refusal(worker, outcome) do
    receive do
      {:nvr_recording, ^worker, {:error, reason}} -> reason
    after
      0 ->
        case outcome do
          {:error, reason} -> reason
          _ -> :unexpected_writer_status
        end
    end
  end

  defp stop(worker) do
    ServiceRadarNVR.stop(worker)
  catch
    :exit, _ -> :ok
  end

  # A binary result is already canonical JSON, such as an archive receipt,
  # reclaim receipt or a block descriptor.
  defp respond(conn, status, result) do
    body = if is_binary(result), do: result, else: Jason.encode!(result)

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
    |> halt()
  end
end
