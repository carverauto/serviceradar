defmodule ServiceRadarWebNG.Api.StreamController do
  use ServiceRadarWebNGWeb, :controller

  require Logger

  @doc """
  Upgrades an incoming HTTP request into a persistent WebSocket connection 
  for the high-fidelity Arrow IPC data stream.
  """
  def connect(conn, %{"session_id" => session_id}) do
    # At this point, the API authentication pipeline has already validated 
    # the OAuth2 Bearer token in the request headers and attached the user to conn.assigns.
    user = conn.assigns[:current_user]
    
    Logger.info("Upgrading God-View Arrow stream for user #{user.id}, session: #{session_id}")
    
    conn
    |> WebSockAdapter.upgrade(
      ServiceRadarWebNGWeb.Channels.ArrowStreamHandler,
      [session_id: session_id, user_id: user.id],
      timeout: 60_000
    )
    |> halt()
  end
end
