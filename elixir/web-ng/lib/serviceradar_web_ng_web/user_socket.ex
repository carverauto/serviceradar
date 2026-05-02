defmodule ServiceRadarWebNGWeb.UserSocket do
  use Phoenix.Socket

  alias ServiceRadar.Identity.RBAC
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Auth.Guardian

  channel "dashboards:*", ServiceRadarWebNGWeb.DashboardFrameChannel
  channel "topology:*", ServiceRadarWebNGWeb.TopologyChannel

  @impl true
  def connect(_params, socket, connect_info) do
    with %{session: %{"user_token" => token}} <- connect_info,
         {:ok, user, _claims} <- Guardian.verify_token(token) do
      scope = Scope.for_user(user, permissions: RBAC.permissions_for_user(user))

      {:ok,
       socket
       |> assign(:current_user, user)
       |> assign(:current_scope, scope)}
    else
      _ -> :error
    end
  end

  @impl true
  def id(socket), do: "users_sessions:#{socket.assigns.current_user.id}"
end
