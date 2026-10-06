defmodule ServiceRadarWebNGWeb.CliPkceAuthorizeLive do
  @moduledoc """
  Browser consent page for `serviceradar-cli auth login --web`.

  The CLI probes `GET /api/v1/cli/auth/authorize` before it opens a browser.
  A logged-out visit redirects to log-in and keeps the query on `return_to`,
  which is a 302 and counts as "this server supports PKCE". Approval mints a
  one-time code and redirects the browser to the CLI's loopback callback.
  Anything other than `http://127.0.0.1:<port>/cli/auth/callback` is refused
  on this page, so the redirect cannot leave the machine.
  """

  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.AuthorizationSettings
  alias ServiceRadar.Identity.CliAuthorizationCode
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadarWebNGWeb.CliPkce

  require Logger

  @approval_permission "cli.session.create"
  @code_ttl_seconds 600

  # Matches CliAuthController's @fallback_allowed_scopes, including edge.manage.
  @fallback_allowed_scopes ["dashboard.publish", "plugin.publish", "plugins.manage", "edge.manage"]

  @impl true
  def mount(params, _session, socket) do
    socket = assign(socket, :page_title, "Authorize CLI")

    case socket.assigns[:current_scope] do
      %{user: %{}} ->
        # The logged-out probe never reaches this clause. The consent page
        # reads RBAC and AuthorizationSettings, so that work waits until the
        # socket is connected. The static render has no database.
        socket =
          if connected?(socket) do
            load_consent(socket, params)
          else
            socket
            |> assign(:can_approve?, false)
            |> assign(:state, :pending)
            |> assign(:request, nil)
          end

        {:ok, socket}

      _ ->
        return_to = "/api/v1/cli/auth/authorize?" <> URI.encode_query(params)
        {:ok, redirect(socket, to: ~p"/users/log-in?return_to=#{return_to}")}
    end
  end

  @impl true
  def handle_event("approve", _params, socket) do
    request = socket.assigns.request

    cond do
      socket.assigns.state != :consent or is_nil(request) ->
        {:noreply, put_flash(socket, :error, "This authorization request is not valid.")}

      not socket.assigns.can_approve? ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Your role does not allow CLI authentication. Ask an admin for the cli.session.create permission."
         )}

      true ->
        mint_and_redirect(socket, request)
    end
  end

  def handle_event("deny", _params, socket) do
    case socket.assigns.request do
      %{redirect_uri: uri, state: state} ->
        query = URI.encode_query(%{error: "access_denied", state: state})
        {:noreply, redirect(socket, external: uri <> "?" <> query)}

      _ ->
        {:noreply, put_flash(socket, :error, "This authorization request is not valid.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-md p-6 space-y-6">
        <header class="text-center space-y-2">
          <h1 class="text-2xl font-semibold">Authorize CLI</h1>
          <p class="text-sm text-sr-muted">
            Allow this ServiceRadar CLI on your computer to sign in as you.
          </p>
        </header>

        <%= case @state do %>
          <% :pending -> %>
            <p id="cli-pkce-pending" class="text-sm text-sr-muted text-center">
              Checking this request.
            </p>
          <% :consent -> %>
            <div class="sr-ui-card bg-sr-subtle shadow">
              <div class="sr-ui-card-body space-y-3">
                <div>
                  <div class="text-sm font-medium text-sr-ink">Client</div>
                  <div class="font-medium">{@request.client_id}</div>
                </div>
                <div>
                  <div class="text-sm font-medium text-sr-ink">Requested scope</div>
                  <div id="cli-pkce-scope" class="font-mono text-sm">{@request.scope}</div>
                </div>
                <div>
                  <div class="text-sm font-medium text-sr-ink">Returns to</div>
                  <div id="cli-pkce-redirect" class="font-mono text-sm break-all">
                    {@request.redirect_uri}
                  </div>
                </div>
              </div>
            </div>

            <%= if @can_approve? do %>
              <div class="flex gap-3">
                <.ui_button
                  id="cli-pkce-deny"
                  type="button"
                  phx-click="deny"
                  size="sm"
                  variant="ghost"
                  class="flex-1"
                >
                  Deny
                </.ui_button>
                <.ui_button
                  id="cli-pkce-approve"
                  type="button"
                  phx-click="approve"
                  size="sm"
                  variant="primary"
                  class="flex-1"
                >
                  Approve
                </.ui_button>
              </div>
            <% else %>
              <div id="cli-pkce-forbidden" class={ui_alert_class("warning")}>
                <div>
                  <h2 class="font-semibold">Your role does not allow CLI authentication.</h2>
                  <p class="text-sm">
                    Ask an admin to grant the <code class="font-mono">cli.session.create</code>
                    permission.
                  </p>
                </div>
              </div>
            <% end %>
          <% :invalid_scope -> %>
            <div id="cli-pkce-invalid" class={ui_alert_class("error")}>
              <div>
                <h2 class="font-semibold">This CLI scope is not allowed.</h2>
                <p class="text-sm">
                  Ask an admin to allow it under Settings, then run
                  <code class="font-mono">serviceradar-cli auth login --web</code>
                  again.
                </p>
              </div>
            </div>
          <% _ -> %>
            <div id="cli-pkce-invalid" class={ui_alert_class("error")}>
              <div>
                <h2 class="font-semibold">This authorization request is not valid.</h2>
                <p class="text-sm">
                  The CLI can only return to its own loopback callback. Run
                  <code class="font-mono">serviceradar-cli auth login --web</code>
                  again.
                </p>
              </div>
            </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  defp load_consent(socket, params) do
    user = socket.assigns.current_scope.user
    permissions = RBAC.permissions_for_user(user)

    socket
    |> assign(:can_approve?, MapSet.member?(permissions, @approval_permission))
    |> assign_request(params)
  end

  defp assign_request(socket, params) do
    case CliPkce.validate_authorize(params, allowed_scopes()) do
      {:ok, request} ->
        socket
        |> assign(:state, :consent)
        |> assign(:request, request)

      {:error, :invalid_scope} ->
        socket
        |> assign(:state, :invalid_scope)
        |> assign(:request, nil)

      {:error, :invalid_request} ->
        socket
        |> assign(:state, :invalid)
        |> assign(:request, nil)
    end
  end

  defp mint_and_redirect(socket, request) do
    actor = SystemActor.system(:cli_auth)
    plaintext = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    attrs = %{
      user_id: socket.assigns.current_scope.user.id,
      client_id: request.client_id,
      code_hash: :sha256 |> :crypto.hash(plaintext) |> Base.encode16(case: :lower),
      redirect_uri: request.redirect_uri,
      code_challenge: request.code_challenge,
      scope: request.scope,
      expires_at: DateTime.shift(DateTime.utc_now(), second: @code_ttl_seconds)
    }

    case CliAuthorizationCode.create(attrs, actor: actor) do
      {:ok, _row} ->
        query = URI.encode_query(%{code: plaintext, state: request.state})
        {:noreply, redirect(socket, external: request.redirect_uri <> "?" <> query)}

      {:error, reason} ->
        Logger.error("CLI PKCE authorization mint failed: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, "Failed to authorize this CLI. Try again.")}
    end
  end

  defp allowed_scopes do
    actor = SystemActor.system(:cli_auth)

    case AuthorizationSettings.get_settings(actor: actor) do
      {:ok, %{cli_allowed_scopes: scopes}} when is_list(scopes) -> scopes
      _ -> @fallback_allowed_scopes
    end
  end
end
