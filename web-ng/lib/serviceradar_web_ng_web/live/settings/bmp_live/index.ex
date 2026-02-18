defmodule ServiceRadarWebNGWeb.Settings.BmpLive.Index do
  @moduledoc """
  Admin-managed BMP settings for routing ingestion and causal overlays.
  """

  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.SettingsComponents

  alias ServiceRadar.Observability.BmpSettings
  alias ServiceRadar.Observability.BmpSettingsRuntime
  alias ServiceRadarWebNG.RBAC

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "settings.networks.manage") do
      settings = load_settings(scope)

      {:ok,
       socket
       |> assign(:page_title, "BMP Settings")
       |> assign(:current_path, "/settings/networks/bmp")
       |> assign(:settings, settings)
       |> assign(:settings_form, settings_to_form(settings))}
    else
      {:ok,
       socket
       |> put_flash(:error, "Not authorized to manage BMP settings")
       |> redirect(to: ~p"/settings/profile")}
    end
  end

  @impl true
  def handle_event("settings_validate", %{"settings" => params}, socket) do
    {:noreply,
     assign(socket, :settings_form, merge_settings_form(socket.assigns.settings_form, params))}
  end

  def handle_event("settings_save", %{"settings" => params}, socket) do
    scope = socket.assigns.current_scope

    settings = socket.assigns.settings || load_settings(scope)
    update_params = build_settings_update_params(params)

    result =
      case settings do
        %BmpSettings{} = record ->
          BmpSettings.update_settings(record, update_params, scope: scope)

        _ ->
          BmpSettings.create(update_params, scope: scope)
      end

    case result do
      {:ok, %BmpSettings{} = updated} ->
        _ = BmpSettings.apply_routing_retention_policy(updated)
        _ = BmpSettingsRuntime.force_refresh()

        {:noreply,
         socket
         |> put_flash(:info, "Saved BMP settings")
         |> assign(:settings, updated)
         |> assign(:settings_form, settings_to_form(updated))}

      {:error, err} ->
        {:noreply, socket |> put_flash(:error, "Failed to save settings: #{inspect(err)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.settings_shell current_path="/settings/networks/bmp">
        <div class="space-y-4">
          <.settings_nav current_path="/settings/networks/bmp" current_scope={@current_scope} />
          <.network_nav current_path="/settings/networks/bmp" current_scope={@current_scope} />
        </div>

        <section class="space-y-4 max-w-3xl">
          <div>
            <h1 class="text-xl font-semibold">BMP</h1>
            <p class="text-sm text-base-content/60">
              Tune high-volume BMP ingestion, routing retention, and God-View routing causal overlay bounds.
            </p>
          </div>

          <div class="rounded-xl border border-base-200 bg-base-100 p-4">
            <.form
              :if={@settings_form}
              for={@settings_form}
              id="bmp-settings-form"
              phx-change="settings_validate"
              phx-submit="settings_save"
            >
              <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
                <.input
                  field={@settings_form[:bmp_routing_retention_days]}
                  type="number"
                  min="1"
                  max="30"
                  label="Routing retention (days)"
                />

                <.input
                  field={@settings_form[:bmp_ocsf_min_severity]}
                  type="number"
                  min="0"
                  max="6"
                  label="OCSF promotion min severity"
                />

                <.input
                  field={@settings_form[:god_view_causal_overlay_window_seconds]}
                  type="number"
                  min="30"
                  max="3600"
                  label="God-View causal window (seconds)"
                />

                <.input
                  field={@settings_form[:god_view_causal_overlay_max_events]}
                  type="number"
                  min="32"
                  max="10000"
                  label="God-View max merged events"
                />

                <.input
                  field={@settings_form[:god_view_routing_causal_severity_threshold]}
                  type="number"
                  min="0"
                  max="6"
                  label="God-View routing severity threshold"
                />
              </div>

              <div class="mt-4 flex justify-end">
                <button class="btn btn-sm btn-primary" type="submit">Save Settings</button>
              </div>
            </.form>
          </div>
        </section>
      </.settings_shell>
    </Layouts.app>
    """
  end

  defp load_settings(scope) do
    case BmpSettings.get_settings(scope: scope) do
      {:ok, %BmpSettings{} = settings} ->
        settings

      _ ->
        nil
    end
  end

  defp settings_to_form(%BmpSettings{} = settings) do
    %{
      "bmp_routing_retention_days" => to_string(settings.bmp_routing_retention_days),
      "bmp_ocsf_min_severity" => to_string(settings.bmp_ocsf_min_severity),
      "god_view_causal_overlay_window_seconds" =>
        to_string(settings.god_view_causal_overlay_window_seconds),
      "god_view_causal_overlay_max_events" =>
        to_string(settings.god_view_causal_overlay_max_events),
      "god_view_routing_causal_severity_threshold" =>
        to_string(settings.god_view_routing_causal_severity_threshold)
    }
  end

  defp settings_to_form(_), do: default_settings_form()

  defp default_settings_form do
    %{
      "bmp_routing_retention_days" => "3",
      "bmp_ocsf_min_severity" => "4",
      "god_view_causal_overlay_window_seconds" => "300",
      "god_view_causal_overlay_max_events" => "512",
      "god_view_routing_causal_severity_threshold" => "4"
    }
  end

  defp merge_settings_form(form, params) when is_map(form) and is_map(params) do
    Map.merge(form, params)
  end

  defp merge_settings_form(_form, params) when is_map(params),
    do: Map.merge(default_settings_form(), params)

  defp build_settings_update_params(params) when is_map(params) do
    %{
      bmp_routing_retention_days: int_param(params["bmp_routing_retention_days"], 3),
      bmp_ocsf_min_severity: int_param(params["bmp_ocsf_min_severity"], 4),
      god_view_causal_overlay_window_seconds:
        int_param(params["god_view_causal_overlay_window_seconds"], 300),
      god_view_causal_overlay_max_events:
        int_param(params["god_view_causal_overlay_max_events"], 512),
      god_view_routing_causal_severity_threshold:
        int_param(params["god_view_routing_causal_severity_threshold"], 4)
    }
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
