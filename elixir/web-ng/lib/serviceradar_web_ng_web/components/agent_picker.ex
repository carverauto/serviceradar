defmodule ServiceRadarWebNGWeb.Components.AgentPicker do
  @moduledoc """
  Reusable searchable modal picker for selecting one or many enrolled agents.

  Designed to scale cleanly to fleets with thousands of agents: the trigger
  renders either a compact selected-agent button (single-select) or removable
  agent chips (multi-select) backed by a hidden form input, while the modal
  filters agents by UID, host, or IP and caps rendered rows.
  """

  use Phoenix.Component

  import ServiceRadarWebNGWeb.CoreComponents, only: [icon: 1]
  import ServiceRadarWebNGWeb.UIComponents, only: [ui_badge: 1, ui_button: 1, ui_modal: 1]

  @default_max_visible 50

  attr(:id, :string, required: true)
  attr(:label, :string, required: true)
  attr(:field_name, :string, required: true)
  attr(:mode, :atom, default: :single, values: [:single, :multi])
  attr(:selected, :any, default: nil)
  attr(:placeholder, :string, default: "Select an agent...")
  attr(:target_key, :string, required: true)
  attr(:open_event, :string, default: "open_agent_picker")
  attr(:remove_event, :string, default: "remove_picked_agent")
  attr(:agents_by_uid, :map, default: %{})
  attr(:online_agent_ids, :any, default: nil)
  attr(:netperf_agent_ids, :any, default: nil)

  def agent_picker_field(assigns) do
    selected_list = normalize_selected(assigns.selected, assigns.mode)
    hidden_value = if assigns.mode == :multi, do: Enum.join(selected_list, ", "), else: List.first(selected_list) || ""
    online_ids = assigns.online_agent_ids || MapSet.new()
    netperf_ids = assigns.netperf_agent_ids || MapSet.new()

    assigns =
      assigns
      |> assign(:selected_list, selected_list)
      |> assign(:hidden_value, hidden_value)
      |> assign(:online_ids, online_ids)
      |> assign(:netperf_ids, netperf_ids)

    ~H"""
    <div id={@id} class="space-y-1.5">
      <label class="block text-sm font-medium text-sr-ink">{@label}</label>
      <input type="hidden" name={@field_name} value={@hidden_value} />

      <%= if @mode == :single do %>
        <% current_uid = List.first(@selected_list) %>
        <% current_agent = current_uid && Map.get(@agents_by_uid, current_uid) %>
        <button
          type="button"
          id={"#{@id}-trigger"}
          phx-click={@open_event}
          phx-value-target={@target_key}
          class="flex w-full items-center justify-between gap-2 rounded-sr-control border border-sr-line bg-sr-control px-3 py-2 text-left text-sm text-sr-ink transition-colors hover:border-sr-line-hover"
        >
          <%= if current_uid do %>
            <span class="flex min-w-0 flex-wrap items-center gap-1.5">
              <span class="truncate font-mono text-xs font-medium text-sr-ink">{current_uid}</span>
              <span :if={current_agent && current_agent.ip} class="font-mono text-xs text-sr-muted">
                {current_agent.ip}
              </span>
              <.ui_badge :if={MapSet.member?(@online_ids, current_uid)} variant="success" size="xs">
                Online
              </.ui_badge>
              <.ui_badge :if={MapSet.member?(@netperf_ids, current_uid)} variant="info" size="xs">
                netperf
              </.ui_badge>
            </span>
          <% else %>
            <span class="text-sr-muted">{@placeholder}</span>
          <% end %>
          <.icon name="hero-magnifying-glass" class="size-4 shrink-0 text-sr-muted" />
        </button>
      <% else %>
        <div class="rounded-sr-control border border-sr-line bg-sr-control p-2 space-y-2">
          <div :if={@selected_list != []} class="flex flex-wrap gap-1.5">
            <span
              :for={uid <- @selected_list}
              class="inline-flex items-center gap-1 rounded-full border border-sr-line bg-sr-subtle px-2.5 py-0.5 font-mono text-xs text-sr-ink"
            >
              <span>{uid}</span>
              <button
                type="button"
                phx-click={@remove_event}
                phx-value-target={@target_key}
                phx-value-uid={uid}
                aria-label={"Remove #{uid}"}
                class="ml-0.5 text-sr-muted hover:text-sr-ink"
              >
                &times;
              </button>
            </span>
          </div>
          <button
            type="button"
            id={"#{@id}-trigger"}
            phx-click={@open_event}
            phx-value-target={@target_key}
            class="inline-flex items-center gap-1.5 rounded-sr-control border border-sr-line bg-sr-surface px-2.5 py-1 text-xs font-medium text-sr-ink hover:border-sr-line-hover"
          >
            <.icon name="hero-magnifying-glass" class="size-3.5 text-sr-muted" />
            <span>
              {if @selected_list == [],
                do: @placeholder,
                else: "Add or change agents (#{length(@selected_list)})"}
            </span>
          </button>
        </div>
      <% end %>
    </div>
    """
  end

  attr(:id, :string, default: "agent-picker-modal")
  attr(:open, :boolean, default: false)
  attr(:title, :string, default: "Select Agent")
  attr(:mode, :atom, default: :single, values: [:single, :multi])
  attr(:agents, :list, default: [])
  attr(:selected, :any, default: [])
  attr(:query, :string, default: "")
  attr(:only_netperf, :boolean, default: false)
  attr(:show_netperf_filter, :boolean, default: true)
  attr(:online_agent_ids, :any, default: nil)
  attr(:netperf_agent_ids, :any, default: nil)
  attr(:max_visible, :integer, default: @default_max_visible)
  attr(:search_event, :string, default: "agent_picker_search")
  attr(:select_event, :string, default: "agent_picker_select")
  attr(:toggle_netperf_event, :string, default: "agent_picker_toggle_netperf")
  attr(:close_event, :string, default: "close_agent_picker")

  def agent_picker_modal(assigns) do
    online_ids = assigns.online_agent_ids || MapSet.new()
    netperf_ids = assigns.netperf_agent_ids || MapSet.new()
    selected_set = assigns.selected |> normalize_selected(assigns.mode) |> MapSet.new()

    filtered =
      filter_agents(assigns.agents, assigns.query, assigns.only_netperf, netperf_ids)

    visible = Enum.take(filtered, assigns.max_visible)

    assigns =
      assigns
      |> assign(:online_ids, online_ids)
      |> assign(:netperf_ids, netperf_ids)
      |> assign(:selected_set, selected_set)
      |> assign(:total_matches, length(filtered))
      |> assign(:visible_agents, visible)

    ~H"""
    <.ui_modal
      id={@id}
      open={@open}
      size="form"
      on_cancel={@close_event}
      box_class="max-w-2xl"
    >
      <:title>{@title}</:title>

      <div class="space-y-3">
        <div class="flex flex-wrap items-center gap-2">
          <form phx-change={@search_event} phx-submit={@search_event} class="flex-1 min-w-[200px]">
            <input
              type="search"
              name="query"
              value={@query}
              placeholder="Search by agent UID, hostname, or IP address..."
              phx-debounce="150"
              autofocus
              class="w-full rounded-sr-control border border-sr-line bg-sr-control px-3 py-2 text-sm text-sr-ink placeholder:text-sr-muted focus:border-sr-brand focus:outline-none"
            />
          </form>
          <button
            :if={@show_netperf_filter}
            type="button"
            phx-click={@toggle_netperf_event}
            class={[
              "rounded-sr-control border px-3 py-2 text-xs font-medium transition-colors",
              if(@only_netperf,
                do: "border-sr-brand bg-sr-brand/15 text-sr-brand",
                else: "border-sr-line bg-sr-control text-sr-muted hover:text-sr-ink"
              )
            ]}
          >
            netperf only
          </button>
        </div>

        <div class="flex items-center justify-between text-xs text-sr-muted">
          <span>
            Showing {length(@visible_agents)} of {@total_matches} matching agents
          </span>
          <span :if={@mode == :multi}>
            {MapSet.size(@selected_set)} selected
          </span>
        </div>

        <div class="max-h-80 overflow-y-auto divide-y divide-sr-line/60 rounded-sr-control border border-sr-line bg-sr-surface">
          <%= if @visible_agents == [] do %>
            <div class="px-4 py-8 text-center text-sm text-sr-muted">
              No agents match your search filter.
            </div>
          <% else %>
            <button
              :for={agent <- @visible_agents}
              type="button"
              phx-click={@select_event}
              phx-value-uid={agent.uid}
              class={[
                "flex w-full items-center justify-between gap-3 px-3 py-2.5 text-left transition-colors hover:bg-sr-subtle/60",
                MapSet.member?(@selected_set, agent.uid) && "bg-sr-brand/10"
              ]}
            >
              <div class="min-w-0">
                <div class="flex flex-wrap items-center gap-1.5">
                  <span class="font-mono text-xs font-semibold text-sr-ink">{agent.uid}</span>
                  <.ui_badge
                    :if={MapSet.member?(@online_ids, agent.uid)}
                    variant="success"
                    size="xs"
                  >
                    Online
                  </.ui_badge>
                  <.ui_badge
                    :if={MapSet.member?(@netperf_ids, agent.uid)}
                    variant="info"
                    size="xs"
                  >
                    netperf
                  </.ui_badge>
                </div>
                <div class="mt-0.5 flex flex-wrap items-center gap-2 font-mono text-[11px] text-sr-muted">
                  <span :if={agent.host && agent.host != ""}>{agent.host}</span>
                  <span :if={agent.ip && agent.ip != ""}>{agent.ip}</span>
                </div>
              </div>
              <span
                :if={MapSet.member?(@selected_set, agent.uid)}
                class="shrink-0 font-mono text-xs font-semibold text-sr-brand"
              >
                Selected
              </span>
            </button>
          <% end %>
        </div>

        <div class="flex justify-end gap-2 pt-1">
          <.ui_button type="button" variant="primary" size="sm" phx-click={@close_event}>
            {if @mode == :multi, do: "Done", else: "Close"}
          </.ui_button>
        </div>
      </div>
    </.ui_modal>
    """
  end

  @doc false
  def filter_agents(agents, query, only_netperf?, netperf_ids) do
    needle = query |> to_string() |> String.trim() |> String.downcase()

    Enum.filter(agents, fn agent ->
      netperf_ok? = not only_netperf? or MapSet.member?(netperf_ids, agent.uid)

      query_ok? =
        needle == "" or
          contains_ci?(agent.uid, needle) or
          contains_ci?(Map.get(agent, :host), needle) or
          contains_ci?(Map.get(agent, :ip), needle)

      netperf_ok? and query_ok?
    end)
  end

  defp contains_ci?(val, needle) when is_binary(val), do: String.contains?(String.downcase(val), needle)
  defp contains_ci?(_, _), do: false

  defp normalize_selected(nil, _mode), do: []
  defp normalize_selected("", _mode), do: []

  defp normalize_selected(value, :single) when is_binary(value) do
    case String.trim(value) do
      "" -> []
      trimmed -> [trimmed]
    end
  end

  defp normalize_selected(value, :multi) when is_binary(value) do
    value
    |> String.split([",", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_selected(list, _mode) when is_list(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_selected(_, _mode), do: []
end
