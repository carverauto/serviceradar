defmodule ServiceRadarWebNGWeb.OAuthConsentLive do
  @moduledoc """
  Consent page for MCP authorization-code clients.
  """

  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Identity.Constants
  alias ServiceRadarWebNG.Mcp.OAuth.Audit
  alias ServiceRadarWebNG.Mcp.OAuth.IdP
  alias ServiceRadarWebNG.Mcp.OAuth.RedirectURI
  alias ServiceRadarWebNG.Mcp.OAuth.Server
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.FeatureFlags

  @impl true
  def mount(_params, session, socket) do
    cond do
      not FeatureFlags.mcp_enabled?() ->
        {:ok, redirect(socket, to: ~p"/")}

      is_nil(socket.assigns[:current_scope]) or is_nil(socket.assigns.current_scope.user) ->
        {:ok, redirect(socket, to: ~p"/users/log-in?return_to=/oauth/consent")}

      not RBAC.can?(socket.assigns.current_scope, Constants.mcp_manage_permission()) ->
        {:ok,
         socket
         |> put_flash(:error, "You don't have permission to authorize MCP clients.")
         |> redirect(to: ~p"/dashboard")}

      true ->
        request = session["mcp_oauth_request"]
        idp = IdP.from_session(session, socket.assigns.current_scope)
        user = socket.assigns.current_scope.user

        socket =
          socket
          |> assign(:page_title, "Authorize MCP")
          |> assign(:request, request)
          |> assign(:idp, idp)

        if is_map(request) and Server.active_grant?(user, request["client_id"]) do
          case Server.complete_authorization(user, request, idp) do
            {:ok, _grant, url} -> {:ok, redirect(socket, external: url)}
            _ -> {:ok, socket}
          end
        else
          {:ok, socket}
        end
    end
  end

  @impl true
  def handle_event("approve", _params, socket) do
    user = socket.assigns.current_scope.user
    request = socket.assigns.request
    idp = socket.assigns.idp

    with true <- is_map(request),
         {:ok, _grant, url} <- Server.complete_authorization(user, request, idp) do
      {:noreply, redirect(socket, external: url)}
    else
      _ ->
        {:noreply, put_flash(socket, :error, "Unable to complete authorization.")}
    end
  end

  def handle_event("deny", _params, socket) do
    request = socket.assigns.request
    user = socket.assigns.current_scope.user

    Audit.authorize_denied(
      actor_id: user && user.id,
      client_id: request && request["client_id"],
      route: "/oauth/consent"
    )

    if is_map(request) do
      {:noreply, redirect(socket, external: deny_redirect(request))}
    else
      {:noreply, redirect(socket, to: ~p"/")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-md p-6 space-y-6">
        <header class="text-center space-y-2">
          <h1 class="text-2xl font-semibold">Authorize MCP access</h1>
          <p class="text-sm text-sr-muted">
            An MCP client wants to query ServiceRadar as you. This uses your
            existing sign-in (including SSO) and does not share your password.
          </p>
        </header>

        <%= if @request do %>
          <div class="sr-ui-card bg-sr-subtle shadow">
            <div class="sr-ui-card-body space-y-3">
              <div>
                <div class="text-sm font-medium text-sr-ink">Client</div>
                <div class="font-mono text-sm">{@request["client_id"]}</div>
              </div>
              <div>
                <div class="text-sm font-medium text-sr-ink">Scopes</div>
                <div class="font-mono text-sm">{@request["scope"]}</div>
              </div>
            </div>
          </div>

          <div class="flex gap-3">
            <.ui_button type="button" phx-click="deny" size="sm" variant="ghost" class="flex-1">
              Deny
            </.ui_button>
            <.ui_button type="button" phx-click="approve" size="sm" variant="primary" class="flex-1">
              Approve
            </.ui_button>
          </div>
        <% else %>
          <p class="text-sm text-sr-muted">
            No pending authorization request. Start again from your MCP client.
          </p>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  defp deny_redirect(request) do
    RedirectURI.append_query(request["redirect_uri"], %{
      "error" => "access_denied",
      "error_description" => "The user denied the request",
      "state" => request["state"]
    })
  end
end
