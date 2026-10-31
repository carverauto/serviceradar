defmodule ServiceRadarWebNGWeb.Admin.ManagedComponentsLive.Index do
  @moduledoc "Operator inventory and lifecycle controls for managed service certificates."
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Edge.ComponentCertificate
  alias ServiceRadar.Edge.ComponentCertificateAuthority, as: Authority
  alias ServiceRadar.Edge.ManagedCertificateLifecycle, as: Lifecycle
  alias ServiceRadar.Edge.ManagedCertificateOperation
  alias ServiceRadar.Edge.ManagedComponent
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.Shell

  require Ash.Query

  @impl true
  def mount(_params, _session, socket) do
    if RBAC.can?(socket.assigns.current_scope, "settings.edge.manage") do
      socket =
        assign(socket,
          page_title: "Service certificates",
          components: [],
          operations: %{},
          certificates: [],
          selected: nil,
          cursor: nil,
          more?: false,
          loading?: true
        )

      if connected?(socket) do
        Phoenix.PubSub.subscribe(ServiceRadar.PubSub, Authority.topic())
        send(self(), :refresh)
        Process.send_after(self(), :poll, 10_000)
      end

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "You do not have permission to manage service certificates.")
       |> push_navigate(to: ~p"/dashboard")}
    end
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, reload(socket)}
  def handle_info(:certificate_policy_changed, socket), do: {:noreply, reload(socket)}

  def handle_info(:poll, socket) do
    Process.send_after(self(), :poll, 10_000)
    {:noreply, reload(socket)}
  end

  @impl true
  def handle_event("next", _, socket) do
    cursor =
      case List.last(socket.assigns.components) do
        nil -> nil
        component -> component.component_id
      end

    {:noreply, socket |> assign(:cursor, cursor) |> reload()}
  end

  def handle_event("first", _, socket), do: {:noreply, socket |> assign(:cursor, nil) |> reload()}

  def handle_event("inspect", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case ComponentCertificate
         |> Ash.Query.for_read(:read, %{}, scope: scope)
         |> Ash.Query.filter(component_id == ^id)
         |> Ash.Query.sort(issued_at: :desc)
         |> Ash.Query.limit(20)
         |> Ash.read(scope: scope) do
      {:ok, certificates} -> {:noreply, assign(socket, selected: id, certificates: certificates)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not load certificate history.")}
    end
  end

  def handle_event("close", _, socket), do: {:noreply, assign(socket, selected: nil, certificates: [])}

  def handle_event(action, %{"id" => id}, socket) when action in ["rotate", "revoke", "reenroll"] do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "settings.edge.manage") do
      result =
        case action do
          "rotate" -> Lifecycle.rotate(id, scope: scope)
          "revoke" -> Authority.revoke_component(id, "operator-request", scope: scope)
          "reenroll" -> Authority.reenroll_component(id, scope: scope)
        end

      case result do
        {:ok, _} ->
          {:noreply, socket |> put_flash(:info, action_message(action)) |> reload()}

        {:error, _} ->
          {:noreply,
           put_flash(socket, :error, "The action could not be completed. Refresh the component state and try again.")}
      end
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to manage service certificates.")}
    end
  end

  defp action_message("rotate") do
    "Rotation requested. Installation and receiver confirmation are tracked separately."
  end

  defp action_message("revoke") do
    "Revocation saved. Disconnected receivers may still have stale policy."
  end

  defp action_message("reenroll") do
    "Re-enrollment allowed in a new generation. Old certificates remain revoked."
  end

  defp reload(socket) do
    scope = socket.assigns.current_scope
    cursor = socket.assigns.cursor

    query =
      ManagedComponent
      |> Ash.Query.for_read(:read, %{}, scope: scope)
      |> Ash.Query.sort(:component_id)
      |> Ash.Query.limit(51)

    query = if cursor, do: Ash.Query.filter(query, component_id > ^cursor), else: query

    with {:ok, rows} <- Ash.read(query, scope: scope),
         components = Enum.take(rows, 50),
         ids = Enum.map(components, & &1.component_id),
         {:ok, operations} <-
           ManagedCertificateOperation
           |> Ash.Query.for_read(:read, %{}, scope: scope)
           |> Ash.Query.filter(component_id in ^ids and status != :superseded)
           |> Ash.read(scope: scope) do
      assign(socket,
        components: components,
        operations: Map.new(operations, &{&1.component_id, &1}),
        more?: length(rows) > 50,
        loading?: false
      )
    else
      {:error, _} -> socket |> assign(:loading?, false) |> put_flash(:error, "Could not refresh managed certificates.")
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <Shell.settings_chrome
        current_path="/admin/service-certificates"
        current_scope={@current_scope}
        active_view={@settings_active_view}
        active_category={@settings_active_category}
        breadcrumbs={@settings_breadcrumbs}
        nav_tree={@settings_nav_tree}
        palette={@settings_palette}
        stats={@settings_stats}
      >
        <div class="space-y-5" id="managed-certificates">
          <div>
            <h1 class="text-xl font-semibold">Service certificates</h1>
            <p class="text-sm text-sr-muted">
              Manage identities separately from their host agents.
              Revoking a component blocks renewal until re-enrollment.
            </p>
          </div>
          <.ui_panel>
            <p class="text-sm text-sr-muted">
              Saved policy is the desired state. Installation, receiver-observed
              certificate use, and revocation enforcement are separate evidence.
              Offline edges can continue local ingestion with stale policy until
              they reconnect.
            </p>
          </.ui_panel>
          <p :if={@loading?} class="text-sm text-sr-muted">Loading service certificates...</p>
          <.ui_panel :if={!@loading? && @components == []}>
            No managed components on this page. Enroll a leaf or collector with
            the CLI to start managing its certificates.
          </.ui_panel>
          <.ui_panel :for={component <- @components}>
            <.component_row component={component} operation={@operations[component.component_id]} />
          </.ui_panel>
          <div class="flex gap-2">
            <.ui_button :if={@cursor} phx-click="first" size="sm">First page</.ui_button>
            <.ui_button :if={@more?} phx-click="next" size="sm">Next page</.ui_button>
          </div>
          <.ui_panel :if={@selected}>
            <:header><span>Recent certificates: {@selected}</span></:header>
            <p class="text-xs text-sr-muted">
              Most recent 20 issued certificates. History includes superseded and revoked identities.
            </p>
            <div :for={certificate <- @certificates} class="py-3 border-b border-base-300">
              <p class="text-sm">{certificate.role} / generation {certificate.generation}</p>
              <p class="font-mono text-xs break-all">{certificate.fingerprint}</p>
              <p class="text-xs text-sr-muted">Expires {certificate.not_after}</p>
            </div>
            <.ui_button phx-click="close" size="sm">Close history</.ui_button>
          </.ui_panel>
        </div>
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end

  attr :component, :map, required: true
  attr :operation, :any, required: true

  def component_row(assigns) do
    assigns = assign(assigns, :infrastructure_grant, infrastructure_grant(assigns.component))

    ~H"""
    <div id={"managed-component-#{@component.component_id}"} class="space-y-3">
      <div class="flex flex-wrap justify-between gap-3">
        <div class="min-w-0">
          <h2 class="font-semibold">{@component.component_type}</h2>
          <p class="font-mono text-xs break-all">{@component.component_id}</p>
          <p class="text-xs text-sr-muted">
            Host: {@component.host_agent_id || "Deployment managed"} / generation {@component.generation}
          </p>
        </div>
        <span class={if @component.blocked, do: "badge badge-error", else: "badge badge-outline"}>
          {if @component.blocked, do: "Revocation requested", else: "Enrollment allowed"}
        </span>
      </div>
      <div :if={@operation} class="text-sm space-y-1">
        <p>Operation: {@operation.status}</p>
        <p>Installed: {confirmation(@operation.receipt["installed"])}</p>
        <p>Activated: {confirmation(@operation.receipt["activated"])}</p>
        <p>
          Receiver-observed roles: {Enum.join(Map.keys(@operation.observed_roles), ", ")
          |> empty_as_pending()}
        </p>
        <p :if={@operation.renew_after}>Renewal due: {@operation.renew_after}</p>
        <p :if={@operation.error} class="text-error">{@operation.error}</p>
      </div>
      <p class="text-xs text-sr-muted">Revocation enforcement across receivers: unconfirmed.</p>
      <div
        :if={@infrastructure_grant}
        id={"managed-component-grant-#{@component.component_id}"}
        class="space-y-1 text-sm"
      >
        <%= case @infrastructure_grant do %>
          <% {:stored, grant} -> %>
            <p>Stored NATS grant</p>
            <p class="font-mono text-xs">Publish allow: {format_subjects(grant.publish)}</p>
            <p class="font-mono text-xs">Publish deny: {format_subjects(grant.publish_deny)}</p>
            <p class="font-mono text-xs">Subscribe allow: {format_subjects(grant.subscribe)}</p>
            <p class="font-mono text-xs">Subscribe deny: {format_subjects(grant.subscribe_deny)}</p>
          <% :missing -> %>
            <p>No stored NATS grant.</p>
        <% end %>
      </div>
      <div class="flex flex-wrap gap-2">
        <.ui_button phx-click="inspect" phx-value-id={@component.component_id} size="sm">Certificates</.ui_button>
        <.ui_button
          :if={!@component.blocked && @component.host_agent_id}
          phx-click="rotate"
          phx-value-id={@component.component_id}
          size="sm"
        >Rotate</.ui_button>
        <.ui_button
          :if={!@component.blocked}
          phx-click="revoke"
          phx-value-id={@component.component_id}
          data-confirm="Revoke this component and block its automatic renewal?"
          variant="danger"
          size="sm"
        >Revoke</.ui_button>
        <.ui_button
          :if={@component.blocked}
          phx-click="reenroll"
          phx-value-id={@component.component_id}
          data-confirm="Allow a new enrollment generation? Previously revoked certificates will remain revoked."
          size="sm"
        >Re-enroll</.ui_button>
      </div>
    </div>
    """
  end

  defp infrastructure_grant(%{component_type: type, nats_permissions: permissions}) do
    if ManagedComponent.infrastructure_type?(type) do
      case grant_lists(permissions) do
        {:ok, grant} -> {:stored, grant}
        :missing -> :missing
      end
    end
  end

  defp grant_lists(permissions) when is_map(permissions) do
    with publish when is_list(publish) <- grant_list(permissions, :publish),
         subscribe when is_list(subscribe) <- grant_list(permissions, :subscribe),
         {:ok, publish_deny} <- optional_list(grant_list(permissions, :publish_deny)),
         {:ok, subscribe_deny} <- optional_list(grant_list(permissions, :subscribe_deny)) do
      {:ok,
       %{
         publish: publish,
         subscribe: subscribe,
         publish_deny: publish_deny,
         subscribe_deny: subscribe_deny
       }}
    else
      _ -> :missing
    end
  end

  defp grant_lists(_permissions), do: :missing

  defp grant_list(permissions, key) do
    Map.get(permissions, key, Map.get(permissions, Atom.to_string(key)))
  end

  defp optional_list(nil), do: {:ok, []}
  defp optional_list(subjects) when is_list(subjects), do: {:ok, subjects}
  defp optional_list(_subjects), do: :error

  defp format_subjects([]), do: "(empty)"
  defp format_subjects(subjects), do: Enum.join(subjects, ", ")

  defp empty_as_pending(""), do: "Not confirmed"
  defp empty_as_pending(value), do: value

  defp confirmation(value) do
    if value, do: "Yes", else: "Not confirmed"
  end
end
