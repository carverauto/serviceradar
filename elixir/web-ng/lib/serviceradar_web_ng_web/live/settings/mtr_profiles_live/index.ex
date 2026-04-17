defmodule ServiceRadarWebNGWeb.Settings.MtrProfilesLive.Index do
  @moduledoc """
  LiveView for MTR automation profiles.
  """
  use ServiceRadarWebNGWeb, :live_view

  import Ash.Expr
  import ServiceRadarWebNGWeb.QueryBuilderComponents
  import ServiceRadarWebNGWeb.SettingsComponents

  alias ServiceRadar.AgentRegistry
  alias ServiceRadar.Edge.AgentCommand
  alias ServiceRadar.Observability.MtrPolicy
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.SRQL.Catalog

  require Ash.Query

  @command_type_mtr_bulk_run "mtr.bulk_run"
  @protocol_icmp "icmp"
  @protocol_udp "udp"
  @protocol_tcp "tcp"
  @protocols [@protocol_icmp, @protocol_udp, @protocol_tcp]
  @execution_profile_fast "fast"
  @execution_profile_balanced "balanced"
  @execution_profile_deep "deep"
  @execution_profiles [
    @execution_profile_fast,
    @execution_profile_balanced,
    @execution_profile_deep
  ]
  @selector_query_key "srql_query"
  @selector_limit_key "limit"
  @selector_agent_id_key "agent_id"
  @selector_execution_profile_key "bulk_execution_profile"
  @payload_targets_key "targets"
  @payload_total_targets_key "total_targets"
  @payload_timed_out_targets_key "timed_out_targets"
  @payload_targets_per_minute_key "targets_per_minute"
  @payload_concurrency_key "concurrency"
  @payload_max_concurrency_key "max_concurrency"
  @payload_concurrency_history_key "concurrency_history"

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "settings.networks.manage") do
      {:ok,
       socket
       |> assign(:page_title, "MTR Automation")
       |> assign(:current_path, "/settings/networks/mtr")
       |> assign(:profiles, load_profiles(scope))
       |> assign(:show_form, nil)
       |> assign(:selected_profile, nil)
       |> assign(:form, nil)
       |> assign(:target_device_count, nil)
       |> assign(:bulk_interval_guidance, nil)
       |> assign(:agents, list_connected_agents())
       |> assign(:builder_open, false)
       |> assign(:builder, default_builder_state())
       |> assign(:builder_sync, true)}
    else
      {:ok,
       socket
       |> put_flash(:error, "You do not have access to MTR automation settings")
       |> push_navigate(to: ~p"/settings/profile")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "MTR Automation")
    |> assign(:show_form, nil)
    |> assign(:selected_profile, nil)
    |> assign(:form, nil)
    |> assign(:target_device_count, nil)
    |> assign(:bulk_interval_guidance, nil)
    |> assign(:builder_open, false)
    |> assign(:builder, default_builder_state())
    |> assign(:builder_sync, true)
  end

  defp apply_action(socket, :new_profile, _params) do
    defaults = default_form_params()

    socket
    |> assign(:page_title, "New MTR Automation Profile")
    |> assign(:show_form, :new_profile)
    |> assign(:selected_profile, nil)
    |> assign(:form, to_form(defaults, as: :form))
    |> assign(
      :target_device_count,
      count_target_devices(socket.assigns.current_scope, defaults[@selector_query_key])
    )
    |> assign(:builder_open, false)
    |> assign(:builder, default_builder_state())
    |> assign(:builder_sync, true)
    |> assign(:agents, list_connected_agents())
    |> assign(
      :bulk_interval_guidance,
      bulk_interval_guidance(
        socket.assigns.current_scope,
        defaults["preferred_agent_id"],
        defaults[@selector_execution_profile_key],
        count_target_devices(socket.assigns.current_scope, defaults[@selector_query_key]),
        defaults["baseline_interval_sec"]
      )
    )
  end

  defp apply_action(socket, :edit_profile, %{"id" => id}) do
    scope = socket.assigns.current_scope

    case Ash.get(MtrPolicy, id, scope: scope) do
      {:ok, profile} ->
        params = profile_to_form_params(profile)
        {builder, builder_sync} = parse_target_query_to_builder(params[@selector_query_key])

        socket
        |> assign(:page_title, "Edit #{profile.name}")
        |> assign(:show_form, :edit_profile)
        |> assign(:selected_profile, profile)
        |> assign(:form, to_form(params, as: :form))
        |> assign(:target_device_count, count_target_devices(scope, params[@selector_query_key]))
        |> assign(
          :bulk_interval_guidance,
          bulk_interval_guidance(
            scope,
            params["preferred_agent_id"],
            params[@selector_execution_profile_key],
            count_target_devices(scope, params[@selector_query_key]),
            params["baseline_interval_sec"]
          )
        )
        |> assign(:builder_open, false)
        |> assign(:builder, builder)
        |> assign(:builder_sync, builder_sync)
        |> assign(:agents, list_connected_agents())

      {:error, _} ->
        socket
        |> put_flash(:error, "MTR profile not found")
        |> push_navigate(to: ~p"/settings/networks/mtr")
    end
  end

  @impl true
  def handle_event("validate_profile", %{"form" => params}, socket) do
    query = normalize_target_query(Map.get(params, @selector_query_key))
    params = Map.put(params, @selector_query_key, query || "")
    {parsed_builder, builder_sync} = parse_target_query_to_builder(query)

    socket =
      socket
      |> assign(:form, to_form(params, as: :form))
      |> assign(:target_device_count, count_target_devices(socket.assigns.current_scope, query))
      |> assign(
        :bulk_interval_guidance,
        bulk_interval_guidance(
          socket.assigns.current_scope,
          Map.get(params, "preferred_agent_id"),
          Map.get(params, @selector_execution_profile_key),
          count_target_devices(socket.assigns.current_scope, query),
          Map.get(params, "baseline_interval_sec")
        )
      )
      |> assign(:builder_sync, builder_sync)

    socket =
      if builder_sync do
        assign(socket, :builder, parsed_builder)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("save_profile", %{"form" => params}, socket) do
    scope = socket.assigns.current_scope
    query = normalize_target_query(Map.get(params, @selector_query_key))
    selector_limit = parse_int(Map.get(params, @selector_limit_key), 100, 1)
    preferred_agent_id = blank_to_nil(Map.get(params, "preferred_agent_id"))

    bulk_execution_profile =
      normalize_bulk_execution_profile(Map.get(params, @selector_execution_profile_key))

    target_selector =
      maybe_put(
        %{
          @selector_query_key => query || "in:devices",
          @selector_limit_key => selector_limit,
          @selector_execution_profile_key => bulk_execution_profile
        },
        @selector_agent_id_key,
        preferred_agent_id
      )

    attrs = %{
      name: String.trim(Map.get(params, "name", "")),
      enabled: parse_bool(Map.get(params, "enabled"), true),
      scope: "managed_devices",
      partition_id: blank_to_nil(Map.get(params, "partition_id")),
      target_selector: target_selector,
      baseline_interval_sec: parse_int(Map.get(params, "baseline_interval_sec"), 300, 30),
      baseline_protocol: normalize_protocol(Map.get(params, "baseline_protocol")),
      baseline_canary_vantages: parse_int(Map.get(params, "baseline_canary_vantages"), 0, 0),
      incident_fanout_max_agents: parse_int(Map.get(params, "incident_fanout_max_agents"), 3, 1),
      incident_cooldown_sec: parse_int(Map.get(params, "incident_cooldown_sec"), 600, 30),
      recovery_capture: parse_bool(Map.get(params, "recovery_capture"), true),
      consensus_mode: normalize_consensus_mode(Map.get(params, "consensus_mode")),
      consensus_threshold: parse_float(Map.get(params, "consensus_threshold"), 0.66, 0.0, 1.0),
      consensus_min_agents: parse_int(Map.get(params, "consensus_min_agents"), 2, 1)
    }

    case save_profile(socket.assigns.show_form, socket.assigns.selected_profile, attrs, scope) do
      {:ok, _profile} ->
        {:noreply,
         socket
         |> assign(:profiles, load_profiles(scope))
         |> put_flash(:info, "MTR automation profile saved")
         |> push_navigate(to: ~p"/settings/networks/mtr")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:form, to_form(params, as: :form))
         |> put_flash(:error, "Failed to save MTR profile: #{format_error(reason)}")}
    end
  end

  def handle_event("toggle_profile", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    with {:ok, profile} <- Ash.get(MtrPolicy, id, scope: scope),
         {:ok, _} <- MtrPolicy.update_policy(profile, %{enabled: !profile.enabled}, scope: scope) do
      {:noreply, assign(socket, :profiles, load_profiles(scope))}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to update profile: #{format_error(reason)}")}
    end
  end

  def handle_event("delete_profile", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    with {:ok, profile} <- Ash.get(MtrPolicy, id, scope: scope),
         :ok <- Ash.destroy(profile, scope: scope) do
      {:noreply,
       socket
       |> assign(:profiles, load_profiles(scope))
       |> put_flash(:info, "MTR profile deleted")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete profile: #{format_error(reason)}")}
    end
  end

  def handle_event("builder_toggle", _params, socket) do
    builder_open = !socket.assigns.builder_open

    socket =
      if builder_open do
        params = socket.assigns.form.params || %{}
        target_query = Map.get(params, @selector_query_key, "")
        {builder, builder_sync} = parse_target_query_to_builder(target_query)

        socket
        |> assign(:builder_open, true)
        |> assign(:builder, builder)
        |> assign(:builder_sync, builder_sync)
      else
        assign(socket, :builder_open, false)
      end

    {:noreply, socket}
  end

  def handle_event("builder_change", %{"builder" => builder_params}, socket) do
    builder = update_builder(socket.assigns.builder, builder_params)

    {:noreply,
     socket
     |> assign(:builder, builder)
     |> assign(:builder_sync, true)
     |> maybe_sync_builder_to_form()}
  end

  def handle_event("builder_add_filter", _params, socket) do
    config = Catalog.entity("devices")
    filters = Map.get(socket.assigns.builder, "filters", [])

    next = %{"field" => config.default_filter_field, "op" => "contains", "value" => ""}
    builder = Map.put(socket.assigns.builder, "filters", filters ++ [next])

    {:noreply,
     socket
     |> assign(:builder, builder)
     |> assign(:builder_sync, true)
     |> maybe_sync_builder_to_form()}
  end

  def handle_event("builder_remove_filter", %{"idx" => idx_str}, socket) do
    index =
      case Integer.parse(idx_str) do
        {i, ""} -> i
        _ -> -1
      end

    filters =
      socket.assigns.builder
      |> Map.get("filters", [])
      |> Enum.with_index()
      |> Enum.reject(fn {_f, i} -> i == index end)
      |> Enum.map(fn {f, _i} -> f end)

    builder = Map.put(socket.assigns.builder, "filters", filters)

    {:noreply,
     socket
     |> assign(:builder, builder)
     |> assign(:builder_sync, true)
     |> maybe_sync_builder_to_form()}
  end

  def handle_event("builder_apply", _params, socket) do
    query = build_target_query(socket.assigns.builder)
    params = socket.assigns.form.params || %{}
    params = Map.put(params, @selector_query_key, query)

    {:noreply,
     socket
     |> assign(:form, to_form(params, as: :form))
     |> assign(:builder_sync, true)
     |> assign(:target_device_count, count_target_devices(socket.assigns.current_scope, query))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.settings_shell current_path={@current_path}>
        <.settings_nav current_path={@current_path} current_scope={@current_scope} />
        <.network_nav current_path={@current_path} current_scope={@current_scope} />

        <%= if @show_form in [:new_profile, :edit_profile] do %>
          <.profile_form
            form={@form}
            show_form={@show_form}
            selected_profile={@selected_profile}
            target_device_count={@target_device_count}
            builder_open={@builder_open}
            builder={@builder}
            builder_sync={@builder_sync}
            agents={@agents}
            bulk_interval_guidance={@bulk_interval_guidance}
          />
        <% else %>
          <.profiles_table profiles={@profiles} />
        <% end %>
      </.settings_shell>
    </Layouts.app>
    """
  end

  attr(:profiles, :list, required: true)

  defp profiles_table(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div class="flex w-full items-center justify-between">
          <div class="text-sm font-semibold">MTR Automation Profiles</div>
          <.link navigate={~p"/settings/networks/mtr/new"}>
            <.ui_button variant="primary" size="sm">
              <.icon name="hero-plus" class="size-4" /> New Profile
            </.ui_button>
          </.link>
        </div>
      </:header>

      <div class="overflow-x-auto">
        <table class="table table-sm table-zebra">
          <thead>
            <tr>
              <th>Name</th>
              <th>Scope Query</th>
              <th>Preferred Agent</th>
              <th>Protocol</th>
              <th>Baseline</th>
              <th>Incident Fanout</th>
              <th>Status</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={profile <- @profiles}>
              <td class="font-medium">{profile.name}</td>
              <td class="font-mono text-xs max-w-[280px] truncate" title={selector_query(profile)}>
                {selector_query(profile)}
              </td>
              <td class="font-mono text-xs">{selector_agent(profile) || "-"}</td>
              <td>{String.upcase(profile.baseline_protocol || @protocol_icmp)}</td>
              <td>{profile.baseline_interval_sec}s</td>
              <td>{profile.incident_fanout_max_agents}</td>
              <td>
                <span class={[
                  "badge badge-sm",
                  if(profile.enabled, do: "badge-success", else: "badge-ghost")
                ]}>
                  {if profile.enabled, do: "ENABLED", else: "DISABLED"}
                </span>
              </td>
              <td>
                <div class="flex items-center gap-1">
                  <button
                    type="button"
                    class="btn btn-xs btn-ghost"
                    phx-click="toggle_profile"
                    phx-value-id={profile.id}
                  >
                    {if profile.enabled, do: "Disable", else: "Enable"}
                  </button>
                  <.link
                    navigate={~p"/settings/networks/mtr/#{profile.id}/edit"}
                    class="btn btn-xs btn-ghost"
                  >
                    Edit
                  </.link>
                  <button
                    type="button"
                    class="btn btn-xs btn-ghost text-error"
                    phx-click="delete_profile"
                    phx-value-id={profile.id}
                    data-confirm="Delete this MTR profile?"
                  >
                    Delete
                  </button>
                </div>
              </td>
            </tr>
            <tr :if={@profiles == []}>
              <td colspan="8" class="text-center py-8 text-base-content/50">
                No MTR automation profiles configured yet.
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </.ui_panel>
    """
  end

  attr(:form, :map, required: true)
  attr(:show_form, :atom, required: true)
  attr(:selected_profile, :any, default: nil)
  attr(:target_device_count, :any, default: nil)
  attr(:builder_open, :boolean, default: false)
  attr(:builder, :map, default: %{})
  attr(:builder_sync, :boolean, default: true)
  attr(:agents, :list, default: [])
  attr(:bulk_interval_guidance, :any, default: nil)

  defp profile_form(assigns) do
    config = Catalog.entity("devices")
    assigns = assign(assigns, :config, config)

    ~H"""
    <.ui_panel>
      <:header>
        <div class="text-sm font-semibold">
          {if @show_form == :new_profile,
            do: "New MTR Automation Profile",
            else: "Edit #{@selected_profile.name}"}
        </div>
      </:header>

      <form id="mtr-builder-form" phx-change="builder_change" phx-debounce="200"></form>

      <.form for={@form} phx-change="validate_profile" phx-submit="save_profile" class="space-y-6">
        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <div>
            <label class="label"><span class="label-text">Profile Name</span></label>
            <.input type="text" field={@form[:name]} class="input input-bordered w-full" required />
          </div>
          <label class="flex items-center gap-2 mt-8 cursor-pointer">
            <.input
              type="checkbox"
              field={@form[:enabled]}
              class="checkbox checkbox-sm checkbox-primary"
            />
            <span class="label-text">Enabled</span>
          </label>
        </div>

        <div class="space-y-4">
          <h3 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
            Device Scope
          </h3>
          <div>
            <label class="label"><span class="label-text">Target Query (SRQL)</span></label>
            <div class="flex items-center gap-2">
              <div class="flex-1">
                <.input
                  type="text"
                  field={@form[:target_query]}
                  class="input input-bordered w-full font-mono text-sm"
                  placeholder="in:devices tags.role:edge"
                />
              </div>
              <.ui_icon_button
                active={@builder_open}
                aria-label="Toggle query builder"
                phx-click="builder_toggle"
              >
                <.icon name="hero-adjustments-horizontal" class="size-4" />
              </.ui_icon_button>
            </div>
          </div>

          <div :if={@builder_open} class="border border-base-200 rounded-lg p-4 bg-base-100/50">
            <div class="flex items-center justify-between mb-4">
              <div class="text-sm font-semibold">Query Builder</div>
              <div class="flex items-center gap-2">
                <.ui_badge :if={not @builder_sync} size="sm">Not applied</.ui_badge>
                <.ui_button
                  :if={not @builder_sync}
                  size="sm"
                  variant="ghost"
                  type="button"
                  phx-click="builder_apply"
                >
                  Apply to query
                </.ui_button>
              </div>
            </div>

            <div class="flex flex-col gap-3">
              <%= for {filter, idx} <- Enum.with_index(Map.get(@builder, "filters", [])) do %>
                <div class="flex items-center gap-3">
                  <.query_builder_pill label="Filter">
                    <.ui_inline_select
                      name={"builder[filters][#{idx}][field]"}
                      form="mtr-builder-form"
                    >
                      <%= for field <- @config.filter_fields do %>
                        <option value={field} selected={filter["field"] == field}>{field}</option>
                      <% end %>
                    </.ui_inline_select>
                    <.ui_inline_select name={"builder[filters][#{idx}][op]"} form="mtr-builder-form">
                      <option value="contains" selected={(filter["op"] || "contains") == "contains"}>
                        contains
                      </option>
                      <option value="not_contains" selected={filter["op"] == "not_contains"}>
                        does not contain
                      </option>
                      <option value="equals" selected={filter["op"] == "equals"}>equals</option>
                      <option value="not_equals" selected={filter["op"] == "not_equals"}>
                        does not equal
                      </option>
                    </.ui_inline_select>
                    <.ui_inline_input
                      type="text"
                      name={"builder[filters][#{idx}][value]"}
                      value={filter["value"] || ""}
                      form="mtr-builder-form"
                      class="w-48"
                    />
                  </.query_builder_pill>

                  <.ui_icon_button
                    size="xs"
                    phx-click="builder_remove_filter"
                    phx-value-idx={idx}
                    aria-label="Remove filter"
                  >
                    <.icon name="hero-x-mark" class="size-4" />
                  </.ui_icon_button>
                </div>
              <% end %>

              <button
                type="button"
                class="inline-flex items-center gap-2 rounded-md border border-dashed border-primary/40 px-3 py-2 text-sm text-primary/80 hover:bg-primary/5 w-fit"
                phx-click="builder_add_filter"
              >
                <.icon name="hero-plus" class="size-4" /> Add filter
              </button>
            </div>
          </div>

          <div :if={@target_device_count != nil} class="text-sm">
            <span class="font-semibold">{@target_device_count}</span>
            <span class="text-base-content/60">device(s) currently match this query</span>
          </div>

          <div
            :if={@bulk_interval_guidance}
            class={[
              "rounded-lg border px-3 py-3 text-sm",
              if(@bulk_interval_guidance.warning?,
                do: "border-warning/40 bg-warning/10",
                else: "border-success/30 bg-success/10"
              )
            ]}
          >
            <div class="font-semibold">
              Bulk baseline guidance for {@bulk_interval_guidance.agent_id} ({String.upcase(
                @bulk_interval_guidance.execution_profile
              )})
            </div>
            <div class="text-base-content/70 mt-1">
              Measured throughput: {@bulk_interval_guidance.targets_per_minute} targets/min
            </div>
            <div class="text-base-content/70">
              Effective concurrency: {@bulk_interval_guidance.effective_concurrency}
            </div>
            <div :if={@bulk_interval_guidance.timeout_ratio_percent > 0} class="text-base-content/70">
              Avg timeout ratio: {@bulk_interval_guidance.timeout_ratio_percent}%
            </div>
            <div class="text-base-content/70">
              Estimated runtime for current scope: {@bulk_interval_guidance.estimated_duration_sec}s
            </div>
            <div class="text-base-content/70">
              Recommended minimum interval: {@bulk_interval_guidance.recommended_interval_sec}s
            </div>
            <div
              :if={@bulk_interval_guidance.throttled_runs > 0}
              class="text-base-content/70"
            >
              Adaptive backoff observed in {@bulk_interval_guidance.throttled_runs}/{@bulk_interval_guidance.sample_count} recent runs.
            </div>
            <div :if={@bulk_interval_guidance.warning?} class="mt-2 font-medium text-warning-content">
              Configured interval is tighter than the measured recommendation and is likely to overlap.
            </div>
            <div :if={!@bulk_interval_guidance.warning?} class="mt-2 font-medium text-success-content">
              Configured interval leaves headroom relative to measured throughput.
            </div>
          </div>
        </div>

        <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
          <div>
            <label class="label"><span class="label-text">Selector Limit</span></label>
            <.input
              type="number"
              field={@form[:selector_limit]}
              class="input input-bordered w-full"
              min="1"
            />
          </div>
          <div>
            <label class="label"><span class="label-text">Preferred Agent</span></label>
            <.input
              type="select"
              field={@form[:preferred_agent_id]}
              class="select select-bordered w-full"
              options={[
                {"Auto-select by policy", ""} | Enum.map(@agents, &{agent_label(&1), agent_id(&1)})
              ]}
            />
          </div>
          <div>
            <label class="label"><span class="label-text">Partition (optional)</span></label>
            <.input
              type="text"
              field={@form[:partition_id]}
              class="input input-bordered w-full"
              placeholder="default"
            />
          </div>
        </div>

        <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
          <div>
            <label class="label"><span class="label-text">Protocol</span></label>
            <.input
              type="select"
              field={@form[:baseline_protocol]}
              class="select select-bordered w-full"
              options={[{"ICMP", @protocol_icmp}, {"UDP", @protocol_udp}, {"TCP", @protocol_tcp}]}
            />
          </div>
          <div>
            <label class="label"><span class="label-text">Bulk Execution Profile</span></label>
            <.input
              type="select"
              field={@form[:bulk_execution_profile]}
              class="select select-bordered w-full"
              options={[
                {"Fast", @execution_profile_fast},
                {"Balanced", @execution_profile_balanced},
                {"Deep", @execution_profile_deep}
              ]}
            />
          </div>
          <div>
            <label class="label"><span class="label-text">Baseline Interval (sec)</span></label>
            <.input
              type="number"
              field={@form[:baseline_interval_sec]}
              class="input input-bordered w-full"
              min="30"
            />
          </div>
          <div>
            <label class="label"><span class="label-text">Canary Vantages</span></label>
            <.input
              type="number"
              field={@form[:baseline_canary_vantages]}
              class="input input-bordered w-full"
              min="0"
            />
          </div>
          <div>
            <label class="label"><span class="label-text">Incident Cooldown (sec)</span></label>
            <.input
              type="number"
              field={@form[:incident_cooldown_sec]}
              class="input input-bordered w-full"
              min="30"
            />
          </div>
          <div>
            <label class="label"><span class="label-text">Incident Fanout</span></label>
            <.input
              type="number"
              field={@form[:incident_fanout_max_agents]}
              class="input input-bordered w-full"
              min="1"
            />
          </div>
          <div>
            <label class="label"><span class="label-text">Consensus Mode</span></label>
            <.input
              type="select"
              field={@form[:consensus_mode]}
              class="select select-bordered w-full"
              options={[
                {"Majority", "majority"},
                {"Unanimous", "unanimous"},
                {"Threshold", "threshold"}
              ]}
            />
          </div>
          <div>
            <label class="label"><span class="label-text">Consensus Threshold</span></label>
            <.input
              type="number"
              field={@form[:consensus_threshold]}
              class="input input-bordered w-full"
              step="0.01"
              min="0"
              max="1"
            />
          </div>
          <div>
            <label class="label"><span class="label-text">Consensus Min Agents</span></label>
            <.input
              type="number"
              field={@form[:consensus_min_agents]}
              class="input input-bordered w-full"
              min="1"
            />
          </div>
        </div>

        <label class="flex items-center gap-2 cursor-pointer">
          <.input
            type="checkbox"
            field={@form[:recovery_capture]}
            class="checkbox checkbox-sm checkbox-primary"
          />
          <span class="label-text">Run recovery capture MTR on return-to-healthy transitions</span>
        </label>

        <div class="flex justify-end gap-2 pt-4 border-t border-base-200">
          <.link navigate={~p"/settings/networks/mtr"}>
            <.ui_button variant="ghost">Cancel</.ui_button>
          </.link>
          <.ui_button type="submit" variant="primary">
            {if @show_form == :new_profile, do: "Create Profile", else: "Save Changes"}
          </.ui_button>
        </div>
      </.form>
    </.ui_panel>
    """
  end

  defp load_profiles(scope) do
    case Ash.read(MtrPolicy, scope: scope) do
      {:ok, %Ash.Page.Keyset{results: profiles}} -> Enum.sort_by(profiles, & &1.name)
      {:ok, profiles} when is_list(profiles) -> Enum.sort_by(profiles, & &1.name)
      _ -> []
    end
  end

  defp save_profile(:new_profile, _profile, attrs, scope), do: MtrPolicy.create_policy(attrs, scope: scope)

  defp save_profile(:edit_profile, profile, attrs, scope), do: MtrPolicy.update_policy(profile, attrs, scope: scope)

  defp save_profile(_, _profile, _attrs, _scope), do: {:error, :invalid_form_state}

  defp default_form_params do
    %{
      "name" => "",
      "enabled" => true,
      @selector_query_key => "in:devices",
      @selector_limit_key => 100,
      "preferred_agent_id" => "",
      "partition_id" => "",
      "baseline_protocol" => @protocol_icmp,
      @selector_execution_profile_key => @execution_profile_fast,
      "baseline_interval_sec" => 300,
      "baseline_canary_vantages" => 0,
      "incident_fanout_max_agents" => 3,
      "incident_cooldown_sec" => 600,
      "recovery_capture" => true,
      "consensus_mode" => "majority",
      "consensus_threshold" => 0.66,
      "consensus_min_agents" => 2
    }
  end

  defp profile_to_form_params(profile) do
    selector = profile.target_selector || %{}
    defaults = default_form_params()

    %{
      "name" => fallback(profile.name, defaults["name"]),
      "enabled" => truthy(profile.enabled),
      @selector_query_key => selector_query(profile),
      @selector_limit_key => fallback(Map.get(selector, @selector_limit_key), defaults[@selector_limit_key]),
      "preferred_agent_id" => fallback(Map.get(selector, @selector_agent_id_key), defaults["preferred_agent_id"]),
      "partition_id" => fallback(profile.partition_id, defaults["partition_id"]),
      "baseline_protocol" => fallback(profile.baseline_protocol, defaults["baseline_protocol"]),
      @selector_execution_profile_key =>
        fallback(
          Map.get(selector, @selector_execution_profile_key),
          defaults[@selector_execution_profile_key]
        ),
      "baseline_interval_sec" => fallback(profile.baseline_interval_sec, defaults["baseline_interval_sec"]),
      "baseline_canary_vantages" => fallback(profile.baseline_canary_vantages, defaults["baseline_canary_vantages"]),
      "incident_fanout_max_agents" =>
        fallback(profile.incident_fanout_max_agents, defaults["incident_fanout_max_agents"]),
      "incident_cooldown_sec" => fallback(profile.incident_cooldown_sec, defaults["incident_cooldown_sec"]),
      "recovery_capture" => truthy(profile.recovery_capture),
      "consensus_mode" => fallback(profile.consensus_mode, defaults["consensus_mode"]),
      "consensus_threshold" => fallback(profile.consensus_threshold, defaults["consensus_threshold"]),
      "consensus_min_agents" => fallback(profile.consensus_min_agents, defaults["consensus_min_agents"])
    }
  end

  defp selector_query(profile) do
    selector = profile.target_selector || %{}
    Map.get(selector, @selector_query_key) || "in:devices"
  end

  defp selector_agent(profile) do
    selector = profile.target_selector || %{}
    Map.get(selector, @selector_agent_id_key)
  end

  defp bulk_interval_guidance(_scope, preferred_agent_id, _execution_profile, _target_count, _configured_interval)
       when preferred_agent_id in [nil, ""] do
    nil
  end

  defp bulk_interval_guidance(_scope, _preferred_agent_id, _execution_profile, target_count, _configured_interval)
       when not is_integer(target_count) or target_count <= 0 do
    nil
  end

  defp bulk_interval_guidance(scope, preferred_agent_id, execution_profile, target_count, configured_interval) do
    configured_interval = parse_int(configured_interval, 300, 30)
    execution_profile = normalize_bulk_execution_profile(execution_profile)

    query =
      AgentCommand
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(
        expr(
          command_type == @command_type_mtr_bulk_run and agent_id == ^preferred_agent_id and
            status == :completed
        )
      )
      |> Ash.Query.sort(completed_at: :desc)
      |> Ash.Query.limit(20)

    with {:ok, jobs} <- Ash.read(query, scope: scope),
         measurements when measurements != [] <-
           jobs
           |> List.wrap()
           |> Enum.filter(&(bulk_job_profile(&1) == execution_profile))
           |> Enum.flat_map(&bulk_job_measurement/1) do
      avg_targets_per_minute =
        measurements
        |> Enum.map(& &1.targets_per_minute)
        |> average()

      avg_effective_concurrency =
        measurements
        |> Enum.map(& &1.effective_concurrency)
        |> average()

      avg_timeout_ratio =
        measurements
        |> Enum.map(& &1.timeout_ratio)
        |> average()

      throttled_runs = Enum.count(measurements, & &1.throttled?)

      estimated_duration_sec =
        if avg_targets_per_minute > 0 do
          ceil(target_count / avg_targets_per_minute * 60)
        else
          0
        end

      headroom_factor =
        cond do
          throttled_runs > 0 and avg_timeout_ratio >= 0.10 -> 1.7
          avg_timeout_ratio >= 0.10 -> 1.6
          throttled_runs > 0 -> 1.4
          true -> 1.25
        end

      recommended_interval_sec =
        estimated_duration_sec
        |> Kernel.*(headroom_factor)
        |> ceil()
        |> round_up_to_30()
        |> max(30)

      %{
        agent_id: preferred_agent_id,
        execution_profile: execution_profile,
        targets_per_minute: Float.round(avg_targets_per_minute, 1),
        effective_concurrency: Float.round(avg_effective_concurrency, 1),
        timeout_ratio_percent: Float.round(avg_timeout_ratio * 100, 1),
        estimated_duration_sec: estimated_duration_sec,
        recommended_interval_sec: recommended_interval_sec,
        throttled_runs: throttled_runs,
        sample_count: length(measurements),
        warning?: configured_interval < recommended_interval_sec
      }
    else
      _ -> nil
    end
  end

  defp bulk_job_measurement(job) do
    total_targets = extract_bulk_total_targets(job)
    payload = job.result_payload || job.progress_payload || %{}
    {effective_concurrency, throttled?} = extract_bulk_concurrency_measurement(payload)
    timed_out_targets = extract_int_metric(payload, @payload_timed_out_targets_key) || 0
    timeout_ratio = safe_ratio(timed_out_targets, total_targets)

    case extract_float_metric(payload, @payload_targets_per_minute_key) do
      value when is_float(value) and value > 0 ->
        [
          %{
            targets_per_minute: value,
            effective_concurrency: effective_concurrency,
            timeout_ratio: timeout_ratio,
            throttled?: throttled?
          }
        ]

      _ ->
        with total when is_integer(total) and total > 0 <- total_targets,
             %DateTime{} = inserted_at <- job.inserted_at,
             %DateTime{} = completed_at <- job.completed_at,
             duration_sec when duration_sec > 0 <-
               DateTime.diff(completed_at, inserted_at, :second) do
          [
            %{
              targets_per_minute: total / (duration_sec / 60),
              effective_concurrency: effective_concurrency,
              timeout_ratio: timeout_ratio,
              throttled?: throttled?
            }
          ]
        else
          _ -> []
        end
    end
  end

  defp extract_bulk_concurrency_measurement(payload) when is_map(payload) do
    history = extract_bulk_concurrency_history(payload)

    if history == [] do
      current = extract_float_metric(payload, @payload_concurrency_key) || 0.0
      max = extract_float_metric(payload, @payload_max_concurrency_key) || current
      {current, max > current and current > 0}
    else
      avg_effective_concurrency =
        history
        |> Enum.map(&Map.get(&1, :concurrency, 0))
        |> Enum.reject(&(&1 <= 0))
        |> average()

      throttled? =
        Enum.any?(history, fn sample ->
          max_concurrency = Map.get(sample, :max_concurrency, 0)
          concurrency = Map.get(sample, :concurrency, 0)
          max_concurrency > 0 and concurrency > 0 and concurrency < max_concurrency
        end)

      effective_concurrency =
        if avg_effective_concurrency > 0 do
          avg_effective_concurrency
        else
          extract_float_metric(payload, @payload_concurrency_key) || 0.0
        end

      {effective_concurrency, throttled?}
    end
  end

  defp extract_bulk_concurrency_measurement(_payload), do: {0.0, false}

  defp extract_bulk_concurrency_history(payload) when is_map(payload) do
    payload
    |> Map.get(@payload_concurrency_history_key, [])
    |> List.wrap()
    |> Enum.map(fn
      %{} = sample ->
        %{
          concurrency: extract_int_metric(sample, @payload_concurrency_key) || 0,
          max_concurrency: extract_int_metric(sample, @payload_max_concurrency_key) || 0
        }

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp bulk_job_profile(job) do
    payload = job.payload || %{}
    normalize_bulk_execution_profile(Map.get(payload, @selector_execution_profile_key))
  end

  defp extract_bulk_total_targets(job) do
    payload = job.result_payload || job.progress_payload || %{}

    case Map.get(payload, @payload_total_targets_key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} -> parsed
          _ -> length(List.wrap(job.payload[@payload_targets_key]))
        end

      _ ->
        length(List.wrap(job.payload[@payload_targets_key]))
    end
  end

  defp average(values) when is_list(values) and values != [] do
    Enum.sum(values) / length(values)
  end

  defp average(_values), do: 0.0

  defp safe_ratio(_value, total) when total in [0, 0.0, nil], do: 0.0
  defp safe_ratio(value, total), do: min(1.0, max(value / total, 0.0))

  defp normalize_bulk_execution_profile(nil), do: @execution_profile_fast

  defp normalize_bulk_execution_profile(value) do
    value =
      value
      |> to_string()
      |> String.trim()
      |> String.downcase()

    if value in @execution_profiles, do: value, else: @execution_profile_fast
  end

  defp extract_float_metric(payload, key) when is_map(payload) do
    case Map.get(payload, key) do
      value when is_float(value) ->
        value

      value when is_integer(value) ->
        value * 1.0

      value when is_binary(value) ->
        case Float.parse(value) do
          {parsed, ""} -> parsed
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp extract_float_metric(_payload, _key), do: nil

  defp extract_int_metric(payload, key) when is_map(payload) do
    case Map.get(payload, key) do
      value when is_integer(value) ->
        value

      value when is_float(value) ->
        trunc(value)

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} -> parsed
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp extract_int_metric(_payload, _key), do: nil

  defp round_up_to_30(value) when is_integer(value) do
    rem = rem(value, 30)
    if rem == 0, do: value, else: value + 30 - rem
  end

  defp list_connected_agents do
    AgentRegistry.find_agents()
  rescue
    _ -> []
  end

  defp agent_id(agent) do
    Map.get(agent, :agent_id) || Map.get(agent, @selector_agent_id_key) || ""
  end

  defp agent_label(agent) do
    id = agent_id(agent)
    partition = Map.get(agent, :partition_id) || Map.get(agent, "partition_id")

    if is_binary(partition) and partition != "" and partition != "default" do
      "#{id} (#{partition})"
    else
      id
    end
  end

  defp normalize_target_query(nil), do: nil
  defp normalize_target_query(""), do: nil

  defp normalize_target_query(query) when is_binary(query) do
    query = String.trim(query)

    cond do
      query == "" -> nil
      String.starts_with?(query, "in:") -> query
      true -> "in:devices " <> query
    end
  end

  defp normalize_target_query(_), do: nil

  defp count_target_devices(_scope, nil), do: nil
  defp count_target_devices(_scope, ""), do: nil

  defp count_target_devices(scope, target_query) when is_binary(target_query) do
    with normalized when is_binary(normalized) <- normalize_target_query(target_query),
         full_query = build_count_query(normalized),
         {:ok, %{"results" => [%{"total" => count} | _]}} <-
           srql_module().query(full_query, %{scope: scope}) do
      extract_total_count(count)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp build_count_query(normalized) when is_binary(normalized) do
    normalized =
      normalized
      |> String.replace(~r/(^|\s)limit:\S+/i, "")
      |> String.replace(~r/(^|\s)stats:"[^"]*"/i, "")
      |> String.replace(~r/(^|\s)stats:\S+/i, "")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    Kernel.<>("#{normalized} stats:\"count() as total\"", " limit:1")
  end

  defp extract_total_count(count) when is_integer(count), do: count
  defp extract_total_count(count) when is_float(count), do: trunc(count)

  defp extract_total_count(count) when is_binary(count) do
    case Integer.parse(count) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp extract_total_count(_count), do: nil

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end

  defp default_builder_state do
    config = Catalog.entity("devices")

    %{
      "filters" => [
        %{"field" => config.default_filter_field, "op" => "contains", "value" => ""}
      ]
    }
  end

  defp parse_target_query_to_builder(nil), do: {default_builder_state(), true}
  defp parse_target_query_to_builder(""), do: {default_builder_state(), true}

  defp parse_target_query_to_builder(query) when is_binary(query) do
    query = String.trim(query)

    if query == "" do
      {default_builder_state(), true}
    else
      case parse_filters_from_query(query) do
        {:ok, filters} when filters != [] -> {%{"filters" => filters}, true}
        _ -> {default_builder_state(), false}
      end
    end
  end

  defp parse_filters_from_query(query) do
    known_prefixes = ["in:", "limit:", "sort:", "time:", "stats:"]

    tokens =
      query
      |> String.split(~r/(?<!\\)\s+/, trim: true)
      |> Enum.reject(fn token ->
        Enum.any?(known_prefixes, &String.starts_with?(token, &1))
      end)

    filters =
      tokens
      |> Enum.map(&parse_filter_token/1)
      |> Enum.reject(&is_nil/1)

    if length(filters) == length(tokens), do: {:ok, filters}, else: {:error, :unsupported_query}
  end

  defp parse_filter_token(token) do
    {field_expr, negated} =
      if String.starts_with?(token, "!") do
        {String.replace_prefix(token, "!", ""), true}
      else
        {token, false}
      end

    case String.split(field_expr, ":", parts: 2) do
      [field, value] when field != "" and value != "" ->
        %{
          "field" => field,
          "op" => if(negated, do: "not_contains", else: "contains"),
          "value" => value
        }

      _ ->
        nil
    end
  end

  defp update_builder(builder, params) do
    filters =
      params
      |> Map.get("filters", %{})
      |> Enum.sort_by(fn {k, _} ->
        case Integer.parse(to_string(k)) do
          {i, ""} -> i
          _ -> 1_000_000_000
        end
      end)
      |> Enum.map(fn {_idx, filter} ->
        %{
          "field" => Map.get(filter, "field", ""),
          "op" => Map.get(filter, "op", "contains"),
          "value" => Map.get(filter, "value", "")
        }
      end)
      |> Enum.reject(fn f -> String.trim(f["field"]) == "" and String.trim(f["value"]) == "" end)

    Map.put(builder, "filters", filters)
  end

  defp build_target_query(builder) do
    filters =
      builder
      |> Map.get("filters", [])
      |> Enum.filter(&builder_filter_present?/1)

    base = "in:devices"

    case filters do
      [] ->
        base

      _ ->
        filter_tokens = Enum.map(filters, &builder_filter_token/1)
        Enum.join([base | filter_tokens], " ")
    end
  end

  defp builder_filter_present?(filter) do
    String.trim(filter["field"] || "") != "" and String.trim(filter["value"] || "") != ""
  end

  defp builder_filter_token(filter) do
    field = String.trim(filter["field"] || "")

    value =
      filter["value"]
      |> to_string()
      |> String.trim()
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    needs_quotes? = Regex.match?(~r/[^A-Za-z0-9_.-]/, value)

    token_value =
      if needs_quotes? do
        "\"#{value}\""
      else
        value
      end

    case filter["op"] || "contains" do
      "not_contains" -> "!#{field}:#{token_value}"
      "equals" -> "#{field}:#{token_value}"
      "not_equals" -> "!#{field}:#{token_value}"
      _ -> "#{field}:#{token_value}"
    end
  end

  defp maybe_sync_builder_to_form(socket) do
    if socket.assigns.builder_sync do
      query = build_target_query(socket.assigns.builder)
      params = socket.assigns.form.params || %{}
      params = Map.put(params, @selector_query_key, query)

      socket
      |> assign(:form, to_form(params, as: :form))
      |> assign(:target_device_count, count_target_devices(socket.assigns.current_scope, query))
    else
      socket
    end
  end

  defp parse_int(nil, default, _min), do: default
  defp parse_int("", default, _min), do: default

  defp parse_int(value, _default, min) when is_integer(value) do
    max(value, min)
  end

  defp parse_int(value, default, min) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> max(parsed, min)
      _ -> default
    end
  end

  defp parse_int(_value, default, _min), do: default

  defp parse_bool(value, _default) when is_boolean(value), do: value
  defp parse_bool("true", _default), do: true
  defp parse_bool("false", _default), do: false
  defp parse_bool("on", _default), do: true
  defp parse_bool("off", _default), do: false
  defp parse_bool(_value, default), do: default

  defp parse_float(nil, default, _min, _max), do: default
  defp parse_float("", default, _min, _max), do: default

  defp parse_float(value, default, min_val, max_val) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> parsed |> Kernel.max(min_val) |> Kernel.min(max_val)
      _ -> default
    end
  end

  defp parse_float(value, _default, min_val, max_val) when is_float(value),
    do: value |> Kernel.max(min_val) |> Kernel.min(max_val)

  defp parse_float(value, _default, min_val, max_val) when is_integer(value),
    do: (value / 1.0) |> Kernel.max(min_val) |> Kernel.min(max_val)

  defp parse_float(_value, default, _min, _max), do: default

  defp normalize_protocol(value) do
    value = value |> to_string() |> String.downcase()
    if value in @protocols, do: value, else: @protocol_icmp
  end

  defp normalize_consensus_mode(value) do
    value = value |> to_string() |> String.downcase()
    if value in ["majority", "unanimous", "threshold"], do: value, else: "majority"
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp blank_to_nil(_), do: nil

  defp truthy(value), do: value == true

  defp fallback(nil, default), do: default
  defp fallback("", default), do: default
  defp fallback(value, _default), do: value

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason), do: inspect(reason)
end
