defmodule ServiceRadarWebNGWeb.UserSocket do
  use Phoenix.Socket

  alias ServiceRadarWebNG.Auth.Guardian

  channel "topology:*", ServiceRadarWebNGWeb.TopologyChannel

  @impl true
  def connect(_params, socket, connect_info) do
    with %{session: %{"user_token" => token}} <- connect_info,
         {:ok, user, _claims} <- Guardian.verify_token(token) do
      {:ok, assign(socket, :current_user, user)}
    else
      _ -> :error
    end
  end

  @impl true
  def id(socket), do: "users_sessions:#{socket.assigns.current_user.id}"
end
