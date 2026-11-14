defmodule ServiceRadarNVR.Ingest do
  @moduledoc """
  Finite, authenticated H264 input. A successful response reports local seals only.

  One HTTP/1 request owns one producer and one recording worker. The connection
  deadline survives caller loss. Broken or incomplete bodies cancel the worker
  and preserve its journal; only an explicit end marker followed by HTTP EOF can
  request a seal. There is no automatic retry, takeover or storage initialization.
  """
  @behaviour Plug

  import Plug.Conn

  alias ServiceRadarNVR.IngestStream
  alias ServiceRadarRecording.Inbox
  alias ServiceRadarRecordingControl.RecoveryGate

  @impl true
  def init(config), do: config

  @impl true
  def call(conn, config) do
    {:ok, timer} = :timer.exit_after(config.max_duration_ms, :kill)

    try do
      with :https <- conn.scheme,
           %{ssl_cert: certificate} when is_binary(certificate) <- get_peer_data(conn),
           true <- :crypto.hash(:sha256, certificate) == config.ingest.client_sha256,
           ["Bearer " <> token] when byte_size(token) <= 512 <- get_req_header(conn, "authorization"),
           true <- Plug.Crypto.secure_compare(:crypto.hash(:sha256, token), config.ingest.token_sha256) do
        route(conn, config)
      else
        _ -> respond(conn, 401, %{error: "unauthorized"})
      end
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

          _ ->
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

  defp route(conn, _config), do: respond(conn, 404, %{error: "not_found"})

  defp consume(stream, worker, inbox, blocks) do
    case IngestStream.next(stream) do
      {:ok, unit, stream} ->
        with :ok <- Inbox.offer(inbox, Map.put(unit, :media_ingest_id, inbox.media_ingest_id)),
             %{last_sequence: sequence} when sequence == unit.sequence <- ServiceRadarNVR.status(worker),
             {:ok, blocks} <- completed_blocks(worker, blocks) do
          consume(stream, worker, inbox, blocks)
        end

      {:done, stream} ->
        :ok = Inbox.finish(inbox)
        await_seal(worker, stream.conn, blocks)

      error ->
        error
    end
  end

  # Status is ordered behind the offered frame from this same producer. Network
  # backpressure waits here, outside the shared camera/live-view pipeline.
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

  defp await_seal(worker, conn, blocks) do
    receive do
      {:nvr_block_sealed, ^worker, %{snapshot: snapshot}} when length(blocks) < 255 ->
        await_seal(worker, conn, [Path.basename(snapshot.directory) | blocks])

      {:nvr_block_sealed, ^worker, _receipt} ->
        {:error, :too_many_blocks}

      {:nvr_recording, ^worker, {:ok, %{snapshot: snapshot}}} ->
        {:ok, Enum.reverse([Path.basename(snapshot.directory) | blocks]), conn}

      {:nvr_recording, ^worker, {:error, _} = error} ->
        error
    after
      5000 -> {:error, :seal_timeout}
    end
  end

  defp stop(worker) do
    ServiceRadarNVR.stop(worker)
  catch
    :exit, _ -> :ok
  end

  defp respond(conn, status, result) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(result))
    |> halt()
  end
end
