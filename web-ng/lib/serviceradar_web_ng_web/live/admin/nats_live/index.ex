defmodule ServiceRadarWebNGWeb.Admin.NatsLive.Index do
  @moduledoc """
  LiveView for NATS platform administration.

  Super admin view for:
  - Operator status and bootstrap
  - System account status
  - Tenant NATS account management
  - Reprovisioning failed accounts
  """
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.AdminComponents

  require Ash.Query

  alias ServiceRadar.Infrastructure.NatsOperator
  alias ServiceRadar.Identity.Tenant

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to updates if needed
      :ok
    end

    socket =
      socket
      |> assign(:page_title, "NATS Administration")
      |> assign(:show_bootstrap_modal, false)
      |> assign(:show_token_modal, false)
      |> assign(:generated_token, nil)
      |> assign(:filter_status, nil)
      |> load_operator_status()
      |> load_tenant_accounts()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params), do: socket

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> load_operator_status()
     |> load_tenant_accounts()}
  end

  def handle_event("open_token_modal", _params, socket) do
    {:noreply, assign(socket, :show_token_modal, true)}
  end

  def handle_event("close_token_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_token_modal, false)
     |> assign(:generated_token, nil)}
  end

  def handle_event("generate_token", %{"expires_hours" => hours_str}, socket) do
    hours = String.to_integer(hours_str)
    expires_in_seconds = hours * 3600

    case generate_bootstrap_token(expires_in_seconds) do
      {:ok, token_record} ->
        {:noreply,
         socket
         |> assign(:generated_token, %{
           token: token_record.token_secret,
           expires_at: token_record.expires_at
         })}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to generate token")}
    end
  end

  def handle_event("copy_token", %{"token" => token}, socket) do
    {:noreply,
     socket
     |> push_event("clipboard", %{text: token})
     |> put_flash(:info, "Copied to clipboard")}
  end

  def handle_event("filter_tenants", %{"status" => status}, socket) do
    {:noreply,
     socket
     |> assign(:filter_status, if(status == "", do: nil, else: status))
     |> load_tenant_accounts()}
  end

  def handle_event("reprovision", %{"id" => tenant_id}, socket) do
    case reprovision_tenant(tenant_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> load_tenant_accounts()
         |> put_flash(:info, "Reprovisioning job enqueued")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Tenant not found")}

      {:error, :not_retriable} ->
        {:noreply, put_flash(socket, :error, "Tenant is not in a retriable state")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to enqueue reprovisioning")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-6xl p-6 space-y-6">
        <.admin_nav current_path="/admin/nats" />

        <div class="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold text-base-content">NATS Administration</h1>
            <p class="text-sm text-base-content/60">
              Manage NATS operator and tenant accounts.
            </p>
          </div>
          <div class="flex gap-2">
            <.ui_button variant="ghost" size="sm" phx-click="refresh">
              <.icon name="hero-arrow-path" class="size-4" /> Refresh
            </.ui_button>
            <.ui_button variant="primary" size="sm" phx-click="open_token_modal">
              <.icon name="hero-key" class="size-4" /> Generate Token
            </.ui_button>
          </div>
        </div>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
          <.operator_status_card operator={@operator} />
          <.system_account_card operator={@operator} />
        </div>

        <.ui_panel>
          <:header>
            <div>
              <div class="text-sm font-semibold">Tenant NATS Accounts</div>
              <p class="text-xs text-base-content/60">
                {@tenants |> length()} tenant(s)
              </p>
            </div>
            <div class="flex gap-2">
              <select
                name="status"
                class="select select-sm select-bordered"
                phx-change="filter_tenants"
              >
                <option value="">All Statuses</option>
                <option value="pending" selected={@filter_status == "pending"}>Pending</option>
                <option value="ready" selected={@filter_status == "ready"}>Ready</option>
                <option value="error" selected={@filter_status == "error"}>Error</option>
              </select>
            </div>
          </:header>

          <div class="overflow-x-auto">
            <%= if @tenants == [] do %>
              <div class="rounded-xl border border-dashed border-base-200 bg-base-100 p-8 text-center">
                <div class="text-sm font-semibold text-base-content">No tenants found</div>
                <p class="mt-1 text-xs text-base-content/60">
                  Tenants will appear here once created.
                </p>
              </div>
            <% else %>
              <table class="table table-sm">
                <thead>
                  <tr class="text-xs uppercase tracking-wide text-base-content/60">
                    <th>Tenant</th>
                    <th>NATS Status</th>
                    <th>Account Public Key</th>
                    <th>Provisioned</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  <%= for tenant <- @tenants do %>
                    <tr class="hover:bg-base-200/30">
                      <td>
                        <div class="font-medium">{tenant.name}</div>
                        <div class="text-xs text-base-content/60">{tenant.slug}</div>
                      </td>
                      <td>
                        <.nats_status_badge status={tenant.nats_account_status} />
                      </td>
                      <td class="font-mono text-xs">
                        <%= if tenant.nats_account_public_key do %>
                          {String.slice(tenant.nats_account_public_key, 0, 12)}...
                        <% else %>
                          <span class="text-base-content/40">-</span>
                        <% end %>
                      </td>
                      <td class="text-xs text-base-content/70">
                        {format_datetime(tenant.nats_account_provisioned_at)}
                      </td>
                      <td>
                        <%= if tenant.nats_account_status in [:error, :pending, :failed] do %>
                          <.ui_button
                            variant="ghost"
                            size="xs"
                            phx-click="reprovision"
                            phx-value-id={tenant.id}
                          >
                            <.icon name="hero-arrow-path" class="size-3" /> Retry
                          </.ui_button>
                        <% end %>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            <% end %>
          </div>
        </.ui_panel>
      </div>

      <.token_modal
        :if={@show_token_modal}
        generated_token={@generated_token}
      />
    </Layouts.app>
    """
  end

  defp operator_status_card(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div class="flex items-center gap-2">
          <.icon name="hero-server-stack" class="size-5 text-primary" />
          <span class="font-semibold">Operator Status</span>
        </div>
      </:header>

      <%= if @operator do %>
        <div class="space-y-3">
          <div class="flex items-center gap-2">
            <.nats_status_badge status={@operator.status} />
            <span class="text-sm">{@operator.name}</span>
          </div>

          <div class="grid grid-cols-2 gap-4 text-sm">
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/60">Public Key</div>
              <code class="text-xs font-mono">
                <%= if @operator.public_key do %>
                  {String.slice(@operator.public_key, 0, 16)}...
                <% else %>
                  <span class="text-base-content/40">Not set</span>
                <% end %>
              </code>
            </div>
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/60">Bootstrapped</div>
              <span class="text-xs">{format_datetime(@operator.bootstrapped_at)}</span>
            </div>
          </div>

          <%= if @operator.error_message do %>
            <div class="alert alert-error text-xs">
              <.icon name="hero-exclamation-triangle" class="size-4" />
              {@operator.error_message}
            </div>
          <% end %>
        </div>
      <% else %>
        <div class="text-center py-6">
          <div class="inline-flex items-center justify-center w-12 h-12 rounded-full bg-warning/10 mb-3">
            <.icon name="hero-exclamation-triangle" class="size-6 text-warning" />
          </div>
          <div class="text-sm font-semibold">Not Initialized</div>
          <p class="text-xs text-base-content/60 mt-1">
            Generate a bootstrap token and run the CLI to initialize.
          </p>
        </div>
      <% end %>
    </.ui_panel>
    """
  end

  defp system_account_card(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div class="flex items-center gap-2">
          <.icon name="hero-cog-6-tooth" class="size-5 text-secondary" />
          <span class="font-semibold">System Account</span>
        </div>
      </:header>

      <%= if @operator && @operator.system_account_public_key do %>
        <div class="space-y-3">
          <div class="flex items-center gap-2">
            <.ui_badge variant="success" size="sm">Active</.ui_badge>
          </div>

          <div>
            <div class="text-xs uppercase tracking-wide text-base-content/60">Public Key</div>
            <code class="text-xs font-mono">
              {String.slice(@operator.system_account_public_key, 0, 16)}...
            </code>
          </div>

          <p class="text-xs text-base-content/60">
            The system account is used for internal NATS server operations
            like monitoring and administration.
          </p>
        </div>
      <% else %>
        <div class="text-center py-6">
          <div class="inline-flex items-center justify-center w-12 h-12 rounded-full bg-base-200 mb-3">
            <.icon name="hero-cog-6-tooth" class="size-6 text-base-content/40" />
          </div>
          <div class="text-sm font-semibold text-base-content/60">Not Configured</div>
          <p class="text-xs text-base-content/40 mt-1">
            System account will be created during bootstrap.
          </p>
        </div>
      <% end %>
    </.ui_panel>
    """
  end

  defp token_modal(assigns) do
    ~H"""
    <dialog id="token_modal" class="modal modal-open">
      <div class="modal-box">
        <form method="dialog">
          <button
            class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
            phx-click="close_token_modal"
          >
            x
          </button>
        </form>

        <%= if @generated_token do %>
          <div class="text-center">
            <div class="inline-flex items-center justify-center w-16 h-16 rounded-full bg-success/10 mb-4">
              <.icon name="hero-check-circle" class="size-10 text-success" />
            </div>
            <h3 class="text-xl font-bold">Token Generated</h3>
            <p class="text-sm text-base-content/70 mt-1">
              Copy this token now. It won't be shown again.
            </p>
          </div>

          <div class="mt-6 space-y-4">
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/60 mb-1">
                Bootstrap Token
              </div>
              <div class="relative">
                <code class="block text-xs font-mono bg-base-200 p-3 rounded-lg break-all">
                  {@generated_token.token}
                </code>
                <button
                  type="button"
                  class="btn btn-sm btn-ghost absolute top-1 right-1"
                  phx-click="copy_token"
                  phx-value-token={@generated_token.token}
                >
                  <.icon name="hero-clipboard" class="size-4" />
                </button>
              </div>
            </div>

            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/60 mb-1">Expires</div>
              <span class="text-sm">{format_datetime(@generated_token.expires_at)}</span>
            </div>

            <div class="alert alert-info text-xs">
              <.icon name="hero-information-circle" class="size-4" />
              <div>
                Run this on your NATS server:
                <code class="block mt-1 font-mono">
                  serviceradar-cli nats-bootstrap --token &lt;TOKEN&gt; --api-url https://your-api.example.com
                </code>
              </div>
            </div>
          </div>

          <div class="modal-action">
            <button type="button" class="btn btn-primary" phx-click="close_token_modal">
              Done
            </button>
          </div>
        <% else %>
          <h3 class="text-lg font-bold">Generate Bootstrap Token</h3>
          <p class="py-2 text-sm text-base-content/70">
            Generate a one-time token for NATS operator bootstrap.
          </p>

          <form phx-submit="generate_token" class="mt-4 space-y-4">
            <div class="form-control">
              <label class="label">
                <span class="label-text">Token Validity</span>
              </label>
              <select name="expires_hours" class="select select-bordered w-full">
                <option value="1">1 hour</option>
                <option value="4">4 hours</option>
                <option value="24" selected>24 hours</option>
                <option value="72">3 days</option>
                <option value="168">7 days</option>
              </select>
            </div>

            <div class="alert alert-warning text-xs">
              <.icon name="hero-exclamation-triangle" class="size-4" />
              <span>Tokens can only be used once and should be kept secure.</span>
            </div>

            <div class="modal-action">
              <button type="button" class="btn" phx-click="close_token_modal">Cancel</button>
              <button type="submit" class="btn btn-primary">Generate Token</button>
            </div>
          </form>
        <% end %>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button phx-click="close_token_modal">close</button>
      </form>
    </dialog>
    """
  end

  defp nats_status_badge(assigns) do
    status = assigns.status

    {variant, label} =
      case status do
        :ready -> {"success", "Ready"}
        :pending -> {"warning", "Pending"}
        :error -> {"error", "Error"}
        :failed -> {"error", "Failed"}
        nil -> {"ghost", "Not Set"}
        other -> {"ghost", to_string(other)}
      end

    assigns = assigns |> assign(:variant, variant) |> assign(:label, label)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
    """
  end

  # Data loading

  defp load_operator_status(socket) do
    operator =
      case NatsOperator
           |> Ash.Query.for_read(:get_current)
           |> Ash.Query.limit(1)
           |> Ash.read_one(authorize?: false) do
        {:ok, operator} -> operator
        {:error, _} -> nil
      end

    assign(socket, :operator, operator)
  end

  defp load_tenant_accounts(socket) do
    filter_status = socket.assigns[:filter_status]

    query =
      Tenant
      |> Ash.Query.for_read(:read)
      |> Ash.Query.select([:id, :slug, :name, :nats_account_status, :nats_account_public_key, :nats_account_provisioned_at])
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(100)

    query =
      if filter_status do
        status_atom = String.to_existing_atom(filter_status)
        Ash.Query.filter(query, nats_account_status == ^status_atom)
      else
        query
      end

    tenants =
      case Ash.read(query, authorize?: false) do
        {:ok, tenants} -> tenants
        {:error, _} -> []
      end

    assign(socket, :tenants, tenants)
  end

  # Actions

  defp generate_bootstrap_token(expires_in_seconds) do
    expires_at = DateTime.add(DateTime.utc_now(), expires_in_seconds, :second)

    # Generate token
    token_bytes = :crypto.strong_rand_bytes(32)
    token_secret = Base.url_encode64(token_bytes, padding: false)
    token_hash = :crypto.hash(:sha256, token_secret) |> Base.encode16(case: :lower)

    case ServiceRadar.Infrastructure.NatsPlatformToken
         |> Ash.Changeset.for_create(:generate, %{
           purpose: :nats_bootstrap,
           expires_at: expires_at
         })
         |> Ash.Changeset.force_change_attribute(:token_hash, token_hash)
         |> Ash.create(authorize?: false) do
      {:ok, record} ->
        # Return with the plaintext token (not stored)
        {:ok, Map.put(record, :token_secret, token_secret)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp reprovision_tenant(tenant_id) do
    with {:ok, tenant} <- get_tenant(tenant_id),
         :ok <- validate_retriable(tenant) do
      ServiceRadar.NATS.Workers.CreateAccountWorker.enqueue(tenant_id)
    end
  end

  defp get_tenant(tenant_id) do
    case Tenant
         |> Ash.Query.for_read(:read)
         |> Ash.Query.filter(id == ^tenant_id)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, tenant} -> {:ok, tenant}
      {:error, error} -> {:error, error}
    end
  end

  defp validate_retriable(tenant) do
    if tenant.nats_account_status in [:error, :pending, :failed] do
      :ok
    else
      {:error, :not_retriable}
    end
  end

  defp format_datetime(nil), do: "-"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end

  defp format_datetime(%NaiveDateTime{} = dt) do
    dt
    |> DateTime.from_naive!("Etc/UTC")
    |> format_datetime()
  end
end
