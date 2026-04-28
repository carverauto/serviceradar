defmodule ServiceRadarWebNGWeb.Settings.ThreatIntelLive.Index do
  @moduledoc """
  LiveView for assigning the first-party AlienVault OTX threat-intel edge plugin.
  """

  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.SettingsComponents

  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Observability.IpThreatIntelCache
  alias ServiceRadar.Observability.NetflowSettings
  alias ServiceRadar.Observability.OTXRetrohuntFinding
  alias ServiceRadar.Observability.OTXRetrohuntRun
  alias ServiceRadar.Observability.ThreatIntelIndicator
  alias ServiceRadar.Observability.ThreatIntelOTXSyncWorker
  alias ServiceRadar.Observability.ThreatIntelRetrohuntWorker
  alias ServiceRadar.Observability.ThreatIntelSourceObject
  alias ServiceRadar.Observability.ThreatIntelSyncStatus
  alias ServiceRadar.Plugins.ConfigSchema
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadarWebNG.Plugins.Assignments
  alias ServiceRadarWebNG.Plugins.Packages

  require Ash.Query
  require Logger

  @plugin_id "alienvault-otx-threat-intel"
  @default_form %{
    "agent_uid" => "",
    "enabled" => "true",
    "interval_seconds" => "3600",
    "timeout_seconds" => "60",
    "base_url" => "https://otx.alienvault.com",
    "api_key_secret_ref" => "",
    "limit" => "100",
    "page" => "1",
    "timeout_ms" => "60000",
    "max_pages" => "100",
    "max_indicators" => "5000"
  }
  @default_settings_form %{
    "otx_enabled" => "false",
    "otx_execution_mode" => "edge_plugin",
    "otx_base_url" => "https://otx.alienvault.com",
    "otx_api_key" => "",
    "clear_otx_api_key" => "false",
    "otx_sync_interval_seconds" => "3600",
    "otx_page_size" => "10",
    "otx_timeout_ms" => "60000",
    "otx_max_indicators" => "2000",
    "otx_modified_since" => "",
    "otx_raw_payload_archive_enabled" => "false",
    "otx_retrohunt_window_seconds" => "7776000",
    "threat_intel_match_window_seconds" => "3600"
  }

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "plugins.assign") do
      {:ok, load_page(socket)}
    else
      {:ok,
       socket
       |> put_flash(:error, "Not authorized to manage threat intelligence")
       |> redirect(to: ~p"/settings/profile")}
    end
  end

  @impl true
  def handle_event("assignment_change", %{"assignment" => params}, socket) do
    {:noreply, assign(socket, :assignment_form, Map.merge(socket.assigns.assignment_form, params))}
  end

  def handle_event("settings_change", %{"settings" => params}, socket) do
    {:noreply,
     assign(
       socket,
       :otx_settings_form,
       Map.merge(socket.assigns.otx_settings_form || @default_settings_form, params)
     )}
  end

  def handle_event("save_settings", %{"settings" => params}, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "settings.netflow.manage") do
      save_otx_settings(socket, scope, params)
    else
      {:noreply, put_flash(socket, :error, "Not authorized")}
    end
  end

  def handle_event("save_assignment", %{"assignment" => params}, socket) do
    scope = socket.assigns.current_scope

    with %PluginPackage{} = package <- socket.assigns.approved_package,
         {:ok, attrs} <- parse_assignment(params, package) do
      case existing_assignment(socket.assigns.assignments, attrs.agent_uid) do
        nil ->
          create_assignment(socket, scope, attrs)

        %PluginAssignment{} = assignment ->
          update_assignment(socket, scope, assignment, attrs)
      end
    else
      nil ->
        {:noreply, put_flash(socket, :error, "Approved AlienVault OTX package not found")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, format_error(reason))}
    end
  end

  def handle_event("delete_assignment", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Assignments.delete(id, scope: scope) do
      :ok ->
        {:noreply,
         socket
         |> reload_assignments()
         |> put_flash(:info, "Assignment removed")}

      {:ok, _assignment} ->
        {:noreply,
         socket
         |> reload_assignments()
         |> put_flash(:info, "Assignment removed")}

      {:error, error} ->
        Logger.warning("Threat intel assignment deletion failed", id: id, error: inspect(error))
        {:noreply, put_flash(socket, :error, "Failed to remove assignment")}
    end
  end

  def handle_event("sync_now", _params, socket) do
    if RBAC.can?(socket.assigns.current_scope, "plugins.assign") do
      case ThreatIntelOTXSyncWorker.ensure_scheduled(schedule_in: 1) do
        {:ok, _job} ->
          {:noreply, put_flash(socket, :info, "OTX sync queued")}

        {:error, :oban_unavailable} ->
          {:noreply, put_flash(socket, :error, "Job scheduler is unavailable")}

        {:error, error} ->
          Logger.warning("Threat intel sync enqueue failed", error: inspect(error))
          {:noreply, put_flash(socket, :error, "Failed to queue OTX sync")}
      end
    else
      {:noreply, put_flash(socket, :error, "Not authorized")}
    end
  end

  def handle_event("retrohunt_now", _params, socket) do
    if RBAC.can?(socket.assigns.current_scope, "plugins.assign") do
      opts =
        case socket.assigns.otx_settings do
          %NetflowSettings{otx_retrohunt_window_seconds: seconds, otx_max_indicators: limit} ->
            [window_seconds: seconds, max_indicators: limit]

          _ ->
            []
        end

      case ThreatIntelRetrohuntWorker.enqueue_manual(opts) do
        {:ok, _job} ->
          {:noreply, put_flash(socket, :info, "OTX retrohunt queued")}

        {:error, :oban_unavailable} ->
          {:noreply, put_flash(socket, :error, "Job scheduler is unavailable")}

        {:error, error} ->
          Logger.warning("Threat intel retrohunt enqueue failed", error: inspect(error))
          {:noreply, put_flash(socket, :error, "Failed to queue OTX retrohunt")}
      end
    else
      {:noreply, put_flash(socket, :error, "Not authorized")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.settings_shell current_path="/settings/networks/threat-intel">
        <div class="space-y-4">
          <.settings_nav
            current_path="/settings/networks/threat-intel"
            current_scope={@current_scope}
          />
          <.network_nav current_path="/settings/networks/threat-intel" current_scope={@current_scope} />
        </div>

        <section class="space-y-4">
          <div class="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
            <div>
              <h1 class="text-xl font-semibold">Threat Intel</h1>
              <p class="text-sm text-base-content/60">
                Configure edge collection for AlienVault OTX indicators.
              </p>
            </div>
            <.link navigate={~p"/settings/agents/plugins"} class="btn btn-sm btn-ghost">
              Plugin Registry
            </.link>
            <div class="flex flex-wrap gap-2">
              <button type="button" class="btn btn-sm btn-outline" phx-click="retrohunt_now">
                Retrohunt Now
              </button>
              <button type="button" class="btn btn-sm btn-primary" phx-click="sync_now">
                Sync Now
              </button>
            </div>
          </div>

          <div class="grid grid-cols-1 gap-4 xl:grid-cols-[minmax(0,1fr)_minmax(360px,420px)]">
            <div class="space-y-4">
              <div class="rounded-xl border border-base-200 bg-base-100 p-4">
                <div class="flex flex-wrap items-start justify-between gap-3">
                  <div>
                    <div class="text-sm font-semibold">AlienVault OTX Edge Collector</div>
                    <div class="font-mono text-xs text-base-content/60">{@plugin_id}</div>
                  </div>
                  <.package_status package={@latest_package} approved_package={@approved_package} />
                </div>
              </div>

              <div class="rounded-xl border border-base-200 bg-base-100 p-4">
                <div class="mb-3 text-sm font-semibold">Assignments</div>
                <%= if @assignments == [] do %>
                  <div class="rounded-lg border border-dashed border-base-300 p-4 text-sm text-base-content/60">
                    No edge assignments.
                  </div>
                <% else %>
                  <div class="divide-y divide-base-200">
                    <%= for assignment <- @assignments do %>
                      <div class="flex flex-col gap-3 py-3 first:pt-0 last:pb-0 md:flex-row md:items-center md:justify-between">
                        <div>
                          <div class="font-mono text-sm">{assignment.agent_uid}</div>
                          <div class="text-xs text-base-content/60">
                            every {assignment.interval_seconds}s, timeout {assignment.timeout_seconds}s
                          </div>
                        </div>
                        <div class="flex items-center gap-2">
                          <%= if assignment.enabled do %>
                            <.ui_badge size="xs" variant="success">enabled</.ui_badge>
                          <% else %>
                            <.ui_badge size="xs" variant="ghost">disabled</.ui_badge>
                          <% end %>
                          <button
                            type="button"
                            class="btn btn-ghost btn-xs"
                            phx-click="delete_assignment"
                            phx-value-id={assignment.id}
                            data-confirm="Remove this assignment?"
                          >
                            Remove
                          </button>
                        </div>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>

              <div class="rounded-xl border border-base-200 bg-base-100 p-4">
                <div class="mb-3 text-sm font-semibold">Sync Health</div>
                <%= if @sync_statuses == [] do %>
                  <div class="rounded-lg border border-dashed border-base-300 p-4 text-sm text-base-content/60">
                    No sync runs recorded.
                  </div>
                <% else %>
                  <div class="divide-y divide-base-200">
                    <%= for status <- @sync_statuses do %>
                      <div class="py-3 first:pt-0 last:pb-0 space-y-2">
                        <div class="flex flex-wrap items-start justify-between gap-2">
                          <div>
                            <div class="font-mono text-sm">{status_agent_label(status)}</div>
                            <div class="text-xs text-base-content/60">
                              {status.collection_id || "collection"} · {format_datetime(
                                status.last_attempt_at
                              )}
                            </div>
                          </div>
                          <.ui_badge size="xs" variant={status_badge_variant(status.last_status)}>
                            {status.last_status}
                          </.ui_badge>
                        </div>
                        <div class="grid grid-cols-2 gap-2 text-xs sm:grid-cols-4">
                          <.status_count label="Objects" value={status.objects_count} />
                          <.status_count label="IOCs" value={status.indicators_count} />
                          <.status_count label="Skipped" value={status.skipped_count} />
                          <.status_count label="Total" value={status.total_count} />
                        </div>
                        <div
                          :if={skipped_by_type(status) != []}
                          class="flex flex-wrap items-center gap-1 text-xs text-base-content/60"
                        >
                          <span>Skipped types:</span>
                          <span
                            :for={{type, count} <- skipped_by_type(status)}
                            class="badge badge-xs badge-outline"
                          >
                            {type}: {count}
                          </span>
                        </div>
                        <div :if={status.last_error} class="text-xs text-error">
                          {status.last_error}
                        </div>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>

              <div class="rounded-xl border border-base-200 bg-base-100 p-4">
                <div class="mb-3 text-sm font-semibold">Current NetFlow Findings</div>
                <div class="grid grid-cols-2 gap-2 text-xs sm:grid-cols-4">
                  <.status_count label="Matched IPs" value={@netflow_findings.matched_ips} />
                  <.status_count label="IOC Hits" value={@netflow_findings.indicator_matches} />
                  <.status_count label="Max Severity" value={@netflow_findings.max_severity || 0} />
                  <.status_count label="Sources" value={length(@netflow_findings.sources)} />
                </div>
                <div :if={@netflow_findings.sources != []} class="mt-3 flex flex-wrap gap-1">
                  <span
                    :for={source <- @netflow_findings.sources}
                    class="badge badge-xs badge-outline"
                  >
                    {source}
                  </span>
                </div>
                <%= if @netflow_findings.recent == [] do %>
                  <div class="mt-3 rounded-lg border border-dashed border-base-300 p-4 text-sm text-base-content/60">
                    No current NetFlow IOC matches.
                  </div>
                <% else %>
                  <div class="mt-3 overflow-x-auto">
                    <table class="table table-sm">
                      <thead>
                        <tr>
                          <th>IP</th>
                          <th>Hits</th>
                          <th>Severity</th>
                          <th>Updated</th>
                        </tr>
                      </thead>
                      <tbody>
                        <tr :for={finding <- @netflow_findings.recent}>
                          <td class="font-mono">{finding.ip}</td>
                          <td>{finding.match_count}</td>
                          <td>{finding.max_severity || 0}</td>
                          <td>{format_datetime(finding.looked_up_at)}</td>
                        </tr>
                      </tbody>
                    </table>
                  </div>
                <% end %>
              </div>

              <div class="rounded-xl border border-base-200 bg-base-100 p-4">
                <div class="mb-3 text-sm font-semibold">Retrohunt Runs</div>
                <%= if @retrohunt_runs == [] do %>
                  <div class="rounded-lg border border-dashed border-base-300 p-4 text-sm text-base-content/60">
                    No retrohunt runs recorded.
                  </div>
                <% else %>
                  <div class="divide-y divide-base-200">
                    <%= for run <- @retrohunt_runs do %>
                      <div class="py-3 first:pt-0 last:pb-0 space-y-2">
                        <div class="flex flex-wrap items-start justify-between gap-2">
                          <div>
                            <div class="font-mono text-sm">{run.source}</div>
                            <div class="text-xs text-base-content/60">
                              {format_datetime(run.window_start)} - {format_datetime(run.window_end)}
                            </div>
                          </div>
                          <.ui_badge size="xs" variant={status_badge_variant(run.status)}>
                            {run.status}
                          </.ui_badge>
                        </div>
                        <div class="grid grid-cols-2 gap-2 text-xs sm:grid-cols-4">
                          <.status_count label="Indicators" value={run.indicators_evaluated} />
                          <.status_count label="Findings" value={run.findings_count} />
                          <.status_count label="Unsupported" value={run.unsupported_count} />
                          <.status_count label="Age" value={run_age_seconds(run)} />
                        </div>
                        <div :if={run.error} class="text-xs text-error">{run.error}</div>
                      </div>
                    <% end %>
                  </div>
                <% end %>

                <div :if={@retrohunt_findings != []} class="mt-4 overflow-x-auto">
                  <table class="table table-sm">
                    <thead>
                      <tr>
                        <th>Observed IP</th>
                        <th>Indicator</th>
                        <th>Direction</th>
                        <th>Evidence</th>
                        <th>Last Seen</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr :for={finding <- @retrohunt_findings}>
                        <td class="font-mono">{finding.observed_ip}</td>
                        <td class="font-mono">{finding.indicator}</td>
                        <td>{finding.direction}</td>
                        <td>{finding.evidence_count}</td>
                        <td>{format_datetime(finding.last_seen_at)}</td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              </div>

              <div class="rounded-xl border border-base-200 bg-base-100 p-4">
                <div class="mb-3 text-sm font-semibold">Imported Indicators</div>
                <%= if @indicators == [] do %>
                  <div class="rounded-lg border border-dashed border-base-300 p-4 text-sm text-base-content/60">
                    No imported indicators.
                  </div>
                <% else %>
                  <div class="overflow-x-auto">
                    <table class="table table-sm">
                      <thead>
                        <tr>
                          <th>Indicator</th>
                          <th>Source</th>
                          <th>Label</th>
                          <th>Confidence</th>
                          <th>Last Seen</th>
                        </tr>
                      </thead>
                      <tbody>
                        <%= for indicator <- @indicators do %>
                          <tr>
                            <td class="font-mono">{indicator.indicator}</td>
                            <td>{indicator.source}</td>
                            <td>{indicator.label || "-"}</td>
                            <td>{format_optional_int(indicator.confidence)}</td>
                            <td>{format_datetime(indicator.last_seen_at)}</td>
                          </tr>
                        <% end %>
                      </tbody>
                    </table>
                  </div>
                <% end %>
              </div>

              <div class="rounded-xl border border-base-200 bg-base-100 p-4">
                <div class="mb-3 text-sm font-semibold">Source Objects</div>
                <%= if @source_objects == [] do %>
                  <div class="rounded-lg border border-dashed border-base-300 p-4 text-sm text-base-content/60">
                    No source object metadata.
                  </div>
                <% else %>
                  <div class="divide-y divide-base-200">
                    <%= for object <- @source_objects do %>
                      <div class="py-3 first:pt-0 last:pb-0">
                        <div class="flex flex-col gap-2 md:flex-row md:items-start md:justify-between">
                          <div class="min-w-0">
                            <div class="truncate font-mono text-sm">{object.object_id}</div>
                            <div class="text-xs text-base-content/60">
                              {object.object_type} · {object.source} · {object.collection_id || "-"}
                            </div>
                          </div>
                          <div class="shrink-0 text-xs text-base-content/60">
                            {format_datetime(object.modified_at)}
                          </div>
                        </div>
                        <div
                          :if={source_object_label(object)}
                          class="mt-2 text-xs text-base-content/70"
                        >
                          {source_object_label(object)}
                        </div>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>
            </div>

            <div class="space-y-4">
              <div class="rounded-xl border border-base-200 bg-base-100 p-4">
                <div class="mb-3 flex items-center justify-between gap-3">
                  <div class="text-sm font-semibold">OTX Settings</div>
                  <.ui_badge :if={otx_api_key_present?(@otx_settings)} size="xs" variant="success">
                    key saved
                  </.ui_badge>
                </div>
                <form
                  id="otx-settings-form"
                  phx-change="settings_change"
                  phx-submit="save_settings"
                  class="space-y-3"
                >
                  <div class="grid grid-cols-2 gap-3">
                    <label class="flex items-center gap-2 text-sm">
                      <input type="hidden" name="settings[otx_enabled]" value="false" />
                      <input
                        type="checkbox"
                        name="settings[otx_enabled]"
                        value="true"
                        class="toggle toggle-sm"
                        checked={@otx_settings_form["otx_enabled"] == "true"}
                      /> OTX enabled
                    </label>
                    <label class="flex items-center gap-2 text-sm">
                      <input
                        type="hidden"
                        name="settings[otx_raw_payload_archive_enabled]"
                        value="false"
                      />
                      <input
                        type="checkbox"
                        name="settings[otx_raw_payload_archive_enabled]"
                        value="true"
                        class="toggle toggle-sm"
                        checked={@otx_settings_form["otx_raw_payload_archive_enabled"] == "true"}
                      /> Raw archive
                    </label>
                  </div>

                  <div>
                    <label class="label">
                      <span class="label-text">Execution Mode</span>
                    </label>
                    <select
                      name="settings[otx_execution_mode]"
                      class="select select-bordered w-full"
                    >
                      <option
                        value="edge_plugin"
                        selected={@otx_settings_form["otx_execution_mode"] == "edge_plugin"}
                      >
                        Edge Plugin
                      </option>
                      <option
                        value="core_worker"
                        selected={@otx_settings_form["otx_execution_mode"] == "core_worker"}
                      >
                        Core Worker
                      </option>
                    </select>
                  </div>

                  <div>
                    <label class="label">
                      <span class="label-text">Core OTX API Key</span>
                    </label>
                    <input
                      type="password"
                      name="settings[otx_api_key]"
                      value=""
                      class="input input-bordered w-full"
                      autocomplete="off"
                      placeholder={
                        if otx_api_key_present?(@otx_settings),
                          do: "Leave blank to keep stored key",
                          else: ""
                      }
                    />
                    <label
                      :if={otx_api_key_present?(@otx_settings)}
                      class="mt-2 flex items-center gap-2 text-xs text-base-content/70"
                    >
                      <input type="hidden" name="settings[clear_otx_api_key]" value="false" />
                      <input
                        type="checkbox"
                        name="settings[clear_otx_api_key]"
                        value="true"
                        class="checkbox checkbox-xs"
                        checked={@otx_settings_form["clear_otx_api_key"] == "true"}
                      /> Clear stored key
                    </label>
                  </div>

                  <div>
                    <label class="label">
                      <span class="label-text">Base URL</span>
                    </label>
                    <input
                      type="url"
                      name="settings[otx_base_url]"
                      value={@otx_settings_form["otx_base_url"]}
                      class="input input-bordered w-full"
                    />
                  </div>

                  <div class="grid grid-cols-2 gap-3">
                    <.number_input
                      name="settings[otx_sync_interval_seconds]"
                      label="Sync Interval"
                      value={@otx_settings_form["otx_sync_interval_seconds"]}
                      min="60"
                    />
                    <.number_input
                      name="settings[threat_intel_match_window_seconds]"
                      label="Match Window"
                      value={@otx_settings_form["threat_intel_match_window_seconds"]}
                      min="60"
                    />
                    <.number_input
                      name="settings[otx_page_size]"
                      label="Page Size"
                      value={@otx_settings_form["otx_page_size"]}
                      min="1"
                    />
                    <.number_input
                      name="settings[otx_timeout_ms]"
                      label="HTTP Timeout"
                      value={@otx_settings_form["otx_timeout_ms"]}
                      min="1000"
                    />
                    <.number_input
                      name="settings[otx_max_indicators]"
                      label="Max IOCs"
                      value={@otx_settings_form["otx_max_indicators"]}
                      min="1"
                    />
                    <.number_input
                      name="settings[otx_retrohunt_window_seconds]"
                      label="Retrohunt Window"
                      value={@otx_settings_form["otx_retrohunt_window_seconds"]}
                      min="3600"
                    />
                  </div>

                  <div>
                    <label class="label">
                      <span class="label-text">Modified Since</span>
                    </label>
                    <input
                      type="text"
                      name="settings[otx_modified_since]"
                      value={@otx_settings_form["otx_modified_since"]}
                      class="input input-bordered w-full"
                    />
                  </div>

                  <div class="flex justify-end pt-2">
                    <button class="btn btn-sm btn-primary" type="submit">Save Settings</button>
                  </div>
                </form>
              </div>

              <div class="rounded-xl border border-base-200 bg-base-100 p-4">
                <div class="mb-3 text-sm font-semibold">OTX Assignment</div>
                <form
                  id="otx-assignment-form"
                  phx-change="assignment_change"
                  phx-submit="save_assignment"
                  class="space-y-3"
                >
                  <div>
                    <label class="label">
                      <span class="label-text">Agent</span>
                    </label>
                    <select
                      name="assignment[agent_uid]"
                      class="select select-bordered w-full"
                      disabled={is_nil(@approved_package)}
                    >
                      <option value="">Select an agent</option>
                      <%= for agent <- @agents do %>
                        <option
                          value={agent.uid}
                          selected={@assignment_form["agent_uid"] == agent.uid}
                        >
                          {agent_label(agent)}
                        </option>
                      <% end %>
                    </select>
                  </div>

                  <div>
                    <label class="label">
                      <span class="label-text">OTX API Key</span>
                    </label>
                    <input
                      type="password"
                      name="assignment[api_key_secret_ref]"
                      value=""
                      class="input input-bordered w-full"
                      autocomplete="off"
                      disabled={is_nil(@approved_package)}
                      placeholder={api_key_placeholder(@assignment_form["agent_uid"], @assignments)}
                    />
                  </div>

                  <div>
                    <label class="label">
                      <span class="label-text">Base URL</span>
                    </label>
                    <input
                      type="url"
                      name="assignment[base_url]"
                      value={@assignment_form["base_url"]}
                      class="input input-bordered w-full"
                      disabled={is_nil(@approved_package)}
                    />
                  </div>

                  <div class="grid grid-cols-2 gap-3">
                    <.number_input
                      name="assignment[interval_seconds]"
                      label="Interval"
                      value={@assignment_form["interval_seconds"]}
                      min="60"
                      disabled={is_nil(@approved_package)}
                    />
                    <.number_input
                      name="assignment[timeout_seconds]"
                      label="Timeout"
                      value={@assignment_form["timeout_seconds"]}
                      min="1"
                      disabled={is_nil(@approved_package)}
                    />
                    <.number_input
                      name="assignment[limit]"
                      label="Page Size"
                      value={@assignment_form["limit"]}
                      min="1"
                      disabled={is_nil(@approved_package)}
                    />
                    <.number_input
                      name="assignment[max_indicators]"
                      label="Max IOCs"
                      value={@assignment_form["max_indicators"]}
                      min="1"
                      disabled={is_nil(@approved_package)}
                    />
                    <.number_input
                      name="assignment[page]"
                      label="Page"
                      value={@assignment_form["page"]}
                      min="1"
                      disabled={is_nil(@approved_package)}
                    />
                    <.number_input
                      name="assignment[timeout_ms]"
                      label="HTTP Timeout"
                      value={@assignment_form["timeout_ms"]}
                      min="1000"
                      disabled={is_nil(@approved_package)}
                    />
                    <.number_input
                      name="assignment[max_pages]"
                      label="Max Pages"
                      value={@assignment_form["max_pages"]}
                      min="1"
                      disabled={is_nil(@approved_package)}
                    />
                  </div>

                  <label class="flex items-center gap-2 text-sm">
                    <input type="hidden" name="assignment[enabled]" value="false" />
                    <input
                      type="checkbox"
                      name="assignment[enabled]"
                      value="true"
                      class="toggle toggle-sm"
                      checked={@assignment_form["enabled"] == "true"}
                      disabled={is_nil(@approved_package)}
                    /> Enabled
                  </label>

                  <div class="flex justify-end pt-2">
                    <button
                      class="btn btn-sm btn-primary"
                      type="submit"
                      disabled={is_nil(@approved_package)}
                    >
                      Save Assignment
                    </button>
                  </div>
                </form>
              </div>
            </div>
          </div>
        </section>
      </.settings_shell>
    </Layouts.app>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :min, :string, default: nil
  attr :disabled, :boolean, default: false

  defp number_input(assigns) do
    ~H"""
    <div>
      <label class="label">
        <span class="label-text">{@label}</span>
      </label>
      <input
        type="number"
        name={@name}
        value={@value}
        min={@min}
        class="input input-bordered w-full"
        disabled={@disabled}
      />
    </div>
    """
  end

  attr :package, PluginPackage, default: nil
  attr :approved_package, PluginPackage, default: nil

  defp package_status(assigns) do
    ~H"""
    <%= cond do %>
      <% @approved_package -> %>
        <.ui_badge size="sm" variant="success">approved {@approved_package.version}</.ui_badge>
      <% @package -> %>
        <.ui_badge size="sm" variant="warning">{@package.status} {@package.version}</.ui_badge>
      <% true -> %>
        <.ui_badge size="sm" variant="ghost">not imported</.ui_badge>
    <% end %>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true

  defp status_count(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-200/70 bg-base-100/60 p-2">
      <div class="text-base-content/50">{@label}</div>
      <div class="font-mono text-sm">{@value}</div>
    </div>
    """
  end

  defp load_page(socket) do
    scope = socket.assigns.current_scope
    packages = Packages.list(%{"plugin_id" => @plugin_id, "limit" => 20}, scope: scope)
    approved_package = Enum.find(packages, &(&1.status == :approved))
    latest_package = List.first(packages)
    otx_settings = load_otx_settings(scope)

    socket
    |> assign(:page_title, "Threat Intel")
    |> assign(:plugin_id, @plugin_id)
    |> assign(:agents, list_agents(scope))
    |> assign(:packages, packages)
    |> assign(:latest_package, latest_package)
    |> assign(:approved_package, approved_package)
    |> assign(:assignments, list_assignments(approved_package, scope))
    |> assign(:sync_statuses, list_sync_statuses(scope))
    |> assign(:retrohunt_runs, list_retrohunt_runs(scope))
    |> assign(:retrohunt_findings, list_retrohunt_findings(scope))
    |> assign(:netflow_findings, netflow_findings_summary(scope))
    |> assign(:indicators, list_indicators(scope))
    |> assign(:source_objects, list_source_objects(scope))
    |> assign(:otx_settings, otx_settings)
    |> assign(:otx_settings_form, otx_settings_to_form(otx_settings))
    |> assign(:assignment_form, @default_form)
  end

  defp save_otx_settings(socket, scope, params) do
    settings = socket.assigns.otx_settings || load_otx_settings(scope)
    attrs = build_otx_settings_attrs(params)

    result =
      case settings do
        %NetflowSettings{} = record ->
          record
          |> Ash.Changeset.for_update(:update, attrs)
          |> Ash.update(scope: scope)

        _ ->
          NetflowSettings
          |> Ash.Changeset.for_create(:create, attrs)
          |> Ash.create(scope: scope)
      end

    case result do
      {:ok, %NetflowSettings{} = _updated} ->
        reloaded = load_otx_settings(scope)

        {:noreply,
         socket
         |> put_flash(:info, "Saved OTX settings")
         |> assign(:otx_settings, reloaded)
         |> assign(:otx_settings_form, otx_settings_to_form(reloaded))}

      {:error, error} ->
        Logger.warning("Threat intel settings save failed", error: inspect(error))
        {:noreply, put_flash(socket, :error, "Failed to save OTX settings")}
    end
  end

  defp reload_assignments(socket) do
    assign(
      socket,
      :assignments,
      list_assignments(socket.assigns.approved_package, socket.assigns.current_scope)
    )
  end

  defp create_assignment(socket, scope, attrs) do
    case Assignments.create(attrs, scope: scope) do
      {:ok, _assignment} ->
        {:noreply,
         socket
         |> reload_assignments()
         |> assign(:assignment_form, @default_form)
         |> put_flash(:info, "Assignment saved")}

      {:error, error} ->
        Logger.warning("Threat intel assignment creation failed", error: inspect(error))
        {:noreply, put_flash(socket, :error, "Failed to save assignment")}
    end
  end

  defp update_assignment(socket, scope, assignment, attrs) do
    update_attrs =
      attrs
      |> Map.delete(:agent_uid)
      |> Map.delete(:plugin_package_id)

    case Assignments.update(assignment.id, update_attrs, scope: scope) do
      {:ok, _assignment} ->
        {:noreply,
         socket
         |> reload_assignments()
         |> assign(:assignment_form, @default_form)
         |> put_flash(:info, "Assignment saved")}

      {:error, error} ->
        Logger.warning("Threat intel assignment update failed",
          id: assignment.id,
          error: inspect(error)
        )

        {:noreply, put_flash(socket, :error, "Failed to save assignment")}
    end
  end

  defp list_agents(scope) do
    Agent
    |> Ash.Query.for_read(:read)
    |> Ash.Query.limit(200)
    |> Ash.Query.sort(name: :asc)
    |> Ash.read!(scope: scope)
  rescue
    _ -> []
  end

  defp list_assignments(nil, _scope), do: []

  defp list_assignments(%PluginPackage{id: package_id}, scope) do
    Assignments.list(%{"plugin_package_id" => package_id, "limit" => 200}, scope: scope)
  end

  defp list_sync_statuses(scope) do
    ThreatIntelSyncStatus
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(source == "alienvault_otx" or plugin_id == ^@plugin_id)
    |> Ash.Query.limit(20)
    |> Ash.Query.sort(last_attempt_at: :desc)
    |> Ash.read!(scope: scope)
  rescue
    _ -> []
  end

  defp list_retrohunt_runs(scope) do
    OTXRetrohuntRun
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(source == "alienvault_otx")
    |> Ash.Query.limit(6)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.read!(scope: scope)
  rescue
    error ->
      Logger.debug("Failed to load OTX retrohunt runs", error: inspect(error))
      []
  end

  defp list_retrohunt_findings(scope) do
    OTXRetrohuntFinding
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(source == "alienvault_otx")
    |> Ash.Query.limit(12)
    |> Ash.Query.sort(last_seen_at: :desc)
    |> Ash.read!(scope: scope)
  rescue
    error ->
      Logger.debug("Failed to load OTX retrohunt findings", error: inspect(error))
      []
  end

  defp list_indicators(scope) do
    ThreatIntelIndicator
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(source == "alienvault_otx")
    |> Ash.Query.limit(25)
    |> Ash.Query.sort(last_seen_at: :desc)
    |> Ash.read!(scope: scope)
  rescue
    _ -> []
  end

  defp list_source_objects(scope) do
    ThreatIntelSourceObject
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(source == "alienvault_otx" or provider == "alienvault_otx")
    |> Ash.Query.limit(20)
    |> Ash.Query.sort(modified_at: :desc)
    |> Ash.read!(scope: scope)
  rescue
    _ -> []
  end

  defp load_otx_settings(scope) do
    result =
      NetflowSettings
      |> Ash.Query.for_read(:get_singleton)
      |> Ash.read_one(scope: scope)

    case result do
      {:ok, %NetflowSettings{} = settings} ->
        settings

      _ ->
        nil
    end
  rescue
    error ->
      Logger.debug("Failed to load OTX settings", error: inspect(error))
      nil
  end

  defp otx_settings_to_form(nil), do: @default_settings_form

  defp otx_settings_to_form(%NetflowSettings{} = settings) do
    %{
      "otx_enabled" => settings.otx_enabled |> truthy() |> to_string(),
      "otx_execution_mode" => settings.otx_execution_mode || "edge_plugin",
      "otx_base_url" => settings.otx_base_url || "https://otx.alienvault.com",
      "otx_api_key" => "",
      "clear_otx_api_key" => "false",
      "otx_sync_interval_seconds" => to_string(settings.otx_sync_interval_seconds || 3_600),
      "otx_page_size" => to_string(settings.otx_page_size || 10),
      "otx_timeout_ms" => to_string(settings.otx_timeout_ms || 60_000),
      "otx_max_indicators" => to_string(settings.otx_max_indicators || 2_000),
      "otx_modified_since" => settings.otx_modified_since || "",
      "otx_raw_payload_archive_enabled" => settings.otx_raw_payload_archive_enabled |> truthy() |> to_string(),
      "otx_retrohunt_window_seconds" => to_string(settings.otx_retrohunt_window_seconds || 7_776_000),
      "threat_intel_match_window_seconds" => to_string(settings.threat_intel_match_window_seconds || 3_600)
    }
  end

  defp build_otx_settings_attrs(params) when is_map(params) do
    attrs = %{
      otx_enabled: truthy_param?(Map.get(params, "otx_enabled")),
      otx_execution_mode: normalize_execution_mode(Map.get(params, "otx_execution_mode")),
      otx_base_url:
        params
        |> Map.get("otx_base_url", "https://otx.alienvault.com")
        |> to_string()
        |> String.trim(),
      otx_sync_interval_seconds: to_int(Map.get(params, "otx_sync_interval_seconds"), 3_600),
      otx_page_size: clamp_int(Map.get(params, "otx_page_size"), 10, 1, 100),
      otx_timeout_ms: to_int(Map.get(params, "otx_timeout_ms"), 60_000),
      otx_max_indicators: clamp_int(Map.get(params, "otx_max_indicators"), 2_000, 1, 5_000),
      otx_modified_since: blank_to_nil(Map.get(params, "otx_modified_since")),
      otx_raw_payload_archive_enabled: truthy_param?(Map.get(params, "otx_raw_payload_archive_enabled")),
      otx_retrohunt_window_seconds: to_int(Map.get(params, "otx_retrohunt_window_seconds"), 7_776_000),
      threat_intel_match_window_seconds: to_int(Map.get(params, "threat_intel_match_window_seconds"), 3_600),
      clear_otx_api_key: truthy_param?(Map.get(params, "clear_otx_api_key"))
    }

    case blank_to_nil(Map.get(params, "otx_api_key")) do
      nil -> attrs
      api_key -> Map.put(attrs, :otx_api_key, api_key)
    end
  end

  defp build_otx_settings_attrs(_params), do: %{}

  defp netflow_findings_summary(scope) do
    now = DateTime.utc_now()

    findings =
      IpThreatIntelCache
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(matched == true and expires_at > ^now)
      |> Ash.Query.limit(200)
      |> Ash.Query.sort(looked_up_at: :desc)
      |> Ash.read!(scope: scope)

    %{
      matched_ips: length(findings),
      indicator_matches: Enum.reduce(findings, 0, &(&2 + normalize_int(&1.match_count))),
      max_severity: max_threat_severity(findings),
      sources:
        findings
        |> Enum.flat_map(&List.wrap(&1.sources))
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.uniq()
        |> Enum.sort(),
      recent: Enum.take(findings, 8)
    }
  rescue
    error ->
      Logger.debug("Failed to load threat intel NetFlow finding summary", error: inspect(error))

      %{
        matched_ips: 0,
        indicator_matches: 0,
        max_severity: nil,
        sources: [],
        recent: []
      }
  end

  defp max_threat_severity(findings) do
    findings
    |> Enum.map(& &1.max_severity)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      severities -> Enum.max(severities)
    end
  end

  defp parse_assignment(params, package) when is_map(params) do
    with {:ok, agent_uid} <- required_string(params["agent_uid"], "Agent is required"),
         {:ok, interval_seconds} <- parse_positive_int(params["interval_seconds"], 3600),
         {:ok, timeout_seconds} <- parse_positive_int(params["timeout_seconds"], 60),
         {:ok, params_map} <- parse_plugin_params(params, package.config_schema || %{}) do
      {:ok,
       %{
         agent_uid: agent_uid,
         plugin_package_id: package.id,
         enabled: params["enabled"] == "true",
         interval_seconds: interval_seconds,
         timeout_seconds: timeout_seconds,
         params: params_map
       }}
    end
  end

  defp parse_plugin_params(params, config_schema) do
    raw =
      %{
        "base_url" => params["base_url"],
        "api_key_secret_ref" => params["api_key_secret_ref"],
        "limit" => params["limit"],
        "page" => params["page"],
        "timeout_ms" => params["timeout_ms"],
        "max_pages" => params["max_pages"],
        "max_indicators" => params["max_indicators"]
      }
      |> Enum.reject(fn
        {_key, nil} -> true
        {_key, value} when is_binary(value) -> String.trim(value) == ""
        _ -> false
      end)
      |> Map.new(fn {key, value} -> {key, trim_string(value)} end)

    {:ok, ConfigSchema.normalize_params(stringify_keys(config_schema), raw)}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp required_string(value, message) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, message}
      trimmed -> {:ok, trimmed}
    end
  end

  defp required_string(_value, message), do: {:error, message}

  defp parse_positive_int(value, default) do
    value = trim_string(value)

    case Integer.parse(value || "") do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ when is_integer(default) and default > 0 -> {:ok, default}
      _ -> {:error, "Expected a positive integer"}
    end
  end

  defp trim_string(value) when is_binary(value), do: String.trim(value)
  defp trim_string(value), do: value

  defp stringify_keys(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp existing_assignment(assignments, agent_uid) do
    Enum.find(assignments, &(&1.agent_uid == agent_uid))
  end

  defp agent_label(agent) do
    cond do
      is_binary(agent.name) and agent.name != "" -> "#{agent.name} (#{agent.uid})"
      is_binary(agent.host) and agent.host != "" -> "#{agent.host} (#{agent.uid})"
      true -> agent.uid
    end
  end

  defp api_key_placeholder(agent_uid, assignments) do
    if is_binary(agent_uid) and existing_assignment(assignments, agent_uid) do
      "Leave blank to keep stored key"
    else
      ""
    end
  end

  defp status_agent_label(%ThreatIntelSyncStatus{} = status) do
    cond do
      status.agent_id != "" -> status.agent_id
      status.plugin_id != "" -> status.plugin_id
      true -> status.source
    end
  end

  defp status_badge_variant(status) when status in ["ok", "success"], do: "success"
  defp status_badge_variant(status) when status in ["warn", "warning"], do: "warning"
  defp status_badge_variant(status) when status in ["critical", "error", "failed"], do: "error"
  defp status_badge_variant(_status), do: "ghost"

  defp otx_api_key_present?(%NetflowSettings{otx_api_key_present: true}), do: true
  defp otx_api_key_present?(_settings), do: false

  defp skipped_by_type(%ThreatIntelSyncStatus{metadata: %{} = metadata}) do
    metadata
    |> Map.get("skipped_by_type", %{})
    |> case do
      %{} = counts ->
        counts
        |> Enum.map(fn {type, count} -> {to_string(type), normalize_int(count)} end)
        |> Enum.reject(fn {_type, count} -> count <= 0 end)
        |> Enum.sort_by(fn {type, _count} -> type end)

      _ ->
        []
    end
  end

  defp skipped_by_type(_status), do: []

  defp format_datetime(nil), do: "-"
  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_datetime(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_datetime(value), do: to_string(value)

  defp format_optional_int(nil), do: "-"
  defp format_optional_int(value), do: to_string(value)

  defp run_age_seconds(%OTXRetrohuntRun{started_at: %DateTime{} = started_at, finished_at: %DateTime{} = finished_at}) do
    max(DateTime.diff(finished_at, started_at, :second), 0)
  end

  defp run_age_seconds(%OTXRetrohuntRun{started_at: %DateTime{} = started_at}) do
    max(DateTime.diff(DateTime.utc_now(), started_at, :second), 0)
  end

  defp run_age_seconds(_run), do: 0

  defp truthy(true), do: true
  defp truthy("true"), do: true
  defp truthy("1"), do: true
  defp truthy(_), do: false

  defp truthy_param?(true), do: true
  defp truthy_param?("true"), do: true
  defp truthy_param?("1"), do: true
  defp truthy_param?("on"), do: true
  defp truthy_param?(_), do: false

  defp normalize_int(value) when is_integer(value), do: value
  defp normalize_int(_value), do: 0

  defp to_int(value, _default) when is_integer(value) and value > 0, do: value

  defp to_int(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp to_int(_value, default), do: default

  defp clamp_int(value, default, min, max) do
    value
    |> to_int(default)
    |> Kernel.max(min)
    |> Kernel.min(max)
  end

  defp normalize_execution_mode(value) when value in ["edge_plugin", "core_worker"], do: value
  defp normalize_execution_mode(_value), do: "edge_plugin"

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  defp source_object_label(%ThreatIntelSourceObject{metadata: metadata}) when is_map(metadata) do
    metadata["name"] || metadata["label"] || metadata["source_context"]
  end

  defp source_object_label(_object), do: nil

  defp format_error(value) when is_binary(value), do: value
  defp format_error(value), do: inspect(value)
end
