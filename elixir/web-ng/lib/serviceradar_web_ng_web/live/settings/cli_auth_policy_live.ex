defmodule ServiceRadarWebNGWeb.Settings.CliAuthPolicyLive do
  @moduledoc """
  Admin sub-page for the CLI device-code policy.

  Lets a user with the `cli.policy.manage` permission toggle
  `cli_auth_enabled`, change `cli_session_ttl_days`, and edit
  `cli_allowed_scopes` on the singleton
  `ServiceRadar.Identity.AuthorizationSettings` row.

  Disabling the flow makes the CLI's manual-token fallback take over —
  see `ServiceRadarWebNGWeb.CliAuthController` for the 503 path the
  endpoints emit when `cli_auth_enabled` is false.
  """

  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.AuthorizationSettings
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadarWebNGWeb.Settings.Shell

  on_mount {ServiceRadarWebNGWeb.UserAuth, :require_authenticated}

  @policy_permission "cli.policy.manage"

  @impl true
  def mount(_params, _session, socket) do
    permissions =
      case socket.assigns[:current_scope] do
        %{user: %{} = user} -> RBAC.permissions_for_user(user)
        _ -> MapSet.new()
      end

    if MapSet.member?(permissions, @policy_permission) do
      socket =
        socket
        |> assign(:page_title, "CLI authentication")
        |> assign(:current_path, "/settings/cli-auth")
        |> load_settings()

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "You do not have access to CLI authentication settings.")
       |> push_navigate(to: ~p"/settings/profile")}
    end
  end

  @impl true
  def handle_event("save", %{"settings" => params}, socket) do
    actor = SystemActor.system(:cli_auth_policy)

    attrs = %{
      cli_auth_enabled: parse_bool(params["cli_auth_enabled"]),
      cli_session_ttl_days: parse_int(params["cli_session_ttl_days"]),
      cli_allowed_scopes: parse_scopes(params["cli_allowed_scopes"])
    }

    case AuthorizationSettings.update_settings(socket.assigns.settings, attrs, actor: actor) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:settings, updated)
         |> assign(:form_values, settings_to_form(updated))
         |> put_flash(:info, "CLI authentication settings saved.")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Failed to save: #{inspect(error)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      page_title={@page_title}
    >
      <Shell.settings_chrome
        current_path={@current_path}
        current_scope={@current_scope}
        active_view={@settings_active_view}
        active_category={@settings_active_category}
        breadcrumbs={@settings_breadcrumbs}
        nav_tree={@settings_nav_tree}
        palette={@settings_palette}
        stats={@settings_stats}
      >
        <div class="mx-auto w-full max-w-2xl p-6 space-y-6">
          <header>
            <h1 class="text-2xl font-semibold text-sr-ink">CLI authentication</h1>
            <p class="text-sm text-sr-muted">
              Controls the RFC 8628 device-code flow that powers <code class="font-mono">serviceradar-cli auth login</code>. Disabling the
              flow does not revoke tokens already issued — use Settings → CLI sessions
              to revoke individual sessions.
            </p>
          </header>

          <form phx-submit="save" class="space-y-6">
            <div class="flex flex-col gap-1.5">
              <label class="flex cursor-pointer items-center justify-start gap-3">
                <input
                  type="checkbox"
                  name="settings[cli_auth_enabled]"
                  value="true"
                  checked={@form_values.cli_auth_enabled}
                  class={ui_toggle_class()}
                />
                <span class="text-sm font-medium text-sr-ink">
                  Allow new CLI device-code authorizations on this instance
                </span>
              </label>
              <p class="text-xs text-sr-muted mt-1">
                When off, both <code class="font-mono">/api/v1/cli/auth/device</code>
                and <code class="font-mono">/api/v1/cli/auth/token</code>
                respond with 503 <code class="font-mono">cli_auth_disabled</code>; the
                CLI falls back to manual-token paste.
              </p>
            </div>

            <div class="flex flex-col gap-1.5">
              <label class="flex items-center justify-between gap-2">
                <span class="text-sm font-medium text-sr-ink">Issued-token TTL (days)</span>
              </label>
              <input
                type="number"
                name="settings[cli_session_ttl_days]"
                value={@form_values.cli_session_ttl_days}
                min="1"
                max="365"
                class={ui_field_class(class: "w-32")}
              />
              <p class="text-xs text-sr-muted mt-1">
                Default 30 days. Existing tokens keep their original TTL — only
                freshly-issued sessions use the new value.
              </p>
            </div>

            <div class="flex flex-col gap-1.5">
              <label class="flex items-center justify-between gap-2">
                <span class="text-sm font-medium text-sr-ink">Allowed scopes</span>
              </label>
              <textarea
                name="settings[cli_allowed_scopes]"
                rows="3"
                class={ui_field_class(mono: true, class: "min-h-24 py-2.5 text-sm")}
                placeholder="dashboard.publish&#10;plugin.publish"
              ><%= @form_values.cli_allowed_scopes %></textarea>
              <p class="text-xs text-sr-muted mt-1">
                One scope per line (or whitespace/comma separated). Requests for
                scopes outside the list are rejected with 400 <code class="font-mono">invalid_scope</code>.
              </p>
            </div>

            <div class="flex justify-end">
              <.ui_button type="submit" size="sm" variant="primary">Save</.ui_button>
            </div>
          </form>
        </div>
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end

  ## Helpers

  defp load_settings(socket) do
    actor = SystemActor.system(:cli_auth_policy)

    case AuthorizationSettings.get_settings(actor: actor) do
      {:ok, settings} ->
        socket
        |> assign(:settings, settings)
        |> assign(:form_values, settings_to_form(settings))

      _ ->
        fallback = %{
          cli_auth_enabled: true,
          cli_session_ttl_days: 30,
          cli_allowed_scopes: ["dashboard.publish", "plugin.publish", "plugins.manage"]
        }

        socket
        |> assign(:settings, nil)
        |> assign(:form_values, fallback_form(fallback))
    end
  end

  defp settings_to_form(%{} = settings) do
    %{
      cli_auth_enabled: !!settings.cli_auth_enabled,
      cli_session_ttl_days: settings.cli_session_ttl_days || 30,
      cli_allowed_scopes:
        Enum.join(
          settings.cli_allowed_scopes || ["dashboard.publish", "plugin.publish", "plugins.manage"],
          "\n"
        )
    }
  end

  defp fallback_form(%{cli_allowed_scopes: scopes} = fallback) do
    %{
      cli_auth_enabled: fallback.cli_auth_enabled,
      cli_session_ttl_days: fallback.cli_session_ttl_days,
      cli_allowed_scopes: Enum.join(scopes, "\n")
    }
  end

  defp parse_bool("true"), do: true
  defp parse_bool(true), do: true
  defp parse_bool("on"), do: true
  defp parse_bool(_), do: false

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> 30
    end
  end

  defp parse_int(value) when is_integer(value), do: value
  defp parse_int(_), do: 30

  defp parse_scopes(value) when is_binary(value) do
    value
    |> String.split(~r/[\s,]+/, trim: true)
    |> Enum.uniq()
  end

  defp parse_scopes(_), do: ["dashboard.publish", "plugin.publish"]
end
