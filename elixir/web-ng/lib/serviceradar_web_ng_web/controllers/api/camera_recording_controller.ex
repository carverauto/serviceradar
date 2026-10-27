defmodule ServiceRadarWebNGWeb.Api.CameraRecordingController do
  @moduledoc "Authenticated metadata and bounded fragment reads for retained camera archives."

  use ServiceRadarWebNGWeb, :controller

  alias Ash.Error.Forbidden
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.ArchiveUploads
  alias ServiceRadar.Camera.Source
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.CameraArchiveReader
  alias ServiceRadarWebNG.RBAC

  @read_permissions ["devices.view", "devices.cameras.recordings.view"]

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

  def init_object(conn, params), do: read_object(conn, params, :init)

  def fragment(conn, %{"index" => index} = params) when byte_size(index) in 1..4 do
    selector =
      case Integer.parse(index) do
        {value, ""} when value in 0..4095 ->
          if Integer.to_string(value) == index, do: {:fragment, value}, else: :invalid

        _ ->
          :invalid
      end

    read_object(conn, params, selector)
  end

  def fragment(conn, params), do: read_object(conn, params, :invalid)

  defp read_object(conn, %{"camera_source_id" => source_id, "id" => block_id}, selector) do
    conn =
      conn
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_header("x-content-type-options", "nosniff")

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
      {:error, :unauthorized} ->
        error(conn, :unauthorized, "unauthorized")

      {:error, :permission_revoked} ->
        error(conn, :forbidden, "forbidden")

      {:error, %Forbidden{}} ->
        error(conn, :forbidden, "forbidden")

      {:error, :invalid_id} ->
        error(conn, :bad_request, "invalid_request")

      {:error, :recording_block_not_found} ->
        error(conn, :not_found, "recording_not_found")

      {:error, :archive_unavailable} ->
        error(conn, :conflict, "recording_unavailable")

      {:error, reason} when reason in [:invalid_recording_range, :recording_range_too_large] ->
        error(conn, 416, "recording_range_not_satisfiable")

      _ ->
        error(conn, :service_unavailable, "archive_read_unavailable")
    end
  end

  defp authorize_read(%Scope{user: user} = scope, source_id, block_id) when not is_nil(user) do
    with {:ok, scope} <- RBAC.authorize_current(scope, @read_permissions),
         {:ok, source_id} <- cast_id(source_id),
         {:ok, block_id} <- cast_id(block_id),
         {:ok, source} <- Source |> Ash.Query.for_read(:by_id, %{id: source_id}) |> Ash.read_one(scope: scope) do
      if source, do: {:ok, scope, source_id, block_id}, else: {:error, :recording_block_not_found}
    end
  end

  defp authorize_read(_, _, _), do: {:error, :unauthorized}

  defp cast_id(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_id}
    end
  end

  defp error(conn, status, code), do: conn |> put_status(status) |> json(%{error: code})
end
