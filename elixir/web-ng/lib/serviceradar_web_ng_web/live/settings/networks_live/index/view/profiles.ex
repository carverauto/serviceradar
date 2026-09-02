defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.Index.View.Profiles do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Formatting

  attr :profiles, :list, required: true

  def render(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div class="flex items-center justify-between w-full">
          <div>
            <div class="text-sm font-semibold">Scanner Profiles</div>
            <p class="text-xs text-sr-muted">
              {length(@profiles)} profile(s) available
            </p>
          </div>
          <.link navigate={~p"/settings/networks/profiles/new"}>
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
              <th>Name</th>
              <th>Ports</th>
              <th>Modes</th>
              <th>Settings</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@profiles == []}>
              <td colspan="5" class="text-center text-sr-muted py-8">
                No scanner profiles configured. Create one to define reusable scan settings.
              </td>
            </tr>
            <%= for profile <- @profiles do %>
              <tr class="hover:bg-sr-subtle/40">
                <td>
                  <div class="font-medium">{profile.name}</div>
                  <p :if={profile.description} class="text-xs text-sr-muted truncate max-w-xs">
                    {profile.description}
                  </p>
                </td>
                <td class="text-xs font-mono">
                  {format_ports_for_modes(profile.ports, profile.sweep_modes)}
                </td>
                <td>
                  <div class="flex flex-wrap gap-1">
                    <%= for mode <- (profile.sweep_modes || []) do %>
                      <.ui_badge variant="ghost" size="xs">{mode}</.ui_badge>
                    <% end %>
                  </div>
                </td>
                <td class="text-xs">
                  <div>Concurrency: {profile.concurrency}</div>
                  <div>Timeout: {profile.timeout}</div>
                </td>
                <td>
                  <div class="flex items-center gap-1">
                    <.link navigate={~p"/settings/networks/profiles/#{profile.id}/edit"}>
                      <.ui_button variant="ghost" size="xs">
                        <.icon name="hero-pencil" class="size-3" />
                      </.ui_button>
                    </.link>
                    <.ui_button
                      variant="ghost"
                      size="xs"
                      phx-click="delete_profile"
                      phx-value-id={profile.id}
                      data-confirm="Are you sure you want to delete this scanner profile?"
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
