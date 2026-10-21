defmodule ServiceRadarWebNGWeb.Admin.PluginPackageLive.OrphanedAssignments do
  @moduledoc """
  Needs-attention panel for plugin assignments that still run after their
  owner went away.

  An enabled policy assignment whose credential rule or target policy is
  missing, disabled, or no longer covers the agent is not retracted
  automatically. This panel lists them and lets an operator retract one or all
  of them. The plugins page loads the list only for operators with
  `settings.plugins.manage` and owns the events
  (`retract_orphaned_assignment`, `retract_all_orphaned_assignments`).
  """

  use ServiceRadarWebNGWeb, :html

  attr :orphans, :list, required: true

  def panel(assigns) do
    ~H"""
    <.ui_panel :if={@orphans != []} id="orphaned-plugin-assignments">
      <:header>
        <div>
          <div class="flex items-center gap-2 text-sm font-semibold">
            <.icon name="hero-exclamation-triangle" class="size-4 text-warning" /> Needs attention
            <.ui_badge id="orphaned-plugin-assignments-count" variant="warning" size="xs">
              {length(@orphans)}
            </.ui_badge>
          </div>
          <p class="text-xs text-sr-muted">
            These assignments are still enabled although the credential rule or target policy
            that created them is missing, disabled, or no longer covers the agent.
          </p>
        </div>
        <.ui_button
          id="retract-all-orphaned-assignments"
          variant="warning"
          size="sm"
          phx-click="retract_all_orphaned_assignments"
          data-confirm="Disable every listed assignment?"
        >
          Retract all
        </.ui_button>
      </:header>

      <div class="overflow-x-auto">
        <table class="w-full text-left text-sm">
          <thead class="text-xs uppercase text-sr-muted">
            <tr>
              <th class="px-3 py-2">Plugin</th>
              <th class="px-3 py-2">Agent</th>
              <th class="px-3 py-2">Owner</th>
              <th class="px-3 py-2">Owner state</th>
              <th class="px-3 py-2"></th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={orphan <- @orphans}
              id={"orphaned-assignment-#{orphan.assignment_id}"}
              class="border-t border-sr-line"
            >
              <td class="px-3 py-2">
                <div class="font-medium text-sr-ink">{orphan.package_name || orphan.plugin_id}</div>
                <div :if={orphan.package_version} class="text-xs text-sr-muted">
                  {orphan.package_version}
                </div>
              </td>
              <td class="px-3 py-2 font-mono text-xs">{orphan.agent_uid}</td>
              <td class="px-3 py-2">
                <div>{owner_kind_label(orphan.owner_kind)}</div>
                <div class="font-mono text-xs text-sr-muted">
                  {orphan.owner_name || orphan.owner_id}
                </div>
              </td>
              <td class="px-3 py-2">
                <.ui_badge variant="warning" size="xs">
                  {owner_state_label(orphan.owner_state)}
                </.ui_badge>
              </td>
              <td class="px-3 py-2 text-right">
                <.ui_button
                  id={"retract-orphaned-assignment-#{orphan.assignment_id}"}
                  variant="ghost"
                  size="xs"
                  phx-click="retract_orphaned_assignment"
                  phx-value-id={orphan.assignment_id}
                >
                  Retract
                </.ui_button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </.ui_panel>
    """
  end

  defp owner_kind_label(:credential_rule), do: "Credential rule"
  defp owner_kind_label(:plugin_target_policy), do: "Target policy"

  defp owner_state_label(:missing), do: "Deleted"
  defp owner_state_label(:disabled), do: "Disabled"
  defp owner_state_label(:out_of_scope), do: "Out of scope"
end
