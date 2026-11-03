defmodule ServiceRadarWebNGWeb.Admin.ManagedComponentsLive.Index do
  @moduledoc "Operator inventory and lifecycle controls for managed service certificates."
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Edge.ComponentCertificate
  alias ServiceRadar.Edge.ComponentCertificateAuthority, as: Authority
  alias ServiceRadar.Edge.ManagedCertificateLifecycle, as: Lifecycle
  alias ServiceRadar.Edge.ManagedCertificateOperation
  alias ServiceRadar.Edge.ManagedComponent
  alias ServiceRadar.Edge.RevokedComponentCertificate
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.Shell

  require Ash.Query

  @page_size 25

  @impl true
  def mount(_params, _session, socket) do
    if RBAC.can?(socket.assigns.current_scope, "settings.edge.manage") do
      socket =
        assign(socket,
          page_title: "Service certificates",
          components: [],
          operations: %{},
          certificates: [],
          revoked_fingerprints: MapSet.new(),
          revoked_generations: MapSet.new(),
          selected: nil,
          cursor: nil,
          previous_cursors: [],
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
  def handle_event("next", _, %{assigns: %{more?: true, components: components}} = socket) do
    cursor = List.last(components).component_id
    previous_cursors = [socket.assigns.cursor | socket.assigns.previous_cursors]
    {:noreply, navigate(socket, cursor, previous_cursors)}
  end

  def handle_event("next", _, socket), do: {:noreply, socket}

  def handle_event("previous", _, %{assigns: %{previous_cursors: [cursor | rest]}} = socket) do
    {:noreply, navigate(socket, cursor, rest)}
  end

  def handle_event("previous", _, socket), do: {:noreply, socket}

  def handle_event("first", _, socket) do
    {:noreply, navigate(socket, nil, [])}
  end

  def handle_event("inspect", %{"id" => id}, socket), do: {:noreply, load_history(socket, id)}

  def handle_event("close", _, socket), do: {:noreply, clear_selection(socket)}

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

  def handle_event("revoke-certificate", %{"id" => id, "fingerprint" => fingerprint}, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "settings.edge.manage") do
      case Authority.revoke_component_certificate(id, fingerprint, "operator-request", scope: scope) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(
             :info,
             "Fingerprint revoked. The component stays enrolled. Disconnected receivers may still have stale policy."
           )
           |> reload()}

        {:error, _} ->
          {:noreply,
           put_flash(socket, :error, "The certificate could not be revoked. Refresh the history and try again.")}
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

  defp navigate(socket, cursor, previous_cursors) do
    case read_page(socket, cursor) do
      {:ok, page} ->
        socket
        |> assign(page)
        |> assign(cursor: cursor, previous_cursors: previous_cursors, loading?: false)
        |> clear_selection()

      {:error, _} ->
        refuse_page(socket)
    end
  end

  defp reload(socket) do
    case read_page(socket, socket.assigns.cursor) do
      {:ok, page} ->
        socket
        |> assign(page)
        |> assign(:loading?, false)
        |> refresh_open_history()

      {:error, _} ->
        refuse_page(socket)
    end
  end

  defp read_page(socket, cursor) do
    scope = socket.assigns.current_scope

    query =
      ManagedComponent
      |> Ash.Query.for_read(:read, %{}, scope: scope)
      |> Ash.Query.sort(:component_id)
      |> Ash.Query.limit(@page_size + 1)

    query = if cursor, do: Ash.Query.filter(query, component_id > ^cursor), else: query

    with {:ok, rows} <- Ash.read(query, scope: scope),
         components = Enum.take(rows, @page_size),
         ids = Enum.map(components, & &1.component_id),
         {:ok, operations} <- open_operations(ids, scope) do
      {:ok,
       %{
         components: components,
         operations: Map.new(operations, &{&1.component_id, &1}),
         more?: length(rows) > @page_size
       }}
    end
  end

  defp open_operations(ids, scope) do
    ManagedCertificateOperation
    |> Ash.Query.for_read(:read, %{}, scope: scope)
    |> Ash.Query.filter(component_id in ^ids and status != :superseded)
    |> Ash.read(scope: scope)
  end

  defp refuse_page(socket) do
    socket
    |> assign(:loading?, false)
    |> put_flash(:error, "Could not refresh managed certificates.")
  end

  defp refresh_open_history(socket) do
    case socket.assigns.selected do
      id when is_binary(id) -> load_history(socket, id)
      _ -> socket
    end
  end

  defp load_history(socket, id) do
    scope = socket.assigns.current_scope

    if Enum.any?(socket.assigns.components, &(&1.component_id == id)) do
      with {:ok, certificates} <- component_certificates(id, scope),
           {:ok, revoked} <- revocation_marks(id, certificates, scope) do
        assign(socket,
          selected: id,
          certificates: certificates,
          revoked_fingerprints: revoked.fingerprints,
          revoked_generations: revoked.generations
        )
      else
        {:error, _} -> put_flash(socket, :error, "Could not load certificate history.")
      end
    else
      clear_selection(socket)
    end
  end

  defp clear_selection(socket) do
    assign(socket,
      selected: nil,
      certificates: [],
      revoked_fingerprints: MapSet.new(),
      revoked_generations: MapSet.new()
    )
  end

  defp component_certificates(id, scope) do
    ComponentCertificate
    |> Ash.Query.for_read(:read, %{}, scope: scope)
    |> Ash.Query.filter(component_id == ^id)
    |> Ash.Query.sort(issued_at: :desc)
    |> Ash.Query.limit(20)
    |> Ash.read(scope: scope)
  end

  defp revocation_marks(_id, [], _scope) do
    {:ok, %{fingerprints: MapSet.new(), generations: MapSet.new()}}
  end

  defp revocation_marks(id, certificates, scope) do
    fingerprints = Enum.map(certificates, & &1.fingerprint)
    generations = certificates |> Enum.map(& &1.generation) |> Enum.uniq()

    case RevokedComponentCertificate
         |> Ash.Query.for_read(:read, %{}, scope: scope)
         |> Ash.Query.filter(
           component_id == ^id and
             ((is_nil(fingerprint) and generation in ^generations) or fingerprint in ^fingerprints)
         )
         |> Ash.Query.limit(40)
         |> Ash.read(scope: scope) do
      {:ok, rows} ->
        {:ok,
         %{
           fingerprints:
             for(%{fingerprint: fingerprint} <- rows, is_binary(fingerprint), into: MapSet.new(), do: fingerprint),
           generations: for(%{fingerprint: nil, generation: generation} <- rows, into: MapSet.new(), do: generation)
         }}

      error ->
        error
    end
  end

  defp certificate_revoked?(certificate, fingerprints, generations) do
    MapSet.member?(fingerprints, certificate.fingerprint) or
      MapSet.member?(generations, certificate.generation)
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :selected_component, Enum.find(assigns.components, &(&1.component_id == assigns.selected)))

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
              Revoking one fingerprint from its history leaves the component enrolled.
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
          <.ui_panel :if={!@loading? && @components != []}>
            <div class="overflow-x-auto">
              <table id="managed-components-table" class={ui_table_class()}>
                <caption class="sr-only">
                  Managed service certificates. Select a component for details and lifecycle actions.
                </caption>
                <thead>
                  <tr>
                    <th scope="col">Component</th>
                    <th scope="col">Type</th>
                    <th scope="col">Host</th>
                    <th scope="col">Enrollment</th>
                    <th scope="col">Operation</th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={component <- @components}
                    id={"component-row-#{component.component_id}"}
                    phx-click="inspect"
                    phx-value-id={component.component_id}
                    class="cursor-pointer hover:bg-sr-subtle"
                  >
                    <td class="max-w-sm">
                      <button
                        type="button"
                        class="text-left font-mono text-xs break-all text-sr-brand hover:underline focus-visible:underline"
                        phx-click="inspect"
                        phx-value-id={component.component_id}
                        aria-haspopup="dialog"
                      >
                        {component.component_id}
                      </button>
                    </td>
                    <td>{component.component_type}</td>
                    <td>{component.host_agent_id || "Deployment managed"}</td>
                    <td>
                      {if component.blocked, do: "Revocation requested", else: "Enrollment allowed"}
                    </td>
                    <td>
                      {if operation = @operations[component.component_id],
                        do: operation.status,
                        else: "No operation"}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </.ui_panel>
          <nav
            :if={!@loading?}
            aria-label="Service certificate pages"
            class="flex flex-wrap items-center justify-between gap-3"
          >
            <span class="text-sm text-sr-muted">Page {length(@previous_cursors) + 1} · {length(
              @components
            )} components</span>
            <div class="flex gap-2">
              <.ui_button :if={@cursor} phx-click="first" variant="outline" size="sm">First page</.ui_button>
              <.ui_button
                phx-click="previous"
                variant="outline"
                size="sm"
                disabled={@previous_cursors == []}
              >Previous</.ui_button>
              <.ui_button phx-click="next" variant="outline" size="sm" disabled={!@more?}>Next</.ui_button>
            </div>
          </nav>
          <.ui_modal
            :if={@selected_component}
            id="component-details-modal"
            on_cancel="close"
            size="xl"
          >
            <:title>Service certificate details</:title>
            <.component_row component={@selected_component} operation={@operations[@selected]} />
            <h3 class="font-semibold pt-4 border-t border-sr-line">Recent certificates</h3>
            <p :if={@certificates == []} class="text-sm text-sr-muted">No certificates issued yet.</p>
            <p class="text-xs text-sr-muted">
              Most recent 20 issued certificates. Revoking one fingerprint leaves the
              component enrolled. The component Revoke control still blocks renewal.
            </p>
            <div
              :for={certificate <- @certificates}
              id={"managed-certificate-#{certificate.fingerprint}"}
              class="space-y-2 border-b border-base-300 py-3"
            >
              <p class="text-sm">{certificate.role} / generation {certificate.generation}</p>
              <p class="font-mono text-xs break-all">{certificate.fingerprint}</p>
              <p class="text-xs text-sr-muted">Expires {certificate.not_after}</p>
              <p
                :if={certificate_revoked?(certificate, @revoked_fingerprints, @revoked_generations)}
                class="text-xs"
              >
                Revoked
              </p>
              <.ui_button
                :if={!certificate_revoked?(certificate, @revoked_fingerprints, @revoked_generations)}
                id={"revoke-fingerprint-#{certificate.fingerprint}"}
                phx-click="revoke-certificate"
                phx-value-id={@selected}
                phx-value-fingerprint={certificate.fingerprint}
                data-confirm="Revoke this certificate fingerprint? The component stays enrolled."
                variant="danger"
                size="sm"
              >
                Revoke fingerprint
              </.ui_button>
            </div>
            <:actions>
              <.ui_button phx-click="close" variant="outline" size="sm">Close</.ui_button>
            </:actions>
          </.ui_modal>
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
