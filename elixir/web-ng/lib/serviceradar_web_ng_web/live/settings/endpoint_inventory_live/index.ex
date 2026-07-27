defmodule ServiceRadarWebNGWeb.Settings.EndpointInventoryLive.Index do
  @moduledoc """
  Admin-managed endpoint inventory settings.
  """

  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Inventory.EndpointInventorySettings
  alias ServiceRadar.Inventory.EndpointInventorySettingsRuntime
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.Shell

  @path "/settings/agents/endpoint-inventory"

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "settings.edge.manage") do
      settings = load_settings(scope)
      params = settings_to_params(settings)

      {:ok,
       socket
       |> assign(:page_title, "Endpoint Inventory")
       |> assign(:current_path, @path)
       |> assign(:settings, settings)
       |> assign(:settings_params, params)
       |> assign(:settings_form, to_settings_form(params))}
    else
      {:ok,
       socket
       |> put_flash(:error, "Not authorized to manage endpoint inventory settings")
       |> redirect(to: ~p"/settings/profile")}
    end
  end

  @impl true
  def handle_event("settings_validate", %{"settings" => params}, socket) do
    merged_params = merge_settings_form(socket.assigns.settings_params, params)

    {:noreply,
     socket
     |> assign(:settings_params, merged_params)
     |> assign(:settings_form, to_settings_form(merged_params))}
  end

  def handle_event("settings_save", %{"settings" => params}, socket) do
    scope = socket.assigns.current_scope
    settings = socket.assigns.settings || load_settings(scope)
    update_params = build_settings_update_params(params)

    result =
      case settings do
        %EndpointInventorySettings{} = record ->
          EndpointInventorySettings.update_settings(record, update_params, scope: scope)

        _ ->
          EndpointInventorySettings.create(update_params, scope: scope)
      end

    case result do
      {:ok, %EndpointInventorySettings{} = updated} ->
        _ = EndpointInventorySettingsRuntime.force_refresh()
        updated_params = settings_to_params(updated)

        {:noreply,
         socket
         |> put_flash(:info, "Saved endpoint inventory settings")
         |> assign(:settings, updated)
         |> assign(:settings_params, updated_params)
         |> assign(:settings_form, to_settings_form(updated_params))}

      {:error, err} ->
        {:noreply, put_flash(socket, :error, "Failed to save settings: #{inspect(err)}")}
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
        <section class="space-y-4 max-w-2xl">
          <div>
            <h1 class="text-xl font-semibold">Endpoint Inventory</h1>
          </div>

          <div class="rounded-xl border border-sr-line bg-sr-surface p-4">
            <.form
              :if={@settings_form}
              for={@settings_form}
              id="endpoint-inventory-settings-form"
              phx-change="settings_validate"
              phx-submit="settings_save"
            >
              <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
                <.input
                  field={@settings_form[:retention_days]}
                  type="number"
                  min="1"
                  max="365"
                  label="Historical scan retention (days)"
                />
              </div>

              <div class="mt-4 flex justify-end">
                <.ui_button type="submit" size="sm" variant="primary">Save Settings</.ui_button>
              </div>
            </.form>
          </div>
        </section>
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end

  defp load_settings(scope) do
    case EndpointInventorySettings.get_settings(scope: scope) do
      {:ok, %EndpointInventorySettings{} = settings} ->
        settings

      _ ->
        nil
    end
  end

  defp settings_to_params(%EndpointInventorySettings{} = settings) do
    %{"retention_days" => to_string(settings.retention_days)}
  end

  defp settings_to_params(_), do: default_settings_form()

  defp to_settings_form(params) when is_map(params), do: to_form(params, as: :settings)

  defp default_settings_form do
    %{"retention_days" => "30"}
  end

  defp merge_settings_form(form, params) when is_map(form) and is_map(params) do
    Map.merge(form, params)
  end

  defp merge_settings_form(_form, params) when is_map(params), do: Map.merge(default_settings_form(), params)

  defp build_settings_update_params(params) when is_map(params) do
    %{retention_days: int_param(params["retention_days"], 30)}
  end

  defp int_param(nil, default), do: default

  defp int_param(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp int_param(value, _default) when is_integer(value), do: value
  defp int_param(_value, default), do: default
end
