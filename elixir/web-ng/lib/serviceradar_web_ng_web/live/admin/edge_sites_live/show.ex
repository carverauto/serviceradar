defmodule ServiceRadarWebNGWeb.Admin.EdgeSitesLive.Show do
  @moduledoc """
  LiveView for viewing edge site details and downloading configuration bundles.
  """
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.CollectorPackage
  alias ServiceRadar.Edge.EdgeSite
  alias ServiceRadar.Plugins.AddonAssignment
  alias ServiceRadarWebNG.Capabilities
  alias ServiceRadarWebNg.Edge.EdgeSiteBundleGenerator
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.Shell

  require Ash.Query

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "settings.edge.manage") do
      case load_site(id, scope) do
        {:ok, site} ->
          socket =
            socket
            |> assign(:page_title, site.name)
            |> assign(:collectors_enabled, Capabilities.collectors_enabled?())
            |> assign(:site, site)
            |> assign(:leaf_server, site.nats_leaf_server)
            |> load_collectors(id, scope)

          {:ok, socket}

        {:error, :not_found} ->
          {:ok,
           socket
           |> put_flash(:error, "Edge site not found")
           |> push_navigate(to: ~p"/admin/edge-sites")}
      end
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to access Edge Sites.")
       |> push_navigate(to: ~p"/dashboard")}
    end
  end

  @impl true
  def handle_event("download_bundle", _params, socket) do
    site = socket.assigns.site
    leaf_server = socket.assigns.leaf_server

    case generate_bundle(site, leaf_server) do
      {:ok, tarball} ->
        filename = EdgeSiteBundleGenerator.bundle_filename(site)

        {:noreply,
         push_event(socket, "download", %{
           filename: filename,
           content: Base.encode64(tarball),
           content_type: "application/gzip"
         })}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to generate bundle: #{inspect(reason)}")}
    end
  end

  def handle_event("regenerate_config", _params, socket) do
    leaf_server = socket.assigns.leaf_server
    scope = socket.assigns.current_scope

    case regenerate_config(leaf_server, scope) do
      {:ok, _updated} ->
        site_id = socket.assigns.site.id

        case load_site(site_id, scope) do
          {:ok, site} ->
            {:noreply,
             socket
             |> assign(:site, site)
             |> assign(:leaf_server, site.nats_leaf_server)
             |> put_flash(:info, "Configuration regenerated")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to reload site")}
        end

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to regenerate: #{inspect(reason)}")}
    end
  end

  def handle_event("update_nats_url", %{"nats_leaf_url" => url}, socket) do
    site = socket.assigns.site
    scope = socket.assigns.current_scope

    case update_site(site, %{nats_leaf_url: url}, scope) do
      {:ok, updated_site} ->
        {:noreply,
         socket
         |> assign(:site, updated_site)
         |> put_flash(:info, "NATS URL updated")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to update URL")}
    end
  end

  def handle_event("delete_site", _params, socket) do
    site = socket.assigns.site
    scope = socket.assigns.current_scope

    case Ash.destroy(site, scope: scope) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Edge site deleted")
         |> push_navigate(to: ~p"/admin/edge-sites")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete site")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <Shell.settings_chrome
        current_path="/admin/edge-sites"
        current_scope={@current_scope}
        active_view={@settings_active_view}
        active_category={@settings_active_category}
        breadcrumbs={@settings_breadcrumbs}
        nav_tree={@settings_nav_tree}
        palette={@settings_palette}
        stats={@settings_stats}
      >
        <div class="flex flex-wrap items-center justify-between gap-4">
          <div>
            <div class="text-sm ">
              <ul>
                <li><.link navigate={~p"/admin/edge-sites"}>Edge Sites</.link></li>
                <li>{@site.name}</li>
              </ul>
            </div>
            <h1 class="text-2xl font-semibold text-sr-ink">{@site.name}</h1>
            <p class="text-sm text-sr-muted font-mono">{@site.slug}</p>
          </div>
          <div class="flex gap-2">
            <.ui_button
              variant="primary"
              size="sm"
              phx-click="download_bundle"
              disabled={@leaf_server == nil or @leaf_server.status == :pending}
            >
              <.icon name="hero-arrow-down-tray" class="size-4" /> Download Bundle
            </.ui_button>
          </div>
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <.site_details_card site={@site} />
          <.leaf_server_card leaf_server={@leaf_server} />
        </div>

        <.nats_url_card site={@site} />

        <.collectors_card
          collectors={@collectors}
          site={@site}
          collectors_enabled={@collectors_enabled}
        />

        <.danger_zone_card site={@site} />
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end

  defp site_details_card(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div class="flex items-center gap-2">
          <.icon name="hero-building-office-2" class="size-4 text-sr-brand" />
          <span class="font-semibold text-sm">Site Details</span>
        </div>
      </:header>

      <div class="grid grid-cols-2 gap-4 text-sm">
        <div>
          <div class="text-xs uppercase tracking-wide text-sr-muted">Status</div>
          <.site_status_badge status={@site.status} />
        </div>
        <div>
          <div class="text-xs uppercase tracking-wide text-sr-muted">Created</div>
          <.user_time
            id={"admin-edge-site-#{@site.id}-inserted-at"}
            value={@site.inserted_at}
            timezone={@current_scope.user.timezone || "Etc/UTC"}
            style={:compact}
          />
        </div>
        <div>
          <div class="text-xs uppercase tracking-wide text-sr-muted">Last Seen</div>
          <span>{format_relative_time(@site.last_seen_at)}</span>
        </div>
        <div>
          <div class="text-xs uppercase tracking-wide text-sr-muted">Site ID</div>
          <code class="text-xs font-mono">{String.slice(@site.id, 0, 8)}...</code>
        </div>
      </div>
    </.ui_panel>
    """
  end

  defp leaf_server_card(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div class="flex items-center gap-2">
          <.icon name="hero-server" class="size-4 text-secondary" />
          <span class="font-semibold text-sm">NATS Leaf Server</span>
        </div>
        <.ui_button
          :if={@leaf_server && @leaf_server.status != :pending}
          variant="ghost"
          size="xs"
          phx-click="regenerate_config"
        >
          <.icon name="hero-arrow-path" class="size-3" /> Regenerate
        </.ui_button>
      </:header>

      <%= if @leaf_server do %>
        <div class="space-y-4">
          <div class="grid grid-cols-2 gap-4 text-sm">
            <div>
              <div class="text-xs uppercase tracking-wide text-sr-muted">Status</div>
              <.leaf_status_badge status={@leaf_server.status} />
            </div>
            <div>
              <div class="text-xs uppercase tracking-wide text-sr-muted">Upstream URL</div>
              <code class="text-xs font-mono">{@leaf_server.upstream_url}</code>
            </div>
            <div>
              <div class="text-xs uppercase tracking-wide text-sr-muted">Provisioned</div>
              <.user_time
                id={"admin-edge-site-#{@site.id}-leaf-provisioned-at"}
                value={@leaf_server.provisioned_at}
                timezone={@current_scope.user.timezone || "Etc/UTC"}
                style={:compact}
              />
            </div>
            <div>
              <div class="text-xs uppercase tracking-wide text-sr-muted">Connected</div>
              <.user_time
                id={"admin-edge-site-#{@site.id}-leaf-connected-at"}
                value={@leaf_server.connected_at}
                timezone={@current_scope.user.timezone || "Etc/UTC"}
                style={:compact}
              />
            </div>
          </div>

          <%= if @leaf_server.cert_expires_at do %>
            <.cert_expiry_warning cert_expires_at={@leaf_server.cert_expires_at} />
          <% end %>
        </div>
      <% else %>
        <div class="text-center py-4 text-sm text-sr-muted">
          <.ui_spinner size="sm" />
          <span class="ml-2">Provisioning NATS leaf server...</span>
        </div>
      <% end %>
    </.ui_panel>
    """
  end

  defp nats_url_card(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div class="flex items-center gap-2">
          <.icon name="hero-link" class="size-4 text-accent" />
          <span class="font-semibold text-sm">Local NATS URL</span>
        </div>
      </:header>

      <form phx-submit="update_nats_url" class="flex gap-2">
        <input
          type="text"
          name="nats_leaf_url"
          value={@site.nats_leaf_url}
          class={ui_field_class(size: "sm", mono: true, class: "flex-1")}
          placeholder="nats://10.0.1.50:4222"
        />
        <.ui_button type="submit" variant="ghost" size="sm">
          Update
        </.ui_button>
      </form>
      <p class="text-xs text-sr-muted mt-2">
        This is the URL collectors will use to connect to the local NATS leaf server.
        Update this after deploying the leaf server with the correct IP address.
      </p>
    </.ui_panel>
    """
  end

  defp collectors_card(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div class="flex items-center gap-2">
          <.icon name="hero-cpu-chip" class="size-4 text-info" />
          <span class="font-semibold text-sm">Collectors at this Site</span>
        </div>
        <.ui_button
          :if={@collectors_enabled}
          variant="ghost"
          size="xs"
          navigate={~p"/admin/collectors"}
        >
          Manage Collectors
        </.ui_button>
      </:header>

      <%= if @collectors == [] do %>
        <div class="text-center py-4 text-sm text-sr-muted">
          No collectors assigned to this site.
          <.link
            :if={@collectors_enabled}
            navigate={~p"/admin/collectors"}
            class="text-sr-brand hover:underline"
          >
            Create a collector
          </.link>
          <%= if @collectors_enabled do %>
            and assign it to this site.
          <% else %>
            Collector onboarding is disabled for this deployment.
          <% end %>
        </div>
      <% else %>
        <div class="sr-ui-table-shell">
          <table class={ui_table_class(size: "xs")}>
            <thead>
              <tr class="text-[11px] uppercase tracking-wide text-sr-muted">
                <th>Collector</th>
                <th>Type</th>
                <th>Status</th>
              </tr>
            </thead>
            <tbody>
              <%= for collector <- @collectors do %>
                <tr>
                  <td class="font-mono text-xs">{collector.user_name}</td>
                  <td><.collector_type_badge type={collector.collector_type} /></td>
                  <td><.status_badge status={collector.status} /></td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% end %>
    </.ui_panel>
    """
  end

  defp danger_zone_card(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div class="flex items-center gap-2">
          <.icon name="hero-exclamation-triangle" class="size-4 text-error" />
          <span class="font-semibold text-sm text-error">Danger Zone</span>
        </div>
      </:header>

      <div class="flex items-center justify-between">
        <div>
          <div class="font-medium">Delete Edge Site</div>
          <p class="text-xs text-sr-muted">
            This will delete the edge site and all associated configuration.
            Collectors will need to be reassigned or will fall back to direct SaaS connection.
          </p>
        </div>
        <.ui_button
          phx-click="delete_site"
          data-confirm="Are you sure you want to delete this edge site? This action cannot be undone."
          size="sm"
          variant="danger"
        >
          Delete Site
        </.ui_button>
      </div>
    </.ui_panel>
    """
  end

  defp cert_expiry_warning(assigns) do
    days_until_expiry = DateTime.diff(assigns.cert_expires_at, DateTime.utc_now(), :day)

    {alert_class, message} =
      cond do
        days_until_expiry < 0 ->
          {"alert-error", "Certificate has expired!"}

        days_until_expiry < 7 ->
          {"alert-error", "Certificate expires in #{days_until_expiry} days!"}

        days_until_expiry < 30 ->
          {"alert-warning", "Certificate expires in #{days_until_expiry} days"}

        true ->
          {nil, nil}
      end

    assigns = assign(assigns, :alert_class, alert_class)
    assigns = assign(assigns, :message, message)
    assigns = assign(assigns, :days_until_expiry, days_until_expiry)

    ~H"""
    <%= if @alert_class do %>
      <div class={"alert #{@alert_class} text-xs"}>
        <.icon name="hero-exclamation-triangle" class="size-4" />
        <span>
          {@message} Regenerate the configuration to get new certificates.
        </span>
      </div>
    <% end %>
    """
  end

  defp site_status_badge(assigns) do
    variant =
      case assigns.status do
        :pending -> "warning"
        :active -> "success"
        :offline -> "error"
        _ -> "ghost"
      end

    assigns = assign(assigns, :variant, variant)

    ~H"""
    <.ui_badge variant={@variant}>{@status}</.ui_badge>
    """
  end

  defp leaf_status_badge(assigns) do
    variant =
      case assigns.status do
        :pending -> "warning"
        :provisioned -> "info"
        :connected -> "success"
        :disconnected -> "error"
        _ -> "ghost"
      end

    assigns = assign(assigns, :variant, variant)

    ~H"""
    <.ui_badge variant={@variant}>{@status}</.ui_badge>
    """
  end

  defp status_badge(assigns) do
    variant =
      case assigns.status do
        :pending -> "warning"
        :provisioning -> "info"
        :ready -> "success"
        :downloaded -> "success"
        :installed -> "success"
        :revoked -> "error"
        :failed -> "error"
        _ -> "ghost"
      end

    assigns = assign(assigns, :variant, variant)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@status}</.ui_badge>
    """
  end

  defp collector_type_badge(assigns) do
    {label, variant} =
      case assigns.type do
        :flowgger -> {"Syslog", "info"}
        :trapd -> {"SNMP", "secondary"}
        :netflow -> {"NetFlow", "accent"}
        :sflow -> {"sFlow", "accent"}
        :otel -> {"OTel", "primary"}
        _ -> {to_string(assigns.type), "ghost"}
      end

    assigns = assigns |> assign(:label, label) |> assign(:variant, variant)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
    """
  end

  # Data loading

  defp load_site(id, scope) do
    case EdgeSite
         |> Ash.Query.for_read(:read)
         |> Ash.Query.filter(id == ^id)
         |> Ash.Query.load(:nats_leaf_server)
         |> Ash.read_one(scope: scope) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, site} -> {:ok, site}
      {:error, error} -> {:error, error}
    end
  end

  defp load_collectors(socket, site_id, scope) do
    collectors =
      case CollectorPackage
           |> Ash.Query.for_read(:read)
           |> Ash.Query.filter(edge_site_id == ^site_id)
           |> Ash.Query.sort(inserted_at: :desc)
           |> Ash.read(scope: scope) do
        {:ok, packages} -> packages
        {:error, _} -> []
      end

    assign(socket, :collectors, collectors)
  end

  defp update_site(site, attrs, scope) do
    site
    |> Ash.Changeset.for_update(:update, attrs)
    |> Ash.update(scope: scope)
  end

  defp regenerate_config(leaf_server, scope) do
    leaf_server
    |> Ash.Changeset.for_update(:reprovision, %{})
    |> Ash.update(scope: scope)
  end

  defp generate_bundle(site, leaf_server) do
    with {:ok, direct_leaf_identities} <- get_direct_leaf_identities(site.id),
         {:ok, nats_creds} <- get_nats_creds(),
         {:ok, leaf_key_pem} <- decrypt_leaf_key(leaf_server),
         {:ok, server_key_pem} <- decrypt_server_key(leaf_server) do
      EdgeSiteBundleGenerator.create_tarball(
        site,
        leaf_server,
        nats_creds,
        leaf_key_pem: leaf_key_pem,
        server_key_pem: server_key_pem,
        direct_leaf_identities: direct_leaf_identities
      )
    end
  end

  defp get_direct_leaf_identities(site_id) do
    actor = SystemActor.system(:edge_site_bundle_generator)

    query =
      AddonAssignment
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(edge_site_id == ^site_id and enabled == true)

    case Ash.read(query, actor: actor) do
      {:ok, assignments} ->
        {:ok,
         assignments
         |> Enum.filter(&direct_leaf_assignment?/1)
         |> Enum.map(&direct_leaf_identity/1)
         |> Enum.reject(&is_nil/1)}

      {:error, reason} ->
        {:error, {:direct_leaf_identity_read_failed, reason}}
    end
  end

  defp direct_leaf_assignment?(assignment) do
    direct_backend?(assignment.params) and
      assignment.direct_access_status in [:pending, :ready] and
      is_binary(assignment.direct_identity_component_id) and
      is_binary(assignment.direct_identity_partition_id) and
      is_map(assignment.direct_subject_scope)
  end

  defp direct_backend?(params) when is_map(params) do
    output = Map.get(params, :output) || Map.get(params, "output") || %{}
    backend = Map.get(output, :backend) || Map.get(output, "backend")
    backend in [:jetstream, "jetstream"]
  end

  defp direct_backend?(_params), do: false

  defp direct_leaf_identity(assignment) do
    %{
      component_id: assignment.direct_identity_component_id,
      partition_id: assignment.direct_identity_partition_id,
      scope: assignment.direct_subject_scope
    }
  end

  defp get_nats_creds do
    # In single-deployment mode, NATS credentials come from environment configuration
    # In production, these would be provisioned by the control plane
    nats_jwt = Application.get_env(:serviceradar, :nats_account_jwt)

    creds_content = """
    -----BEGIN NATS USER JWT-----
    #{nats_jwt || "PLACEHOLDER_JWT"}
    ------END NATS USER JWT------

    ************************* IMPORTANT *************************
    NKEY Seed printed below can be used to sign and prove identity.
    NKEYs are sensitive and should be treated as secrets.

    -----BEGIN USER NKEY SEED-----
    PLACEHOLDER_SEED
    ------END USER NKEY SEED------
    """

    {:ok, creds_content}
  end

  defp decrypt_leaf_key(nil), do: {:error, :no_leaf_server}

  defp decrypt_leaf_key(leaf_server) do
    case leaf_server.leaf_key_pem_ciphertext do
      nil -> {:error, :no_leaf_key}
      ciphertext -> ServiceRadar.Vault.decrypt(ciphertext)
    end
  end

  defp decrypt_server_key(nil), do: {:error, :no_leaf_server}

  defp decrypt_server_key(leaf_server) do
    case leaf_server.server_key_pem_ciphertext do
      nil -> {:error, :no_server_key}
      ciphertext -> ServiceRadar.Vault.decrypt(ciphertext)
    end
  end

  defp format_relative_time(nil), do: "Never"

  defp format_relative_time(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86_400)}d ago"
    end
  end
end
