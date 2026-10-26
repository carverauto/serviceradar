defmodule ServiceRadarWebNGWeb.Settings.InventoryCleanupLive do
  @moduledoc """
  Inventory Cleanup settings: ephemeral device expiry, source id retirement and
  its mass-change guard, and the purge of soft-deleted devices after the
  retention window.

  This page was a Sweep Profiles tab (`/settings/networks?tab=cleanup`);
  `NetworksLive.Index` sends that URL here.
  """

  use ServiceRadarWebNGWeb, :live_view

  alias AshPhoenix.Form
  alias ServiceRadar.Inventory.DeviceCleanupSettings
  alias ServiceRadar.Inventory.DeviceCleanupWorker
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.InventoryCleanupLive.Form, as: CleanupForm
  alias ServiceRadarWebNGWeb.Settings.Shell

  @current_path "/settings/networks/inventory-cleanup"
  @permission "settings.networks.manage"

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, @permission) do
      socket =
        socket
        |> assign(:page_title, "Inventory Cleanup")
        |> assign(:current_path, @current_path)

      # Reading (and on first use creating) the settings row waits for the
      # connected mount.
      if connected?(socket) do
        {:ok, assign_settings(socket, load_or_create_settings(scope))}
      else
        {:ok, socket |> assign(:loaded?, false) |> assign(:settings, nil) |> assign(:form, nil)}
      end
    else
      {:ok,
       socket
       |> put_flash(:error, "Not authorized to manage inventory cleanup settings")
       |> redirect(to: ~p"/settings/profile")}
    end
  end

  @impl true
  def handle_event(event, params, socket) do
    if RBAC.can?(socket.assigns.current_scope, @permission) do
      authorized_event(event, params, socket)
    else
      {:noreply, put_flash(socket, :error, "Not authorized")}
    end
  end

  defp authorized_event("validate_cleanup_settings", %{"cleanup" => params}, socket) do
    form = Form.validate(socket.assigns.form, params)

    {:noreply, assign(socket, :form, to_form(form))}
  end

  defp authorized_event("save_cleanup_settings", %{"cleanup" => params}, socket) do
    form = Form.validate(socket.assigns.form, params)

    case Form.submit(form, params: params) do
      {:ok, settings} ->
        _ = DeviceCleanupWorker.ensure_scheduled()

        {:noreply,
         socket
         |> assign_settings(settings)
         |> put_flash(:info, "Inventory cleanup settings saved")}

      {:error, form} ->
        {:noreply,
         socket
         |> assign(:form, to_form(form))
         |> put_flash(:error, "Failed to save inventory cleanup settings")}
    end
  end

  defp authorized_event("run_cleanup_now", _params, socket) do
    case DeviceCleanupSettings.run_cleanup(scope: socket.assigns.current_scope) do
      {:ok, _} ->
        {:noreply, put_flash(socket, :info, "Cleanup job queued")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to queue cleanup: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <Shell.settings_chrome
        current_path={@current_path}
        current_scope={@current_scope}
        active_view={@settings_active_view}
        active_category={@settings_active_category}
        breadcrumbs={@settings_breadcrumbs}
        nav_tree={@settings_nav_tree}
        palette={@settings_palette}
        stats={@settings_stats}
      >
        <CleanupForm.render :if={@loaded?} form={@form} settings={@settings} />
        <div
          :if={not @loaded?}
          id="inventory-cleanup-loading"
          class="rounded-xl border border-sr-line bg-sr-surface p-6 text-sm text-sr-muted"
        >
          Loading inventory cleanup settings…
        </div>
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end

  defp assign_settings(socket, settings) do
    socket
    |> assign(:loaded?, true)
    |> assign(:settings, settings)
    |> assign(:form, settings_form(socket.assigns.current_scope, settings))
  end

  defp load_or_create_settings(scope) do
    case DeviceCleanupSettings.get_settings(scope: scope) do
      {:ok, settings} ->
        settings

      {:error, _} ->
        case DeviceCleanupSettings.create_settings(%{}, scope: scope) do
          {:ok, settings} ->
            _ = DeviceCleanupWorker.ensure_scheduled()
            settings

          {:error, _} ->
            nil
        end
    end
  end

  defp settings_form(_scope, nil), do: nil

  defp settings_form(scope, settings) do
    settings
    |> Form.for_update(:update, domain: ServiceRadar.Inventory, scope: scope, as: "cleanup")
    |> to_form()
  end
end
