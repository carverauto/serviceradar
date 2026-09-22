defmodule ServiceRadarWebNGWeb.UserLive.ApiCredentials do
  @moduledoc """
  LiveView for managing user API credentials (OAuth clients).

  Allows users to:
  - Create new API clients with custom scopes
  - View and manage existing clients
  - Revoke or delete clients
  - View usage statistics
  """
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Identity.Constants
  alias ServiceRadar.Identity.OAuthClient
  alias ServiceRadar.Identity.OAuthClient.Credentials
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.Shell

  @api_credentials_permission Constants.api_credentials_manage_permission()

  on_mount {ServiceRadarWebNGWeb.UserAuth, :require_sudo_mode}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path="/settings/api-credentials"
      page_title="Settings"
    >
      <Shell.settings_chrome
        current_path="/settings/api-credentials"
        current_scope={@current_scope}
        active_view={@settings_active_view}
        active_category={@settings_active_category}
        breadcrumbs={@settings_breadcrumbs}
        nav_tree={@settings_nav_tree}
        palette={@settings_palette}
        stats={@settings_stats}
      >
        <div class="mx-auto w-full max-w-4xl p-6 space-y-6">
          <div class="flex justify-between items-center">
            <div>
              <h1 class="text-2xl font-semibold text-sr-ink">API Credentials</h1>
              <p class="text-sm text-sr-muted">
                Create and manage OAuth2 client credentials for programmatic API access.
              </p>
            </div>
            <.ui_button type="button" phx-click="open_create_modal" size="sm" variant="primary">
              <svg
                xmlns="http://www.w3.org/2000/svg"
                fill="none"
                viewBox="0 0 24 24"
                stroke-width="1.5"
                stroke="currentColor"
                class="w-5 h-5"
              >
                <path stroke-linecap="round" stroke-linejoin="round" d="M12 4.5v15m7.5-7.5h-15" />
              </svg>
              Create Client
            </.ui_button>
          </div>

          <%= if @show_secret_modal do %>
            <.secret_modal secret={@new_secret} client={@new_client} />
          <% end %>

          <%= if @show_create_modal do %>
            <.create_modal form={@create_form} />
          <% end %>

          <%= if @show_revoke_modal do %>
            <.revoke_modal client={@client_to_revoke} />
          <% end %>

          <.ui_panel>
            <:header>
              <div>
                <div class="text-sm font-semibold">Your API Clients</div>
                <p class="text-xs text-sr-muted">
                  These clients can be used to access the ServiceRadar API programmatically.
                </p>
              </div>
            </:header>

            <%= if Enum.empty?(@clients) do %>
              <div class="text-center py-8 text-sr-muted">
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke-width="1.5"
                  stroke="currentColor"
                  class="w-12 h-12 mx-auto mb-4 opacity-50"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    d="M15.75 5.25a3 3 0 013 3m3 0a6 6 0 01-7.029 5.912c-.563-.097-1.159.026-1.563.43L10.5 17.25H8.25v2.25H6v2.25H2.25v-2.818c0-.597.237-1.17.659-1.591l6.499-6.499c.404-.404.527-1 .43-1.563A6 6 0 1121.75 8.25z"
                  />
                </svg>
                <p>No API clients yet.</p>
                <p class="text-sm">Create a client to get started with API access.</p>
              </div>
            <% else %>
              <div class="sr-ui-table-shell">
                <table class={ui_table_class(zebra: true)}>
                  <thead>
                    <tr>
                      <th>Name</th>
                      <th>Client ID</th>
                      <th>Scopes</th>
                      <th>Status</th>
                      <th>Last Used</th>
                      <th>Uses</th>
                      <th>Actions</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for client <- @clients do %>
                      <tr>
                        <td>
                          <div class="font-medium">{client.name}</div>
                          <%= if client.description do %>
                            <div class="text-xs text-sr-muted">{client.description}</div>
                          <% end %>
                        </td>
                        <td>
                          <code class="text-xs bg-sr-subtle px-2 py-1 rounded">
                            {client.id |> to_string() |> String.slice(0..7)}...
                          </code>
                          <.ui_button
                            type="button"
                            phx-click="copy_client_id"
                            phx-value-id={client.id}
                            title="Copy full Client ID"
                            size="xs"
                            variant="ghost"
                            class="ml-1"
                          >
                            <svg
                              xmlns="http://www.w3.org/2000/svg"
                              fill="none"
                              viewBox="0 0 24 24"
                              stroke-width="1.5"
                              stroke="currentColor"
                              class="w-4 h-4"
                            >
                              <path
                                stroke-linecap="round"
                                stroke-linejoin="round"
                                d="M15.666 3.888A2.25 2.25 0 0013.5 2.25h-3c-1.03 0-1.9.693-2.166 1.638m7.332 0c.055.194.084.4.084.612v0a.75.75 0 01-.75.75H9a.75.75 0 01-.75-.75v0c0-.212.03-.418.084-.612m7.332 0c.646.049 1.288.11 1.927.184 1.1.128 1.907 1.077 1.907 2.185V19.5a2.25 2.25 0 01-2.25 2.25H6.75A2.25 2.25 0 014.5 19.5V6.257c0-1.108.806-2.057 1.907-2.185a48.208 48.208 0 011.927-.184"
                              />
                            </svg>
                          </.ui_button>
                        </td>
                        <td>
                          <%= for scope <- client.scopes do %>
                            <.ui_badge size="sm" variant={scope_badge_variant(scope)}>
                              {scope}
                            </.ui_badge>
                          <% end %>
                        </td>
                        <td>
                          <.ui_badge size="sm" variant={status_color(client)}>
                            {status_label(client)}
                          </.ui_badge>
                        </td>
                        <td class="text-sm">
                          <%= if client.last_used_at do %>
                            <.last_used_time
                              id={"api-credential-#{client.id}-last-used-at"}
                              value={client.last_used_at}
                              timezone={@current_scope.user.timezone || "Etc/UTC"}
                            />
                          <% else %>
                            <span class="text-sr-muted">Never</span>
                          <% end %>
                        </td>
                        <td class="text-sm">{client.use_count}</td>
                        <td>
                          <%= if is_nil(client.revoked_at) do %>
                            <.ui_dropdown align="end">
                              <:trigger>
                                <.ui_icon_button
                                  size="xs"
                                  variant="ghost"
                                  aria-label="Credential actions"
                                >
                                  <.icon name="hero-ellipsis-vertical" class="size-4" />
                                </.ui_icon_button>
                              </:trigger>
                              <:item>
                                <button
                                  type="button"
                                  phx-click="open_revoke_modal"
                                  phx-value-id={client.id}
                                  class="text-warning"
                                >
                                  Revoke
                                </button>
                              </:item>
                              <:item>
                                <button
                                  type="button"
                                  phx-click="delete_client"
                                  phx-value-id={client.id}
                                  class="text-error"
                                >
                                  Delete
                                </button>
                              </:item>
                            </.ui_dropdown>
                          <% else %>
                            <.ui_button
                              phx-click="delete_client"
                              phx-value-id={client.id}
                              size="xs"
                              variant="ghost"
                              class="text-error"
                            >
                              Delete
                            </.ui_button>
                          <% end %>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>
          </.ui_panel>

          <.ui_panel>
            <:header>
              <div>
                <div class="text-sm font-semibold">How to Use</div>
                <p class="text-xs text-sr-muted">
                  Use the OAuth2 client credentials flow to get access tokens.
                </p>
              </div>
            </:header>

            <div class="space-y-4 text-sm">
              <div>
                <h4 class="font-medium mb-2">1. Exchange credentials for a token</h4>
                <div class="mockup-code text-xs">
                  <pre data-prefix="$"><code>curl -X POST <%= @base_url %>/oauth/token \</code></pre>
                  <pre data-prefix=" "><code>  -d "grant_type=client_credentials" \</code></pre>
                  <pre data-prefix=" "><code>  -d "client_id=YOUR_CLIENT_ID" \</code></pre>
                  <pre data-prefix=" "><code>  -d "client_secret=YOUR_CLIENT_SECRET"</code></pre>
                </div>
              </div>

              <div>
                <h4 class="font-medium mb-2">2. Use the token in API requests</h4>
                <div class="mockup-code text-xs">
                  <pre data-prefix="$"><code>curl -H "Authorization: Bearer YOUR_ACCESS_TOKEN" \</code></pre>
                  <pre data-prefix=" "><code>  <%= @base_url %>/api/v2/devices</code></pre>
                </div>
              </div>

              <div class={ui_alert_class("info")}>
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  fill="none"
                  viewBox="0 0 24 24"
                  class="stroke-current shrink-0 w-6 h-6"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
                  >
                  </path>
                </svg>
                <span>
                  Access tokens are valid for 1 hour. Request a new token when the current one expires.
                </span>
              </div>
            </div>
          </.ui_panel>
        </div>
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end

  defp create_modal(assigns) do
    ~H"""
    <.ui_modal id="create-api-client-modal" size="sm" on_cancel="close_create_modal">
      <:title>Create API Client</:title>

      <.form for={@form} phx-submit="create_client" phx-change="validate_create" class="space-y-4">
        <div class="flex flex-col gap-1.5">
          <label class="flex items-center justify-between gap-2">
            <span class="text-sm font-medium text-sr-ink">Name</span>
          </label>
          <input
            type="text"
            name="client[name]"
            value={@form[:name].value}
            class={ui_field_class(class: "w-full")}
            placeholder="My API Client"
            required
          />
        </div>

        <div class="flex flex-col gap-1.5">
          <label class="flex items-center justify-between gap-2">
            <span class="text-sm font-medium text-sr-ink">Description (optional)</span>
          </label>
          <textarea
            name="client[description]"
            class={ui_field_class(class: "w-full min-h-24 py-2.5")}
            placeholder="What this client is used for..."
          ><%= @form[:description].value %></textarea>
        </div>

        <div class="flex flex-col gap-1.5">
          <label class="flex items-center justify-between gap-2">
            <span class="text-sm font-medium text-sr-ink">Scopes</span>
          </label>
          <div class="space-y-2">
            <label class="flex items-center gap-2 cursor-pointer">
              <input
                type="checkbox"
                name="client[scopes][]"
                value="read"
                checked
                class={ui_checkbox_class()}
              />
              <span class="text-sm font-medium text-sr-ink">Read</span>
              <span class="text-xs text-sr-muted">
                - View devices, events, and configuration
              </span>
            </label>
            <label class="flex items-center gap-2 cursor-pointer">
              <input
                type="checkbox"
                name="client[scopes][]"
                value="write"
                class={ui_checkbox_class()}
              />
              <span class="text-sm font-medium text-sr-ink">Write</span>
              <span class="text-xs text-sr-muted">- Create and modify resources</span>
            </label>
            <label class="flex items-center gap-2 cursor-pointer">
              <input
                type="checkbox"
                name="client[scopes][]"
                value="mcp"
                class={ui_checkbox_class()}
              />
              <span class="text-sm font-medium text-sr-ink">MCP</span>
              <span class="text-xs text-sr-muted">- Call the MCP server at /mcp</span>
            </label>
          </div>
        </div>

        <div class="flex justify-end gap-2 pt-2">
          <.ui_button type="button" phx-click="close_create_modal" size="sm" variant="neutral">
            Cancel
          </.ui_button>
          <.ui_button type="submit" size="sm" variant="primary">Create Client</.ui_button>
        </div>
      </.form>
    </.ui_modal>
    """
  end

  defp secret_modal(assigns) do
    ~H"""
    <.ui_modal id="api-client-secret-modal" size="sm" on_cancel="close_secret_modal">
      <:title>
        <span class="text-emerald-600 dark:text-emerald-300">Client Created Successfully!</span>
      </:title>

      <.ui_alert variant="warning">
        <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
        <span>
          <strong>Save these credentials now!</strong> The client secret will not be shown again.
        </span>
      </.ui_alert>

      <div class="space-y-4">
        <div>
          <label class="flex items-center justify-between gap-2">
            <span class="text-sm font-medium text-sr-ink">Client ID</span>
          </label>
          <div class={ui_join_class(class: "w-full")}>
            <input
              type="text"
              value={@client.id}
              readonly
              class={ui_field_class(mono: true, class: "w-full text-sm")}
            />
            <.ui_button
              type="button"
              phx-click="copy_value"
              phx-value-value={@client.id}
              size="sm"
              variant="outline"
            >
              Copy
            </.ui_button>
          </div>
        </div>

        <div>
          <label class="flex items-center justify-between gap-2">
            <span class="text-sm font-medium text-sr-ink">Client Secret</span>
          </label>
          <div class={ui_join_class(class: "w-full")}>
            <input
              type="text"
              value={@secret}
              readonly
              class={ui_field_class(mono: true, class: "w-full text-sm")}
            />
            <.ui_button
              type="button"
              phx-click="copy_value"
              phx-value-value={@secret}
              size="sm"
              variant="outline"
            >
              Copy
            </.ui_button>
          </div>
        </div>
      </div>

      <:actions>
        <.ui_button type="button" phx-click="close_secret_modal" size="sm" variant="primary">
          I've Saved My Credentials
        </.ui_button>
      </:actions>
    </.ui_modal>
    """
  end

  defp revoke_modal(assigns) do
    ~H"""
    <.ui_modal id="revoke-api-client-modal" size="sm" on_cancel="close_revoke_modal">
      <:title>
        <span class="text-amber-700 dark:text-amber-300">Revoke Client?</span>
      </:title>

      <p>
        Are you sure you want to revoke <strong>{@client.name}</strong>?
      </p>
      <p class="text-sm text-sr-muted">
        This will immediately invalidate any existing tokens issued to this client.
        The client will no longer be able to authenticate.
      </p>

      <:actions>
        <.ui_button type="button" phx-click="close_revoke_modal" size="sm" variant="neutral">
          Cancel
        </.ui_button>
        <.ui_button
          type="button"
          phx-click="confirm_revoke"
          phx-value-id={@client.id}
          size="sm"
          variant="warning"
        >
          Revoke Client
        </.ui_button>
      </:actions>
    </.ui_modal>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, @api_credentials_permission) do
      user = scope.user

      {:ok,
       socket
       |> assign(:clients, load_clients(user))
       |> assign(:show_create_modal, false)
       |> assign(:show_secret_modal, false)
       |> assign(:show_revoke_modal, false)
       |> assign(:create_form, to_form(%{"name" => "", "description" => "", "scopes" => ["read"]}))
       |> assign(:new_client, nil)
       |> assign(:new_secret, nil)
       |> assign(:client_to_revoke, nil)
       |> assign(:base_url, get_base_url())}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to manage API credentials.")
       |> push_navigate(to: ~p"/dashboard")}
    end
  end

  @impl true
  def handle_event("open_create_modal", _params, socket) do
    {:noreply, assign(socket, :show_create_modal, true)}
  end

  def handle_event("close_create_modal", _params, socket) do
    {:noreply, assign(socket, :show_create_modal, false)}
  end

  def handle_event("validate_create", %{"client" => params}, socket) do
    {:noreply, assign(socket, :create_form, to_form(params))}
  end

  def handle_event("create_client", %{"client" => params}, socket) do
    user = socket.assigns.current_scope.user
    name = params["name"] || ""
    description = params["description"]
    scopes = params["scopes"] || ["read"]

    # Ensure scopes is a list
    scopes = if is_list(scopes), do: scopes, else: [scopes]

    case Credentials.create_client(user.id,
           name: name,
           description: description,
           scopes: scopes,
           actor: user
         ) do
      {:ok, client, raw_secret} ->
        {:noreply,
         socket
         |> assign(:show_create_modal, false)
         |> assign(:show_secret_modal, true)
         |> assign(:new_client, client)
         |> assign(:new_secret, raw_secret)
         |> assign(:clients, load_clients(user))}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Failed to create client: #{inspect(error)}")}
    end
  end

  def handle_event("close_secret_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_secret_modal, false)
     |> assign(:new_client, nil)
     |> assign(:new_secret, nil)}
  end

  def handle_event("copy_client_id", %{"id" => id}, socket) do
    {:noreply, push_event(socket, "clipboard", %{text: id})}
  end

  def handle_event("copy_value", %{"value" => value}, socket) do
    {:noreply, push_event(socket, "clipboard", %{text: value})}
  end

  def handle_event("open_revoke_modal", %{"id" => id}, socket) do
    client = Enum.find(socket.assigns.clients, &(to_string(&1.id) == id))

    if client do
      {:noreply,
       socket
       |> assign(:show_revoke_modal, true)
       |> assign(:client_to_revoke, client)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_revoke_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_revoke_modal, false)
     |> assign(:client_to_revoke, nil)}
  end

  def handle_event("confirm_revoke", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user

    # Pass the current-scope user as the Ash actor: OAuthClient's read policy
    # (`user_id == ^actor(:id)` OR `is_admin()`) filters a nil-actor read to
    # empty, which would surface a spurious "Client not found".
    case OAuthClient.get_by_id(id, actor: user) do
      {:ok, client} ->
        case OAuthClient.revoke(client, %{}, actor: user) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(:show_revoke_modal, false)
             |> assign(:client_to_revoke, nil)
             |> assign(:clients, load_clients(user))
             |> put_flash(:info, "Client revoked successfully.")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to revoke client.")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Client not found.")}
    end
  end

  def handle_event("delete_client", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user

    # Pass the current-scope user as the Ash actor so the owner read policy
    # authorizes the lookup. The `:by_id` action has no enabled/revoked filter,
    # so revoked clients remain findable (and therefore deletable) once the
    # actor is present.
    case OAuthClient.get_by_id(id, actor: user) do
      {:ok, client} ->
        case OAuthClient.destroy(client, actor: user) do
          :ok ->
            {:noreply,
             socket
             |> assign(:clients, load_clients(user))
             |> put_flash(:info, "Client deleted successfully.")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete client.")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Client not found.")}
    end
  end

  defp load_clients(user) do
    case OAuthClient.list_by_user(user.id, actor: user) do
      {:ok, clients} -> clients
      {:error, _} -> []
    end
  end

  defp get_base_url do
    ServiceRadarWebNGWeb.Endpoint.url()
  end

  defp scope_badge_variant("read"), do: "info"
  defp scope_badge_variant("write"), do: "success"
  defp scope_badge_variant("admin"), do: "warning"
  defp scope_badge_variant(_), do: "ghost"

  defp status_color(%{revoked_at: revoked_at}) when not is_nil(revoked_at), do: "error"
  defp status_color(%{enabled: false}), do: "ghost"

  defp status_color(%{expires_at: expires_at}) when not is_nil(expires_at) do
    if DateTime.before?(expires_at, DateTime.utc_now()) do
      "warning"
    else
      "success"
    end
  end

  defp status_color(_), do: "success"

  defp status_label(%{revoked_at: revoked_at}) when not is_nil(revoked_at), do: "Revoked"
  defp status_label(%{enabled: false}), do: "Disabled"

  defp status_label(%{expires_at: expires_at}) when not is_nil(expires_at) do
    if DateTime.before?(expires_at, DateTime.utc_now()) do
      "Expired"
    else
      "Active"
    end
  end

  defp status_label(_), do: "Active"

  attr(:id, :string, required: true)
  attr(:value, :any, required: true)
  attr(:timezone, :string, required: true)

  defp last_used_time(assigns) do
    assigns = assign(assigns, :display, format_relative_time(assigns.value))

    ~H"""
    <%= case @display do %>
      <% {:absolute, value} -> %>
        <.user_time id={@id} value={value} timezone={@timezone} style={:date} />
      <% relative -> %>
        <span>{relative}</span>
        <.user_time
          id={@id}
          value={@value}
          timezone={@timezone}
          style={:full}
          class="sr-only"
        />
    <% end %>
    """
  end

  defp format_relative_time(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "Just now"
      diff < 3600 -> "#{div(diff, 60)} min ago"
      diff < 86_400 -> "#{div(diff, 3600)} hours ago"
      diff < 604_800 -> "#{div(diff, 86_400)} days ago"
      true -> {:absolute, datetime}
    end
  end
end
