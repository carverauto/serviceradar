defmodule ServiceRadarWebNGWeb.Settings.NetflowLive.Index do
  @moduledoc """
  Admin-managed NetFlow settings.

  Currently includes:
  - Local CIDRs used for directionality tagging (inbound/outbound/internal/external)
  """

  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.SettingsComponents

  alias AshPhoenix.Form
  alias ServiceRadar.Observability.NetflowLocalCidr
  alias ServiceRadar.Observability.NetflowSettings
  alias ServiceRadar.Observability.{GeoLiteMmdbDownloadWorker, IpEnrichmentRefreshWorker}
  alias ServiceRadar.SweepJobs.ObanSupport
  alias ServiceRadarWebNG.RBAC

  require Ash.Query

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "settings.netflow.manage") do
      settings = load_settings(scope)

      {:ok,
       socket
       |> assign(:page_title, "NetFlow Settings")
       |> assign(:current_path, "/settings/netflows")
       |> assign(:cidrs, load_cidrs(scope))
       |> assign(:settings, settings)
       |> assign(:settings_form, settings_to_form(settings))
       |> assign(:selected, nil)
       |> assign(:ash_form, nil)
       |> assign(:form, nil)}
    else
      {:ok,
       socket
       |> put_flash(:error, "Not authorized to manage NetFlow settings")
       |> redirect(to: ~p"/settings/profile")}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "NetFlow Settings")
    |> assign(:current_path, "/settings/netflows")
    |> assign(:selected, nil)
    |> assign(:ash_form, nil)
    |> assign(:form, nil)
  end

  defp apply_action(socket, :new, _params) do
    scope = socket.assigns.current_scope

    ash_form =
      Form.for_create(NetflowLocalCidr, :create, domain: ServiceRadar.Observability, scope: scope)

    socket
    |> assign(:page_title, "Add Local CIDR")
    |> assign(:current_path, "/settings/netflows")
    |> assign(:selected, nil)
    |> assign(:ash_form, ash_form)
    |> assign(:form, to_form(ash_form))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    scope = socket.assigns.current_scope

    case get_cidr(scope, id) do
      nil ->
        socket
        |> put_flash(:error, "CIDR not found")
        |> push_navigate(to: ~p"/settings/netflows")

      cidr ->
        ash_form =
          Form.for_update(cidr, :update, domain: ServiceRadar.Observability, scope: scope)

        socket
        |> assign(:page_title, "Edit Local CIDR")
        |> assign(:current_path, "/settings/netflows")
        |> assign(:selected, cidr)
        |> assign(:ash_form, ash_form)
        |> assign(:form, to_form(ash_form))
    end
  end

  @impl true
  def handle_event("validate", %{"form" => params}, socket) do
    ash_form = socket.assigns.ash_form
    ash_form = Form.validate(ash_form, params)

    {:noreply,
     socket
     |> assign(:ash_form, ash_form)
     |> assign(:form, to_form(ash_form))}
  end

  def handle_event("save", %{"form" => params}, socket) do
    ash_form = socket.assigns.ash_form

    case Form.submit(ash_form, params: params) do
      {:ok, _record} ->
        {:noreply,
         socket
         |> put_flash(:info, "Saved")
         |> assign(:cidrs, load_cidrs(socket.assigns.current_scope))
         |> push_navigate(to: ~p"/settings/netflows")}

      {:error, ash_form} ->
        {:noreply,
         socket
         |> put_flash(:error, "Validation error")
         |> assign(:ash_form, ash_form)
         |> assign(:form, to_form(ash_form))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case get_cidr(scope, id) do
      nil ->
        {:noreply, socket |> put_flash(:error, "CIDR not found")}

      cidr ->
        case Ash.destroy(cidr, scope: scope) do
          :ok ->
            {:noreply,
             socket
             |> put_flash(:info, "Deleted")
             |> assign(:cidrs, load_cidrs(scope))}

          {:error, err} ->
            {:noreply, socket |> put_flash(:error, format_ash_error(err))}
        end
    end
  end

  def handle_event("settings_validate", %{"settings" => params}, socket) do
    # Keep the in-memory form state in sync; we intentionally avoid clearing secrets
    # unless the user explicitly checks the "clear" box.
    {:noreply,
     assign(socket, :settings_form, merge_settings_form(socket.assigns.settings_form, params))}
  end

  def handle_event("settings_save", %{"settings" => params}, socket) do
    scope = socket.assigns.current_scope
    user = scope.user

    settings = socket.assigns.settings || load_settings(scope)

    update_params = build_settings_update_params(params)

    result =
      case settings do
        %NetflowSettings{} = record ->
          NetflowSettings.update_settings(record, update_params, actor: user)

        _ ->
          NetflowSettings.create(update_params, actor: user)
      end

    case result do
      {:ok, %NetflowSettings{} = updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "Saved settings")
         |> assign(:settings, updated)
         |> assign(:settings_form, settings_to_form(updated))}

      {:error, err} ->
        {:noreply, socket |> put_flash(:error, "Failed to save settings: #{inspect(err)}")}
    end
  end

  def handle_event("run_mmdb_refresh", _params, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "settings.netflow.manage") do
      case ObanSupport.safe_insert(GeoLiteMmdbDownloadWorker.new(%{})) do
        {:ok, _job} ->
          {:noreply, socket |> put_flash(:info, "Queued MMDB refresh job")}

        {:error, :oban_unavailable} ->
          {:noreply,
           socket
           |> put_flash(:error, "Oban is unavailable in this environment.")}

        {:error, err} ->
          {:noreply, socket |> put_flash(:error, "Failed to queue job: #{inspect(err)}")}
      end
    else
      {:noreply, socket |> put_flash(:error, "Not authorized")}
    end
  end

  def handle_event("run_enrichment_refresh", _params, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "settings.netflow.manage") do
      case ObanSupport.safe_insert(IpEnrichmentRefreshWorker.new(%{})) do
        {:ok, _job} ->
          {:noreply, socket |> put_flash(:info, "Queued enrichment refresh job")}

        {:error, :oban_unavailable} ->
          {:noreply,
           socket
           |> put_flash(:error, "Oban is unavailable in this environment.")}

        {:error, err} ->
          {:noreply, socket |> put_flash(:error, "Failed to queue job: #{inspect(err)}")}
      end
    else
      {:noreply, socket |> put_flash(:error, "Not authorized")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.settings_shell current_path="/settings/netflows">
        <div class="space-y-4">
          <.settings_nav current_path="/settings/netflows" current_scope={@current_scope} />
          <.network_nav current_path="/settings/netflows" current_scope={@current_scope} />
        </div>

        <div class="grid gap-6 lg:grid-cols-[1fr,520px]">
          <section class="space-y-4">
            <div>
              <h1 class="text-xl font-semibold">NetFlow</h1>
              <p class="text-sm text-base-content/60">
                Configure directionality tagging based on local networks. These CIDRs are used by SRQL
                queries and enrichment pipelines to label flows as inbound/outbound/internal/external.
              </p>
            </div>

            <div class="rounded-xl border border-base-200 bg-base-100 p-4">
              <h2 class="text-sm font-semibold">Optional Enrichment and Security</h2>
              <p class="text-xs text-base-content/60 mt-1">
                These settings are deployment-scoped. External providers are only used by background jobs,
                never at query time.
              </p>

              <.form
                :if={@settings_form}
                for={@settings_form}
                id="netflow-settings-form"
                phx-change="settings_validate"
                phx-submit="settings_save"
              >
                <div class="mt-4 grid grid-cols-1 gap-4">
                  <div class="rounded-lg border border-base-200 bg-base-200/30 p-3">
                    <div class="flex items-center justify-between gap-3">
                      <div>
                        <div class="text-xs font-semibold">GeoIP (MMDB)</div>
                        <div class="text-xs text-base-content/60 mt-1">
                          GeoIP is populated by background jobs and stored in `ip_geo_enrichment_cache`.
                        </div>
                      </div>
                      <div class="flex items-center gap-2">
                        <button type="button" class="btn btn-sm" phx-click="run_mmdb_refresh">
                          Run MMDB refresh
                        </button>
                        <button type="button" class="btn btn-sm" phx-click="run_enrichment_refresh">
                          Run enrichment refresh
                        </button>
                      </div>
                    </div>

                    <div class="mt-3 grid grid-cols-1 gap-3">
                      <.input
                        field={@settings_form[:geoip_enabled]}
                        type="checkbox"
                        label="Enable GeoIP enrichment (background only)"
                      />

                      <div class="grid gap-2 text-xs text-base-content/70">
                        <div class="grid grid-cols-1 gap-1 sm:grid-cols-3 sm:gap-4">
                          <div class="font-semibold text-base-content/80">MMDB refresh</div>
                          <div>
                            Last success:
                            <span class="font-mono">
                              {format_dt(@settings && @settings.geolite_mmdb_last_success_at)}
                            </span>
                          </div>
                          <div class="truncate">
                            Last error:
                            <span class="font-mono">
                              {@settings && (@settings.geolite_mmdb_last_error || "—")}
                            </span>
                          </div>
                        </div>

                        <div class="grid grid-cols-1 gap-1 sm:grid-cols-3 sm:gap-4">
                          <div class="font-semibold text-base-content/80">IP enrichment</div>
                          <div>
                            Last success:
                            <span class="font-mono">
                              {format_dt(@settings && @settings.ip_enrichment_last_success_at)}
                            </span>
                          </div>
                          <div class="truncate">
                            Last error:
                            <span class="font-mono">
                              {@settings && (@settings.ip_enrichment_last_error || "—")}
                            </span>
                          </div>
                        </div>
                      </div>
                    </div>
                  </div>

                  <div class="rounded-lg border border-base-200 bg-base-200/30 p-3">
                    <div class="text-xs font-semibold">ipinfo.io/lite</div>
                    <div class="mt-2 grid grid-cols-1 gap-3">
                      <.input
                        field={@settings_form[:ipinfo_enabled]}
                        type="checkbox"
                        label="Enable ipinfo enrichment (background only)"
                      />
                      <.input
                        field={@settings_form[:ipinfo_base_url]}
                        type="text"
                        label="Base URL"
                        placeholder="https://api.ipinfo.io"
                      />

                      <div class="grid grid-cols-1 gap-2">
                        <label class="label p-0">
                          <span class="label-text text-sm">Token (optional)</span>
                        </label>
                        <input
                          class="input input-bordered w-full"
                          type="password"
                          name="settings[ipinfo_api_key]"
                          value=""
                          autocomplete="off"
                          placeholder={
                            if ipinfo_token_present?(@settings), do: "(set)", else: "(not set)"
                          }
                        />
                        <div class="text-xs text-base-content/60">
                          Leave blank to keep existing. Check "clear" to remove.
                        </div>
                      </div>

                      <label class="flex items-center gap-2 text-sm">
                        <input
                          type="checkbox"
                          class="checkbox checkbox-sm"
                          name="settings[clear_ipinfo_api_key]"
                          value="true"
                        />
                        <span>Clear token</span>
                      </label>
                    </div>
                  </div>

                  <div class="rounded-lg border border-base-200 bg-base-200/30 p-3">
                    <div class="text-xs font-semibold">Threat Intel (Feature Flag)</div>
                    <div class="mt-2 grid grid-cols-1 gap-3">
                      <.input
                        field={@settings_form[:threat_intel_enabled]}
                        type="checkbox"
                        label="Enable threat intel matching"
                      />
                      <div class="grid grid-cols-1 gap-2">
                        <label class="label p-0">
                          <span class="label-text text-sm">Feed URLs (one per line)</span>
                        </label>
                        <textarea
                          class="textarea textarea-bordered w-full"
                          name="settings[threat_intel_feed_urls_text]"
                          rows="3"
                        ><%= Enum.join(Map.get(@settings_form.source, :threat_intel_feed_urls, []) || [], "\n") %></textarea>
                      </div>
                    </div>
                  </div>

                  <div class="rounded-lg border border-base-200 bg-base-200/30 p-3">
                    <div class="text-xs font-semibold">Anomaly Detection (Feature Flag)</div>
                    <div class="mt-2 grid grid-cols-1 gap-3">
                      <.input
                        field={@settings_form[:anomaly_enabled]}
                        type="checkbox"
                        label="Enable anomaly flags"
                      />
                      <.input
                        field={@settings_form[:anomaly_baseline_window_seconds]}
                        type="number"
                        label="Baseline window seconds"
                      />
                      <.input
                        field={@settings_form[:anomaly_threshold_percent]}
                        type="number"
                        label="Threshold percent increase"
                      />
                    </div>
                  </div>

                  <div class="rounded-lg border border-base-200 bg-base-200/30 p-3">
                    <div class="text-xs font-semibold">Port Scan Detection (Feature Flag)</div>
                    <div class="mt-2 grid grid-cols-1 gap-3">
                      <.input
                        field={@settings_form[:port_scan_enabled]}
                        type="checkbox"
                        label="Enable port scan flags"
                      />
                      <.input
                        field={@settings_form[:port_scan_window_seconds]}
                        type="number"
                        label="Window seconds"
                      />
                      <.input
                        field={@settings_form[:port_scan_unique_ports_threshold]}
                        type="number"
                        label="Unique ports threshold"
                      />
                    </div>
                  </div>
                </div>

                <div class="mt-4 flex justify-end">
                  <button class="btn btn-sm btn-primary" type="submit">Save Settings</button>
                </div>
              </.form>
            </div>

            <div class="flex items-center justify-between">
              <h2 class="text-sm font-semibold">Local CIDRs</h2>
              <.link navigate={~p"/settings/netflows/new"} class="btn btn-sm btn-primary">
                Add CIDR
              </.link>
            </div>

            <div class="overflow-x-auto rounded-xl border border-base-200 bg-base-100">
              <table class="table">
                <thead>
                  <tr>
                    <th>Partition</th>
                    <th>Label</th>
                    <th>CIDR</th>
                    <th>Status</th>
                    <th class="text-right">Actions</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for cidr <- @cidrs do %>
                    <tr id={"cidr-#{cidr.id}"}>
                      <td class="font-mono text-xs">{cidr.partition || "*"}</td>
                      <td>{cidr.label || ""}</td>
                      <td class="font-mono text-xs">{cidr.cidr}</td>
                      <td>
                        <span class={[
                          "badge badge-sm",
                          (cidr.enabled && "badge-success") || "badge-ghost"
                        ]}>
                          {if(cidr.enabled, do: "enabled", else: "disabled")}
                        </span>
                      </td>
                      <td class="text-right space-x-2">
                        <.link navigate={~p"/settings/netflows/#{cidr.id}/edit"} class="btn btn-xs">
                          Edit
                        </.link>
                        <button
                          type="button"
                          class="btn btn-xs btn-ghost text-error"
                          phx-click="delete"
                          phx-value-id={cidr.id}
                          data-confirm="Delete this CIDR?"
                        >
                          Delete
                        </button>
                      </td>
                    </tr>
                  <% end %>
                  <%= if Enum.empty?(@cidrs) do %>
                    <tr>
                      <td colspan="5" class="text-sm text-base-content/60">
                        No CIDRs configured yet.
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          </section>

          <section class="space-y-4">
            <div class="rounded-xl border border-base-200 bg-base-100 p-4">
              <h2 class="text-sm font-semibold">Directionality</h2>
              <p class="text-xs text-base-content/60 mt-1">
                Flows are labeled using the configured CIDRs:
              </p>
              <ul class="mt-3 text-xs text-base-content/80 list-disc pl-5 space-y-1">
                <li><span class="font-semibold">internal</span>: src and dst are local</li>
                <li><span class="font-semibold">outbound</span>: src is local, dst is not</li>
                <li><span class="font-semibold">inbound</span>: src is not local, dst is local</li>
                <li><span class="font-semibold">external</span>: neither is local</li>
              </ul>
              <div class="mt-4 rounded-lg bg-base-200/60 p-3 text-xs">
                Partition scope: set <span class="font-mono">partition</span> to apply only to that
                partition; leave blank to apply globally.
              </div>
            </div>

            <%= if @form do %>
              <div class="rounded-xl border border-base-200 bg-base-100 p-4">
                <h2 class="text-sm font-semibold">
                  {if(@selected, do: "Edit CIDR", else: "Add CIDR")}
                </h2>

                <.form for={@form} id="netflow-cidr-form" phx-change="validate" phx-submit="save">
                  <div class="space-y-3 mt-3">
                    <.input field={@form[:partition]} type="text" label="Partition (optional)" />
                    <.input field={@form[:label]} type="text" label="Label (optional)" />
                    <.input field={@form[:cidr]} type="text" label="CIDR" placeholder="10.0.0.0/8" />
                    <.input field={@form[:enabled]} type="checkbox" label="Enabled" />
                  </div>

                  <div class="mt-5 flex items-center justify-between">
                    <.link navigate={~p"/settings/netflows"} class="btn btn-ghost btn-sm">
                      Cancel
                    </.link>
                    <button class="btn btn-primary btn-sm" type="submit">Save</button>
                  </div>
                </.form>
              </div>
            <% else %>
              <div class="rounded-xl border border-base-200 bg-base-100 p-4">
                <h2 class="text-sm font-semibold">Add CIDRs</h2>
                <p class="text-xs text-base-content/60 mt-1">
                  Use the button on the left to add local networks for directionality tagging.
                </p>
              </div>
            <% end %>
          </section>
        </div>
      </.settings_shell>
    </Layouts.app>
    """
  end

  defp load_cidrs(scope) do
    query =
      NetflowLocalCidr
      |> Ash.Query.for_read(:list, %{})
      |> Ash.Query.sort(enabled: :desc, partition: :asc, cidr: :asc)

    case Ash.read(query, scope: scope) do
      {:ok, %Ash.Page.Keyset{} = page} -> page.results
      {:ok, rows} when is_list(rows) -> rows
      _ -> []
    end
  end

  defp get_cidr(scope, id) do
    query =
      NetflowLocalCidr
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(id == ^id)

    case Ash.read_one(query, scope: scope) do
      {:ok, record} -> record
      _ -> nil
    end
  end

  defp load_settings(scope) do
    user = scope.user

    case NetflowSettings.get_settings(actor: user) do
      {:ok, %NetflowSettings{} = settings} ->
        settings

      _ ->
        # In case the default row hasn't been created in this environment yet.
        case NetflowSettings.create(%{}, actor: user) do
          {:ok, %NetflowSettings{} = settings} -> settings
          _ -> nil
        end
    end
  end

  defp settings_to_form(nil), do: nil

  defp settings_to_form(%NetflowSettings{} = settings) do
    # Build a plain form-like map for settings; we only persist on submit.
    %{
      "geoip_enabled" => truthy(settings.geoip_enabled),
      "ipinfo_enabled" => truthy(settings.ipinfo_enabled),
      "ipinfo_base_url" => settings.ipinfo_base_url || "https://api.ipinfo.io",
      "threat_intel_enabled" => truthy(settings.threat_intel_enabled),
      "threat_intel_feed_urls" => settings.threat_intel_feed_urls || [],
      "anomaly_enabled" => truthy(settings.anomaly_enabled),
      "anomaly_baseline_window_seconds" =>
        to_string(settings.anomaly_baseline_window_seconds || 604_800),
      "anomaly_threshold_percent" => to_string(settings.anomaly_threshold_percent || 300),
      "port_scan_enabled" => truthy(settings.port_scan_enabled),
      "port_scan_window_seconds" => to_string(settings.port_scan_window_seconds || 300),
      "port_scan_unique_ports_threshold" =>
        to_string(settings.port_scan_unique_ports_threshold || 50)
    }
    |> to_form(as: "settings")
  end

  defp settings_to_form(_), do: nil

  defp merge_settings_form(form, params) do
    # Phoenix form struct has `.source`; we merge incoming params into it for re-render.
    merged =
      form.source
      |> Map.merge(params || %{})

    to_form(merged, as: "settings")
  end

  defp build_settings_update_params(params) when is_map(params) do
    feed_urls =
      params
      |> Map.get("threat_intel_feed_urls_text", "")
      |> to_string()
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    base = %{
      geoip_enabled: truthy_param?(Map.get(params, "geoip_enabled")),
      ipinfo_enabled: truthy_param?(Map.get(params, "ipinfo_enabled")),
      ipinfo_base_url: Map.get(params, "ipinfo_base_url") |> to_string() |> String.trim(),
      threat_intel_enabled: truthy_param?(Map.get(params, "threat_intel_enabled")),
      threat_intel_feed_urls: feed_urls,
      anomaly_enabled: truthy_param?(Map.get(params, "anomaly_enabled")),
      anomaly_baseline_window_seconds:
        to_int(Map.get(params, "anomaly_baseline_window_seconds"), 604_800),
      anomaly_threshold_percent: to_int(Map.get(params, "anomaly_threshold_percent"), 300),
      port_scan_enabled: truthy_param?(Map.get(params, "port_scan_enabled")),
      port_scan_window_seconds: to_int(Map.get(params, "port_scan_window_seconds"), 300),
      port_scan_unique_ports_threshold:
        to_int(Map.get(params, "port_scan_unique_ports_threshold"), 50),
      clear_ipinfo_api_key: truthy_param?(Map.get(params, "clear_ipinfo_api_key"))
    }

    api_key = Map.get(params, "ipinfo_api_key")

    if is_binary(api_key) and String.trim(api_key) != "" do
      Map.put(base, :ipinfo_api_key, String.trim(api_key))
    else
      base
    end
  end

  defp build_settings_update_params(_), do: %{}

  defp truthy(true), do: true
  defp truthy("true"), do: true
  defp truthy("1"), do: true
  defp truthy(_), do: false

  defp truthy_param?(true), do: true
  defp truthy_param?("true"), do: true
  defp truthy_param?("1"), do: true
  defp truthy_param?("on"), do: true
  defp truthy_param?(_), do: false

  defp ipinfo_token_present?(%NetflowSettings{ipinfo_api_key: value}) when is_binary(value),
    do: String.trim(value) != ""

  defp ipinfo_token_present?(_), do: false

  defp to_int(nil, default), do: default
  defp to_int("", default), do: default

  defp to_int(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} -> n
      _ -> default
    end
  end

  defp to_int(value, _default) when is_integer(value), do: value
  defp to_int(_value, default), do: default

  defp format_ash_error(%Ash.Error.Invalid{errors: errors}) do
    Enum.map_join(errors, ", ", fn
      %{message: message} -> message
      _ -> "Validation error"
    end)
  end

  defp format_ash_error(_), do: "Unexpected error"

  defp format_dt(nil), do: "—"
  defp format_dt(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
  defp format_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_dt(_), do: "—"
end
