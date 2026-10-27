defmodule ServiceRadarWebNGWeb.Api.CameraRecordingController do
  @moduledoc "Authenticated discovery, metadata, playlists and bounded reads for retained camera archives."

  use ServiceRadarWebNGWeb, :controller

  alias Ash.Error.Forbidden
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.ArchiveUploads
  alias ServiceRadar.Camera.Source
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.CameraArchivePlaylist
  alias ServiceRadarWebNG.CameraArchiveReader
  alias ServiceRadarWebNG.RBAC

  @read_permissions ["devices.view", "devices.cameras.recordings.view"]

  def index(conn, %{"camera_source_id" => source_id} = params) do
    conn = private_media(conn)

    with {:ok, source_id} <- authorize_inventory(conn.assigns[:current_scope], source_id),
         {:ok, limit} <- decimal(Map.get(params, "limit", "10"), 1, 20),
         {:ok, inventory} <-
           ArchiveUploads.archive_inventory(source_id, [limit: limit, cursor: params["cursor"]],
             actor: SystemActor.system(:camera_archive_metadata)
           ) do
      json(conn, %{data: inventory})
    else
      {:error, :invalid_page} -> error(conn, :bad_request, "invalid_request")
      {:error, reason} -> archive_error(conn, reason)
    end
  end

  def show(conn, %{"camera_source_id" => source_id, "id" => block_id}) do
    conn = put_resp_header(conn, "cache-control", "private, no-store")

    with {:ok, _scope, source_id, block_id} <- authorize_read(conn.assigns[:current_scope], source_id, block_id),
         {:ok, metadata} <-
           ArchiveUploads.archive_metadata(source_id, block_id, actor: SystemActor.system(:camera_archive_metadata)) do
      json(conn, %{data: metadata})
    else
      {:error, :unauthorized} -> error(conn, :unauthorized, "unauthorized")
      {:error, :permission_revoked} -> error(conn, :forbidden, "forbidden")
      {:error, :invalid_id} -> error(conn, :bad_request, "invalid_request")
      {:error, :recording_block_not_found} -> error(conn, :not_found, "recording_not_found")
      {:error, %Forbidden{}} -> error(conn, :forbidden, "forbidden")
      {:error, _} -> error(conn, :service_unavailable, "archive_metadata_unavailable")
    end
  end

  def playlist(conn, %{"camera_source_id" => source_id, "id" => block_id} = params) do
    conn = private_media(conn)

    with {:ok, _scope, source_id, block_id} <- authorize_read(conn.assigns[:current_scope], source_id, block_id),
         true <- get_req_header(conn, "range") == [] || {:error, :invalid_id},
         {:ok, first} <- decimal(Map.get(params, "first", "0"), 0, 4095),
         {:ok, count} <- decimal(Map.get(params, "count", "64"), 1, 64),
         {:ok, metadata} <-
           ArchiveUploads.archive_metadata(source_id, block_id, actor: SystemActor.system(:camera_archive_metadata)),
         {:ok, playlist} <- CameraArchivePlaylist.render(metadata, first, count) do
      conn |> put_resp_content_type("application/vnd.apple.mpegurl", nil) |> send_resp(200, playlist)
    else
      {:error, reason} -> archive_error(conn, reason)
    end
  end

  def init_object(conn, params), do: read_object(conn, params, :init)

  def fragment(conn, params) do
    selector =
      case decimal(params["index"], 0, 4095) do
        {:ok, index} -> {:fragment, index}
        _ -> :invalid
      end

    read_object(conn, params, selector)
  end

  defp read_object(conn, %{"camera_source_id" => source_id, "id" => block_id}, selector) do
    conn = private_media(conn)

    deadline = System.monotonic_time(:millisecond) + 10_000
    opts = [actor: SystemActor.system(:camera_archive_reader)]

    with {:ok, scope, source_id, block_id} <- authorize_read(conn.assigns[:current_scope], source_id, block_id),
         true <- (selector != :invalid and get_req_header(conn, "range") == []) || {:error, :invalid_id},
         {:ok, plan} <- ArchiveUploads.archive_range(source_id, block_id, selector, opts),
         {:ok, bytes} <- CameraArchiveReader.fetch(plan, deadline),
         {:ok, _, ^source_id, ^block_id} <- authorize_read(scope, source_id, block_id),
         {:ok, current} <- ArchiveUploads.archive_range(source_id, block_id, selector, opts),
         true <- current == plan and System.monotonic_time(:millisecond) < deadline do
      conn |> put_resp_content_type("video/mp4", nil) |> send_resp(200, bytes)
    else
      {:error, reason} -> archive_error(conn, reason)
      _ -> archive_error(conn, :read_failed)
    end
  end

  defp private_media(conn) do
    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
  end

  defp decimal(value, minimum, maximum) when is_binary(value) and byte_size(value) in 1..4 do
    case Integer.parse(value) do
      {integer, ""} when integer >= minimum and integer <= maximum ->
        if Integer.to_string(integer) == value, do: {:ok, integer}, else: {:error, :invalid_id}

      _ ->
        {:error, :invalid_id}
    end
  end

  defp decimal(_, _, _), do: {:error, :invalid_id}

  defp archive_error(conn, :unauthorized), do: error(conn, :unauthorized, "unauthorized")
  defp archive_error(conn, :permission_revoked), do: error(conn, :forbidden, "forbidden")
  defp archive_error(conn, %Forbidden{}), do: error(conn, :forbidden, "forbidden")
  defp archive_error(conn, :invalid_id), do: error(conn, :bad_request, "invalid_request")
  defp archive_error(conn, :recording_block_not_found), do: error(conn, :not_found, "recording_not_found")
  defp archive_error(conn, :archive_unavailable), do: error(conn, :conflict, "recording_unavailable")

  defp archive_error(conn, reason) when reason in [:invalid_recording_range, :recording_range_too_large],
    do: error(conn, 416, "recording_range_not_satisfiable")

  defp archive_error(conn, reason) when reason in [:invalid_recording_window, :recording_window_too_large],
    do: error(conn, 416, "recording_window_not_satisfiable")

  defp archive_error(conn, _), do: error(conn, :service_unavailable, "archive_read_unavailable")

  defp authorize_read(%Scope{user: user} = scope, source_id, block_id) when not is_nil(user) do
    with {:ok, scope} <- RBAC.authorize_current(scope, @read_permissions),
         {:ok, source_id} <- cast_id(source_id),
         {:ok, block_id} <- cast_id(block_id),
         :ok <- source_exists(scope, source_id) do
      {:ok, scope, source_id, block_id}
    end
  end

  defp authorize_read(_, _, _), do: {:error, :unauthorized}

  defp authorize_inventory(%Scope{user: user} = scope, source_id) when not is_nil(user) do
    with {:ok, scope} <- RBAC.authorize_current(scope, @read_permissions),
         {:ok, source_id} <- cast_id(source_id),
         :ok <- source_exists(scope, source_id) do
      {:ok, source_id}
    end
  end

  defp authorize_inventory(_, _), do: {:error, :unauthorized}

  defp source_exists(scope, source_id) do
    with {:ok, source} <- Source |> Ash.Query.for_read(:by_id, %{id: source_id}) |> Ash.read_one(scope: scope) do
      if source, do: :ok, else: {:error, :recording_block_not_found}
    end
  end

  defp cast_id(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_id}
    end
  end

  defp error(conn, status, code), do: conn |> put_status(status) |> json(%{error: code})
end
