defmodule ServiceRadarWebNGWeb.Settings.NetperfLive.View do
  @moduledoc """
  HEEx templates for `ServiceRadarWebNGWeb.Settings.NetperfLive.Index`.
  """

  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.Components.AgentPicker

  alias ServiceRadarWebNGWeb.Settings.NetperfLive.Data
  alias ServiceRadarWebNGWeb.Settings.NetperfLive.Forms
  alias ServiceRadarWebNGWeb.Settings.Shell

  def render(assigns) do
    assigns = assign(assigns, :timezone, user_timezone(assigns.current_scope))

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
        <section id="netperf-settings-page" class="space-y-5">
          <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <h1 class="text-xl font-semibold text-sr-ink">Network Performance</h1>
              <p class="mt-1 text-sm text-sr-muted">
                Configure embedded agent Hub &amp; Spoke policies, Hub Responders, bounded test profiles, and run on-demand tests.
              </p>
            </div>
            <div class="flex flex-wrap items-center gap-2">
              <.ui_button
                id="netperf-dashboard-link"
                variant="neutral"
                size="sm"
                navigate={
                  @dashboard_route || ~p"/observability/metrics?#{%{q: "in:netperf_metrics"}}"
                }
              >
                <.icon name="hero-chart-bar" class="size-4" />
                {if @dashboard_route, do: "Network Performance Dashboard", else: "Netperf Metrics"}
              </.ui_button>
              <.ui_button
                id="netperf-run-test-btn"
                type="button"
                variant="primary"
                size="sm"
                phx-click="open_run_modal"
              >
                <.icon name="hero-play" class="size-4" /> Run Test Now
              </.ui_button>
            </div>
          </div>

          <.active_run_banner :if={@active_run} active_run={@active_run} />

          <%= if @loading? do %>
            <.ui_panel id="netperf-loading-panel">
              <div class="flex items-center gap-3 py-6 text-sm text-sr-muted">
                <.ui_spinner size="sm" />
                <span>Loading network performance configuration…</span>
              </div>
            </.ui_panel>
          <% else %>
            <%= case @show_form do %>
              <% action when action in [:new_policy, :edit_policy] -> %>
                <.policy_form
                  form={@form}
                  form_params={@form_params}
                  show_form={@show_form}
                  profiles={@profiles_list}
                  responders={@responders_list}
                  agents_by_uid={@agents_by_uid}
                  online_agent_ids={@online_agent_ids}
                  netperf_agent_ids={@netperf_agent_ids}
                />
              <% action when action in [:new_responder, :edit_responder] -> %>
                <.responder_form
                  form={@form}
                  show_form={@show_form}
                  agents_by_uid={@agents_by_uid}
                  online_agent_ids={@online_agent_ids}
                  netperf_agent_ids={@netperf_agent_ids}
                />
              <% action when action in [:new_profile, :edit_profile] -> %>
                <.profile_form form={@form} show_form={@show_form} />
              <% nil -> %>
                <.tab_bar active_tab={@active_tab} />

                <div class={if(@active_tab == "policies", do: "block", else: "hidden")}>
                  <.policies_panel
                    streams={@streams}
                    count={@policies_count}
                    profiles_count={@profiles_count}
                    responders_count={@responders_count}
                  />
                </div>

                <div class={if(@active_tab == "responders", do: "block", else: "hidden")}>
                  <.responders_panel
                    streams={@streams}
                    count={@responders_count}
                    online_agent_ids={@online_agent_ids}
                    netperf_agent_ids={@netperf_agent_ids}
                  />
                </div>

                <div class={if(@active_tab == "profiles", do: "block", else: "hidden")}>
                  <.profiles_panel streams={@streams} count={@profiles_count} />
                </div>

                <.recent_runs_panel
                  streams={@streams}
                  count={@recent_runs_count}
                  timezone={@timezone}
                />
            <% end %>
          <% end %>

          <.run_modal
            open={@show_run_modal}
            run_form={@run_form}
            run_error={@run_error}
            agents_by_uid={@agents_by_uid}
            responders={@responders_list}
            profiles={@profiles_list}
            online_agent_ids={@online_agent_ids}
            netperf_agent_ids={@netperf_agent_ids}
          />

          <.agent_picker_modal
            :if={@agent_picker}
            id="agent-picker-modal"
            open={true}
            title={@agent_picker.title}
            mode={@agent_picker.mode}
            agents={@agent_picker.agents}
            selected={@agent_picker.selected}
            query={@agent_picker.query}
            only_netperf={@agent_picker.only_netperf}
            online_agent_ids={@online_agent_ids}
            netperf_agent_ids={@netperf_agent_ids}
          />
        </section>
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end

  defp tab_bar(assigns) do
    tabs = [
      %{
        label: "Policies",
        patch: ~p"/settings/networks/netperf?tab=policies",
        active: assigns.active_tab == "policies",
        variant: if(assigns.active_tab == "policies", do: "soft", else: "ghost")
      },
      %{
        label: "Hub Responders",
        patch: ~p"/settings/networks/netperf?tab=responders",
        active: assigns.active_tab == "responders",
        variant: if(assigns.active_tab == "responders", do: "soft", else: "ghost")
      },
      %{
        label: "Profiles",
        patch: ~p"/settings/networks/netperf?tab=profiles",
        active: assigns.active_tab == "profiles",
        variant: if(assigns.active_tab == "profiles", do: "soft", else: "ghost")
      }
    ]

    assigns = assign(assigns, :tabs, tabs)

    ~H"""
    <div class="border-b border-sr-line pb-2">
      <.ui_tabs tabs={@tabs} />
    </div>
    """
  end

  defp policies_panel(assigns) do
    ~H"""
    <.ui_panel id="netperf-policies-panel">
      <:header>
        <div>
          <h2 class="text-base font-semibold text-sr-ink">Policies</h2>
          <p class="text-xs text-sr-muted">
            Assign Hub &amp; Spoke or Hub Mesh topologies linking spoke selectors, profiles, and Hub Responders.
          </p>
        </div>
        <.ui_button
          :if={@profiles_count > 0}
          id="netperf-new-policy-btn"
          variant="primary"
          size="sm"
          patch={~p"/settings/networks/netperf/policies/new"}
        >
          <.icon name="hero-plus" class="size-4" /> New Policy
        </.ui_button>
        <.ui_button
          :if={@profiles_count == 0}
          id="netperf-new-policy-btn"
          type="button"
          variant="primary"
          size="sm"
          disabled
        >
          <.icon name="hero-plus" class="size-4" /> New Policy
        </.ui_button>
      </:header>

      <.ui_alert :if={@profiles_count == 0} variant="warning" class="mb-4">
        Create a profile on the Profiles tab before creating a network performance policy.
      </.ui_alert>

      <div class="overflow-x-auto">
        <table
          id="netperf-policies-table"
          class={ui_table_class(size: "sm", zebra: true, class: "w-full")}
        >
          <thead>
            <tr>
              <th>Policy</th>
              <th>Mode</th>
              <th>Profile</th>
              <th>Hub Responders</th>
              <th>Spoke Selector</th>
              <th>Epoch</th>
              <th>Status</th>
              <th class="text-right">Actions</th>
            </tr>
          </thead>
          <tbody id="netperf-policies-tbody" phx-update="stream">
            <tr :for={{id, policy} <- @streams.policies} id={id}>
              <td>
                <div class="font-medium text-sr-ink">{policy.name}</div>
                <div :if={policy.description} class="text-xs text-sr-muted">{policy.description}</div>
              </td>
              <td>
                <.ui_badge
                  variant={if(policy.mode == :hub_mesh, do: "info", else: "outline")}
                  size="xs"
                >
                  {if policy.mode == :hub_mesh, do: "Hub Mesh", else: "Hub & Spoke"}
                </.ui_badge>
              </td>
              <td class="text-xs text-sr-ink">
                <%= if loaded_assoc?(policy.profile) do %>
                  <div class="font-medium">{policy.profile.name}</div>
                  <div class="text-sr-muted">
                    {String.upcase(to_string(policy.profile.protocol))} · {policy.profile.direction} · {Forms.format_bps(
                      policy.profile.bandwidth_bps
                    )}
                  </div>
                <% else %>
                  <span class="text-sr-muted">—</span>
                <% end %>
              </td>
              <td class="text-xs text-sr-ink">
                <%= if loaded_assoc?(policy.responders) do %>
                  <div class="flex flex-wrap gap-1">
                    <.ui_badge :for={resp <- policy.responders} variant="ghost" size="xs">
                      {resp.name}
                    </.ui_badge>
                  </div>
                <% else %>
                  <span class="text-sr-muted">None attached</span>
                <% end %>
              </td>
              <td class="text-xs text-sr-muted">
                <%= if policy.mode == :hub_mesh do %>
                  Pairwise Hub Mesh
                <% else %>
                  {Forms.summarize_spoke_selector(policy.spoke_selector)}
                <% end %>
              </td>
              <td class="font-mono text-xs text-sr-ink">v{policy.authority_epoch}</td>
              <td>
                <.ui_badge variant={if(policy.enabled, do: "success", else: "ghost")} size="xs">
                  {if policy.enabled, do: "Enabled", else: "Disabled"}
                </.ui_badge>
              </td>
              <td class="text-right">
                <div class="inline-flex items-center gap-1">
                  <.ui_button
                    type="button"
                    variant="ghost"
                    size="xs"
                    phx-click="toggle_policy"
                    phx-value-id={policy.id}
                  >
                    {if policy.enabled, do: "Disable", else: "Enable"}
                  </.ui_button>
                  <.ui_button
                    variant="ghost"
                    size="xs"
                    patch={~p"/settings/networks/netperf/policies/#{policy.id}/edit"}
                  >
                    Edit
                  </.ui_button>
                  <.ui_button
                    type="button"
                    variant="danger"
                    size="xs"
                    phx-click="delete_policy"
                    phx-value-id={policy.id}
                    data-confirm="Delete this network performance policy?"
                  >
                    Delete
                  </.ui_button>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <p :if={@count == 0} id="netperf-policies-empty" class="py-6 text-center text-sm text-sr-muted">
        No network performance policies configured yet.
      </p>
    </.ui_panel>
    """
  end

  defp responders_panel(assigns) do
    ~H"""
    <.ui_panel id="netperf-responders-panel">
      <:header>
        <div>
          <h2 class="text-base font-semibold text-sr-ink">Hub Responders</h2>
          <p class="text-xs text-sr-muted">
            Enable opt-in mTLS TCP/UDP listeners on enrolled Hub agents and manage authority epochs.
          </p>
        </div>
        <.ui_button
          id="netperf-new-responder-btn"
          variant="primary"
          size="sm"
          patch={~p"/settings/networks/netperf/responders/new"}
        >
          <.icon name="hero-plus" class="size-4" /> New Hub Responder
        </.ui_button>
      </:header>

      <div class="overflow-x-auto">
        <table
          id="netperf-responders-table"
          class={ui_table_class(size: "sm", zebra: true, class: "w-full")}
        >
          <thead>
            <tr>
              <th>Name</th>
              <th>Agent UID</th>
              <th>Resolved Endpoint</th>
              <th>UDP</th>
              <th>Capacity</th>
              <th>Authority Epoch</th>
              <th>Status</th>
              <th class="text-right">Actions</th>
            </tr>
          </thead>
          <tbody id="netperf-responders-tbody" phx-update="stream">
            <tr :for={{id, responder} <- @streams.responders} id={id}>
              <td class="font-medium text-sr-ink">{responder.name}</td>
              <td>
                <div class="flex flex-wrap items-center gap-1.5">
                  <span class="font-mono text-xs text-sr-ink">{responder.agent_uid}</span>
                  <.ui_badge
                    :if={MapSet.member?(@online_agent_ids, responder.agent_uid)}
                    variant="success"
                    size="xs"
                  >
                    Online
                  </.ui_badge>
                  <.ui_badge
                    :if={MapSet.member?(@netperf_agent_ids, responder.agent_uid)}
                    variant="info"
                    size="xs"
                  >
                    netperf
                  </.ui_badge>
                </div>
              </td>
              <td class="font-mono text-xs text-sr-ink">
                <%= if addr = Data.resolve_responder_address(responder) do %>
                  <span>{addr}:{responder.listen_port}</span>
                  <.ui_badge
                    :if={is_nil(responder.advertise_address) or responder.advertise_address == ""}
                    variant="ghost"
                    size="xs"
                  >
                    auto
                  </.ui_badge>
                <% else %>
                  <span class="text-sr-muted">Unresolved:{responder.listen_port}</span>
                <% end %>
              </td>
              <td>
                <.ui_badge variant={if(responder.udp_enabled, do: "info", else: "ghost")} size="xs">
                  {if responder.udp_enabled, do: "#{responder.listen_port}/UDP", else: "TCP only"}
                </.ui_badge>
              </td>
              <td class="text-xs text-sr-muted">
                {responder.max_concurrent_sessions} sessions · {Forms.format_bps(
                  responder.max_total_bandwidth_bps
                )}
              </td>
              <td>
                <.ui_badge variant="outline" size="xs">epoch {responder.authority_epoch}</.ui_badge>
              </td>
              <td>
                <.ui_badge variant={if(responder.enabled, do: "success", else: "ghost")} size="xs">
                  {if responder.enabled, do: "Enabled", else: "Disabled"}
                </.ui_badge>
              </td>
              <td class="text-right">
                <div class="inline-flex items-center gap-1">
                  <.ui_button
                    type="button"
                    variant="ghost"
                    size="xs"
                    phx-click="bump_authority_epoch"
                    phx-value-id={responder.id}
                  >
                    Bump Epoch
                  </.ui_button>
                  <.ui_button
                    type="button"
                    variant="ghost"
                    size="xs"
                    phx-click="toggle_responder"
                    phx-value-id={responder.id}
                  >
                    {if responder.enabled, do: "Disable", else: "Enable"}
                  </.ui_button>
                  <.ui_button
                    variant="ghost"
                    size="xs"
                    patch={~p"/settings/networks/netperf/responders/#{responder.id}/edit"}
                  >
                    Edit
                  </.ui_button>
                  <.ui_button
                    type="button"
                    variant="danger"
                    size="xs"
                    phx-click="delete_responder"
                    phx-value-id={responder.id}
                    data-confirm="Delete this Hub Responder?"
                  >
                    Delete
                  </.ui_button>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <p
        :if={@count == 0}
        id="netperf-responders-empty"
        class="py-6 text-center text-sm text-sr-muted"
      >
        No Hub Responders configured yet.
      </p>
    </.ui_panel>
    """
  end

  defp profiles_panel(assigns) do
    ~H"""
    <.ui_panel id="netperf-profiles-panel">
      <:header>
        <div>
          <h2 class="text-base font-semibold text-sr-ink">Profiles</h2>
          <p class="text-xs text-sr-muted">
            Reusable bounded test parameters shared across Hub &amp; Spoke policies and on-demand presets.
          </p>
        </div>
        <.ui_button
          id="netperf-new-profile-btn"
          variant="primary"
          size="sm"
          patch={~p"/settings/networks/netperf/profiles/new"}
        >
          <.icon name="hero-plus" class="size-4" /> New Profile
        </.ui_button>
      </:header>

      <div class="overflow-x-auto">
        <table
          id="netperf-profiles-table"
          class={ui_table_class(size: "sm", zebra: true, class: "w-full")}
        >
          <thead>
            <tr>
              <th>Name</th>
              <th>Protocol &amp; Direction</th>
              <th>Bandwidth Ceiling</th>
              <th>Duration / Omit</th>
              <th>Parallel</th>
              <th>Packet Length</th>
              <th>Interval</th>
              <th class="text-right">Actions</th>
            </tr>
          </thead>
          <tbody id="netperf-profiles-tbody" phx-update="stream">
            <tr :for={{id, profile} <- @streams.profiles} id={id}>
              <td>
                <div class="font-medium text-sr-ink">{profile.name}</div>
                <div :if={profile.description} class="text-xs text-sr-muted">
                  {profile.description}
                </div>
              </td>
              <td class="text-xs text-sr-ink">
                <.ui_badge variant="outline" size="xs">
                  {String.upcase(to_string(profile.protocol))}
                </.ui_badge>
                <span class="ml-1">{profile.direction}</span>
              </td>
              <td class="font-mono text-xs text-sr-ink">{Forms.format_bps(profile.bandwidth_bps)}</td>
              <td class="text-xs text-sr-muted">
                {profile.duration_sec}s / {profile.omit_sec}s omit
              </td>
              <td class="text-xs text-sr-ink">{profile.parallel}</td>
              <td class="text-xs text-sr-muted">{profile.packet_length} B</td>
              <td class="text-xs text-sr-muted">{profile.interval_seconds}s</td>
              <td class="text-right">
                <div class="inline-flex items-center gap-1">
                  <.ui_button
                    variant="ghost"
                    size="xs"
                    patch={~p"/settings/networks/netperf/profiles/#{profile.id}/edit"}
                  >
                    Edit
                  </.ui_button>
                  <.ui_button
                    type="button"
                    variant="danger"
                    size="xs"
                    phx-click="delete_profile"
                    phx-value-id={profile.id}
                    data-confirm="Delete this network performance profile?"
                  >
                    Delete
                  </.ui_button>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <p :if={@count == 0} id="netperf-profiles-empty" class="py-6 text-center text-sm text-sr-muted">
        No network performance profiles configured yet.
      </p>
    </.ui_panel>
    """
  end

  defp policy_form(assigns) do
    profile_options = Enum.map(assigns.profiles, &{&1.name, to_string(&1.id)})
    selected_responder_ids = assigns.form_params |> Map.get("responder_ids", []) |> List.wrap()
    hub_mesh? = Map.get(assigns.form_params, "mode") == "hub_mesh"

    assigns =
      assigns
      |> assign(:profile_options, profile_options)
      |> assign(:selected_responder_ids, selected_responder_ids)
      |> assign(:hub_mesh?, hub_mesh?)

    ~H"""
    <.ui_panel id="netperf-policy-form-panel">
      <:header>
        <div>
          <h2 class="text-base font-semibold text-sr-ink">
            {if @show_form == :new_policy,
              do: "New Network Performance Policy",
              else: "Edit Network Performance Policy"}
          </h2>
          <p class="text-xs text-sr-muted">
            Bind a test profile, target Hub Responders, and optional spoke selection criteria.
          </p>
        </div>
        <.ui_button variant="ghost" size="sm" patch={~p"/settings/networks/netperf?tab=policies"}>
          Cancel
        </.ui_button>
      </:header>

      <.form
        for={@form}
        id="netperf-policy-form"
        phx-change="validate_policy"
        phx-submit="save_policy"
        class="space-y-4"
      >
        <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
          <.input field={@form[:name]} type="text" label="Policy Name" required />
          <.input
            field={@form[:mode]}
            type="select"
            label="Topology Mode"
            options={[{"Hub & Spoke", "hub_and_spoke"}, {"Hub Mesh (pairwise)", "hub_mesh"}]}
          />
        </div>

        <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
          <.input
            field={@form[:profile_id]}
            type="select"
            label="Profile"
            options={@profile_options}
            prompt="Select a profile..."
            required
          />
          <.input field={@form[:description]} type="text" label="Description" />
        </div>

        <.input field={@form[:enabled]} type="checkbox" label="Policy enabled" />

        <div class="space-y-2 rounded-sr-surface border border-sr-line bg-sr-subtle/40 p-3">
          <div class="text-sm font-medium text-sr-ink">Target Hub Responders</div>
          <input type="hidden" name="policy[responder_ids][]" value="" />
          <%= if @responders == [] do %>
            <p class="text-xs text-sr-muted">No Hub Responders exist yet.</p>
          <% else %>
            <div class="grid grid-cols-1 gap-2 sm:grid-cols-2 lg:grid-cols-3">
              <label
                :for={responder <- @responders}
                class="flex cursor-pointer items-center gap-2 rounded-sr-control border border-sr-line bg-sr-surface px-3 py-2 text-sm text-sr-ink"
              >
                <input
                  type="checkbox"
                  name="policy[responder_ids][]"
                  value={responder.id}
                  checked={to_string(responder.id) in @selected_responder_ids}
                  class={ui_checkbox_class(size: "sm")}
                />
                <span class="truncate font-medium">{responder.name}</span>
                <span class="font-mono text-xs text-sr-muted">({responder.agent_uid})</span>
              </label>
            </div>
          <% end %>
        </div>

        <div
          id="netperf-spoke-selector-fields"
          class={[
            "space-y-3 rounded-sr-surface border border-sr-line bg-sr-subtle/30 p-3",
            @hub_mesh? && "hidden"
          ]}
        >
          <div class="text-sm font-medium text-sr-ink">Spoke Selector (Hub &amp; Spoke)</div>
          <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
            <.input
              field={@form[:spoke_partition_id]}
              type="text"
              label="Partition ID (optional)"
              placeholder="default"
            />
            <.input
              field={@form[:spoke_tags_text]}
              type="text"
              label="Tags (key=value, comma-separated)"
              placeholder="site=branch-01, tier=edge"
            />
          </div>
          <.input
            field={@form[:spoke_srql_query]}
            type="text"
            label="SRQL Selector (agents or devices)"
            placeholder="in:agents status:connected"
          />
          <.agent_picker_field
            id="netperf-policy-spoke-agents-picker"
            label="Explicit Spoke Agents"
            field_name="policy[spoke_agent_uids_text]"
            mode={:multi}
            selected={@form[:spoke_agent_uids_text].value}
            placeholder="Browse & select spoke agents..."
            target_key="policy_spokes"
            agents_by_uid={@agents_by_uid}
            online_agent_ids={@online_agent_ids}
            netperf_agent_ids={@netperf_agent_ids}
          />
        </div>

        <div class="flex items-center justify-end gap-2">
          <.ui_button variant="neutral" size="sm" patch={~p"/settings/networks/netperf?tab=policies"}>
            Cancel
          </.ui_button>
          <.ui_button id="netperf-save-policy-btn" type="submit" variant="primary" size="sm">
            Save Policy
          </.ui_button>
        </div>
      </.form>
    </.ui_panel>
    """
  end

  defp responder_form(assigns) do
    ~H"""
    <.ui_panel id="netperf-responder-form-panel">
      <:header>
        <div>
          <h2 class="text-base font-semibold text-sr-ink">
            {if @show_form == :new_responder, do: "New Hub Responder", else: "Edit Hub Responder"}
          </h2>
          <p class="text-xs text-sr-muted">
            Enable a single mTLS TCP/UDP listener port on an enrolled agent.
          </p>
        </div>
        <.ui_button variant="ghost" size="sm" patch={~p"/settings/networks/netperf?tab=responders"}>
          Cancel
        </.ui_button>
      </:header>

      <.form
        for={@form}
        id="netperf-responder-form"
        phx-change="validate_responder"
        phx-submit="save_responder"
        class="space-y-4"
      >
        <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
          <%= if @show_form == :new_responder do %>
            <.agent_picker_field
              id="netperf-responder-agent-picker"
              label="Agent"
              field_name="responder[agent_uid]"
              mode={:single}
              selected={@form[:agent_uid].value}
              placeholder="Browse & select an enrolled agent..."
              target_key="responder_agent"
              agents_by_uid={@agents_by_uid}
              online_agent_ids={@online_agent_ids}
              netperf_agent_ids={@netperf_agent_ids}
            />
          <% else %>
            <.input field={@form[:agent_uid]} type="text" label="Agent UID (immutable)" readonly />
          <% end %>
          <.input field={@form[:name]} type="text" label="Display Name" required />
        </div>

        <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
          <.input
            field={@form[:advertise_address]}
            type="text"
            label="Advertise Address (optional override)"
            placeholder="Defaults to agent IP / host"
          />
          <.input
            field={@form[:listen_port]}
            type="number"
            label="Listen Port"
            min="1"
            max="65535"
            required
          />
        </div>

        <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
          <.input
            field={@form[:max_concurrent_sessions]}
            type="number"
            label="Max Concurrent Sessions"
            min="1"
            max="64"
            required
          />
          <.input
            field={@form[:max_total_bandwidth_bps]}
            type="number"
            label="Max Aggregate Bandwidth (bps)"
            min="100000"
            max="100000000000"
            required
          />
        </div>

        <div class="flex flex-wrap gap-6">
          <.input field={@form[:enabled]} type="checkbox" label="Responder enabled" />
          <.input
            field={@form[:udp_enabled]}
            type="checkbox"
            label="Enable single-port HMAC UDP probes"
          />
        </div>

        <div class="flex items-center justify-end gap-2">
          <.ui_button
            variant="neutral"
            size="sm"
            patch={~p"/settings/networks/netperf?tab=responders"}
          >
            Cancel
          </.ui_button>
          <.ui_button id="netperf-save-responder-btn" type="submit" variant="primary" size="sm">
            Save Hub Responder
          </.ui_button>
        </div>
      </.form>
    </.ui_panel>
    """
  end

  defp profile_form(assigns) do
    ~H"""
    <.ui_panel id="netperf-profile-form-panel">
      <:header>
        <div>
          <h2 class="text-base font-semibold text-sr-ink">
            {if @show_form == :new_profile,
              do: "New Network Performance Profile",
              else: "Edit Network Performance Profile"}
          </h2>
          <p class="text-xs text-sr-muted">
            Bounded protocol, direction, paced bandwidth ceiling, and duration parameters.
          </p>
        </div>
        <.ui_button variant="ghost" size="sm" patch={~p"/settings/networks/netperf?tab=profiles"}>
          Cancel
        </.ui_button>
      </:header>

      <.form
        for={@form}
        id="netperf-profile-form"
        phx-change="validate_profile"
        phx-submit="save_profile"
        class="space-y-4"
      >
        <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
          <.input field={@form[:name]} type="text" label="Profile Name" required />
          <.input field={@form[:description]} type="text" label="Description" />
        </div>

        <div class="grid grid-cols-1 gap-4 md:grid-cols-3">
          <.input
            field={@form[:protocol]}
            type="select"
            label="Protocol"
            options={[{"TCP (mTLS)", "tcp"}, {"UDP (HMAC)", "udp"}]}
          />
          <.input
            field={@form[:direction]}
            type="select"
            label="Direction"
            options={[
              {"Upload (Spoke -> Hub)", "upload"},
              {"Download (Hub -> Spoke)", "download"},
              {"Bidirectional", "bidirectional"}
            ]}
          />
          <.input
            field={@form[:bandwidth_bps]}
            type="number"
            label="Bandwidth Ceiling (bps)"
            min="100000"
            max="10000000000"
            required
          />
        </div>

        <div class="grid grid-cols-1 gap-4 md:grid-cols-4">
          <.input
            field={@form[:duration_sec]}
            type="number"
            label="Duration (sec)"
            min="1"
            max="30"
            required
          />
          <.input
            field={@form[:omit_sec]}
            type="number"
            label="Omit Warm-up (sec)"
            min="0"
            max="5"
            required
          />
          <.input
            field={@form[:parallel]}
            type="number"
            label="Parallel Streams"
            min="1"
            max="8"
            required
          />
          <.input
            field={@form[:packet_length]}
            type="number"
            label="Packet Length (bytes)"
            min="64"
            max="65507"
            required
          />
        </div>

        <.input
          field={@form[:interval_seconds]}
          type="number"
          label="Schedule Interval (sec)"
          min="60"
          max="86400"
          required
        />

        <div class="flex items-center justify-end gap-2">
          <.ui_button variant="neutral" size="sm" patch={~p"/settings/networks/netperf?tab=profiles"}>
            Cancel
          </.ui_button>
          <.ui_button id="netperf-save-profile-btn" type="submit" variant="primary" size="sm">
            Save Profile
          </.ui_button>
        </div>
      </.form>
    </.ui_panel>
    """
  end

  defp active_run_banner(assigns) do
    variant =
      case assigns.active_run.state do
        :completed -> "success"
        :failed -> "error"
        _ -> "info"
      end

    assigns = assign(assigns, :variant, variant)

    ~H"""
    <.ui_alert id="netperf-active-run-status" variant={@variant}>
      <div class="flex w-full flex-col gap-1 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <div class="font-semibold">
            On-Demand Test ({@active_run.sender_agent_id} → {@active_run.responder_agent_id}) · {String.upcase(
              to_string(@active_run.state)
            )}
          </div>
          <div class="text-xs opacity-90">{@active_run.message}</div>
        </div>
        <div :if={is_map(@active_run.result_payload)} class="flex flex-wrap gap-3 font-mono text-xs">
          <span :if={bps = @active_run.result_payload["bits_per_second"]}>
            {Forms.format_bps(bps)}
          </span>
          <span :if={jitter = @active_run.result_payload["jitter_ms"]}>
            jitter: {jitter} ms
          </span>
          <span :if={loss = @active_run.result_payload["loss_percent"]}>
            loss: {loss}%
          </span>
        </div>
      </div>
    </.ui_alert>
    """
  end

  defp recent_runs_panel(assigns) do
    ~H"""
    <.ui_panel id="netperf-recent-runs-panel">
      <:header>
        <div>
          <h2 class="text-base font-semibold text-sr-ink">Recent On-Demand Runs</h2>
          <p class="text-xs text-sr-muted">
            Interactive `netperf.run` ControlStream commands dispatched from Settings.
          </p>
        </div>
      </:header>

      <div class="overflow-x-auto">
        <table
          id="netperf-recent-runs-table"
          class={ui_table_class(size: "sm", zebra: true, class: "w-full")}
        >
          <thead>
            <tr>
              <th>Time</th>
              <th>Sender</th>
              <th>Responder</th>
              <th>Params</th>
              <th>Status</th>
              <th>Result</th>
            </tr>
          </thead>
          <tbody id="netperf-recent-runs-tbody" phx-update="stream">
            <tr :for={{id, run} <- @streams.recent_runs} id={id}>
              <td class="text-xs text-sr-muted">
                <.user_time
                  id={"netperf-run-time-#{run.id}"}
                  value={run.completed_at || run.inserted_at}
                  timezone={@timezone}
                  style={:compact}
                />
              </td>
              <td class="font-mono text-xs text-sr-ink">{run.agent_id}</td>
              <td class="font-mono text-xs text-sr-ink">
                {(run.payload || %{})["responder_agent_id"] || "—"}
              </td>
              <td class="text-xs text-sr-muted">
                {String.upcase(to_string((run.payload || %{})["protocol"] || "tcp"))} · {(run.payload ||
                                                                                            %{})[
                  "direction"
                ] || "upload"}
              </td>
              <td>
                <.ui_badge variant={badge_variant_for(run.status)} size="xs">
                  {run.status}
                </.ui_badge>
              </td>
              <td class="font-mono text-xs text-sr-ink">
                <%= if bps = get_in(run.result_payload || %{}, ["bits_per_second"]) do %>
                  {Forms.format_bps(bps)}
                <% else %>
                  {run.message || "—"}
                <% end %>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <p
        :if={@count == 0}
        id="netperf-recent-runs-empty"
        class="py-4 text-center text-sm text-sr-muted"
      >
        No on-demand runs recorded yet.
      </p>
    </.ui_panel>
    """
  end

  defp run_modal(assigns) do
    responder_options =
      Enum.map(assigns.responders, fn responder ->
        status = if responder.enabled, do: "", else: " (disabled)"
        {"#{responder.name} (#{responder.agent_uid})#{status}", responder.agent_uid}
      end)

    profile_options = Enum.map(assigns.profiles, &{&1.name, to_string(&1.id)})

    assigns =
      assigns
      |> assign(:responder_options, responder_options)
      |> assign(:profile_options, profile_options)

    ~H"""
    <.ui_modal
      id="netperf-run-modal"
      open={@open}
      size="lg"
      on_cancel="close_run_modal"
    >
      <:title>Run On-Demand Network Performance Test</:title>

      <.ui_alert :if={@run_error} id="netperf-run-error" variant="error">
        {@run_error}
      </.ui_alert>

      <.form
        :if={@run_form}
        for={@run_form}
        id="netperf-run-form"
        phx-change="validate_run"
        phx-submit="run_netperf_test"
        class="space-y-3"
      >
        <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <.agent_picker_field
            id="netperf-run-sender-picker"
            label="Spoke Sender Agent"
            field_name="run[sender_agent_id]"
            mode={:single}
            selected={@run_form[:sender_agent_id].value}
            placeholder="Browse & select sender agent..."
            target_key="run_sender"
            agents_by_uid={@agents_by_uid}
            online_agent_ids={@online_agent_ids}
            netperf_agent_ids={@netperf_agent_ids}
          />
          <.input
            field={@run_form[:responder_agent_id]}
            type="select"
            label="Hub Responder Agent"
            options={@responder_options}
            prompt="Select responder..."
            required
          />
        </div>

        <div class="grid grid-cols-1 gap-3 sm:grid-cols-3">
          <.input field={@run_form[:target_address]} type="text" label="Target Address" required />
          <.input
            field={@run_form[:target_port]}
            type="number"
            label="Target Port"
            min="1"
            max="65535"
            required
          />
          <.input
            field={@run_form[:profile_id]}
            type="select"
            label="Profile Preset (optional)"
            options={@profile_options}
            prompt="Custom parameters"
          />
        </div>

        <div class="grid grid-cols-1 gap-3 sm:grid-cols-3">
          <.input
            field={@run_form[:protocol]}
            type="select"
            label="Protocol"
            options={[{"TCP (mTLS)", "tcp"}, {"UDP (HMAC)", "udp"}]}
          />
          <.input
            field={@run_form[:direction]}
            type="select"
            label="Direction"
            options={[
              {"Upload", "upload"},
              {"Download", "download"},
              {"Bidirectional", "bidirectional"}
            ]}
          />
          <.input
            field={@run_form[:bandwidth_bps]}
            type="number"
            label="Bandwidth Ceiling (bps)"
            min="100000"
            max="10000000000"
            required
          />
        </div>

        <div class="grid grid-cols-2 gap-3 sm:grid-cols-4">
          <.input
            field={@run_form[:duration_sec]}
            type="number"
            label="Duration (s)"
            min="1"
            max="30"
            required
          />
          <.input
            field={@run_form[:omit_sec]}
            type="number"
            label="Omit (s)"
            min="0"
            max="5"
            required
          />
          <.input
            field={@run_form[:parallel]}
            type="number"
            label="Parallel"
            min="1"
            max="8"
            required
          />
          <.input
            field={@run_form[:packet_length]}
            type="number"
            label="Packet Size (B)"
            min="64"
            max="65507"
            required
          />
        </div>

        <div class="flex items-center justify-end gap-2 pt-2">
          <.ui_button type="button" variant="neutral" size="sm" phx-click="close_run_modal">
            Cancel
          </.ui_button>
          <.ui_button id="netperf-submit-run-btn" type="submit" variant="primary" size="sm">
            Dispatch netperf.run
          </.ui_button>
        </div>
      </.form>
    </.ui_modal>
    """
  end

  defp loaded_assoc?(%Ash.NotLoaded{}), do: false
  defp loaded_assoc?(nil), do: false
  defp loaded_assoc?([]), do: false
  defp loaded_assoc?(_), do: true

  defp user_timezone(%{user: %{timezone: tz}}) when is_binary(tz) and tz != "", do: tz
  defp user_timezone(_), do: "Etc/UTC"
end
