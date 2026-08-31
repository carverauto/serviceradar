defmodule ServiceRadarWebNGWeb.CliDeviceAuthorizeLive do
  @moduledoc """
  Approval LiveView for the RFC 8628 CLI device-code flow.

  Reachable at `/cli/auth/device?user_code=XXXX-XXXX`. The CLI prints
  this URL after `serviceradar-cli auth login`; opening it in a browser
  lands here.

  States the LiveView renders:

  - **Unauthenticated** — redirects to `/users/log-in?return_to=...`
    so the user_code stays pinned through log-in.
  - **No code typed yet** — input form for the user to paste their
    user_code by hand.
  - **Code valid + pending** — Approve / Deny prompt with the requesting
    client and scope.
  - **Code expired / unknown / already actioned** — explanatory error
    state with no buttons.

  Approve flips the matching `DeviceAuthorization` row to `:approved`;
  the polling CLI observes the new status and exchanges its device code
  for a Guardian JWT. Deny flips the row to `:denied`; the CLI surfaces
  the rejection as RFC 8628 `access_denied`.

  RBAC gating on `cli.session.create` lands in §12 of the proposal; the
  current build assumes any authenticated user may approve their own
  device code (matching the rest of the OAuth flows in this app).
  """

  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.DeviceAuthorization
  alias ServiceRadar.Identity.RBAC

  @valid_user_code ~r/^[BCDFGHJKLMNPQRSTVWXZ]{4}-[BCDFGHJKLMNPQRSTVWXZ]{4}$/
  @approval_permission "cli.session.create"

  @impl true
  def mount(params, _session, socket) do
    case socket.assigns[:current_scope] do
      %{user: %{} = user} ->
        permissions = RBAC.permissions_for_user(user)

        socket =
          socket
          |> assign(:page_title, "Authorize CLI Session")
          |> assign(:can_approve?, MapSet.member?(permissions, @approval_permission))
          |> load_state(params)

        {:ok, socket}

      _ ->
        return_to = build_return_to(params)
        {:ok, redirect(socket, to: ~p"/users/log-in?return_to=#{return_to}")}
    end
  end

  @impl true
  def handle_event("submit_code", %{"user_code" => raw}, socket) do
    {:noreply, load_state(socket, %{"user_code" => normalize_user_code(raw)})}
  end

  def handle_event("approve", _params, socket) do
    if socket.assigns[:can_approve?] do
      case socket.assigns.row do
        %DeviceAuthorization{status: :pending} = row ->
          actor = SystemActor.system(:cli_auth)

          case DeviceAuthorization.approve(row, socket.assigns.current_scope.user.id, actor: actor) do
            {:ok, updated} ->
              {:noreply,
               socket
               |> put_flash(:info, "CLI session approved. You can close this tab.")
               |> assign(:row, updated)
               |> assign(:state, :approved)}

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, "Failed to approve: #{inspect(reason)}")}
          end

        _ ->
          {:noreply, put_flash(socket, :error, "This authorization is no longer pending.")}
      end
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         "Your role does not allow CLI authentication. Ask an admin for the cli.session.create permission."
       )}
    end
  end

  def handle_event("deny", _params, socket) do
    if socket.assigns[:can_approve?] do
      case socket.assigns.row do
        %DeviceAuthorization{status: :pending} = row ->
          actor = SystemActor.system(:cli_auth)

          case DeviceAuthorization.deny(row, actor: actor) do
            {:ok, updated} ->
              {:noreply,
               socket
               |> put_flash(:info, "CLI session denied.")
               |> assign(:row, updated)
               |> assign(:state, :denied)}

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, "Failed to deny: #{inspect(reason)}")}
          end

        _ ->
          {:noreply, put_flash(socket, :error, "This authorization is no longer pending.")}
      end
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         "Your role does not allow CLI authentication. Ask an admin for the cli.session.create permission."
       )}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-md p-6 space-y-6">
        <header class="text-center space-y-2">
          <h1 class="text-2xl font-semibold">Authorize CLI Session</h1>
          <p class="text-sm text-sr-muted">
            Confirm the CLI session ServiceRadar should issue for your account.
          </p>
        </header>

        <%= case @state do %>
          <% :prompt -> %>
            <form phx-submit="submit_code" class="space-y-4">
              <label class="flex flex-col gap-1.5 w-full">
                <span class="text-sm font-medium text-sr-ink">Device code</span>
                <input
                  type="text"
                  name="user_code"
                  value={@user_code || ""}
                  required
                  autocomplete="off"
                  spellcheck="false"
                  pattern="[A-Z]{4}-[A-Z]{4}"
                  placeholder="WDJB-MJHT"
                  class={ui_field_class(mono: true, class: "uppercase tracking-widest")}
                />
              </label>
              <.ui_button type="submit" size="sm" variant="primary" class="w-full">
                Look up code
              </.ui_button>
            </form>
          <% :pending -> %>
            <div class="sr-ui-card bg-sr-subtle shadow">
              <div class="sr-ui-card-body space-y-3">
                <div>
                  <div class="text-sm font-medium text-sr-ink">Client</div>
                  <div class="font-medium">{@row.client_id}</div>
                </div>
                <div>
                  <div class="text-sm font-medium text-sr-ink">Requested scope</div>
                  <div class="font-mono text-sm">{@row.scope}</div>
                </div>
                <div>
                  <div class="text-sm font-medium text-sr-ink">User code</div>
                  <div class="font-mono tracking-widest">{@row.user_code}</div>
                </div>
                <div>
                  <div class="text-sm font-medium text-sr-ink">Expires</div>
                  <div class="text-sm">
                    <.user_time
                      id={"cli-device-authorization-#{@row.user_code}-expires-at"}
                      value={@row.expires_at}
                      timezone={@current_scope.user.timezone || "Etc/UTC"}
                      style={:compact}
                    />
                  </div>
                </div>
              </div>
            </div>

            <%= if @can_approve? do %>
              <div class="flex gap-3">
                <.ui_button
                  type="button"
                  phx-click="deny"
                  data-confirm="Deny this CLI session?"
                  size="sm"
                  variant="ghost"
                  class="flex-1"
                >
                  Deny
                </.ui_button>
                <.ui_button
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
              <div class={ui_alert_class("warning")}>
                <div>
                  <h2 class="font-semibold">Your role does not allow CLI authentication.</h2>
                  <p class="text-sm">
                    Ask an admin to grant the <code class="font-mono">cli.session.create</code>
                    permission. The polling CLI will receive an
                    <code class="font-mono">expired_token</code>
                    error after the device code TTL elapses.
                  </p>
                </div>
              </div>
            <% end %>
          <% :approved -> %>
            <div class={ui_alert_class("success")}>
              <div>
                <h2 class="font-semibold">Approved.</h2>
                <p class="text-sm">
                  The CLI received its session token. You can close this tab and return to your terminal.
                </p>
              </div>
            </div>
          <% :denied -> %>
            <div class={ui_alert_class("warning")}>
              <div>
                <h2 class="font-semibold">Denied.</h2>
                <p class="text-sm">
                  The CLI received the rejection. You can close this tab.
                </p>
              </div>
            </div>
          <% :expired -> %>
            <div class={ui_alert_class("error")}>
              <div>
                <h2 class="font-semibold">This code has expired.</h2>
                <p class="text-sm">
                  Run <code class="font-mono">serviceradar-cli auth login</code>
                  again to start a fresh authorization.
                </p>
              </div>
            </div>
          <% :unknown -> %>
            <div class={ui_alert_class("error")}>
              <div>
                <h2 class="font-semibold">We couldn't find that code.</h2>
                <p class="text-sm">
                  Double-check the code printed by
                  <code class="font-mono">serviceradar-cli auth login</code>
                  and try again.
                </p>
              </div>
            </div>

            <.ui_button
              type="button"
              phx-click="submit_code"
              phx-value-user_code=""
              size="sm"
              variant="ghost"
            >
              Try another code
            </.ui_button>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  ## Helpers

  defp build_return_to(params) do
    case Map.get(params, "user_code") do
      code when is_binary(code) and code != "" ->
        "/cli/auth/device?user_code=#{URI.encode_www_form(code)}"

      _ ->
        "/cli/auth/device"
    end
  end

  defp load_state(socket, params) do
    user_code = params |> Map.get("user_code") |> normalize_user_code()

    cond do
      is_nil(user_code) or user_code == "" ->
        socket
        |> assign(:state, :prompt)
        |> assign(:user_code, nil)
        |> assign(:row, nil)

      not Regex.match?(@valid_user_code, user_code) ->
        socket
        |> assign(:state, :unknown)
        |> assign(:user_code, user_code)
        |> assign(:row, nil)

      true ->
        lookup_row(socket, user_code)
    end
  end

  defp lookup_row(socket, user_code) do
    actor = SystemActor.system(:cli_auth)

    case DeviceAuthorization.get_by_user_code(user_code, actor: actor) do
      {:ok, %DeviceAuthorization{} = row} ->
        socket
        |> assign(:user_code, user_code)
        |> assign(:row, row)
        |> assign(:state, derive_state(row))

      _ ->
        socket
        |> assign(:user_code, user_code)
        |> assign(:row, nil)
        |> assign(:state, :unknown)
    end
  end

  defp derive_state(%DeviceAuthorization{status: :approved}), do: :approved
  defp derive_state(%DeviceAuthorization{status: :denied}), do: :denied

  defp derive_state(%DeviceAuthorization{status: :pending} = row) do
    if DateTime.before?(row.expires_at, DateTime.utc_now()) do
      :expired
    else
      :pending
    end
  end

  defp derive_state(%DeviceAuthorization{status: :expired}), do: :expired
  defp derive_state(_), do: :unknown

  defp normalize_user_code(nil), do: nil

  defp normalize_user_code(value) when is_binary(value) do
    value
    |> String.upcase()
    |> String.replace(~r/\s+/, "")
    |> case do
      "" -> nil
      code -> code
    end
  end

  defp normalize_user_code(_), do: nil
end
