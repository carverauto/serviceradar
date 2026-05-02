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

  alias ServiceRadar.Identity.OAuthClient
  alias ServiceRadar.Identity.OAuthClient.Credentials

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
      <div class="mx-auto w-full max-w-4xl p-6 space-y-6">
        <div class="flex justify-between items-center">
          <div>
            <h1 class="text-2xl font-semibold text-base-content">API Credentials</h1>
            <p class="text-sm text-base-content/60">
              Create and manage OAuth2 client credentials for programmatic API access.
            </p>
          </div>
          <button
            type="button"
            phx-click="open_create_modal"
            class="btn btn-primary"
          >
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
          </button>
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
              <p class="text-xs text-base-content/60">
                These clients can be used to access the ServiceRadar API programmatically.
              </p>
            </div>
          </:header>

          <%= if Enum.empty?(@clients) do %>
            <div class="text-center py-8 text-base-content/60">
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
            <div class="overflow-x-auto">
              <table class="table table-zebra">
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
                          <div class="text-xs text-base-content/60">{client.description}</div>
                        <% end %>
                      </td>
                      <td>
                        <code class="text-xs bg-base-200 px-2 py-1 rounded">
                          {client.id |> to_string() |> String.slice(0..7)}...
                        </code>
                        <button
                          type="button"
                          phx-click="copy_client_id"
                          phx-value-id={client.id}
                          class="btn btn-ghost btn-xs ml-1"
                          title="Copy full Client ID"
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
                        </button>
                      </td>
                      <td>
                        <%= for scope <- client.scopes do %>
                          <span class={"badge badge-sm #{scope_badge_class(scope)}"}>{scope}</span>
                        <% end %>
                      </td>
                      <td>
                        <span class={"badge badge-sm badge-#{status_color(client)}"}>
                          {status_label(client)}
                        </span>
                      </td>
                      <td class="text-sm">
                        <%= if client.last_used_at do %>
                          <span title={DateTime.to_iso8601(client.last_used_at)}>
                            {format_relative_time(client.last_used_at)}
                          </span>
                        <% else %>
                          <span class="text-base-content/40">Never</span>
                        <% end %>
                      </td>
                      <td class="text-sm">{client.use_count}</td>
                      <td>
                        <%= if is_nil(client.revoked_at) do %>
                          <div class="dropdown dropdown-end">
                            <div tabindex="0" role="button" class="btn btn-ghost btn-xs">
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
                                  d="M12 6.75a.75.75 0 110-1.5.75.75 0 010 1.5zM12 12.75a.75.75 0 110-1.5.75.75 0 010 1.5zM12 18.75a.75.75 0 110-1.5.75.75 0 010 1.5z"
                                />
                              </svg>
                            </div>
                            <ul
                              tabindex="0"
                              class="dropdown-content z-[1] menu p-2 shadow bg-base-100 rounded-box w-40"
                            >
                              <li>
                                <button
                                  phx-click="open_revoke_modal"
                                  phx-value-id={client.id}
                                  class="text-warning"
                                >
                                  Revoke
                                </button>
                              </li>
                              <li>
                                <button
                                  phx-click="delete_client"
                                  phx-value-id={client.id}
                                  class="text-error"
                                >
                                  Delete
                                </button>
                              </li>
                            </ul>
                          </div>
                        <% else %>
                          <button
                            phx-click="delete_client"
                            phx-value-id={client.id}
                            class="btn btn-ghost btn-xs text-error"
                          >
                            Delete
                          </button>
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
              <p class="text-xs text-base-content/60">
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

            <div class="alert alert-info">
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
    </Layouts.app>
    """
  end

  defp create_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box">
        <h3 class="font-bold text-lg mb-4">Create API Client</h3>

        <.form for={@form} phx-submit="create_client" phx-change="validate_create" class="space-y-4">
          <div class="form-control">
            <label class="label">
              <span class="label-text">Name</span>
            </label>
            <input
              type="text"
              name="client[name]"
              value={@form[:name].value}
              class="input input-bordered w-full"
              placeholder="My API Client"
              required
            />
          </div>

          <div class="form-control">
            <label class="label">
              <span class="label-text">Description (optional)</span>
            </label>
            <textarea
              name="client[description]"
              class="textarea textarea-bordered w-full"
              placeholder="What this client is used for..."
            ><%= @form[:description].value %></textarea>
          </div>

          <div class="form-control">
            <label class="label">
              <span class="label-text">Scopes</span>
            </label>
            <div class="space-y-2">
              <label class="flex items-center gap-2 cursor-pointer">
                <input
                  type="checkbox"
                  name="client[scopes][]"
                  value="read"
                  checked
                  class="checkbox checkbox-sm"
                />
                <span class="label-text">Read</span>
                <span class="text-xs text-base-content/60">
                  - View devices, events, and configuration
                </span>
              </label>
              <label class="flex items-center gap-2 cursor-pointer">
                <input
                  type="checkbox"
                  name="client[scopes][]"
                  value="write"
                  class="checkbox checkbox-sm"
                />
                <span class="label-text">Write</span>
                <span class="text-xs text-base-content/60">- Create and modify resources</span>
              </label>
            </div>
          </div>

          <div class="modal-action">
            <button type="button" phx-click="close_create_modal" class="btn">Cancel</button>
            <button type="submit" class="btn btn-primary">Create Client</button>
          </div>
        </.form>
      </div>
      <div class="modal-backdrop" phx-click="close_create_modal"></div>
    </div>
    """
  end

  defp secret_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box">
        <h3 class="font-bold text-lg mb-4 text-success">Client Created Successfully!</h3>

        <div class="alert alert-warning mb-4">
          <svg
            xmlns="http://www.w3.org/2000/svg"
            class="stroke-current shrink-0 h-6 w-6"
            fill="none"
            viewBox="0 0 24 24"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"
            />
          </svg>
          <span class="text-sm">
            <strong>Save these credentials now!</strong> The client secret will not be shown again.
          </span>
        </div>

        <div class="space-y-4">
          <div>
            <label class="label">
              <span class="label-text font-medium">Client ID</span>
            </label>
            <div class="join w-full">
              <input
                type="text"
                value={@client.id}
                readonly
                class="input input-bordered join-item w-full font-mono text-sm"
              />
              <button
                type="button"
                phx-click="copy_value"
                phx-value-value={@client.id}
                class="btn btn-outline join-item"
              >
                Copy
              </button>
            </div>
          </div>

          <div>
            <label class="label">
              <span class="label-text font-medium">Client Secret</span>
            </label>
            <div class="join w-full">
              <input
                type="text"
                value={@secret}
                readonly
                class="input input-bordered join-item w-full font-mono text-sm"
              />
              <button
                type="button"
                phx-click="copy_value"
                phx-value-value={@secret}
                class="btn btn-outline join-item"
              >
                Copy
              </button>
            </div>
          </div>
        </div>

        <div class="modal-action">
          <button type="button" phx-click="close_secret_modal" class="btn btn-primary">
            I've Saved My Credentials
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp revoke_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box">
        <h3 class="font-bold text-lg mb-4 text-warning">Revoke Client?</h3>

        <p class="mb-4">
          Are you sure you want to revoke <strong><%= @client.name %></strong>?
        </p>
        <p class="text-sm text-base-content/60 mb-4">
          This will immediately invalidate any existing tokens issued to this client.
          The client will no longer be able to authenticate.
        </p>

        <div class="modal-action">
          <button type="button" phx-click="close_revoke_modal" class="btn">Cancel</button>
          <button
            type="button"
            phx-click="confirm_revoke"
            phx-value-id={@client.id}
            class="btn btn-warning"
          >
            Revoke Client
          </button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="close_revoke_modal"></div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    socket =
      socket
      |> assign(:clients, load_clients(user))
      |> assign(:show_create_modal, false)
      |> assign(:show_secret_modal, false)
      |> assign(:show_revoke_modal, false)
      |> assign(:create_form, to_form(%{"name" => "", "description" => "", "scopes" => ["read"]}))
      |> assign(:new_client, nil)
      |> assign(:new_secret, nil)
      |> assign(:client_to_revoke, nil)
      |> assign(:base_url, get_base_url())

    {:ok, socket}
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
    {:noreply, push_event(socket, "copy_to_clipboard", %{text: id})}
  end

  def handle_event("copy_value", %{"value" => value}, socket) do
    {:noreply, push_event(socket, "copy_to_clipboard", %{text: value})}
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

    case OAuthClient.get_by_id(id) do
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

    case OAuthClient.get_by_id(id) do
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

  defp scope_badge_class("read"), do: "badge-info"
  defp scope_badge_class("write"), do: "badge-success"
  defp scope_badge_class("admin"), do: "badge-warning"
  defp scope_badge_class(_), do: "badge-ghost"

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

  defp format_relative_time(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "Just now"
      diff < 3600 -> "#{div(diff, 60)} min ago"
      diff < 86_400 -> "#{div(diff, 3600)} hours ago"
      diff < 604_800 -> "#{div(diff, 86_400)} days ago"
      true -> Calendar.strftime(datetime, "%b %d, %Y")
    end
  end
end
