defmodule ServiceRadarWebNGWeb.Settings.AnomalyDetectionLive do
  @moduledoc """
  Operator-managed anomaly detection and capacity forecast settings.
  """

  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.SettingsComponents

  alias Ash.Error.Invalid
  alias ServiceRadar.Observability.AnomalyConfigRuntime
  alias ServiceRadar.Observability.AnomalyDetectionConfig
  alias ServiceRadar.Observability.CapacityForecastConfig
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.Shell

  @path "/settings/anomaly-detection"
  @permission "observability.alerts.manage"

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
         {:ok, attrs} <- build_anomaly_attrs(params),
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
        settings_ui={@settings_ui}
        current_path={@current_path}
        current_scope={@current_scope}
        active_view={@settings_active_view}
        active_category={@settings_active_category}
        breadcrumbs={@settings_breadcrumbs}
        nav_tree={@settings_nav_tree}
        palette={@settings_palette}
      >
        <:legacy>
          <div class="space-y-4">
            <.settings_nav current_path={@current_path} current_scope={@current_scope} />
            <.events_nav current_path={@current_path} current_scope={@current_scope} />
          </div>
        </:legacy>

        <section class="space-y-5">
          <div>
            <h1 class="text-xl font-semibold">Anomaly Detection</h1>
          </div>

          <div class="grid gap-5 xl:grid-cols-2">
            <div class="rounded-xl border border-base-200 bg-base-100 p-4">
              <div class="mb-4">
                <h2 class="text-base font-semibold">Streaming Detector</h2>
                <p class="mt-1 text-sm text-base-content/70">
                  These deployment defaults feed central seasonal evaluation and shared
                  runtime context. Edge spike scalar knobs are managed on anomaly add-on
                  assignments or profiles; the default profile seeds only metric feed
                  sources.
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

                <div class="mt-4">
                  <label class="label">
                    <span class="label-text">Metric class overrides (JSON)</span>
                  </label>
                  <textarea
                    name="anomaly[metric_class_overrides]"
                    class="textarea textarea-bordered min-h-44 w-full font-mono text-xs"
                  ><%= @anomaly_form[:metric_class_overrides].value %></textarea>
                </div>

                <div class="mt-4 flex justify-end">
                  <button class="btn btn-sm btn-primary" type="submit">
                    <.icon name="hero-check" class="size-4" /> Save Detector
                  </button>
                </div>
              </.form>
            </div>

            <div class="rounded-xl border border-base-200 bg-base-100 p-4">
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

                <div class="mt-4">
                  <label class="label">
                    <span class="label-text">Metric class overrides (JSON)</span>
                  </label>
                  <textarea
                    name="forecast[metric_class_overrides]"
                    class="textarea textarea-bordered min-h-44 w-full font-mono text-xs"
                  ><%= @forecast_form[:metric_class_overrides].value %></textarea>
                </div>

                <div class="mt-4 flex justify-end">
                  <button class="btn btn-sm btn-primary" type="submit">
                    <.icon name="hero-check" class="size-4" /> Save Forecast
                  </button>
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
    %{
      "n_sigma" => to_string(settings.n_sigma),
      "window_size" => to_string(settings.window_size),
      "window_duration_seconds" => to_string(settings.window_duration_seconds),
      "confirm_slots" => to_string(settings.confirm_slots),
      "min_samples" => to_string(settings.min_samples),
      "metric_class_overrides" => pretty_json(settings.metric_class_overrides)
    }
  end

  defp anomaly_to_params(_settings) do
    %{
      "n_sigma" => "3.0",
      "window_size" => "300",
      "window_duration_seconds" => "900",
      "confirm_slots" => "5",
      "min_samples" => "30",
      "metric_class_overrides" =>
        pretty_json(%{
          "interface" => %{},
          "red" => %{},
          "cpu" => %{},
          "memory" => %{},
          "disk" => %{}
        })
    }
  end

  defp forecast_to_params(%CapacityForecastConfig{} = settings) do
    %{
      "forecast_horizon_seconds" => to_string(settings.forecast_horizon_seconds),
      "warning_horizon_seconds" => to_string(settings.warning_horizon_seconds),
      "warning_threshold_percent" => to_string(settings.warning_threshold_percent),
      "model" => Atom.to_string(settings.model),
      "minimum_history_points" => to_string(settings.minimum_history_points),
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
      "metric_class_overrides" => pretty_json(%{"interface" => %{}, "cpu" => %{}, "memory" => %{}, "disk" => %{}})
    }
  end

  defp to_anomaly_form(params, errors \\ []), do: to_form(params, as: :anomaly, errors: errors)
  defp to_forecast_form(params, errors \\ []), do: to_form(params, as: :forecast, errors: errors)
  defp merge_form(form, params) when is_map(form) and is_map(params), do: Map.merge(form, params)
  defp merge_form(_form, params) when is_map(params), do: params

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

  defp build_anomaly_attrs(params) when is_map(params) do
    with {:ok, overrides} <- decode_json_object(params["metric_class_overrides"]),
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
         metric_class_overrides: overrides
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
           int_param(params["minimum_history_points"], :minimum_history_points) do
      {:ok,
       %{
         forecast_horizon_seconds: forecast_horizon_seconds,
         warning_horizon_seconds: warning_horizon_seconds,
         warning_threshold_percent: warning_threshold_percent,
         model: model,
         minimum_history_points: minimum_history_points,
         metric_class_overrides: overrides
       }}
    else
      {:error, {field, message}} ->
        {:error, {:forecast_form, params, [{field, {message, []}}]}}

      {:error, reason} ->
        {:error, reason}
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
