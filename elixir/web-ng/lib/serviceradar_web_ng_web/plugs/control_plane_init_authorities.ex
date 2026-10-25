defmodule ServiceRadarWebNGWeb.Plugs.ControlPlaneInitAuthorities do
  @moduledoc "Private media-administration transport for bounded init authority."
  @behaviour Plug

  import Plug.Conn

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.ArchiveInitAuthorities
  alias ServiceRadarWebNGWeb.ControlPlaneJSON

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case {conn.method, Enum.map(conn.path_info, &URI.decode/1)} do
      {"GET", ["v1", "media", "init-authorities", id]} ->
        respond_result(
          conn,
          ArchiveInitAuthorities.status(installation(conn), id, actor: actor())
        )

      {"PUT", ["v1", "media", "init-authorities", id]} ->
        read(conn, id, :apply)

      {"POST", ["v1", "media", "init-authorities", id, "revoke"]} ->
        read(conn, id, :revoke)

      _ ->
        conn
    end
  end

  defp read(conn, id, operation) do
    case ControlPlaneJSON.read(conn, 16_384) do
      {:ok, document, conn} ->
        result =
          case {operation, document} do
            {:apply, %{"desired" => %{"binding_id" => ^id}}} ->
              ArchiveInitAuthorities.apply(installation(conn), document, actor: actor())

            {:revoke, %{"binding_id" => ^id}} ->
              ArchiveInitAuthorities.revoke(installation(conn), document, actor: actor())

            _ ->
              {:error, :invalid_init_authority}
          end

        respond_result(conn, result)

      {:error, status, reason, conn} ->
        respond(conn, status, %{status: reason})
    end
  end

  defp installation(conn), do: conn.private.control_plane_media_installation
  defp actor, do: SystemActor.system(:camera_archive_control)
  defp respond_result(conn, {:ok, projection}), do: respond(conn, 200, projection)

  defp respond_result(conn, {:error, reason})
       when reason in [
              :invalid_init_authority,
              :invalid_init_configuration,
              :invalid_init_principal,
              :invalid_init_application,
              :invalid_init_revocation,
              :invalid_archive_binding_id
            ], do: respond(conn, 400, %{status: reason})

  defp respond_result(conn, {:error, reason}) when reason in [:archive_binding_not_found, :init_authority_not_found],
    do: respond(conn, 404, %{status: reason})

  defp respond_result(conn, {:error, reason})
       when reason in [
              :init_authority_revision_stale,
              :init_authority_revision_conflict,
              :init_authority_challenge_mismatch,
              :init_authority_context_mismatch,
              :init_authority_origin_mismatch,
              :init_authority_generation_stale,
              :init_authority_report_unqualified,
              :init_authority_expired,
              :init_authority_not_applied
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
