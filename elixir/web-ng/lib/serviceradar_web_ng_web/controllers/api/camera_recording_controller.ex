defmodule ServiceRadarWebNGWeb.Api.CameraRecordingController do
  @moduledoc "Authenticated metadata snapshots for retained camera archives."

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.ArchiveUploads
  alias ServiceRadar.Camera.Source
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.RBAC

  @read_permissions ["devices.view", "devices.cameras.recordings.view"]

  def show(conn, %{"camera_source_id" => source_id, "id" => block_id}) do
    conn = put_resp_header(conn, "cache-control", "private, no-store")

    with %Scope{user: user} = scope when not is_nil(user) <- conn.assigns[:current_scope],
         {:ok, scope} <- RBAC.authorize_current(scope, @read_permissions),
         {:ok, source_id} <- cast_id(source_id),
         {:ok, block_id} <- cast_id(block_id),
         {:ok, %Source{}} <-
           Source
           |> Ash.Query.for_read(:by_id, %{id: source_id})
           |> Ash.read_one(scope: scope),
         {:ok, metadata} <-
           ArchiveUploads.archive_metadata(source_id, block_id, actor: SystemActor.system(:camera_archive_metadata)) do
      json(conn, %{data: metadata})
    else
      nil -> error(conn, :unauthorized, "unauthorized")
      %Scope{} -> error(conn, :unauthorized, "unauthorized")
      {:error, :permission_revoked} -> error(conn, :forbidden, "forbidden")
      {:error, :invalid_id} -> error(conn, :bad_request, "invalid_request")
      {:ok, nil} -> error(conn, :not_found, "recording_not_found")
      {:error, :recording_block_not_found} -> error(conn, :not_found, "recording_not_found")
      {:error, %Ash.Error.Forbidden{}} -> error(conn, :forbidden, "forbidden")
      {:error, _} -> error(conn, :service_unavailable, "archive_metadata_unavailable")
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
