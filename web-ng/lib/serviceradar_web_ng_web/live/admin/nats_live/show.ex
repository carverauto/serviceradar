defmodule ServiceRadarWebNGWeb.Admin.NatsLive.Show do
  @moduledoc """
  LiveView for tenant NATS account details.

  Displays detailed information about a tenant's NATS account including:
  - Account credentials and status
  - Provisioning history
  - Error details
  - Actions (reprovision, clear/revoke)
  """
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.AdminComponents

  require Ash.Query
  require Logger

  alias ServiceRadar.Identity.Tenant

  @impl true
  def mount(%{"id" => tenant_id}, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Tenant NATS Account")
      |> assign(:show_confirm_modal, false)
      |> assign(:confirm_action, nil)
      |> load_tenant(tenant_id)

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_tenant(socket, socket.assigns.tenant.id)}
  end

  def handle_event("reprovision", _params, socket) do
    tenant = socket.assigns.tenant

    case ServiceRadar.NATS.Workers.CreateAccountWorker.enqueue(tenant.id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> load_tenant(tenant.id)
         |> put_flash(:info, "Reprovisioning job enqueued")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to enqueue reprovisioning")}
    end
  end

  def handle_event("show_clear_confirm", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_confirm_modal, true)
     |> assign(:confirm_action, :clear)}
  end

  def handle_event("close_confirm_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_confirm_modal, false)
     |> assign(:confirm_action, nil)}
  end

  def handle_event("confirm_clear", _params, socket) do
    tenant = socket.assigns.tenant
    actor = socket.assigns.current_scope.user

    case clear_nats_account(tenant, actor) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:show_confirm_modal, false)
         |> assign(:confirm_action, nil)
         |> load_tenant(tenant.id)
         |> put_flash(:info, "NATS account cleared successfully")}

      {:error, reason} ->
        Logger.error("Failed to clear NATS account: #{inspect(reason)}")
        error_msg = format_error(reason)

        {:noreply,
         socket
         |> assign(:show_confirm_modal, false)
         |> put_flash(:error, "Failed to clear NATS account: #{error_msg}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-4xl p-6 space-y-6">
        <.admin_nav current_path="/admin/nats" />

        <div class="flex flex-wrap items-center justify-between gap-4">
          <div>
            <.link navigate={~p"/admin/nats"} class="text-sm text-primary hover:underline">
              &larr; Back to NATS Administration
            </.link>
            <h1 class="text-2xl font-semibold text-base-content mt-1">
              {@tenant.name}
            </h1>
            <p class="text-sm text-base-content/60">
              Tenant NATS Account Details
            </p>
          </div>
          <div class="flex gap-2">
            <.ui_button variant="ghost" size="sm" phx-click="refresh">
              <.icon name="hero-arrow-path" class="size-4" /> Refresh
            </.ui_button>
          </div>
        </div>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
          <.tenant_info_card tenant={@tenant} />
          <.nats_status_card tenant={@tenant} />
        </div>

        <.nats_credentials_panel tenant={@tenant} />

        <.actions_panel tenant={@tenant} />
      </div>

      <.confirm_modal
        :if={@show_confirm_modal}
        action={@confirm_action}
        tenant={@tenant}
      />
    </Layouts.app>
    """
  end

  defp tenant_info_card(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div class="flex items-center gap-2">
          <.icon name="hero-building-office" class="size-5 text-primary" />
          <span class="font-semibold">Tenant Information</span>
        </div>
      </:header>

      <div class="space-y-4">
        <div class="grid grid-cols-2 gap-4">
          <div>
            <div class="text-xs uppercase tracking-wide text-base-content/60">Name</div>
            <span class="text-sm font-medium">{@tenant.name}</span>
          </div>
          <div>
            <div class="text-xs uppercase tracking-wide text-base-content/60">Slug</div>
            <code class="text-sm font-mono">{@tenant.slug}</code>
          </div>
        </div>

        <div class="grid grid-cols-2 gap-4">
          <div>
            <div class="text-xs uppercase tracking-wide text-base-content/60">Status</div>
            <.tenant_status_badge status={@tenant.status} />
          </div>
          <div>
            <div class="text-xs uppercase tracking-wide text-base-content/60">Plan</div>
            <.ui_badge variant="ghost" size="sm">{@tenant.plan}</.ui_badge>
          </div>
        </div>

        <div>
          <div class="text-xs uppercase tracking-wide text-base-content/60">Tenant ID</div>
          <code class="text-xs font-mono text-base-content/70">{@tenant.id}</code>
        </div>
      </div>
    </.ui_panel>
    """
  end

  defp nats_status_card(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div class="flex items-center gap-2">
          <.icon name="hero-server-stack" class="size-5 text-secondary" />
          <span class="font-semibold">NATS Account Status</span>
        </div>
      </:header>

      <div class="space-y-4">
        <div class="flex items-center gap-3">
          <.nats_status_badge status={@tenant.nats_account_status} />
          <%= if @tenant.nats_account_provisioned_at do %>
            <span class="text-xs text-base-content/60">
              Provisioned {format_datetime(@tenant.nats_account_provisioned_at)}
            </span>
          <% end %>
        </div>

        <%= if @tenant.nats_account_error do %>
          <div class="alert alert-error text-sm">
            <.icon name="hero-exclamation-triangle" class="size-5" />
            <div>
              <div class="font-medium">Provisioning Error</div>
              <p class="text-xs mt-1">{@tenant.nats_account_error}</p>
            </div>
          </div>
        <% end %>

        <%= if @tenant.nats_account_status == nil do %>
          <div class="alert alert-info text-sm">
            <.icon name="hero-information-circle" class="size-5" />
            <span>No NATS account has been provisioned for this tenant yet.</span>
          </div>
        <% end %>
      </div>
    </.ui_panel>
    """
  end

  defp nats_credentials_panel(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div class="flex items-center gap-2">
          <.icon name="hero-key" class="size-5 text-accent" />
          <span class="font-semibold">NATS Credentials</span>
        </div>
      </:header>

      <%= if @tenant.nats_account_public_key do %>
        <div class="space-y-4">
          <div>
            <div class="text-xs uppercase tracking-wide text-base-content/60 mb-1">
              Account Public Key
            </div>
            <code class="block text-xs font-mono bg-base-200 p-3 rounded-lg break-all">
              {@tenant.nats_account_public_key}
            </code>
          </div>

          <%= if @tenant.nats_account_jwt do %>
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/60 mb-1">
                Account JWT
              </div>
              <details class="collapse collapse-arrow bg-base-200 rounded-lg">
                <summary class="collapse-title text-xs font-medium min-h-0 py-2">
                  Click to expand JWT
                </summary>
                <div class="collapse-content">
                  <code class="block text-xs font-mono break-all whitespace-pre-wrap">
                    {@tenant.nats_account_jwt}
                  </code>
                </div>
              </details>
            </div>
          <% end %>

          <div class="alert alert-warning text-xs">
            <.icon name="hero-shield-exclamation" class="size-4" />
            <span>
              The account seed is encrypted and stored securely. It is only accessible
              by internal provisioning systems.
            </span>
          </div>
        </div>
      <% else %>
        <div class="text-center py-8">
          <div class="inline-flex items-center justify-center w-12 h-12 rounded-full bg-base-200 mb-3">
            <.icon name="hero-key" class="size-6 text-base-content/40" />
          </div>
          <div class="text-sm font-semibold text-base-content/60">No Credentials</div>
          <p class="text-xs text-base-content/40 mt-1">
            NATS credentials will appear here after provisioning.
          </p>
        </div>
      <% end %>
    </.ui_panel>
    """
  end

  defp actions_panel(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div class="flex items-center gap-2">
          <.icon name="hero-cog-6-tooth" class="size-5 text-base-content/60" />
          <span class="font-semibold">Actions</span>
        </div>
      </:header>

      <div class="flex flex-wrap gap-3">
        <%= if @tenant.nats_account_status in [:error, :pending, nil] do %>
          <.ui_button variant="primary" size="sm" phx-click="reprovision">
            <.icon name="hero-arrow-path" class="size-4" />
            <%= if @tenant.nats_account_status do %>
              Retry Provisioning
            <% else %>
              Provision NATS Account
            <% end %>
          </.ui_button>
        <% end %>

        <%= if @tenant.nats_account_status == :ready do %>
          <.ui_button variant="soft" size="sm" phx-click="reprovision">
            <.icon name="hero-arrow-path" class="size-4" /> Reprovision
          </.ui_button>
        <% end %>

        <%= if @tenant.nats_account_public_key do %>
          <.ui_button variant="outline" size="sm" phx-click="show_clear_confirm">
            <.icon name="hero-trash" class="size-4" /> Clear NATS Account
          </.ui_button>
        <% end %>
      </div>

      <div class="mt-4 text-xs text-base-content/60">
        <p class="mb-2"><strong>Provision/Retry:</strong> Creates or retries creating the NATS account for this tenant.</p>
        <p class="mb-2"><strong>Reprovision:</strong> Regenerates the NATS account credentials and JWT.</p>
        <p><strong>Clear:</strong> Removes all NATS credentials. The tenant will need to be reprovisioned.</p>
      </div>
    </.ui_panel>
    """
  end

  defp confirm_modal(assigns) do
    ~H"""
    <dialog id="confirm_modal" class="modal modal-open">
      <div class="modal-box">
        <h3 class="text-lg font-bold">Clear NATS Account</h3>
        <p class="py-4 text-sm text-base-content/70">
          Are you sure you want to clear the NATS account for <strong>{@tenant.name}</strong>?
        </p>
        <div class="alert alert-warning text-sm mb-4">
          <.icon name="hero-exclamation-triangle" class="size-5" />
          <div>
            <div class="font-medium">Warning</div>
            <p class="text-xs">
              This will remove all NATS credentials for this tenant. Any edge collectors
              using these credentials will lose connectivity. You will need to reprovision
              the account afterwards.
            </p>
          </div>
        </div>
        <div class="modal-action">
          <button type="button" class="btn" phx-click="close_confirm_modal">Cancel</button>
          <button type="button" class="btn btn-error" phx-click="confirm_clear">
            Clear Account
          </button>
        </div>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button phx-click="close_confirm_modal">close</button>
      </form>
    </dialog>
    """
  end

  defp tenant_status_badge(assigns) do
    status = assigns.status

    {variant, label} =
      case status do
        :active -> {"success", "Active"}
        :suspended -> {"warning", "Suspended"}
        :pending -> {"info", "Pending"}
        :deleted -> {"error", "Deleted"}
        _ -> {"ghost", to_string(status)}
      end

    assigns = assigns |> assign(:variant, variant) |> assign(:label, label)

    ~H"""
    <.ui_badge variant={@variant} size="sm">{@label}</.ui_badge>
    """
  end

  defp nats_status_badge(assigns) do
    status = assigns.status

    {variant, label} =
      case status do
        :ready -> {"success", "Ready"}
        :pending -> {"warning", "Pending"}
        :error -> {"error", "Error"}
        nil -> {"ghost", "Not Provisioned"}
        other -> {"ghost", to_string(other)}
      end

    assigns = assigns |> assign(:variant, variant) |> assign(:label, label)

    ~H"""
    <.ui_badge variant={@variant} size="sm">{@label}</.ui_badge>
    """
  end

  # Data loading

  defp load_tenant(socket, tenant_id) do
    case get_tenant(tenant_id) do
      {:ok, tenant} ->
        socket
        |> assign(:tenant, tenant)
        |> assign(:page_title, "#{tenant.name} - NATS Account")

      {:error, _} ->
        socket
        |> put_flash(:error, "Tenant not found")
        |> push_navigate(to: ~p"/admin/nats")
    end
  end

  defp get_tenant(tenant_id) do
    Tenant
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^tenant_id)
    |> Ash.Query.select([
      :id,
      :name,
      :slug,
      :status,
      :plan,
      :nats_account_status,
      :nats_account_public_key,
      :nats_account_jwt,
      :nats_account_error,
      :nats_account_provisioned_at
    ])
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, :not_found}
      {:ok, tenant} -> {:ok, tenant}
      {:error, error} -> {:error, error}
    end
  end

  # Actions

  defp clear_nats_account(tenant, actor) do
    tenant
    |> Ash.Changeset.for_update(:clear_nats_account, %{reason: "Cleared by admin"}, actor: actor)
    |> Ash.update(authorize?: false)
  end

  defp format_error(%Ash.Error.Invalid{errors: errors}) do
    Enum.map_join(errors, ", ", &format_error/1)
  end

  defp format_error(%{message: message}), do: message
  defp format_error(error) when is_binary(error), do: error
  defp format_error(error) when is_atom(error), do: to_string(error)
  defp format_error(error), do: inspect(error)

  defp format_datetime(nil), do: "-"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  end

  defp format_datetime(%NaiveDateTime{} = dt) do
    dt
    |> DateTime.from_naive!("Etc/UTC")
    |> format_datetime()
  end
end
