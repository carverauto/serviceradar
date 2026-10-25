defmodule ServiceRadarCoreElx.CameraStorage.Router do
  @moduledoc false
  use Plug.Router

  alias ServiceRadar.JSONDocument
  alias ServiceRadarCoreElx.CameraStorage.Session

  @body_limit 1_400_000
  @lease_fields ~w(id upload_token upload_epoch descriptor_sha256)

  plug(:authenticate)
  plug(:match)
  plug(:dispatch)

  post "/v1/init-uploads" do
    deadline = System.monotonic_time(:millisecond) + conn.private.storage_listener.operation_ms

    with [content_type] <- get_req_header(conn, "content-type"),
         ["application/json" | _] <- String.split(content_type, ";"),
         {:ok, body, conn} <- read(conn, "", deadline),
         {:ok, %{"schema_version" => 1, "lease" => lease, "init_base64" => encoded} = document} <-
           JSONDocument.decode_object(body, @body_limit),
         true <- map_size(document) == 3 and valid_lease?(lease),
         true <- is_binary(encoded) and byte_size(encoded) <= 1_398_104,
         {:ok, bytes} <- Base.decode64(encoded),
         true <- byte_size(bytes) in 1..1_048_576 and Base.encode64(bytes) == encoded,
         {:ok, result} <- Session.upload(lease, bytes, deadline) do
      respond(conn, 200, result)
    else
      {:error, :request_too_large, conn} -> respond(conn, 413, %{"error" => "request_too_large"})
      {:error, :body_timeout, conn} -> respond(conn, 408, %{"error" => "body_timeout"})
      {:error, :invalid_request} -> respond(conn, 400, %{"error" => "invalid_request"})
      {:error, reason} when is_atom(reason) -> respond(conn, 503, %{"error" => Atom.to_string(reason)})
      _ -> respond(conn, 400, %{"error" => "invalid_request"})
    end
  end

  post "/v1/media-uploads" do
    deadline = System.monotonic_time(:millisecond) + min(30_000, conn.private.storage_listener.operation_ms)

    with ["application/octet-stream"] <- get_req_header(conn, "content-type"),
         [] <- get_req_header(conn, "transfer-encoding"),
         [length] <- get_req_header(conn, "content-length"),
         {:ok, length} <- media_length(length),
         [lease_header] <- get_req_header(conn, "x-serviceradar-upload-lease"),
         {:ok, lease} <- JSONDocument.decode_object(lease_header, 1024),
         true <- valid_lease?(lease),
         {:ok, stage} <- Session.reserve_media(lease, length, deadline) do
      try do
        case stage_media(conn, stage) do
          {:ok, sha, conn} ->
            case Session.finish_media(stage.token, sha) do
              {:ok, result} -> respond(conn, 200, result)
              _ -> respond(conn, 503, %{"error" => "media_upload_unavailable"})
            end

          {:error, status, reason, conn} ->
            respond(conn, status, %{"error" => reason})
        end
      after
        Session.release_media(stage.token)
      end
    else
      {:error, :media_too_large} ->
        respond(conn, 413, %{"error" => "request_too_large"})

      {:error, :storage_busy} ->
        respond(conn, 503, %{"error" => "storage_busy"})

      {:error, :storage_scratch_reconciliation_required} ->
        respond(conn, 503, %{"error" => "storage_scratch_reconciliation_required"})

      {:error, :storage_preparation_refused} ->
        respond(conn, 503, %{"error" => "storage_preparation_refused"})

      {:error, :storage_operation_failed} ->
        respond(conn, 503, %{"error" => "storage_operation_failed"})

      _ ->
        respond(conn, 400, %{"error" => "invalid_request"})
    end
  end

  match _ do
    respond(conn, 404, %{"error" => "not_found"})
  end

  def child_spec(config) do
    Supervisor.child_spec(
      {
        Bandit,
        # Bandit's keepalive path drains unread bodies after Plug returns. This
        # private one-shot listener must close rejected ingress without draining.
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
        ]
      },
      id: __MODULE__
    )
  end

  def init(config), do: config

  def call(conn, config) do
    conn |> put_private(:storage_listener, config) |> super(config)
  end

  defp authenticate(conn, _) do
    config = conn.private.storage_listener
    certificate = conn |> get_peer_data() |> Map.get(:ssl_cert)

    with true <- is_binary(certificate),
         pin = :sha256 |> :crypto.hash(certificate) |> Base.encode16(case: :lower),
         true <- Plug.Crypto.secure_compare(pin, config.pin),
         ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         true <- Plug.Crypto.secure_compare(:crypto.hash(:sha256, token), config.token_sha256) do
      conn
    else
      _ -> conn |> respond(401, %{"error" => "unauthorized"}) |> halt()
    end
  end

  defp read(conn, bytes, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      case read_body(conn, length: @body_limit - byte_size(bytes) + 1, read_length: 65_536, read_timeout: remaining) do
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
      System.monotonic_time(:millisecond) >= deadline -> {:error, :body_timeout, conn}
      status == :ok -> {:ok, bytes, conn}
      true -> read(conn, bytes, deadline)
    end
  end

  defp valid_lease?(lease), do: is_map(lease) and Enum.sort(Map.keys(lease)) == Enum.sort(@lease_fields)

  defp media_length(value) when byte_size(value) in 1..8 do
    case Integer.parse(value) do
      {length, ""} when length > 16_777_216 ->
        {:error, :media_too_large}

      {length, ""} when length > 0 ->
        if Integer.to_string(length) == value, do: {:ok, length}, else: {:error, :invalid_request}

      _ ->
        {:error, :invalid_request}
    end
  end

  defp media_length(_), do: {:error, :media_too_large}

  defp stage_media(conn, stage) do
    case File.open(stage.path, [:write, :binary, :raw, :exclusive]) do
      {:ok, file} ->
        try do
          receive_media(conn, stage, file, 0, :crypto.hash_init(:sha256))
        after
          File.close(file)
        end

      _ ->
        {:error, 503, "scratch_unavailable", conn}
    end
  end

  defp receive_media(conn, stage, file, received, hash) do
    remaining = stage.deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      case read_body(conn, length: 65_536, read_length: 65_536, read_timeout: remaining) do
        {status, bytes, _conn} = part when status in [:ok, :more] and byte_size(bytes) <= 65_536 ->
          stage_part(part, stage, file, received, hash)

        _ ->
          {:error, 408, "body_timeout", conn}
      end
    else
      {:error, 408, "body_timeout", conn}
    end
  end

  defp stage_part({status, bytes, conn}, stage, file, received, hash) do
    total = received + byte_size(bytes)

    with true <- total <= stage.length and System.monotonic_time(:millisecond) < stage.deadline,
         :ok <- IO.binwrite(file, bytes) do
      hash = :crypto.hash_update(hash, bytes)

      case {status, total} do
        {:ok, length} when length == stage.length ->
          {:ok, hash |> :crypto.hash_final() |> Base.encode16(case: :lower), conn}

        {:more, length} when length < stage.length ->
          receive_media(conn, stage, file, total, hash)

        _ ->
          {:error, 400, "media_length_mismatch", conn}
      end
    else
      _ -> {:error, 400, "media_staging_refused", conn}
    end
  end

  defp respond(conn, status, body) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
