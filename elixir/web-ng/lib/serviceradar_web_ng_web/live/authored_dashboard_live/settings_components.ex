defmodule ServiceRadarWebNGWeb.AuthoredDashboardLive.SettingsComponents do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  alias ServiceRadarWebNGWeb.AuthoredDashboardLive.AccessControls

  attr :dashboard, :any, required: true
  attr :access_grants, :list, default: []
  attr :user_grant_form, :any, required: true
  attr :group_grant_form, :any, required: true
  attr :users, :list, default: []
  attr :user_groups, :list, default: []
  attr :can_view_groups?, :boolean, default: false

  def sharing_settings(assigns) do
    ~H"""
    <section class="rounded-lg border border-base-300">
      <div class="flex flex-col gap-2 border-b border-base-300 px-3 py-2 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h3 class="text-sm font-semibold">Sharing</h3>
          <p class="text-xs text-base-content/70">
            Visibility is {@dashboard.visibility}; explicit grants add users or reusable groups.
          </p>
        </div>
        <span class="badge badge-outline">{length(@access_grants)} grants</span>
      </div>

      <div class="grid grid-cols-1 gap-6 p-3 lg:grid-cols-[1fr_360px]">
        <div class="space-y-3">
          <div
            :if={@access_grants == []}
            class="rounded-lg border border-dashed border-base-300 p-4 text-sm text-base-content/60"
          >
            No explicit sharing grants yet.
          </div>

          <div
            :for={grant <- @access_grants}
            class="flex flex-col gap-3 rounded-lg border border-base-300 p-3 sm:flex-row sm:items-center sm:justify-between"
          >
            <div>
              <div class="text-sm font-medium">{AccessControls.grant_label(grant)}</div>
              <div class="mt-1 flex flex-wrap gap-2">
                <span class="badge badge-sm">{grant.subject_type}</span>
                <span class="badge badge-sm badge-outline">{grant.access}</span>
              </div>
            </div>
            <button
              type="button"
              class="btn btn-xs btn-error btn-outline"
              phx-click="revoke_grant"
              phx-value-id={grant.id}
            >
              <.icon name="hero-trash" class="size-4" /> Revoke
            </button>
          </div>
        </div>

        <div class="space-y-4">
          <.form
            for={@user_grant_form}
            as={:grant}
            phx-change="validate_user_grant"
            phx-submit="grant_user"
            class="space-y-3"
          >
            <.input
              field={@user_grant_form[:subject_user_id]}
              type="select"
              label="User"
              options={AccessControls.user_select_options(@users)}
            />
            <.input
              field={@user_grant_form[:access]}
              type="select"
              id="user_grant_access"
              label="Access"
              options={AccessControls.access_select_options()}
            />
            <button type="submit" class="btn btn-sm" disabled={@users == []}>
              <.icon name="hero-user-plus" class="size-4" /> Grant User
            </button>
          </.form>

          <.form
            :if={@can_view_groups?}
            for={@group_grant_form}
            as={:grant}
            phx-change="validate_group_grant"
            phx-submit="grant_group"
            class="space-y-3 border-t border-base-300 pt-4"
          >
            <.input
              field={@group_grant_form[:subject_group_id]}
              type="select"
              label="Group"
              options={AccessControls.group_select_options(@user_groups)}
            />
            <.input
              field={@group_grant_form[:access]}
              type="select"
              id="group_grant_access"
              label="Access"
              options={AccessControls.access_select_options()}
            />
            <button type="submit" class="btn btn-sm" disabled={@user_groups == []}>
              <.icon name="hero-user-group" class="size-4" /> Grant Group
            </button>
          </.form>
        </div>
      </div>
    </section>
    """
  end

  attr :dashboard, :any, required: true
  attr :report_schedule_form, :any, required: true

  def report_schedule_settings(assigns) do
    ~H"""
    <section class="rounded-lg border border-base-300">
      <div class="border-b border-base-300 px-3 py-2">
        <h3 class="text-sm font-semibold">Email Reports</h3>
        <p class="text-xs text-base-content/55">
          One scanner job picks up due schedules and enqueues delivery attempts.
        </p>
      </div>

      <div class="grid grid-cols-1 gap-6 p-3 lg:grid-cols-[1fr_360px]">
        <div class="space-y-3">
          <div
            :if={(@dashboard.report_schedules || []) == []}
            class="rounded-lg border border-dashed border-base-300 p-4 text-sm text-base-content/60"
          >
            No report schedules yet.
          </div>

          <div
            :for={schedule <- @dashboard.report_schedules || []}
            class="rounded-lg border border-base-300 p-3"
          >
            <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
              <div>
                <div class="text-sm font-medium">{schedule.name}</div>
                <div class="mt-1 font-mono text-xs text-base-content/70">
                  {schedule.cron} · {schedule.timezone}
                </div>
              </div>
              <div class="flex items-center gap-2">
                <span class="badge badge-outline">
                  {schedule.last_status || if(schedule.enabled, do: "enabled", else: "disabled")}
                </span>
                <button
                  type="button"
                  class="btn btn-xs btn-ghost"
                  phx-click="toggle_report_schedule"
                  phx-value-id={schedule.id}
                >
                  <.icon
                    name={if(schedule.enabled, do: "hero-pause", else: "hero-play")}
                    class="size-4"
                  />
                </button>
                <button
                  type="button"
                  class="btn btn-xs btn-ghost text-error"
                  phx-click="delete_report_schedule"
                  phx-value-id={schedule.id}
                >
                  <.icon name="hero-trash" class="size-4" />
                </button>
              </div>
            </div>
            <p class="mt-2 text-xs text-base-content/70">
              Next due: {format_value(schedule.next_due_at)}
            </p>
          </div>
        </div>

        <.form
          for={@report_schedule_form}
          as={:schedule}
          phx-change="validate_report_schedule"
          phx-submit="create_report_schedule"
          class="space-y-3"
        >
          <.input field={@report_schedule_form[:name]} type="text" label="Name" />
          <.input field={@report_schedule_form[:cron]} type="text" label="Cron" />
          <.input field={@report_schedule_form[:timezone]} type="text" label="Timezone" />
          <.input field={@report_schedule_form[:recipients]} type="textarea" label="Recipients" />
          <button type="submit" class="btn btn-sm btn-primary">
            <.icon name="hero-envelope" class="size-4" /> Schedule Report
          </button>
        </.form>
      </div>
    </section>
    """
  end

  defp format_value(%DateTime{} = value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M:%S")
  defp format_value(%NaiveDateTime{} = value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M:%S")
  defp format_value(value) when is_binary(value), do: value
  defp format_value(value) when is_integer(value), do: Integer.to_string(value)
  defp format_value(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp format_value(value) when is_boolean(value), do: to_string(value)
  defp format_value(nil), do: ""
  defp format_value(value), do: inspect(value)
end
