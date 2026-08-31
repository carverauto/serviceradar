defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.Index.View.Discovery do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.Settings.NetworksLive.Index.CommandStatus

  alias ServiceRadarWebNGWeb.Settings.NetworksLive.Index.View.MapperJobForm

  attr :jobs, :list, required: true
  attr :show_form, :any, default: nil
  attr :form, :any, default: nil
  attr :seeds_text, :string, default: ""
  attr :mapper_agents, :list, default: []
  attr :unifi_form, :any, default: nil
  attr :unifi_present, :boolean, default: false
  attr :mikrotik, :map, default: %{}
  attr :mapper_command_statuses, :map, default: %{}
  attr :can_manage_networks, :boolean, default: false
  attr :timezone, :string, required: true

  def render(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div class="flex items-center justify-between w-full">
          <div>
            <div class="text-sm font-semibold">Discovery Jobs</div>
            <p class="text-xs text-sr-muted">
              {length(@jobs)} job(s) configured
            </p>
          </div>
          <%= if @show_form in [:new_mapper_job, :edit_mapper_job] do %>
            <.link navigate={~p"/settings/networks/discovery"}>
              <.ui_button variant="ghost" size="sm">Cancel</.ui_button>
            </.link>
          <% else %>
            <.link navigate={~p"/settings/networks/discovery/new"}>
              <.ui_button variant="primary" size="sm">
                <.icon name="hero-plus" class="size-4" /> New Job
              </.ui_button>
            </.link>
          <% end %>
        </div>
      </:header>

      <%= if @show_form in [:new_mapper_job, :edit_mapper_job] do %>
        <MapperJobForm.render
          form={@form}
          seeds_text={@seeds_text}
          agents={@mapper_agents}
          unifi_form={@unifi_form}
          unifi_present={@unifi_present}
          mikrotik={@mikrotik}
        />
      <% else %>
        <div class="sr-ui-table-shell">
          <table class={ui_table_class(size: "sm")}>
            <thead>
              <tr class="text-xs uppercase tracking-wide text-sr-muted">
                <th>Status</th>
                <th>Name</th>
                <th>Interval</th>
                <th>Type</th>
                <th>Partition</th>
                <th>Last Run</th>
                <th>Run Status</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              <tr :if={@jobs == []}>
                <td colspan="8" class="text-center text-sr-muted py-8">
                  No discovery jobs configured. Create one to start mapper discovery.
                </td>
              </tr>
              <%= for job <- @jobs do %>
                <tr class="hover:bg-sr-subtle/40">
                  <td>
                    <button
                      phx-click="toggle_mapper_job"
                      phx-value-id={job.id}
                      class="flex items-center gap-1.5 cursor-pointer"
                    >
                      <span class={"size-2 rounded-full #{if job.enabled, do: "bg-success", else: "bg-sr-muted/30"}"}></span>
                      <span class="text-xs">{if job.enabled, do: "Enabled", else: "Disabled"}</span>
                    </button>
                  </td>
                  <td>
                    <div class="font-medium">{job.name}</div>
                    <p :if={job.description} class="text-xs text-sr-muted truncate max-w-xs">
                      {job.description}
                    </p>
                  </td>
                  <td class="text-xs font-mono">Every {job.interval}</td>
                  <td class="text-xs capitalize">{job.discovery_type}</td>
                  <td class="text-xs">{job.partition}</td>
                  <td class="text-xs text-sr-muted">
                    <.user_time
                      id={"settings-discovery-job-#{job.id}-last-run-at"}
                      value={job.last_run_at}
                      timezone={@timezone}
                      style={:compact}
                      fallback="Never"
                    />
                  </td>
                  <td class="text-xs">
                    <%= if status = Map.get(@mapper_command_statuses, job.id) do %>
                      <.ui_badge variant={command_status_variant(status)} size="xs">
                        {command_status_label(status)}
                      </.ui_badge>
                    <% else %>
                      <%= if job.last_run_status do %>
                        <.ui_badge variant={mapper_run_status_variant(job.last_run_status)} size="xs">
                          {mapper_run_status_label(job.last_run_status)}
                        </.ui_badge>
                      <% else %>
                        <span class="text-xs text-sr-muted">—</span>
                      <% end %>
                      <p
                        :if={is_integer(job.last_run_interface_count)}
                        class="text-[10px] text-sr-muted mt-0.5"
                      >
                        {job.last_run_interface_count} interfaces
                      </p>
                      <p
                        :if={is_binary(job.last_run_error)}
                        class="text-[10px] text-error/80 mt-0.5 truncate max-w-[180px]"
                        title={job.last_run_error}
                      >
                        {job.last_run_error}
                      </p>
                    <% end %>
                  </td>
                  <td>
                    <div class="flex items-center gap-1">
                      <.ui_button
                        :if={@can_manage_networks}
                        id={"run-mapper-job-#{job.id}"}
                        variant="ghost"
                        size="xs"
                        phx-click="run_mapper_job"
                        phx-value-id={job.id}
                      >
                        <.icon name="hero-play" class="size-3" />
                      </.ui_button>
                      <.link navigate={~p"/settings/networks/discovery/#{job.id}/edit"}>
                        <.ui_button variant="ghost" size="xs">
                          <.icon name="hero-pencil" class="size-3" />
                        </.ui_button>
                      </.link>
                      <.ui_button
                        variant="ghost"
                        size="xs"
                        phx-click="delete_mapper_job"
                        phx-value-id={job.id}
                        data-confirm="Are you sure you want to delete this discovery job?"
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
      <% end %>
    </.ui_panel>
    """
  end
end
