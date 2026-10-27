defmodule ServiceRadarCoreElx.CameraStorage.ReadRouter do
  @moduledoc false
  use Plug.Router

  alias ServiceRadar.JSONDocument
  alias ServiceRadarCoreElx.CameraStorage.Read
  alias ServiceRadarCoreElx.CameraStorage.ReadSession

  @body_limit 8192

  plug(:authenticate)
  plug(:match)
  plug(:dispatch)

  post "/v1/archive-ranges" do
    deadline = System.monotonic_time(:millisecond) + 10_000

    with [content_type] <- get_req_header(conn, "content-type"),
         ["application/json" | _] <- String.split(content_type, ";"),
         {:ok, config} <- ReadSession.reserve(deadline) do
      receive_range(conn, config, deadline)
    else
      {:error, _} -> respond(conn, 503, "archive_read_unavailable")
      _ -> respond(conn, 400, "invalid_archive_range")
    end
  end

  match _ do
    respond(conn, 404, "not_found")
  end

  def child_spec(config) do
    Supervisor.child_spec(
      {Bandit,
       plug: {__MODULE__, config},
       scheme: :https,
       port: config.port,
       ip: {0, 0, 0, 0},
       http_1_options: [max_requests: 1],
       http_2_options: [enabled: false],
       thousand_island_options: [
         num_acceptors: 2,
         num_connections: 8,
         transport_options: config.tls ++ [verify: :verify_peer, fail_if_no_peer_cert: true]
       ]},
      id: __MODULE__
    )
  end

  def init(config), do: config

  def call(conn, config), do: conn |> put_private(:archive_read_listener, config) |> super(config)

  defp authenticate(conn, _) do
    config = conn.private.archive_read_listener
    certificate = conn |> get_peer_data() |> Map.get(:ssl_cert)

    with true <- is_binary(certificate),
         pin = Base.encode16(:crypto.hash(:sha256, certificate), case: :lower),
         true <- Plug.Crypto.secure_compare(pin, config.pin),
         ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         true <- Plug.Crypto.secure_compare(:crypto.hash(:sha256, token), config.token_sha256) do
      conn
    else
      _ -> conn |> respond(401, "unauthorized") |> halt()
    end
  end

  defp receive_range(conn, config, deadline) do
    with {:ok, body, conn} <- read(conn, "", deadline),
         {:ok, plan} <- JSONDocument.decode_object(body, @body_limit),
         {:ok, bytes} <- Read.run(config, plan, deadline),
         true <- System.monotonic_time(:millisecond) < deadline do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_content_type("application/octet-stream", nil)
      |> send_resp(200, bytes)
    else
      {:error, :request_too_large, conn} -> respond(conn, 413, "request_too_large")
      {:error, :body_timeout, conn} -> respond(conn, 408, "archive_read_unavailable")
      {:error, :invalid_request} -> respond(conn, 400, "invalid_archive_range")
      {:error, :invalid_archive_range} -> respond(conn, 400, "invalid_archive_range")
      _ -> respond(conn, 503, "archive_read_unavailable")
    end
  end

  defp read(conn, bytes, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      case read_body(conn,
             length: @body_limit - byte_size(bytes) + 1,
             read_length: @body_limit + 1,
             read_timeout: remaining
           ) do
        {status, part, conn} when status in [:ok, :more] ->
          receive_body(status, bytes <> part, conn, deadline)

        _ ->
          {:error, :body_timeout, conn}
      end
    else
      {:error, :body_timeout, conn}
    end
  end

  defp receive_body(status, bytes, conn, deadline) do
    cond do
      byte_size(bytes) > @body_limit -> {:error, :request_too_large, conn}
      status == :ok -> {:ok, bytes, conn}
      true -> read(conn, bytes, deadline)
    end
  end

  defp respond(conn, status, reason) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{"error" => reason}))
  end
end
