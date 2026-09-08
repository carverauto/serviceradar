defmodule ServiceRadarWebNGWeb.DeviceLive.AgentComponents do
  @moduledoc false

  use ServiceRadarWebNGWeb, :html

  # ---------------------------------------------------------------------------
  # Agents Section (linked to OCSF Agents)
  # ---------------------------------------------------------------------------

  attr(:device_row, :map, required: true)

  def agents_section(assigns) do
    agent_list = Map.get(assigns.device_row, "agent_list") || []
    has_agents = is_list(agent_list) and agent_list != []

    assigns =
      assigns
      |> assign(:agent_list, agent_list)
      |> assign(:has_agents, has_agents)

    ~H"""
    <div :if={@has_agents} class="rounded-xl border border-sr-line bg-sr-surface">
      <div class="px-4 py-3 border-b border-sr-line">
        <div class="flex items-center gap-2">
          <.icon name="hero-cpu-chip" class="size-4 text-accent" />
          <span class="text-sm font-semibold">Agents</span>
          <span class="text-xs text-sr-muted">({length(@agent_list)} agents)</span>
        </div>
      </div>
      <div class="p-4">
        <div class="sr-ui-table-shell">
          <table class={ui_table_class(size: "xs", class: "w-full")}>
            <thead>
              <tr>
                <th class="text-xs">UID</th>
                <th class="text-xs">Name</th>
                <th class="text-xs">Type</th>
                <th class="text-xs">Version</th>
                <th class="text-xs">Vendor</th>
              </tr>
            </thead>
            <tbody>
              <%= for agent <- Enum.take(@agent_list, 10) do %>
                <tr class="hover:bg-sr-subtle/40">
                  <td class="font-mono text-xs">
                    <.link
                      navigate={~p"/agents/#{agent_uid(agent)}"}
                      class="text-sr-brand hover:underline hover:underline"
                    >
                      {truncate_uid(agent_uid(agent))}
                    </.link>
                  </td>
                  <td class="text-xs">{Map.get(agent, "name") || "—"}</td>
                  <td class="text-xs">
                    <.agent_type_badge
                      type_id={Map.get(agent, "type_id")}
                      type={Map.get(agent, "type")}
                    />
                  </td>
                  <td class="font-mono text-xs">{Map.get(agent, "version") || "—"}</td>
                  <td class="text-xs">{Map.get(agent, "vendor_name") || "—"}</td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
        <div :if={length(@agent_list) > 10} class="text-xs text-sr-muted mt-2">
          Showing 10 of {length(@agent_list)} agents
        </div>
      </div>
    </div>
    """
  end

  defp agent_uid(agent) when is_map(agent), do: Map.get(agent, "uid") || ""
  defp agent_uid(_), do: ""

  defp truncate_uid(uid) when is_binary(uid) and byte_size(uid) > 24 do
    String.slice(uid, 0, 24) <> "..."
  end

  defp truncate_uid(uid), do: uid

  attr(:type_id, :any, default: nil)
  attr(:type, :any, default: nil)

  defp agent_type_badge(assigns) do
    type_name = assigns.type || get_agent_type_name(assigns.type_id)
    variant = agent_type_variant(assigns.type_id)
    assigns = assigns |> assign(:type_name, type_name) |> assign(:variant, variant)

    ~H"""
    <.ui_badge size="xs" variant={@variant}>{@type_name}</.ui_badge>
    """
  end

  defp get_agent_type_name(nil), do: "Unknown"
  defp get_agent_type_name(0), do: "Unknown"
  defp get_agent_type_name(1), do: "EDR"
  defp get_agent_type_name(4), do: "Performance"
  defp get_agent_type_name(6), do: "Log"
  defp get_agent_type_name(99), do: "Other"
  defp get_agent_type_name(_), do: "Unknown"

  defp agent_type_variant(1), do: "error"
  defp agent_type_variant(4), do: "info"
  defp agent_type_variant(6), do: "warning"
  defp agent_type_variant(99), do: "ghost"
  defp agent_type_variant(_), do: "ghost"
end
