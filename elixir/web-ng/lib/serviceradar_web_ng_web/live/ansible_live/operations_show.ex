defmodule ServiceRadarWebNGWeb.AnsibleLive.OperationsShow do
  @moduledoc """
  Read-only evidence view for one Ansible automation operation.
  """

  use ServiceRadarWebNGWeb, :live_view

  use Permit.Phoenix.LiveView,
    authorization_module: ServiceRadarWebNGWeb.Authorization,
    resource_module: ServiceRadar.Automation.Ansible.AutomationOperation

  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.AnsibleLive.AutomationHistory
  alias ServiceRadarWebNGWeb.AnsibleLive.AutomationHistoryComponents

  require Logger

  @impl true
  def event_mapping do
    Map.put(Permit.Phoenix.LiveView.default_event_mapping(), "refresh", :read)
  end

  @impl true
  def skip_preload, do: [:show, :read]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "ansible.runs.view") do
      socket =
        socket
        |> assign(:page_title, "Ansible operation #{short_id(id)}")
        |> assign(:operation_id, id)
        |> assign(:bundle, nil)

      {:ok, if(connected?(socket), do: load_bundle(socket), else: socket)}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to view Ansible operations.")
       |> push_navigate(to: ~p"/dashboard")}
    end
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, load_bundle(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={~p"/ansible/operations/#{@operation_id}"}
      page_title={@page_title}
      shell={:operations}
    >
      <div
        :if={is_nil(@bundle)}
        id="secure-operation-loading"
        role="status"
        class="mx-auto w-full max-w-7xl p-6"
      >
        <.ui_spinner size="sm" />
        <span class="ml-2 text-sm text-sr-muted">Loading operation evidence…</span>
      </div>
      <AutomationHistoryComponents.operation_detail
        :if={@bundle}
        bundle={@bundle}
        timezone={@current_scope.user.timezone || "Etc/UTC"}
      />
    </Layouts.app>
    """
  end

  defp load_bundle(socket) do
    case AutomationHistory.get_operation_bundle(
           socket.assigns.operation_id,
           socket.assigns.current_scope
         ) do
      {:ok, bundle} ->
        assign(socket, :bundle, bundle)

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Ansible operation not found.")
        |> push_navigate(to: ~p"/ansible/operations")

      {:error, _reason} ->
        Logger.warning("Could not load Ansible operation evidence")

        socket
        |> put_flash(:error, "Operation evidence could not be loaded.")
        |> push_navigate(to: ~p"/ansible/operations")
    end
  end

  defp short_id(id) when is_binary(id) and byte_size(id) > 8, do: String.slice(id, 0, 8) <> "…"

  defp short_id(id), do: to_string(id)
end
