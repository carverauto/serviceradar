defmodule ServiceRadarWebNGWeb.Settings.DeviceHostnameRdnsLive do
  @moduledoc """
  Enable, schedule, and run reverse-DNS hostname enrichment for inventory devices.
  """

  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Inventory.DeviceHostnameRdns
  alias ServiceRadar.Inventory.DeviceHostnameRdnsSettings
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.Shell

  @current_path "/settings/networks/hostname-rdns"
  @permission "settings.networks.manage"

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, @permission) do
      settings = load_or_create_settings(scope)

      {:ok,
       socket
       |> assign(:page_title, "Device Hostnames")
       |> assign(:current_path, @current_path)
       |> assign(:settings, settings)
       |> assign(:form, settings_to_form(settings))
       |> assign(:running?, false)
       |> assign(:preview, nil)
       |> assign(:previewing?, false)}
    else
      {:ok,
       socket
       |> put_flash(:error, "Not authorized to manage reverse-DNS hostname settings")
       |> redirect(to: ~p"/settings/profile")}
    end
  end

  @impl true
  def handle_event("validate", %{"rdns" => params}, socket) do
    {:noreply, assign(socket, :form, merge_form(socket.assigns.form, params))}
  end

  def handle_event("save", %{"rdns" => params}, socket) do
    scope = socket.assigns.current_scope
    attrs = params_to_attrs(params)

    case save_settings(scope, socket.assigns.settings, attrs) do
      {:ok, settings} ->
        {:noreply,
         socket
         |> put_flash(:info, "Reverse-DNS hostname settings saved")
         |> assign(:settings, settings)
         |> assign(:form, settings_to_form(settings))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save settings: #{format_error(reason)}")}
    end
  end

  def handle_event("run_now", _params, %{assigns: %{running?: true}} = socket) do
    {:noreply, socket}
  end

  def handle_event("preview", _params, socket) do
    query =
      socket.assigns.form
      |> form_value("srql_query")
      |> to_string()
      |> String.trim()

    {:noreply,
     socket
     |> assign(:previewing?, true)
     |> start_async(:preview_rdns_cohort, fn -> DeviceHostnameRdns.preview(query, limit: 10) end)}
  end

  def handle_event("run_now", _params, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, @permission) do
      {:noreply,
       socket
       |> assign(:running?, true)
       |> start_async(:run_hostname_rdns, fn -> run_now(scope) end)}
    else
      {:noreply, put_flash(socket, :error, "Not authorized")}
    end
  end

  @impl true
  def handle_async(:run_hostname_rdns, {:ok, {:ok, settings}}, socket) do
    {:noreply,
     socket
     |> assign(:running?, false)
     |> assign(:settings, settings)
     |> assign(:form, settings_to_form(settings))
     |> put_flash(
       :info,
       "Reverse-DNS run finished: looked up #{settings.last_looked_up}, updated #{settings.last_updated}"
     )}
  end

  def handle_async(:run_hostname_rdns, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:running?, false)
     |> put_flash(:error, "Reverse-DNS run failed: #{format_error(reason)}")}
  end

  def handle_async(:run_hostname_rdns, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:running?, false)
     |> put_flash(:error, "Reverse-DNS run crashed: #{inspect(reason)}")}
  end

  def handle_async(:preview_rdns_cohort, {:ok, {:ok, preview}}, socket) do
    {:noreply, socket |> assign(:previewing?, false) |> assign(:preview, preview)}
  end

  def handle_async(:preview_rdns_cohort, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:previewing?, false)
     |> assign(:preview, nil)
     |> put_flash(:error, "SRQL preview failed: #{format_error(reason)}")}
  end

  def handle_async(:preview_rdns_cohort, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:previewing?, false)
     |> put_flash(:error, "SRQL preview crashed: #{inspect(reason)}")}
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
        <section class="space-y-6">
          <div class="flex flex-wrap items-start justify-between gap-4">
            <div>
              <h1 class="text-xl font-semibold">Device Hostnames</h1>
              <p class="mt-1 text-sm text-sr-muted">
                Periodically resolve PTR records for devices selected by an SRQL
                query and fill blank or IP-shaped hostnames. Disable this if your
                resolver should not see those addresses.
              </p>
            </div>
            <.ui_button
              type="button"
              variant="outline"
              size="sm"
              phx-click="run_now"
              disabled={@running? or is_nil(@settings)}
              title="Run the selected cohort now, ignoring the minimum lookup interval"
            >
              <.icon name="hero-arrow-path" class={["size-4", @running? && "animate-spin"]} />
              {if @running?, do: "Running…", else: "Run now"}
            </.ui_button>
          </div>

          <div :if={is_nil(@settings)} role="alert" class={ui_alert_class("warning")}>
            <.icon name="hero-exclamation-triangle" class="size-5" />
            <div>
              <div class="font-semibold">Settings unavailable</div>
              <div class="text-sm">Unable to load reverse-DNS hostname settings.</div>
            </div>
          </div>

          <.form
            :if={@form}
            for={@form}
            id="device-hostname-rdns-form"
            phx-change="validate"
            phx-submit="save"
            class="grid grid-cols-1 gap-6 lg:grid-cols-[minmax(0,1fr),20rem]"
          >
            <div class="space-y-4 rounded-xl border border-sr-line bg-sr-surface p-6">
              <.input field={@form[:enabled]} type="checkbox" label="Enable scheduled reverse DNS" />
              <.input
                field={@form[:cron]}
                type="text"
                label="Schedule (cron)"
                placeholder="0 * * * *"
              />
              <.input field={@form[:timezone]} type="text" label="Timezone" placeholder="Etc/UTC" />
              <.input
                field={@form[:srql_query]}
                type="textarea"
                rows="3"
                label="Device cohort (SRQL)"
                placeholder="in:devices sort:last_seen:desc"
              />
              <p class="text-xs text-sr-muted">
                Only devices returned by this query are considered. Narrow with
                SRQL filters, for example <code class="text-xs">in:devices ip:192.168.2.0/24 sort:last_seen:desc</code>.
                Existing non-IP hostnames are skipped unless overwrite is enabled.
              </p>
              <div class="flex flex-wrap items-center gap-2">
                <.ui_button
                  type="button"
                  variant="ghost"
                  size="sm"
                  phx-click="preview"
                  phx-disable-with="Previewing…"
                  disabled={@previewing?}
                >
                  <.icon name="hero-eye" class="size-4" />
                  {if @previewing?, do: "Previewing…", else: "Preview cohort"}
                </.ui_button>
              </div>
              <div
                :if={@preview}
                class="rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-xs"
              >
                <div class="font-medium text-sr-ink">
                  {length(@preview.rows)} sample row(s) for <code>{@preview.query}</code>
                </div>
                <ul class="mt-2 space-y-1 text-sr-muted">
                  <li :for={row <- @preview.rows}>
                    {row.ip || "no-ip"}
                    <span :if={row.hostname}> · {row.hostname}</span>
                    <span :if={row.uid} class="font-mono"> · {row.uid}</span>
                  </li>
                </ul>
              </div>
              <.input
                field={@form[:batch_size]}
                type="number"
                label="Devices per batch"
                min="1"
              />
              <p class="text-xs text-sr-muted">
                Bounds each device load and processing batch. Every eligible device in the SRQL
                cohort is processed during the run.
              </p>
              <.input
                field={@form[:timeout_ms]}
                type="number"
                label="Lookup timeout (ms)"
                min="50"
              />
              <.input
                field={@form[:retry_after_minutes]}
                type="number"
                label="Minimum lookup interval (minutes)"
                min="5"
              />
              <.input
                field={@form[:overwrite_existing]}
                type="checkbox"
                label="Overwrite existing non-IP hostnames"
              />
              <.ui_button type="submit" variant="primary" size="sm">
                <.icon name="hero-check" class="size-4" /> Save settings
              </.ui_button>
            </div>

            <aside class="space-y-3 rounded-xl border border-sr-line bg-sr-surface p-6 text-sm">
              <h2 class="font-semibold">Last run</h2>
              <dl class="space-y-2 text-sr-muted">
                <div>
                  <dt class="text-xs uppercase tracking-wide">Status</dt>
                  <dd class="text-sr-ink">{(@settings && @settings.last_status) || "Never"}</dd>
                </div>
                <div>
                  <dt class="text-xs uppercase tracking-wide">Last success</dt>
                  <dd class="text-sr-ink">
                    <.user_time
                      id="settings-device-hostname-rdns-last-success-at"
                      value={@settings && @settings.last_success_at}
                      timezone={@current_scope.user.timezone || "Etc/UTC"}
                      style={:compact}
                      fallback="—"
                    />
                  </dd>
                </div>
                <div>
                  <dt class="text-xs uppercase tracking-wide">Next run</dt>
                  <dd class="text-sr-ink">
                    <.user_time
                      id="settings-device-hostname-rdns-next-run-at"
                      value={@settings && @settings.next_run_at}
                      timezone={@current_scope.user.timezone || "Etc/UTC"}
                      style={:compact}
                      fallback="—"
                    />
                  </dd>
                </div>
                <div>
                  <dt class="text-xs uppercase tracking-wide">SRQL rows / eligible</dt>
                  <dd class="text-sr-ink">
                    {(@settings && @settings.last_cohort_rows) || 0} / {(@settings &&
                                                                           @settings.last_candidates) ||
                      0}
                  </dd>
                </div>
                <div>
                  <dt class="text-xs uppercase tracking-wide">Looked up / updated</dt>
                  <dd class="text-sr-ink">
                    {(@settings && @settings.last_looked_up) || 0} / {(@settings &&
                                                                         @settings.last_updated) || 0}
                  </dd>
                </div>
                <div :if={@settings && @settings.last_error}>
                  <dt class="text-xs uppercase tracking-wide">
                    {if @settings.last_status == "error", do: "Error", else: "Note"}
                  </dt>
                  <dd class={
                    if @settings.last_status == "error", do: "text-error", else: "text-sr-ink"
                  }>
                    {@settings.last_error}
                  </dd>
                </div>
              </dl>
              <p class="text-xs text-sr-muted">
                Default schedule is hourly (`0 * * * *`). Each run drains the entire eligible
                cohort in bounded batches.
              </p>
            </aside>
          </.form>
        </section>
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end

  defp load_or_create_settings(scope) do
    case DeviceHostnameRdnsSettings.get_settings(scope: scope) do
      {:ok, %DeviceHostnameRdnsSettings{} = settings} ->
        settings

      {:ok, nil} ->
        create_default(scope)

      {:error, _} ->
        create_default(scope)
    end
  end

  defp create_default(scope) do
    case DeviceHostnameRdnsSettings.create_settings(%{}, scope: scope) do
      {:ok, settings} -> settings
      {:error, _} -> nil
    end
  end

  defp save_settings(scope, %DeviceHostnameRdnsSettings{} = settings, attrs) do
    DeviceHostnameRdnsSettings.update_settings(settings, attrs, scope: scope)
  end

  defp save_settings(scope, _settings, attrs) do
    DeviceHostnameRdnsSettings.create_settings(attrs, scope: scope)
  end

  defp run_now(scope) do
    case load_or_create_settings(scope) do
      %DeviceHostnameRdnsSettings{} = settings ->
        DeviceHostnameRdnsSettings.run_now(settings, scope: scope)

      nil ->
        {:error, :settings_unavailable}
    end
  end

  defp settings_to_form(nil), do: to_form(default_form(), as: :rdns)

  defp settings_to_form(%DeviceHostnameRdnsSettings{} = settings) do
    to_form(
      %{
        "enabled" => settings.enabled,
        "cron" => settings.cron,
        "timezone" => settings.timezone,
        "srql_query" => settings.srql_query || DeviceHostnameRdnsSettings.default_srql_query(),
        "batch_size" => settings.batch_size,
        "timeout_ms" => settings.timeout_ms,
        "retry_after_minutes" => settings.retry_after_minutes,
        "overwrite_existing" => settings.overwrite_existing
      },
      as: :rdns
    )
  end

  defp default_form do
    %{
      "enabled" => true,
      "cron" => DeviceHostnameRdnsSettings.default_cron(),
      "timezone" => "Etc/UTC",
      "srql_query" => DeviceHostnameRdnsSettings.default_srql_query(),
      "batch_size" => 200,
      "timeout_ms" => 250,
      "retry_after_minutes" => 1_440,
      "overwrite_existing" => false
    }
  end

  defp merge_form(form, params) do
    merged =
      Map.merge(form.source, %{
        "enabled" => checkbox_bool(params["enabled"]),
        "cron" => params["cron"] || "",
        "timezone" => params["timezone"] || "Etc/UTC",
        "srql_query" => params["srql_query"] || DeviceHostnameRdnsSettings.default_srql_query(),
        "batch_size" => params["batch_size"],
        "timeout_ms" => params["timeout_ms"],
        "retry_after_minutes" => params["retry_after_minutes"],
        "overwrite_existing" => checkbox_bool(params["overwrite_existing"])
      })

    to_form(merged, as: :rdns)
  end

  defp params_to_attrs(params) do
    %{
      enabled: checkbox_bool(params["enabled"]),
      cron: String.trim(params["cron"] || ""),
      timezone: String.trim(params["timezone"] || "Etc/UTC"),
      srql_query: String.trim(params["srql_query"] || DeviceHostnameRdnsSettings.default_srql_query()),
      batch_size: parse_int(params["batch_size"], 200),
      timeout_ms: parse_int(params["timeout_ms"], 250),
      retry_after_minutes: parse_int(params["retry_after_minutes"], 1_440),
      overwrite_existing: checkbox_bool(params["overwrite_existing"])
    }
  end

  defp checkbox_bool(value) when value in [true, "true", "on", "1"], do: true
  defp checkbox_bool(_value), do: false

  defp form_value(%{source: %{} = source}, key), do: Map.get(source, key) || ""
  defp form_value(_form, _key), do: ""

  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp parse_int(_value, default), do: default

  defp format_error(%Ash.Error.Invalid{} = error), do: Exception.message(error)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
