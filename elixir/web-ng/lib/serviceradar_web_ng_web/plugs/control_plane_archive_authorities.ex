defmodule ServiceRadarWebNGWeb.Plugs.ControlPlaneArchiveAuthorities do
  @moduledoc "Private media-administration transport for bounded archive authority."
  @behaviour Plug

  import Plug.Conn

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.ArchiveAuthorities
  alias ServiceRadarWebNGWeb.ControlPlaneJSON

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case {conn.method, Enum.map(conn.path_info, &URI.decode/1)} do
      {"GET", ["v1", "media", authority, id]}
      when authority in ~w(init-authorities media-authorities manifest-authorities) ->
        respond_result(
          conn,
          ArchiveAuthorities.status(kind(authority), installation(conn), id, actor: actor())
        )

      {"PUT", ["v1", "media", authority, id]}
      when authority in ~w(init-authorities media-authorities manifest-authorities) ->
        read(conn, id, :apply, kind(authority))

      {"POST", ["v1", "media", authority, id, "revoke"]}
      when authority in ~w(init-authorities media-authorities manifest-authorities) ->
        read(conn, id, :revoke, kind(authority))

      _ ->
        conn
    end
  end

  defp read(conn, id, operation, kind) do
    case ControlPlaneJSON.read(conn, 16_384) do
      {:ok, document, conn} ->
        result =
          case {operation, document} do
            {:apply, %{"desired" => %{"binding_id" => ^id}}} ->
              ArchiveAuthorities.apply(kind, installation(conn), document, actor: actor())

            {:revoke, %{"binding_id" => ^id}} ->
              ArchiveAuthorities.revoke(kind, installation(conn), document, actor: actor())

            _ ->
              {:error, invalid_authority(kind)}
          end

        respond_result(conn, result)

      {:error, status, reason, conn} ->
        respond(conn, status, %{status: reason})
    end
  end

  defp kind("init-authorities"), do: :init
  defp kind("media-authorities"), do: :media
  defp kind("manifest-authorities"), do: :manifest
  defp invalid_authority(:init), do: :invalid_init_authority
  defp invalid_authority(:media), do: :invalid_media_authority
  defp invalid_authority(:manifest), do: :invalid_manifest_authority

  defp installation(conn), do: conn.private.control_plane_media_installation
  defp actor, do: SystemActor.system(:camera_archive_control)
  defp respond_result(conn, {:ok, projection}), do: respond(conn, 200, projection)

  defp respond_result(conn, {:error, reason})
       when reason in [
              :invalid_init_authority,
              :invalid_media_authority,
              :invalid_manifest_authority,
              :invalid_init_configuration,
              :invalid_media_configuration,
              :invalid_manifest_configuration,
              :invalid_init_principal,
              :invalid_media_principal,
              :invalid_manifest_principal,
              :invalid_init_application,
              :invalid_media_application,
              :invalid_manifest_application,
              :invalid_init_revocation,
              :invalid_media_revocation,
              :invalid_manifest_revocation,
              :invalid_archive_binding_id
            ], do: respond(conn, 400, %{status: reason})

  defp respond_result(conn, {:error, reason})
       when reason in [
              :archive_binding_not_found,
              :init_authority_not_found,
              :media_authority_not_found,
              :manifest_authority_not_found
            ], do: respond(conn, 404, %{status: reason})

  defp respond_result(conn, {:error, reason})
       when reason in [
              :init_authority_revision_stale,
              :media_authority_revision_stale,
              :manifest_authority_revision_stale,
              :init_authority_revision_conflict,
              :media_authority_revision_conflict,
              :manifest_authority_revision_conflict,
              :init_authority_challenge_mismatch,
              :media_authority_challenge_mismatch,
              :manifest_authority_challenge_mismatch,
              :init_authority_context_mismatch,
              :media_authority_context_mismatch,
              :manifest_authority_context_mismatch,
              :init_authority_origin_mismatch,
              :media_authority_origin_mismatch,
              :manifest_authority_origin_mismatch,
              :init_authority_generation_stale,
              :media_authority_generation_stale,
              :manifest_authority_generation_stale,
              :init_authority_report_unqualified,
              :media_authority_report_unqualified,
              :manifest_authority_report_unqualified,
              :init_authority_expired,
              :media_authority_expired,
              :manifest_authority_expired,
              :init_authority_not_applied,
              :media_authority_not_applied,
              :manifest_authority_not_applied
            ], do: respond(conn, 409, %{status: reason})

  defp respond_result(conn, {:error, _}), do: respond(conn, 503, %{status: "storage_control_unavailable"})

  defp respond(conn, status, body) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end
end
