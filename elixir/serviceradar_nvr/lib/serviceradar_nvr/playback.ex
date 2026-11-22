defmodule ServiceRadarNVR.Playback do
  @moduledoc """
  Read-only playback routes of the read listener (`ServiceRadarNVR.ReadListener`).

  `GET /v1/blocks/<block_id>/init?descriptor_sha256=<hex>` answers the block's
  initialization bytes and `GET /v1/blocks/<block_id>/fragments/<n>?descriptor_sha256=<hex>`
  answers fragment `n` (its descriptor `sequence`). Each read verifies the whole
  sealed block, requires the canonical descriptor's SHA-256 to equal the one
  given, which Core froze when it cataloged the block, and rechecks the selected
  bytes against their journal digest before answering. Paths, offsets and ranges
  are never accepted.

  Answers: 200 `application/octet-stream`; 400 `invalid_read_request` without
  exactly one well-formed `descriptor_sha256`; 401 for a client that fails the
  read pin or token; 404 `block_not_found` or `fragment_not_found`; 409
  `block_not_sealed` when no seal verifies or the selected bytes fail their
  digest, and `descriptor_mismatch` when the block on disk is not the one
  cataloged; 503 `read_unavailable` with `retry-after: 1` when the playback read
  pool is full, a read times out or the recovery state refuses it. Nothing is
  queued and nothing on disk changes.
  """
  @behaviour Plug

  import Plug.Conn

  alias ServiceRadarNVR.Blocks
  alias ServiceRadarNVR.ListenerConfig

  # The playback read pool retires an admitted read after 10 s.
  @deadline_ms 15_000
  @hex64 ~r/\A[0-9a-f]{64}\z/
  # A block never holds more than 256 fragments (`Config.block_fragments_ceiling/0`).
  @fragment_index ~r/\A(0|[1-9][0-9]{0,2})\z/

  @impl true
  def init(config), do: config

  @impl true
  def call(conn, config) do
    {:ok, timer} = :timer.exit_after(@deadline_ms, :kill)

    try do
      if ListenerConfig.authorized?(conn, config.read),
        do: route(conn),
        else: respond(conn, 401, "unauthorized")
    catch
      :exit, _ -> unavailable(conn)
    after
      :timer.cancel(timer)
    end
  end

  defp route(%{method: "GET", path_info: ["v1", "blocks", block_id, "init"]} = conn), do: read(conn, block_id, :init)

  defp route(%{method: "GET", path_info: ["v1", "blocks", block_id, "fragments", index]} = conn) do
    if Regex.match?(@fragment_index, index),
      do: read(conn, block_id, {:fragment, String.to_integer(index)}),
      else: respond(conn, 404, "fragment_not_found")
  end

  defp route(conn), do: respond(conn, 404, "not_found")

  defp read(conn, block_id, selector) do
    conn = fetch_query_params(conn)

    case conn.query_params do
      %{"descriptor_sha256" => digest} = params when map_size(params) == 1 and is_binary(digest) ->
        if Regex.match?(@hex64, digest),
          do: answer(conn, ServiceRadarNVR.playback_read(block_id, digest, selector)),
          else: respond(conn, 400, "invalid_read_request")

      _ ->
        respond(conn, 400, "invalid_read_request")
    end
  end

  defp answer(conn, {:ok, bytes}) do
    conn
    |> secure_headers()
    |> put_resp_content_type("application/octet-stream", nil)
    |> send_resp(200, bytes)
    |> halt()
  end

  defp answer(conn, {:error, :enoent}), do: respond(conn, 404, "block_not_found")
  defp answer(conn, {:error, :not_readable}), do: respond(conn, 404, "fragment_not_found")
  defp answer(conn, {:error, :descriptor_digest_mismatch}), do: respond(conn, 409, "descriptor_mismatch")

  defp answer(conn, {:error, reason}) do
    case Blocks.read_error(reason, :descriptor) do
      :block_not_found -> respond(conn, 404, "block_not_found")
      :block_not_sealed -> respond(conn, 409, "block_not_sealed")
      _ -> unavailable(conn)
    end
  end

  defp unavailable(conn) do
    conn
    |> put_resp_header("retry-after", "1")
    |> respond(503, "read_unavailable")
  end

  defp respond(conn, status, error) do
    conn
    |> secure_headers()
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: error}))
    |> halt()
  end

  defp secure_headers(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
  end
end
