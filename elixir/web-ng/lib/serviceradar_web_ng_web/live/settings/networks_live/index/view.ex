defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.Index.View do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.Settings.NetworksLive.FormComponents
  import ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Executions, only: [merge_running_with_progress: 2]

  alias ServiceRadarWebNGWeb.Settings.NetworksLive.Index.View.ActiveScans
  alias ServiceRadarWebNGWeb.Settings.NetworksLive.Index.View.Discovery
  alias ServiceRadarWebNGWeb.Settings.NetworksLive.Index.View.InventoryCleanup
  alias ServiceRadarWebNGWeb.Settings.NetworksLive.Index.View.Navigation
  alias ServiceRadarWebNGWeb.Settings.NetworksLive.Index.View.Profiles
  alias ServiceRadarWebNGWeb.Settings.NetworksLive.Index.View.SweepGroups
  alias ServiceRadarWebNGWeb.Settings.Shell

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
        <div class="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold text-sr-ink">{page_heading(@live_action)}</h1>
            <p class="text-sm text-sr-muted">
              {page_subheading(@live_action)}
            </p>
          </div>
        </div>

        <%= if discovery_action?(@live_action) do %>
          <Discovery.render
            jobs={@mapper_jobs}
            show_form={@show_mapper_form}
            form={@mapper_form}
            seeds_text={@mapper_seeds_text}
            mapper_agents={@mapper_agents}
            unifi_form={@mapper_unifi_form}
            unifi_present={@mapper_unifi_present}
            mikrotik={@mapper_mikrotik}
            mapper_command_statuses={@mapper_command_statuses}
            can_manage_networks={@can_manage_networks}
            timezone={@current_scope.user.timezone || "Etc/UTC"}
          />
        <% else %>
          <%= if @show_form in [:new_group, :edit_group] do %>
            <.group_form
              form={@form}
              show_form={@show_form}
              profiles={@sweep_profiles}
              agent_picker={@agent_picker}
              agent_picker_open={@agent_picker_open}
              agent_picker_selected_rows={@agent_picker_selected_rows}
              agent_picker_summary_agent={@agent_picker_summary_agent}
              target_device_count={@target_device_count}
              builder_open={@builder_open}
              builder_sync={@builder_sync}
              builder={@builder}
            />
          <% else %>
            <%= if @show_form in [:new_profile, :edit_profile] do %>
              <.profile_form
                form={@form}
                show_form={@show_form}
                can_enable_banner_grab={@can_enable_banner_grab}
                banner_preview_device_count={@banner_preview_device_count}
                banner_grab_draft={Map.get(assigns, :banner_grab_draft)}
              />
            <% else %>
              <%= if @show_form == :show_group do %>
                <.group_detail
                  group={@selected_group}
                  summary_agents={@sweep_group_summary_agents}
                  timezone={@current_scope.user.timezone || "Etc/UTC"}
                />
              <% else %>
                <Navigation.render
                  active_tab={@active_tab}
                  running_count={
                    length(merge_running_with_progress(@running_executions, @execution_progress))
                  }
                />

                <%= case @active_tab do %>
                  <% :groups -> %>
                    <SweepGroups.render
                      groups={@sweep_groups}
                      summary_agents={@sweep_group_summary_agents}
                      sweep_command_statuses={@sweep_command_statuses}
                      can_manage_networks={@can_manage_networks}
                      timezone={@current_scope.user.timezone || "Etc/UTC"}
                    />
                  <% :profiles -> %>
                    <Profiles.render profiles={@sweep_profiles} />
                  <% :active_scans -> %>
                    <ActiveScans.render
                      running={merge_running_with_progress(@running_executions, @execution_progress)}
                      recent={@recent_executions}
                      groups={@sweep_groups}
                      execution_progress={@execution_progress}
                      timezone={@current_scope.user.timezone || "Etc/UTC"}
                    />
                  <% :cleanup -> %>
                    <InventoryCleanup.render form={@cleanup_form} settings={@cleanup_settings} />
                <% end %>
              <% end %>
            <% end %>
          <% end %>
        <% end %>
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end

  # The discovery-jobs live_actions share this LiveView with the sweep-profile
  # ones; give them a distinct H1/subtitle so `/settings/networks` (Sweep
  # Profiles) and `/settings/networks/discovery` (Discovery Jobs) are not
  # visually identical.
  @discovery_actions [:discovery, :new_mapper_job, :edit_mapper_job]

  defp discovery_action?(action), do: action in @discovery_actions

  defp page_heading(action) when action in @discovery_actions, do: "Discovery Jobs"
  defp page_heading(_action), do: "Network Sweeps"

  defp page_subheading(action) when action in @discovery_actions,
    do: "View active discovery jobs, mapper runs, and trigger frequencies."

  defp page_subheading(_action), do: "Configure network discovery sweeps and scanner profiles."
end
