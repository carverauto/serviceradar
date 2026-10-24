defmodule ServiceRadarWebNGWeb.Plugs.ControlPlaneRecordingConfiguration do
  @moduledoc """
  Durable recording stop on the authenticated private media listener.

  This checkpoint can only restrict existing local recording admission. It
  grants no storage authority and attests no fleet-wide drain completion.
  """
  @behaviour Plug

  import Plug.Conn

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.RecordingControl
  alias ServiceRadarWebNGWeb.ControlPlaneJSON

  @body_limit 1_024

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case Enum.map(conn.path_info, &URI.decode/1) do
      ["v1", "media", "configuration"] -> configuration(conn)
      _ -> conn
    end
  end

  defp configuration(%{method: "PUT"} = conn) do
    case ControlPlaneJSON.read(conn, @body_limit) do
      {:ok, document, conn} ->
        respond_result(conn, RecordingControl.stop(installation(conn), document, actor: actor()))

      {:error, status, reason, conn} ->
        respond(conn, status, %{status: reason})
    end
  end

  defp configuration(%{method: "GET"} = conn) do
    respond_result(conn, RecordingControl.status(installation(conn), actor: actor()))
  end

  defp configuration(conn), do: respond(conn, 404, %{status: "not_found"})

  defp respond_result(conn, {:ok, projection}), do: respond(conn, 200, projection)

  defp respond_result(conn, {:error, :invalid_recording_configuration}) do
    respond(conn, 400, %{status: "invalid_recording_configuration"})
  end

  defp respond_result(conn, {:error, reason})
       when reason in [
              :recording_installation_mismatch,
              :recording_generation_stale,
              :recording_revision_stale,
              :recording_revision_conflict
            ] do
    respond(conn, 409, %{status: reason})
  end

  defp respond_result(conn, {:error, _reason}) do
    respond(conn, 503, %{status: "recording_control_unavailable"})
  end

  defp installation(conn), do: conn.private.control_plane_media_installation
  defp actor, do: SystemActor.system(:recording_control)

  defp respond(conn, status, body) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end
end
