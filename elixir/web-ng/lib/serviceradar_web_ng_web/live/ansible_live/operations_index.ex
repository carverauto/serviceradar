defmodule ServiceRadarWebNGWeb.AnsibleLive.OperationsIndex do
  @moduledoc """
  Read-only history for Ansible `AutomationOperation` launches.

  All reads are authorized with the authenticated human scope and pass through
  the secret-safe `AutomationHistory` projection.
  """

  use ServiceRadarWebNGWeb, :live_view

  use Permit.Phoenix.LiveView,
    authorization_module: ServiceRadarWebNGWeb.Authorization,
    resource_module: ServiceRadar.Automation.Ansible.AutomationOperation

  alias ServiceRadarWebNG.AnsibleAutomation.History, as: AutomationHistory
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.AnsibleLive.AutomationHistoryComponents

  require Logger

  @state_filters [
    {"all", nil},
    {"planned", :planned},
    {"dispatching", :dispatching},
    {"running", :running},
    {"succeeded", :succeeded},
    {"failed", :failed},
    {"canceled", :canceled},
    {"dispatch partial", :dispatch_partial},
    {"dispatch ambiguous", :dispatch_ambiguous},
    {"cancel failed", :cancel_failed}
  ]
  @state_filter_map Map.new(@state_filters)

  @impl true
  def event_mapping do
    Map.merge(Permit.Phoenix.LiveView.default_event_mapping(), %{
      "filter_state" => :read,
      "refresh" => :read
    })
  end

  @impl true
  def skip_preload, do: [:index, :read]

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "ansible.runs.view") do
      socket =
        socket
        |> assign(:page_title, "Ansible operations")
        |> assign(:page_limit, 100)
        |> assign(:can_launch, RBAC.can?(scope, "ansible.runs.launch"))
        |> assign(:state_filter, "all")
        |> assign(:state_filters, @state_filters)
        |> assign(:operation_count, 0)
        |> assign(:history_loaded, false)
        |> assign(:history_error, nil)
        |> stream(:operations, [], reset: true)

      {:ok, if(connected?(socket), do: load_operations(socket), else: socket)}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to view Ansible operations.")
       |> push_navigate(to: ~p"/dashboard")}
    end
  end

  @impl true
  def handle_event("filter_state", %{"state" => state}, socket) do
    if Map.has_key?(@state_filter_map, state) do
      {:noreply, socket |> assign(:state_filter, state) |> load_operations()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("refresh", _params, socket), do: {:noreply, load_operations(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path="/ansible/operations"
      page_title={@page_title}
      shell={:operations}
    >
      <div id="secure-ansible-operations" class="mx-auto w-full max-w-7xl space-y-5 p-6">
        <header class="flex flex-wrap items-start justify-between gap-4">
          <div class="space-y-1">
            <h1 class="text-2xl font-semibold">Ansible operations</h1>
            <p class="text-sm text-sr-muted">
              {@operation_count} operation{if @operation_count == 1, do: "", else: "s"} shown
              (capped at {@page_limit}).
            </p>
          </div>
          <div class="flex items-center gap-2">
            <.ui_button
              :if={@can_launch}
              id="select-ansible-launch-devices"
              navigate={~p"/devices"}
              size="sm"
              variant="primary"
            >
              <.icon name="hero-computer-desktop" class="size-4" /> Select Devices
            </.ui_button>
            <.ui_button type="button" phx-click="refresh" size="sm" variant="neutral">
              <.icon name="hero-arrow-path" class="size-4" /> Refresh
            </.ui_button>
          </div>
        </header>

        <div class="flex flex-wrap items-center gap-2" aria-label="Operation state filter">
          <span class="mr-1 text-sm text-sr-muted">Filter:</span>
          <.ui_button
            :for={{label, state} <- @state_filters}
            type="button"
            phx-click="filter_state"
            phx-value-state={label}
            size="xs"
            variant={if(label == @state_filter, do: "primary", else: "ghost")}
            active={label == @state_filter}
          >
            {state || label}
          </.ui_button>
        </div>

        <div :if={@history_error} role="alert" class={ui_alert_class("error")}>
          <.icon name="hero-exclamation-circle" class="size-5" />
          <span>{@history_error}</span>
        </div>

        <div
          :if={not @history_loaded}
          id="secure-operations-loading"
          role="status"
          class="flex items-center gap-2 p-4 text-sm text-sr-muted"
        >
          <.ui_spinner size="sm" /> Loading Ansible operation history…
        </div>

        <div
          :if={@history_loaded and @operation_count == 0 and is_nil(@history_error)}
          id="secure-operations-empty"
          role="status"
          class="rounded-sr-surface border border-dashed border-sr-line p-8 text-center text-sm text-sr-muted"
        >
          No Ansible operations match the current filter.
        </div>

        <div :if={@operation_count > 0} class="overflow-x-auto border border-sr-line bg-sr-surface">
          <table class={ui_table_class(zebra: true)}>
            <thead>
              <tr>
                <th>State</th>
                <th>Action</th>
                <th>Human initiator</th>
                <th>Source</th>
                <th>Mode</th>
                <th>Started</th>
                <th>Ended</th>
                <th>Operation</th>
                <th></th>
              </tr>
            </thead>
            <tbody id="secure-operation-history" phx-update="stream">
              <tr :for={{dom_id, operation} <- @streams.operations} id={dom_id}>
                <td>
                  <span class={AutomationHistoryComponents.state_badge_classes(operation.state)}>
                    {operation.state}
                  </span>
                </td>
                <td><code class="text-xs">{operation.action}</code></td>
                <td>
                  <span class="text-xs">{operation.initiator_principal_type}</span>
                  <code class="block max-w-56 break-all text-xs">
                    {operation.initiator_principal_id}
                  </code>
                </td>
                <td>{operation.request_source}</td>
                <td>
                  <.ui_badge size="sm" variant="ghost">{operation_mode(operation)}</.ui_badge>
                </td>
                <td class="whitespace-nowrap">
                  <.user_time
                    id={"ansible-operation-#{operation.id}-started-at"}
                    value={operation.started_at}
                    timezone={@current_scope.user.timezone || "Etc/UTC"}
                    style={:compact}
                  />
                </td>
                <td class="whitespace-nowrap">
                  <.user_time
                    id={"ansible-operation-#{operation.id}-ended-at"}
                    value={operation.ended_at}
                    timezone={@current_scope.user.timezone || "Etc/UTC"}
                    style={:compact}
                  />
                </td>
                <td><code class="text-xs">{short_id(operation.id)}</code></td>
                <td>
                  <.ui_button
                    navigate={~p"/ansible/operations/#{operation.id}"}
                    size="xs"
                    variant="neutral"
                  >
                    View evidence
                  </.ui_button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp load_operations(socket) do
    state = Map.fetch!(@state_filter_map, socket.assigns.state_filter)

    case AutomationHistory.list_operations(socket.assigns.current_scope, state) do
      {:ok, operations} ->
        socket
        |> assign(:operation_count, length(operations))
        |> assign(:history_loaded, true)
        |> assign(:history_error, nil)
        |> stream(:operations, operations, reset: true)

      {:error, _reason} ->
        Logger.warning("Could not load Ansible operation history")

        socket
        |> assign(:operation_count, 0)
        |> assign(:history_loaded, true)
        |> assign(:history_error, "Ansible operation history could not be loaded.")
        |> stream(:operations, [], reset: true)
    end
  end

  defp operation_mode(%{check_mode: true}), do: "check"
  defp operation_mode(%{mutating: true}), do: "mutating"
  defp operation_mode(_operation), do: "read-only"

  defp short_id(id) when is_binary(id) and byte_size(id) > 8, do: String.slice(id, 0, 8) <> "…"

  defp short_id(id), do: to_string(id)
end
