defmodule ServiceRadarCoreElx.RemoteDesktop.SessionTracker do
  @moduledoc """
  Fetches remote-access desktop sessions for core-elx desktop media services.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.RemoteAccessSession

  @active_statuses ~w(active)a

  def fetch_session(session_id, opts \\ []) when is_binary(session_id) do
    ash_opts = [actor: Keyword.get(opts, :actor, SystemActor.system(:remote_desktop_webrtc))]

    case RemoteAccessSession.get_by_id(session_id, ash_opts) do
      {:ok, %RemoteAccessSession{} = session} -> available_desktop_session(session)
      {:ok, nil} -> {:error, :not_found}
      {:error, %Ash.Error.Query.NotFound{}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp available_desktop_session(%RemoteAccessSession{} = session) do
    with :ok <- require_protocol(session.protocol),
         :ok <- require_active_status(session.status) do
      {:ok, session}
    end
  end

  defp require_protocol(:rdp), do: :ok
  defp require_protocol("rdp"), do: :ok
  defp require_protocol(_protocol), do: {:error, :unsupported_remote_desktop_session}

  defp require_active_status(status) when status in @active_statuses, do: :ok
  defp require_active_status(_status), do: {:error, :not_found}
end
