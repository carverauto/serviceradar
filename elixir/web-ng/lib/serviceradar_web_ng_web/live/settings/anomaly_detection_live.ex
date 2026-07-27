defmodule ServiceRadarWebNGWeb.Settings.AnomalyDetectionLive do
  @moduledoc """
  Operator-managed anomaly detection and capacity forecast settings.
  """

  use ServiceRadarWebNGWeb, :live_view

  alias Ash.Error.Invalid
  alias ServiceRadar.Observability.AnomalyConfigRuntime
  alias ServiceRadar.Observability.AnomalyDetectionConfig
  alias ServiceRadar.Observability.CapacityForecastConfig
  alias ServiceRadar.Observability.CapacityForecasting.Source
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.Shell

  @path "/settings/anomaly-detection"
  @permission "observability.alerts.manage"
  @edge_metric_classes [
    {"cpu", "CPU"},
    {"memory", "Memory"},
    {"disk", "Disk"},
    {"interface", "Interface"},
    {"icmp", "ICMP"},
    {"other", "Other"}
  ]
  @drift_mode_options [
    {"Off", "off"},
    {"Deseasonalized only", "deseasonalized_only"},
    {"Always", "always"}
  ]
  @severity_cap_options [
    {"No cap", ""},
    {"Low", "low"},
    {"Medium", "medium"},
    {"High", "high"},
    {"Critical", "critical"}
  ]
  # Labels for the known opt-in sources; the key list itself derives from
  # `Source.opt_in_names/0` so a source added in serviceradar_core surfaces
  # here automatically (with a humanized fallback label until named).
  @forecast_source_opt_in_labels %{
    "cpu_usage" => "CPU usage (daily p95)",
    "interface_rate" => "Interface utilization (daily p95)",
    "flow_bytes_per_hour" => "Flow volume"
  }
  @forecast_source_opt_in_keys Source.opt_in_names()
  @forecast_source_opt_ins Enum.map(
                             @forecast_source_opt_in_keys,
                             &{&1, Map.get(@forecast_source_opt_in_labels, &1, Phoenix.Naming.humanize(&1))}
                           )
  @edge_metric_class_keys Enum.map(@edge_metric_classes, &elem(&1, 0))
  @float_class_fields ~w(cusum_k cusum_h h_confirm_mult drift_min_effect min_std_floor min_cv)
  @int_class_fields ~w(drift_confirm_window drift_clear_slots drift_adopt_after_samples drift_escalate_after_secs)
  @default_metric_class_overrides %{
    "cpu" => %{"drift_mode" => "deseasonalized_only"},
    "memory" => %{"drift_mode" => "deseasonalized_only"},
    "interface" => %{"drift_mode" => "deseasonalized_only"},
    "disk" => %{"drift_mode" => "off"},
    "icmp" => %{"drift_mode" => "off"},
    "other" => %{"drift_mode" => "off"}
  }
  @default_metric_denylist ["cpu.frequency_hz"]
  @default_emission %{
    "cooldown_secs" => 300,
    "budget_per_tick" => 100,
    "episode_update_interval_secs" => 1_800,
    "reopen_cooldown_secs" => 600
  }

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, @permission) do
      {anomaly_settings, forecast_settings} = load_settings(scope)
      anomaly_params = anomaly_to_params(anomaly_settings)
      forecast_params = forecast_to_params(forecast_settings)

      {:ok,
       socket
       |> assign(:page_title, "Anomaly Detection")
       |> assign(:current_path, @path)
       |> assign(:edge_metric_classes, @edge_metric_classes)
       |> assign(:forecast_source_opt_ins, @forecast_source_opt_ins)
       |> assign(:drift_mode_options, @drift_mode_options)
       |> assign(:severity_cap_options, @severity_cap_options)
       |> assign(:anomaly_settings, anomaly_settings)
       |> assign(:forecast_settings, forecast_settings)
       |> assign(:anomaly_params, anomaly_params)
       |> assign(:forecast_params, forecast_params)
       |> assign(:anomaly_form, to_anomaly_form(anomaly_params))
       |> assign(:forecast_form, to_forecast_form(forecast_params))}
    else
      {:ok,
       socket
       |> put_flash(:error, "Not authorized to manage anomaly detection settings")
       |> redirect(to: ~p"/settings/profile")}
    end
  end

  @impl true
  def handle_event("anomaly_validate", %{"anomaly" => params}, socket) do
    merged = merge_form(socket.assigns.anomaly_params, params)

    {:noreply,
     socket
     |> assign(:anomaly_params, merged)
     |> assign(:anomaly_form, to_anomaly_form(merged))}
  end

  def handle_event("forecast_validate", %{"forecast" => params}, socket) do
    merged = merge_form(socket.assigns.forecast_params, params)

    {:noreply,
     socket
     |> assign(:forecast_params, merged)
     |> assign(:forecast_form, to_forecast_form(merged))}
  end

  def handle_event("anomaly_save", %{"anomaly" => params}, socket) do
    scope = socket.assigns.current_scope

    with :ok <- authorize(socket),
         {:ok, attrs} <- build_anomaly_attrs(params, socket.assigns.anomaly_settings),
         {:ok, %AnomalyDetectionConfig{} = updated} <-
           upsert_anomaly_config(socket.assigns.anomaly_settings, attrs, scope) do
      refresh_runtime_cache()
      updated_params = anomaly_to_params(updated)

      {:noreply,
       socket
       |> put_flash(:info, "Saved anomaly detection settings")
       |> assign(:anomaly_settings, updated)
       |> assign(:anomaly_params, updated_params)
       |> assign(:anomaly_form, to_anomaly_form(updated_params))}
    else
      {:error, :not_authorized} ->
        {:noreply, unauthorized(socket)}

      {:error, :invalid_json} ->
        {:noreply, put_flash(socket, :error, "Metric class overrides must be a JSON object")}

      {:error, :invalid_severity_bands} ->
        {:noreply, put_flash(socket, :error, "Severity band overrides must be JSON objects")}

      {:error, {:anomaly_form, submitted_params, errors}} ->
        {:noreply,
         socket
         |> assign(:anomaly_params, submitted_params)
         |> assign(:anomaly_form, to_anomaly_form(submitted_params, errors))
         |> put_flash(:error, "Fix anomaly settings errors before saving")}

      {:error, %Invalid{} = err} ->
        submitted_params = merge_form(socket.assigns.anomaly_params, params)

        {:noreply,
         socket
         |> assign(:anomaly_params, submitted_params)
         |> assign(:anomaly_form, to_anomaly_form(submitted_params, ash_form_errors(err)))
         |> put_flash(:error, "Fix anomaly settings errors before saving")}

      {:error, err} ->
        {:noreply, put_flash(socket, :error, "Failed to save anomaly settings: #{inspect(err)}")}
    end
  end

  def handle_event("forecast_save", %{"forecast" => params}, socket) do
    scope = socket.assigns.current_scope

    with :ok <- authorize(socket),
         {:ok, attrs} <- build_forecast_attrs(params),
         {:ok, %CapacityForecastConfig{} = updated} <-
           upsert_forecast_config(socket.assigns.forecast_settings, attrs, scope) do
      refresh_runtime_cache()
      updated_params = forecast_to_params(updated)

      {:noreply,
       socket
       |> put_flash(:info, "Saved capacity forecast settings")
       |> assign(:forecast_settings, updated)
       |> assign(:forecast_params, updated_params)
       |> assign(:forecast_form, to_forecast_form(updated_params))}
    else
      {:error, :not_authorized} ->
        {:noreply, unauthorized(socket)}

      {:error, :invalid_json} ->
        {:noreply, put_flash(socket, :error, "Metric class overrides must be a JSON object")}

      {:error, {:forecast_form, submitted_params, errors}} ->
        {:noreply,
         socket
         |> assign(:forecast_params, submitted_params)
         |> assign(:forecast_form, to_forecast_form(submitted_params, errors))
         |> put_flash(:error, "Fix capacity forecast settings errors before saving")}

      {:error, %Invalid{} = err} ->
        submitted_params = merge_form(socket.assigns.forecast_params, params)

        {:noreply,
         socket
         |> assign(:forecast_params, submitted_params)
         |> assign(:forecast_form, to_forecast_form(submitted_params, ash_form_errors(err)))
         |> put_flash(:error, "Fix capacity forecast settings errors before saving")}

      {:error, err} ->
        {:noreply, put_flash(socket, :error, "Failed to save forecast settings: #{inspect(err)}")}
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
        <section class="space-y-5">
          <div>
            <h1 class="text-xl font-semibold">Anomaly Detection</h1>
          </div>

          <div class="grid gap-5 xl:grid-cols-2">
            <div class="rounded-xl border border-sr-line bg-sr-surface p-4">
              <div class="mb-4">
                <h2 class="text-base font-semibold">Streaming Detector</h2>
                <p class="mt-1 text-sm text-sr-muted">
                  These defaults are projected into anomaly add-on profiles under managed
                  params. Explicit profile or assignment params still take precedence.
                </p>
              </div>

              <.form
                :if={@anomaly_form}
                for={@anomaly_form}
                id="anomaly-settings-form"
                phx-change="anomaly_validate"
                phx-submit="anomaly_save"
              >
                <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
                  <.input
                    field={@anomaly_form[:n_sigma]}
                    type="number"
                    step="0.1"
                    min="0.1"
                    max="20"
                    label="N-sigma threshold"
                  />
                  <.input
                    field={@anomaly_form[:window_size]}
                    type="number"
                    min="2"
                    max="86400"
                    label="Window size"
                  />
                  <.input
                    field={@anomaly_form[:window_duration_seconds]}
                    type="number"
                    min="1"
                    max="86400"
                    label="Core target duration (seconds)"
                  />
                  <.input
                    field={@anomaly_form[:confirm_slots]}
                    type="number"
                    min="1"
                    max="10000"
                    label="Confirm slots"
                  />
                  <.input
                    field={@anomaly_form[:min_samples]}
                    type="number"
                    min="1"
                    max="86400"
                    label="Minimum samples"
                  />
                </div>

                <div class="mt-5 border-t border-sr-line pt-4">
                  <h3 class="text-sm font-semibold">Emission Governance</h3>
                  <div class="mt-3 grid grid-cols-1 gap-4 sm:grid-cols-2">
                    <.input
                      field={@anomaly_form[:emission_cooldown_secs]}
                      type="number"
                      min="1"
                      max="86400"
                      label="Per-series cooldown (seconds)"
                    />
                    <.input
                      field={@anomaly_form[:emission_budget_per_tick]}
                      type="number"
                      min="1"
                      max="100000"
                      label="Budget per tick"
                    />
                    <.input
                      field={@anomaly_form[:episode_update_interval_secs]}
                      type="number"
                      min="1"
                      max="86400"
                      label="Episode heartbeat (seconds)"
                    />
                    <.input
                      field={@anomaly_form[:reopen_cooldown_secs]}
                      type="number"
                      min="1"
                      max="86400"
                      label="Reopen cooldown (seconds)"
                    />
                  </div>
                </div>

                <div class="mt-5">
                  <.input
                    field={@anomaly_form[:metric_denylist]}
                    type="textarea"
                    rows="3"
                    label="Metric denylist"
                    class={ui_field_class(mono: true, class: "min-h-24 w-full py-2.5 text-xs")}
                    placeholder="cpu.frequency_hz"
                  />
                </div>

                <div class="mt-5 border-t border-sr-line pt-4">
                  <h3 class="text-sm font-semibold">Metric Classes</h3>
                  <div class="mt-3 divide-y divide-sr-line">
                    <div
                      :for={{class_key, class_label} <- @edge_metric_classes}
                      class="py-4 first:pt-0 last:pb-0"
                    >
                      <% class_values = class_params(@anomaly_params, class_key) %>
                      <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
                        <div>
                          <div class="text-sm font-semibold">{class_label}</div>
                          <div class="text-xs text-sr-muted">{class_key}</div>
                        </div>
                        <label class="flex cursor-pointer items-center justify-start gap-3 sm:justify-end">
                          <span class="text-xs font-medium text-sr-ink">Enabled</span>
                          <input
                            type="hidden"
                            name={"anomaly[classes][#{class_key}][enabled]"}
                            value="false"
                          />
                          <input
                            type="checkbox"
                            name={"anomaly[classes][#{class_key}][enabled]"}
                            value="true"
                            checked={class_enabled?(class_values)}
                            class={ui_toggle_class(size: "sm")}
                          />
                        </label>
                      </div>

                      <div class="mt-3 grid grid-cols-1 gap-3 md:grid-cols-3">
                        <label class="fieldset mb-0">
                          <span class="flex items-center justify-between gap-2 mb-1">Drift mode</span>
                          <select
                            name={"anomaly[classes][#{class_key}][drift_mode]"}
                            class={ui_field_class(size: "sm", class: "w-full")}
                          >
                            {Phoenix.HTML.Form.options_for_select(
                              @drift_mode_options,
                              class_field(class_values, "drift_mode")
                            )}
                          </select>
                        </label>
                        <label class="fieldset mb-0">
                          <span class="flex items-center justify-between gap-2 mb-1">
                            Severity cap
                          </span>
                          <select
                            name={"anomaly[classes][#{class_key}][severity_cap]"}
                            class={ui_field_class(size: "sm", class: "w-full")}
                          >
                            {Phoenix.HTML.Form.options_for_select(
                              @severity_cap_options,
                              class_field(class_values, "severity_cap")
                            )}
                          </select>
                        </label>
                        <label class="fieldset mb-0">
                          <span class="flex items-center justify-between gap-2 mb-1">
                            Drift min effect
                          </span>
                          <input
                            type="number"
                            step="0.1"
                            min="0"
                            name={"anomaly[classes][#{class_key}][drift_min_effect]"}
                            value={class_field(class_values, "drift_min_effect")}
                            class={ui_field_class(size: "sm", class: "w-full")}
                          />
                        </label>
                        <label class="fieldset mb-0">
                          <span class="flex items-center justify-between gap-2 mb-1">CUSUM k</span>
                          <input
                            type="number"
                            step="0.1"
                            min="0"
                            name={"anomaly[classes][#{class_key}][cusum_k]"}
                            value={class_field(class_values, "cusum_k")}
                            class={ui_field_class(size: "sm", class: "w-full")}
                          />
                        </label>
                        <label class="fieldset mb-0">
                          <span class="flex items-center justify-between gap-2 mb-1">CUSUM h</span>
                          <input
                            type="number"
                            step="0.1"
                            min="0"
                            name={"anomaly[classes][#{class_key}][cusum_h]"}
                            value={class_field(class_values, "cusum_h")}
                            class={ui_field_class(size: "sm", class: "w-full")}
                          />
                        </label>
                        <label class="fieldset mb-0">
                          <span class="flex items-center justify-between gap-2 mb-1">
                            Confirm multiplier
                          </span>
                          <input
                            type="number"
                            step="0.1"
                            min="1"
                            name={"anomaly[classes][#{class_key}][h_confirm_mult]"}
                            value={class_field(class_values, "h_confirm_mult")}
                            class={ui_field_class(size: "sm", class: "w-full")}
                          />
                        </label>
                        <label class="fieldset mb-0">
                          <span class="flex items-center justify-between gap-2 mb-1">
                            Confirm window
                          </span>
                          <input
                            type="number"
                            min="1"
                            name={"anomaly[classes][#{class_key}][drift_confirm_window]"}
                            value={class_field(class_values, "drift_confirm_window")}
                            class={ui_field_class(size: "sm", class: "w-full")}
                          />
                        </label>
                        <label class="fieldset mb-0">
                          <span class="flex items-center justify-between gap-2 mb-1">
                            Clear slots
                          </span>
                          <input
                            type="number"
                            min="1"
                            name={"anomaly[classes][#{class_key}][drift_clear_slots]"}
                            value={class_field(class_values, "drift_clear_slots")}
                            class={ui_field_class(size: "sm", class: "w-full")}
                          />
                        </label>
                        <label class="fieldset mb-0">
                          <span class="flex items-center justify-between gap-2 mb-1">
                            Adopt after samples
                          </span>
                          <input
                            type="number"
                            min="1"
                            name={"anomaly[classes][#{class_key}][drift_adopt_after_samples]"}
                            value={class_field(class_values, "drift_adopt_after_samples")}
                            class={ui_field_class(size: "sm", class: "w-full")}
                          />
                        </label>
                        <label class="fieldset mb-0">
                          <span class="flex items-center justify-between gap-2 mb-1">
                            Escalate after seconds
                          </span>
                          <input
                            type="number"
                            min="1"
                            name={"anomaly[classes][#{class_key}][drift_escalate_after_secs]"}
                            value={class_field(class_values, "drift_escalate_after_secs")}
                            class={ui_field_class(size: "sm", class: "w-full")}
                          />
                        </label>
                        <label class="fieldset mb-0">
                          <span class="flex items-center justify-between gap-2 mb-1">
                            Minimum std floor
                          </span>
                          <input
                            type="number"
                            step="0.01"
                            min="0"
                            name={"anomaly[classes][#{class_key}][min_std_floor]"}
                            value={class_field(class_values, "min_std_floor")}
                            class={ui_field_class(size: "sm", class: "w-full")}
                          />
                        </label>
                        <label class="fieldset mb-0">
                          <span class="flex items-center justify-between gap-2 mb-1">Minimum CV</span>
                          <input
                            type="number"
                            step="0.001"
                            min="0"
                            name={"anomaly[classes][#{class_key}][min_cv]"}
                            value={class_field(class_values, "min_cv")}
                            class={ui_field_class(size: "sm", class: "w-full")}
                          />
                        </label>
                        <label class="fieldset mb-0 md:col-span-2">
                          <span class="flex items-center justify-between gap-2 mb-1">
                            Severity bands (JSON)
                          </span>
                          <textarea
                            name={"anomaly[classes][#{class_key}][severity_bands]"}
                            class={
                              ui_field_class(
                                size: "sm",
                                mono: true,
                                class: "min-h-20 w-full py-2 text-xs"
                              )
                            }
                          >{class_field(class_values, "severity_bands")}</textarea>
                        </label>
                      </div>
                    </div>
                  </div>
                </div>

                <div class="mt-4 flex justify-end">
                  <.ui_button type="submit" size="sm" variant="primary">
                    <.icon name="hero-check" class="size-4" /> Save Detector
                  </.ui_button>
                </div>
              </.form>
            </div>

            <div class="rounded-xl border border-sr-line bg-sr-surface p-4">
              <div class="mb-4">
                <h2 class="text-base font-semibold">Capacity Forecast</h2>
              </div>

              <.form
                :if={@forecast_form}
                for={@forecast_form}
                id="capacity-forecast-settings-form"
                phx-change="forecast_validate"
                phx-submit="forecast_save"
              >
                <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
                  <.input
                    field={@forecast_form[:forecast_horizon_seconds]}
                    type="number"
                    min="3600"
                    max="63115200"
                    label="Forecast horizon (seconds)"
                  />
                  <.input
                    field={@forecast_form[:warning_horizon_seconds]}
                    type="number"
                    min="3600"
                    max="63115200"
                    label="Warning horizon (seconds)"
                  />
                  <.input
                    field={@forecast_form[:warning_threshold_percent]}
                    type="number"
                    step="0.1"
                    min="1"
                    max="100"
                    label="Warning threshold (%)"
                  />
                  <.input
                    field={@forecast_form[:model]}
                    type="select"
                    label="Model"
                    options={[
                      {"linear", "linear"},
                      {"seasonal_linear", "seasonal_linear"},
                      {"holt_winters", "holt_winters"}
                    ]}
                  />
                  <.input
                    field={@forecast_form[:minimum_history_points]}
                    type="number"
                    min="2"
                    max="35040"
                    label="Minimum history points"
                  />
                </div>

                <fieldset class="mt-4 rounded-lg border border-sr-line p-3">
                  <legend class="px-1 text-sm font-medium">Additional forecast sources</legend>
                  <p class="mb-2 text-xs text-sr-muted">
                    These daily-aggregate targets are statistically weaker than the default
                    memory and disk exhaustion sources and are off by design.
                  </p>
                  <input type="hidden" name="forecast[default_source_opt_ins][]" value="" />
                  <div class="grid gap-2 sm:grid-cols-2">
                    <label
                      :for={{source_key, source_label} <- @forecast_source_opt_ins}
                      class="flex items-center gap-2 rounded-md border border-sr-line bg-sr-surface px-3 py-2 text-sm"
                    >
                      <input
                        type="checkbox"
                        name="forecast[default_source_opt_ins][]"
                        value={source_key}
                        checked={source_key in selected_source_opt_ins(@forecast_params)}
                        class={ui_checkbox_class()}
                      />
                      <span>{source_label}</span>
                    </label>
                  </div>
                </fieldset>

                <div class="mt-4">
                  <label class="flex items-center justify-between gap-2">
                    <span class="text-sm font-medium text-sr-ink">Metric class overrides (JSON)</span>
                  </label>
                  <textarea
                    name="forecast[metric_class_overrides]"
                    class={ui_field_class(mono: true, class: "min-h-44 w-full py-2.5 text-xs")}
                  ><%= @forecast_form[:metric_class_overrides].value %></textarea>
                </div>

                <div class="mt-4 flex justify-end">
                  <.ui_button type="submit" size="sm" variant="primary">
                    <.icon name="hero-check" class="size-4" /> Save Forecast
                  </.ui_button>
                </div>
              </.form>
            </div>
          </div>
        </section>
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end

  defp load_settings(scope) do
    {load_anomaly_settings(scope), load_forecast_settings(scope)}
  end

  defp load_anomaly_settings(scope) do
    case AnomalyDetectionConfig.get_settings(scope: scope) do
      {:ok, %AnomalyDetectionConfig{} = settings} -> settings
      _ -> nil
    end
  end

  defp load_forecast_settings(scope) do
    case CapacityForecastConfig.get_settings(scope: scope) do
      {:ok, %CapacityForecastConfig{} = settings} -> settings
      _ -> nil
    end
  end

  defp upsert_anomaly_config(%AnomalyDetectionConfig{} = settings, attrs, scope) do
    AnomalyDetectionConfig.update_settings(settings, attrs, scope: scope)
  end

  defp upsert_anomaly_config(_settings, attrs, scope) do
    AnomalyDetectionConfig.create_settings(attrs, scope: scope)
  end

  defp upsert_forecast_config(%CapacityForecastConfig{} = settings, attrs, scope) do
    CapacityForecastConfig.update_settings(settings, attrs, scope: scope)
  end

  defp upsert_forecast_config(_settings, attrs, scope) do
    CapacityForecastConfig.create_settings(attrs, scope: scope)
  end

  defp anomaly_to_params(%AnomalyDetectionConfig{} = settings) do
    emission = normalize_emission(settings.emission || @default_emission)

    %{
      "n_sigma" => to_string(settings.n_sigma),
      "window_size" => to_string(settings.window_size),
      "window_duration_seconds" => to_string(settings.window_duration_seconds),
      "confirm_slots" => to_string(settings.confirm_slots),
      "min_samples" => to_string(settings.min_samples),
      "metric_denylist" => denylist_to_text(settings.metric_denylist || @default_metric_denylist),
      "emission_cooldown_secs" => to_string(Map.get(emission, "cooldown_secs", 300)),
      "emission_budget_per_tick" => to_string(Map.get(emission, "budget_per_tick", 100)),
      "episode_update_interval_secs" => to_string(Map.get(emission, "episode_update_interval_secs", 1_800)),
      "reopen_cooldown_secs" => to_string(Map.get(emission, "reopen_cooldown_secs", 600)),
      "classes" => class_overrides_to_form(settings.metric_class_overrides || %{})
    }
  end

  defp anomaly_to_params(_settings) do
    %{
      "n_sigma" => "3.0",
      "window_size" => "300",
      "window_duration_seconds" => "900",
      "confirm_slots" => "5",
      "min_samples" => "30",
      "metric_denylist" => denylist_to_text(@default_metric_denylist),
      "emission_cooldown_secs" => "300",
      "emission_budget_per_tick" => "100",
      "episode_update_interval_secs" => "1800",
      "reopen_cooldown_secs" => "600",
      "classes" => class_overrides_to_form(@default_metric_class_overrides)
    }
  end

  defp forecast_to_params(%CapacityForecastConfig{} = settings) do
    %{
      "forecast_horizon_seconds" => to_string(settings.forecast_horizon_seconds),
      "warning_horizon_seconds" => to_string(settings.warning_horizon_seconds),
      "warning_threshold_percent" => to_string(settings.warning_threshold_percent),
      "model" => Atom.to_string(settings.model),
      "minimum_history_points" => to_string(settings.minimum_history_points),
      "default_source_opt_ins" => Enum.map(settings.default_source_opt_ins || [], &to_string/1),
      "metric_class_overrides" => pretty_json(settings.metric_class_overrides)
    }
  end

  defp forecast_to_params(_settings) do
    %{
      "forecast_horizon_seconds" => "7776000",
      "warning_horizon_seconds" => "2592000",
      "warning_threshold_percent" => "80.0",
      "model" => "linear",
      "minimum_history_points" => "72",
      "default_source_opt_ins" => [],
      "metric_class_overrides" => pretty_json(%{"interface" => %{}, "cpu" => %{}, "memory" => %{}, "disk" => %{}})
    }
  end

  defp to_anomaly_form(params, errors \\ []), do: to_form(params, as: :anomaly, errors: errors)
  defp to_forecast_form(params, errors \\ []), do: to_form(params, as: :forecast, errors: errors)
  defp merge_form(form, params) when is_map(form) and is_map(params), do: Map.merge(form, params)
  defp merge_form(_form, params) when is_map(params), do: params

  defp class_params(params, class_key) when is_map(params) do
    params
    |> Map.get("classes", %{})
    |> Map.get(class_key, %{})
    |> stringify_keys()
  end

  defp class_params(_params, _class_key), do: %{}

  defp class_enabled?(values) when is_map(values) do
    case Map.get(values, "enabled", true) do
      false -> false
      "false" -> false
      "0" -> false
      _ -> true
    end
  end

  defp class_field(values, field) when is_map(values) do
    case Map.get(values, field, "") do
      nil -> ""
      value when is_binary(value) -> value
      value when is_number(value) -> to_string(value)
      value when is_boolean(value) -> to_string(value)
      %{} = value -> pretty_json(value)
      value -> to_string(value)
    end
  end

  defp class_field(_values, _field), do: ""

  defp authorize(socket) do
    if RBAC.can?(socket.assigns.current_scope, @permission),
      do: :ok,
      else: {:error, :not_authorized}
  end

  defp unauthorized(socket) do
    socket
    |> put_flash(:error, "Not authorized to manage anomaly detection settings")
    |> redirect(to: ~p"/settings/profile")
  end

  defp build_anomaly_attrs(params, settings) when is_map(params) do
    existing_overrides = existing_metric_class_overrides(settings)

    with {:ok, overrides} <- class_overrides_from_params(params["classes"] || %{}, existing_overrides),
         {:ok, metric_denylist} <- metric_denylist_param(params["metric_denylist"]),
         {:ok, emission} <- emission_param(params),
         {:ok, n_sigma} <- float_param(params["n_sigma"], :n_sigma),
         {:ok, window_size} <- int_param(params["window_size"], :window_size),
         {:ok, window_duration_seconds} <-
           int_param(params["window_duration_seconds"], :window_duration_seconds),
         {:ok, confirm_slots} <- int_param(params["confirm_slots"], :confirm_slots),
         {:ok, min_samples} <- int_param(params["min_samples"], :min_samples) do
      {:ok,
       %{
         n_sigma: n_sigma,
         window_size: window_size,
         window_duration_seconds: window_duration_seconds,
         confirm_slots: confirm_slots,
         min_samples: min_samples,
         metric_class_overrides: overrides,
         metric_denylist: metric_denylist,
         emission: emission
       }}
    else
      {:error, {field, message}} ->
        {:error, {:anomaly_form, params, [{field, {message, []}}]}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_forecast_attrs(params) when is_map(params) do
    with {:ok, overrides} <- decode_json_object(params["metric_class_overrides"]),
         {:ok, model} <- model_param(params["model"]),
         {:ok, forecast_horizon_seconds} <-
           int_param(params["forecast_horizon_seconds"], :forecast_horizon_seconds),
         {:ok, warning_horizon_seconds} <-
           int_param(params["warning_horizon_seconds"], :warning_horizon_seconds),
         {:ok, warning_threshold_percent} <-
           float_param(params["warning_threshold_percent"], :warning_threshold_percent),
         {:ok, minimum_history_points} <-
           int_param(params["minimum_history_points"], :minimum_history_points),
         {:ok, default_source_opt_ins} <- source_opt_ins_param(params["default_source_opt_ins"]) do
      {:ok,
       %{
         forecast_horizon_seconds: forecast_horizon_seconds,
         warning_horizon_seconds: warning_horizon_seconds,
         warning_threshold_percent: warning_threshold_percent,
         model: model,
         minimum_history_points: minimum_history_points,
         default_source_opt_ins: default_source_opt_ins,
         metric_class_overrides: overrides
       }}
    else
      {:error, {field, message}} ->
        {:error, {:forecast_form, params, [{field, {message, []}}]}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp class_overrides_from_params(class_params, existing_overrides) when is_map(class_params) do
    existing =
      existing_overrides
      |> stringify_keys()
      |> Map.drop(@edge_metric_class_keys)

    Enum.reduce_while(@edge_metric_classes, {:ok, existing}, fn {class_key, _label}, {:ok, acc} ->
      values = class_params |> Map.get(class_key, %{}) |> stringify_keys()

      case parse_class_override(values) do
        {:ok, parsed} ->
          acc =
            if map_size(parsed) > 0 do
              Map.put(acc, class_key, parsed)
            else
              Map.delete(acc, class_key)
            end

          {:cont, {:ok, acc}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp class_overrides_from_params(_class_params, existing_overrides), do: {:ok, stringify_keys(existing_overrides)}

  defp parse_class_override(values) do
    enabled? = class_enabled?(values)

    with {:ok, drift_mode} <- drift_mode_param(Map.get(values, "drift_mode")),
         {:ok, severity_cap} <- severity_cap_param(Map.get(values, "severity_cap")),
         {:ok, severity_bands} <- severity_bands_param(Map.get(values, "severity_bands")),
         {:ok, parsed_floats} <- parse_class_float_fields(values),
         {:ok, parsed_ints} <- parse_class_int_fields(values) do
      parsed =
        %{}
        |> maybe_put("enabled", if(enabled?, do: nil, else: false))
        |> maybe_put("drift_mode", drift_mode)
        |> maybe_put("severity_cap", severity_cap)
        |> maybe_put("severity_bands", severity_bands)
        |> Map.merge(parsed_floats)
        |> Map.merge(parsed_ints)

      {:ok, parsed}
    end
  end

  defp parse_class_float_fields(values) do
    Enum.reduce_while(@float_class_fields, {:ok, %{}}, fn field, {:ok, acc} ->
      case optional_float_param(Map.get(values, field), :metric_class_overrides) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, Map.put(acc, field, value)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_class_int_fields(values) do
    Enum.reduce_while(@int_class_fields, {:ok, %{}}, fn field, {:ok, acc} ->
      case optional_positive_int_param(Map.get(values, field), :metric_class_overrides) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, Map.put(acc, field, value)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp drift_mode_param(value) when value in ["off", "deseasonalized_only", "always"], do: {:ok, value}

  defp drift_mode_param(value) when value in [nil, ""], do: {:ok, nil}
  defp drift_mode_param(_value), do: {:error, {:metric_class_overrides, "has an invalid drift mode"}}

  defp severity_cap_param(value) when value in ["low", "medium", "high", "critical"], do: {:ok, value}

  defp severity_cap_param(value) when value in [nil, ""], do: {:ok, nil}

  defp severity_cap_param(_value), do: {:error, {:metric_class_overrides, "has an invalid severity cap"}}

  defp severity_bands_param(value) when value in [nil, ""], do: {:ok, nil}

  defp severity_bands_param(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      _ -> {:error, :invalid_severity_bands}
    end
  end

  defp severity_bands_param(%{} = value), do: {:ok, value}
  defp severity_bands_param(_value), do: {:error, :invalid_severity_bands}

  defp metric_denylist_param(value) when is_binary(value) do
    denylist =
      value
      |> String.split(~r/[\n,]/)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    {:ok, denylist}
  end

  defp metric_denylist_param(values) when is_list(values) do
    denylist =
      values
      |> Enum.flat_map(fn
        value when is_binary(value) ->
          trimmed = String.trim(value)
          if trimmed == "", do: [], else: [trimmed]

        _ ->
          []
      end)
      |> Enum.uniq()

    {:ok, denylist}
  end

  defp metric_denylist_param(_value), do: {:ok, []}

  defp emission_param(params) do
    with {:ok, cooldown_secs} <-
           optional_positive_int_param(params["emission_cooldown_secs"], :emission_cooldown_secs),
         {:ok, budget_per_tick} <-
           optional_positive_int_param(params["emission_budget_per_tick"], :emission_budget_per_tick),
         {:ok, episode_update_interval_secs} <-
           optional_positive_int_param(
             params["episode_update_interval_secs"],
             :episode_update_interval_secs
           ),
         {:ok, reopen_cooldown_secs} <-
           optional_positive_int_param(params["reopen_cooldown_secs"], :reopen_cooldown_secs) do
      {:ok,
       %{
         "cooldown_secs" => cooldown_secs || 300,
         "budget_per_tick" => budget_per_tick || 100,
         "episode_update_interval_secs" => episode_update_interval_secs || 1_800,
         "reopen_cooldown_secs" => reopen_cooldown_secs || 600
       }}
    end
  end

  defp decode_json_object(nil), do: {:ok, %{}}
  defp decode_json_object(""), do: {:ok, %{}}

  defp decode_json_object(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      _ -> {:error, :invalid_json}
    end
  end

  defp selected_source_opt_ins(params) when is_map(params) do
    params
    |> Map.get("default_source_opt_ins", [])
    |> List.wrap()
    |> Enum.filter(&(&1 in @forecast_source_opt_in_keys))
  end

  defp selected_source_opt_ins(_params), do: []

  # The hidden [] input submits "" when nothing is checked; drop it along with
  # anything outside the allowed opt-in source names.
  defp source_opt_ins_param(values) when is_list(values) do
    opt_ins =
      values
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&(&1 in @forecast_source_opt_in_keys))
      |> Enum.uniq()

    {:ok, opt_ins}
  end

  defp source_opt_ins_param(_values), do: {:ok, []}

  defp model_param("linear"), do: {:ok, :linear}
  defp model_param("seasonal_linear"), do: {:ok, :seasonal_linear}
  defp model_param("holt_winters"), do: {:ok, :holt_winters}
  defp model_param(_), do: {:error, {:model, "is not supported"}}

  defp int_param(value, field) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> {:ok, int}
      _ -> {:error, {field, "must be an integer"}}
    end
  end

  defp int_param(value, _field) when is_integer(value), do: {:ok, value}
  defp int_param(_value, field), do: {:error, {field, "must be an integer"}}

  defp float_param(value, field) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {float, ""} -> {:ok, float}
      _ -> {:error, {field, "must be a number"}}
    end
  end

  defp float_param(value, _field) when is_number(value), do: {:ok, value * 1.0}
  defp float_param(_value, field), do: {:error, {field, "must be a number"}}

  defp optional_positive_int_param(value, _field) when value in [nil, ""], do: {:ok, nil}

  defp optional_positive_int_param(value, field) do
    with {:ok, int} <- int_param(value, field),
         true <- int > 0 do
      {:ok, int}
    else
      false -> {:error, {field, "must be a positive integer"}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp optional_float_param(value, _field) when value in [nil, ""], do: {:ok, nil}

  defp optional_float_param(value, field) do
    case float_param(value, field) do
      {:ok, float} when is_float(float) and float >= 0.0 -> {:ok, float}
      {:ok, _float} -> {:error, {field, "must be zero or greater"}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp class_overrides_to_form(overrides) do
    overrides = stringify_keys(overrides || %{})

    Map.new(@edge_metric_classes, fn {class_key, _label} ->
      default_values = Map.get(@default_metric_class_overrides, class_key, %{})

      class_values =
        default_values
        |> Map.merge(Map.get(overrides, class_key, %{}))
        |> stringify_keys()
        |> Map.put_new("enabled", true)

      {class_key, class_values}
    end)
  end

  defp existing_metric_class_overrides(%AnomalyDetectionConfig{} = settings), do: settings.metric_class_overrides || %{}

  defp existing_metric_class_overrides(_settings), do: %{}

  defp normalize_emission(emission) when is_map(emission), do: stringify_keys(emission)
  defp normalize_emission(_emission), do: @default_emission

  defp denylist_to_text(values) when is_list(values), do: Enum.join(values, "\n")
  defp denylist_to_text(_values), do: ""

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp stringify_keys(values) when is_map(values) do
    Map.new(values, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(values) when is_list(values), do: Enum.map(values, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp ash_form_errors(%Invalid{errors: errors}) do
    Enum.flat_map(errors, fn error ->
      field = Map.get(error, :field) || Map.get(error, :attribute) || first_path_field(error)
      message = Map.get(error, :message)

      if is_atom(field) and is_binary(message) do
        [{field, {message, []}}]
      else
        []
      end
    end)
  end

  defp ash_form_errors(_err), do: []

  defp first_path_field(%{path: [field | _]}) when is_atom(field), do: field
  defp first_path_field(_error), do: nil

  defp pretty_json(value) do
    Jason.encode!(value || %{}, pretty: true)
  end

  defp refresh_runtime_cache do
    case Process.whereis(AnomalyConfigRuntime) do
      nil -> :ok
      pid -> AnomalyConfigRuntime.refresh(pid)
    end
  rescue
    _ -> :ok
  end
end
