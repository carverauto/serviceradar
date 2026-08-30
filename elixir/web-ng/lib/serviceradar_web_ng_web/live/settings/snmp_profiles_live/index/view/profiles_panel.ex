defmodule ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.View.ProfilesPanel do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Provenance, only: [plugin_badge: 1]

  import ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Targeting,
    only: [format_target_count: 1, target_count_title: 1]

  attr :profiles, :list, required: true
  attr :profile_target_counts, :map, default: %{}

  def profiles_panel(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div class="flex items-center justify-between w-full">
          <div>
            <div class="text-sm font-semibold">SNMP Profiles</div>
            <p class="text-xs text-sr-muted">
              {length(@profiles)} profile(s) configured
            </p>
          </div>
          <.link navigate={~p"/settings/snmp/new"}>
            <.ui_button variant="primary" size="sm">
              <.icon name="hero-plus" class="size-4" /> New Profile
            </.ui_button>
          </.link>
        </div>
      </:header>

      <div class="sr-ui-table-shell">
        <table class={ui_table_class(size: "sm")}>
          <thead>
            <tr class="text-xs uppercase tracking-wide text-sr-muted">
              <th>Status</th>
              <th>Name</th>
              <th>Targeting</th>
              <th>Poll Interval</th>
              <th>Targets</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@profiles == []}>
              <td colspan="6" class="text-center text-sr-muted py-8">
                No SNMP profiles configured. Create one to start monitoring devices via SNMP.
              </td>
            </tr>
            <%= for profile <- @profiles do %>
              <tr class="hover:bg-sr-subtle/40">
                <td>
                  <button
                    phx-click="toggle_profile"
                    phx-value-id={profile.id}
                    class="flex items-center gap-1.5 cursor-pointer"
                  >
                    <span class={"size-2 rounded-full #{if profile.enabled, do: "bg-success", else: "bg-sr-muted/30"}"}></span>
                    <span class="text-xs">{if profile.enabled, do: "Enabled", else: "Disabled"}</span>
                  </button>
                </td>
                <td>
                  <div class="flex items-center gap-2">
                    <.link
                      navigate={~p"/settings/snmp/#{profile.id}/edit"}
                      class="font-medium hover:text-sr-brand"
                    >
                      {profile.name}
                    </.link>
                    <.ui_badge :if={profile.is_default} variant="info" size="xs">Default</.ui_badge>
                    <.plugin_badge
                      record={profile}
                      id={"snmp-profile-#{profile.id}-plugin"}
                    />
                  </div>
                  <p :if={profile.description} class="text-xs text-sr-muted truncate max-w-xs">
                    {profile.description}
                  </p>
                </td>
                <td class="text-xs max-w-xs">
                  <%= cond do %>
                    <% profile.is_default -> %>
                      <span class="text-sr-muted italic">All unmatched devices</span>
                    <% profile.target_query && profile.target_query != "" -> %>
                      <code
                        class="font-mono text-[11px] bg-sr-subtle/50 px-1.5 py-0.5 rounded truncate block max-w-[200px]"
                        title={profile.target_query}
                      >
                        {profile.target_query}
                      </code>
                    <% true -> %>
                      <span class="text-sr-muted">No targeting</span>
                  <% end %>
                </td>
                <td class="font-mono text-xs">
                  {profile.poll_interval}s
                </td>
                <td>
                  <.ui_badge
                    id={"snmp-profile-#{profile.id}-targets"}
                    variant="ghost"
                    size="xs"
                    title={target_count_title(Map.get(@profile_target_counts, profile.id))}
                  >
                    {format_target_count(Map.get(@profile_target_counts, profile.id))}
                  </.ui_badge>
                </td>
                <td>
                  <div class="flex items-center gap-1">
                    <.link navigate={~p"/settings/snmp/#{profile.id}/edit"}>
                      <.ui_button variant="ghost" size="xs" title="Edit profile">
                        <.icon name="hero-pencil" class="size-3" />
                      </.ui_button>
                    </.link>
                    <.ui_button
                      :if={!profile.is_default}
                      variant="ghost"
                      size="xs"
                      phx-click="set_default"
                      phx-value-id={profile.id}
                      title="Set as default"
                    >
                      <.icon name="hero-star" class="size-3" />
                    </.ui_button>
                    <.ui_button
                      :if={!profile.is_default}
                      variant="ghost"
                      size="xs"
                      phx-click="delete_profile"
                      phx-value-id={profile.id}
                      data-confirm="Are you sure you want to delete this profile?"
                      title="Delete profile"
                    >
                      <.icon name="hero-trash" class="size-3" />
                    </.ui_button>
                  </div>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </.ui_panel>
    """
  end
end
