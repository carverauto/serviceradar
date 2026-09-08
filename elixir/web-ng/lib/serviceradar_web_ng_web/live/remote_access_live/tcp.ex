defmodule ServiceRadarWebNGWeb.RemoteAccessLive.TCP do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Edge.RemoteAccessTcpTarget
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.FeatureFlags

  @remote_access_permission "devices.remote_access.tcp.open"

  @impl true
  def mount(%{"target_id" => target_id}, _session, socket) do
    feature_enabled? = FeatureFlags.remote_access_tcp_enabled?()
    can_open? = feature_enabled? and RBAC.can?(socket.assigns.current_scope, @remote_access_permission)

    socket =
      socket
      |> assign(:page_title, "TCP Remote Access")
      |> assign(:target_id, target_id)
      |> assign(:feature_enabled?, feature_enabled?)
      |> assign(:can_open?, can_open?)
      |> assign(:target, nil)
      |> assign(:workflow, "")
      |> assign(:load_error, nil)

    if connected?(socket) and can_open? do
      {:ok, load_target(socket)}
    else
      {:ok, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="flex h-[calc(100vh-4rem)] min-h-[620px] flex-col bg-sr-surface">
        <div class="flex min-h-14 items-center gap-3 border-b border-sr-line px-4">
          <.ui_button navigate={~p"/remote-access/targets"} size="sm" variant="ghost">
            <.icon name="hero-arrow-left" class="size-4" /> Targets
          </.ui_button>
          <div class="min-w-0 flex-1">
            <h1 class="truncate text-sm font-semibold">TCP remote access</h1>
            <p class="truncate font-mono text-xs text-sr-muted">{@target_id}</p>
          </div>
        </div>

        <div
          :if={!@can_open? or @load_error}
          class="flex min-h-0 flex-1 items-center justify-center p-6"
        >
          <div class="max-w-xl rounded border border-error/30 bg-error/10 p-4 text-sm text-error">
            <%= cond do %>
              <% !@feature_enabled? -> %>
                TCP remote access is not enabled for this deployment.
              <% !@can_open? -> %>
                You do not have permission to open TCP remote-access sessions.
              <% true -> %>
                {@load_error}
            <% end %>
          </div>
        </div>

        <.remote_access_tcp_text
          :if={@can_open? and is_nil(@load_error) and not is_nil(@target)}
          id={"remote-access-tcp-#{@target_id}"}
          class="min-h-0 flex-1"
          target_id={@target_id}
          title={@target.name || "TCP remote access"}
          workflow={@workflow}
        />
      </div>
    </Layouts.app>
    """
  end

  defp load_target(socket) do
    case RemoteAccessTcpTarget.get_by_id(socket.assigns.target_id, scope: socket.assigns.current_scope) do
      {:ok, %RemoteAccessTcpTarget{} = target} ->
        if target.enabled and tcp_browser_workflow?(target) do
          socket
          |> assign(:target, target)
          |> assign(:workflow, workflow_text(target))
          |> assign(:load_error, nil)
        else
          assign(socket, :load_error, "This TCP target does not declare an approved browser workflow.")
        end

      {:ok, nil} ->
        assign(socket, :load_error, "TCP target was not found.")

      {:error, _error} ->
        assign(socket, :load_error, "TCP target was not found or is not visible.")
    end
  end

  defp tcp_browser_workflow?(target) do
    metadata = target.metadata || %{}
    browser_renderer(metadata) == "text" or present?(Map.get(metadata, "client_workflow"))
  end

  defp workflow_text(target) do
    target.metadata
    |> Kernel.||(%{})
    |> Map.get("client_workflow")
    |> case do
      value when is_binary(value) -> value
      _value -> "Text TCP renderer enabled by target policy."
    end
  end

  defp browser_renderer(metadata) do
    metadata
    |> Map.get("browser_renderer")
    |> case do
      value when is_binary(value) -> value |> String.trim() |> String.downcase()
      _value -> nil
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)
end
