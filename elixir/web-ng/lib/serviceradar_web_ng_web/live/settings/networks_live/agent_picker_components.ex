defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.AgentPickerComponents do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  alias ServiceRadarWebNGWeb.Live.Settings.NetworksLive.AgentPicker

  attr :state, :any, required: true
  attr :summary_agent, :any, default: nil

  def agent_assignment_fields(assigns) do
    committed_ids = assigns.state.committed |> MapSet.to_list() |> Enum.sort()

    assigns =
      assigns
      |> assign(:committed_ids, committed_ids)
      |> assign(:assignment_mode, if(committed_ids == [], do: "all", else: "selected"))

    ~H"""
    <div id="sweep-agent-assignment" class="space-y-3 rounded-lg border border-sr-line p-4">
      <%= for uid <- @committed_ids do %>
        <input type="hidden" name="form[agent_ids][]" value={uid} />
      <% end %>
      <input type="hidden" name="form[agent_assignment_mode]" value={@assignment_mode} />

      <div class="flex flex-wrap items-center justify-between gap-3">
        <div>
          <div class="text-sm font-medium text-sr-ink">Scanner agents</div>
          <p class="text-xs text-sr-muted">Choose every eligible agent or a fixed subset.</p>
        </div>
        <div class="flex items-center gap-2">
          <.ui_button
            id="sweep-agent-assignment-all"
            type="button"
            size="sm"
            variant={if(@committed_ids == [], do: "primary", else: "outline")}
            phx-click="agent_picker_use_all"
            aria-pressed={to_string(@committed_ids == [])}
          >
            All agents
          </.ui_button>
          <.ui_button
            id="sweep-agent-picker-trigger"
            type="button"
            size="sm"
            variant={if(@committed_ids == [], do: "outline", else: "primary")}
            phx-click="agent_picker_open"
            aria-haspopup="dialog"
            aria-controls="sweep-agent-picker-dialog"
          >
            Choose agents
          </.ui_button>
        </div>
      </div>

      <div id="sweep-agent-assignment-summary" class="text-sm text-sr-muted">
        <%= case @committed_ids do %>
          <% [] -> %>
            All agents in the configured partition
          <% [uid] -> %>
            <%= if @summary_agent do %>
              <span class="text-sr-ink">{agent_label(@summary_agent)}</span>
            <% else %>
              <span class="font-mono text-sr-ink">{uid}</span>
              <span class="ml-1">Unavailable</span>
            <% end %>
          <% ids -> %>
            {length(ids)} selected agents
        <% end %>
      </div>
    </div>
    """
  end

  attr :state, :any, required: true
  attr :open, :boolean, default: false
  attr :selected_rows, :list, default: []

  def agent_picker_modal(assigns) do
    selected_page = AgentPicker.selected_page(assigns.state)

    assigns =
      assigns
      |> assign(:browse_rows, AgentPicker.browse_results(assigns.state))
      |> assign(:selected_page, selected_page)

    ~H"""
    <.ui_modal
      id="sweep-agent-picker-dialog"
      open={@open}
      size="xl"
      on_cancel="agent_picker_cancel"
      data-return-focus="#sweep-agent-picker-trigger"
    >
      <:title>Select scanner agents</:title>

      <div class="flex flex-wrap items-center justify-between gap-3 border-b border-sr-line pb-3">
        <div class="inline-flex rounded-md border border-sr-line p-0.5">
          <button
            id="sweep-agent-picker-browse-tab"
            type="button"
            class={picker_tab_class(@state.mode == :browse)}
            phx-click="agent_picker_show_browse"
            aria-pressed={to_string(@state.mode == :browse)}
          >
            Browse
          </button>
          <button
            id="sweep-agent-picker-selected-tab"
            type="button"
            class={picker_tab_class(@state.mode == :selected)}
            phx-click="agent_picker_show_selected"
            aria-pressed={to_string(@state.mode == :selected)}
          >
            Selected
          </button>
        </div>
        <span id="sweep-agent-picker-selected-count" class="text-sm text-sr-muted" aria-live="polite">
          {@selected_page.count} selected
        </span>
      </div>

      <%= if @state.mode == :browse do %>
        <div class="space-y-3">
          <label for="sweep-agent-picker-search" class="sr-only">Search agents</label>
          <input
            id="sweep-agent-picker-search"
            type="search"
            name="search"
            value={@state.query}
            placeholder="Search by name or UID"
            class={ui_field_class(class: "w-full")}
            phx-keyup="agent_picker_search"
            phx-debounce="300"
            data-dialog-autofocus
          />

          <div
            :if={@state.error}
            class="rounded-md border border-error/30 bg-error/5 p-3"
            role="alert"
          >
            <p class="text-sm text-error">Agents could not be loaded. Your selection is unchanged.</p>
            <.ui_button type="button" size="sm" variant="outline" phx-click="agent_picker_retry">
              Retry
            </.ui_button>
          </div>

          <div
            id="sweep-agent-picker-browse-rows"
            class="max-h-[24rem] overflow-y-auto rounded-md border border-sr-line"
          >
            <p
              :if={@browse_rows == [] and is_nil(@state.error)}
              class="p-5 text-center text-sm text-sr-muted"
            >
              No agents match this search.
            </p>
            <%= for agent <- @browse_rows do %>
              <label
                data-agent-picker-row
                data-agent-picker-uid={agent.uid}
                class="flex cursor-pointer items-start gap-3 border-b border-sr-line px-3 py-2.5 last:border-b-0 hover:bg-sr-subtle/40"
              >
                <input
                  type="checkbox"
                  class={ui_checkbox_class()}
                  checked={MapSet.member?(@state.draft, agent.uid)}
                  phx-click="agent_picker_toggle"
                  phx-value-uid={agent.uid}
                  aria-label={"Select #{agent_accessible_label(agent)}"}
                />
                <span class="min-w-0 flex-1">
                  <span class="block truncate text-sm font-medium text-sr-ink">{agent_label(agent)}</span>
                  <span class="block truncate font-mono text-xs text-sr-muted">{agent.uid}</span>
                  <span class="mt-1 flex flex-wrap gap-1">
                    <.ui_badge size="xs" variant="ghost">
                      Partition {agent_partition(agent)}
                    </.ui_badge>
                    <.ui_badge size="xs" variant="ghost">{agent_status(agent)}</.ui_badge>
                    <.ui_badge
                      :for={capability <- agent_capabilities(agent)}
                      size="xs"
                      variant="ghost"
                    >
                      {capability}
                    </.ui_badge>
                  </span>
                </span>
              </label>
            <% end %>
          </div>

          <div class="flex items-center justify-between gap-3">
            <.ui_button
              type="button"
              size="sm"
              variant="outline"
              phx-click="agent_picker_previous"
              aria-label="Previous agents page"
              disabled={@state.cursor_history == []}
            >
              Previous
            </.ui_button>
            <.ui_button
              type="button"
              size="sm"
              variant="outline"
              phx-click="agent_picker_next"
              aria-label="Next agents page"
              disabled={is_nil(@state.page.after)}
            >
              Next
            </.ui_button>
          </div>
        </div>
      <% else %>
        <div class="space-y-3">
          <div
            :if={@state.selected_error}
            class="rounded-md border border-error/30 bg-error/5 p-3"
            role="alert"
          >
            <p class="text-sm text-error">
              Selected agents could not be loaded. Your selection is unchanged.
            </p>
            <.ui_button
              type="button"
              size="sm"
              variant="outline"
              phx-click="agent_picker_selected_retry"
            >
              Retry
            </.ui_button>
          </div>

          <div
            :if={is_nil(@state.selected_error)}
            id="sweep-agent-picker-selected-rows"
            class="max-h-[24rem] overflow-y-auto rounded-md border border-sr-line"
          >
            <p :if={@selected_page.uids == []} class="p-5 text-center text-sm text-sr-muted">
              No agents selected.
            </p>
            <%= for row <- @selected_rows do %>
              <div
                data-agent-picker-row
                data-agent-picker-uid={row.uid}
                data-agent-unavailable={if(is_nil(row.agent), do: "true", else: nil)}
                class="flex items-center justify-between gap-3 border-b border-sr-line px-3 py-2.5 last:border-b-0"
              >
                <div class="min-w-0">
                  <%= if row.agent do %>
                    <div class="truncate text-sm font-medium text-sr-ink">
                      {agent_label(row.agent)}
                    </div>
                    <div class="truncate font-mono text-xs text-sr-muted">{row.agent.uid}</div>
                    <div class="mt-1 flex flex-wrap gap-1">
                      <.ui_badge size="xs" variant="ghost">
                        Partition {agent_partition(row.agent)}
                      </.ui_badge>
                      <.ui_badge size="xs" variant="ghost">{agent_status(row.agent)}</.ui_badge>
                      <.ui_badge
                        :for={capability <- agent_capabilities(row.agent)}
                        size="xs"
                        variant="ghost"
                      >
                        {capability}
                      </.ui_badge>
                    </div>
                  <% else %>
                    <div class="font-mono text-sm text-sr-ink">{row.uid}</div>
                    <div class="text-xs text-sr-muted">Unavailable</div>
                  <% end %>
                </div>
                <.ui_button
                  type="button"
                  size="xs"
                  variant="ghost"
                  phx-click="agent_picker_remove"
                  phx-value-uid={row.uid}
                  aria-label={"Remove #{row.uid}"}
                >
                  Remove
                </.ui_button>
              </div>
            <% end %>
          </div>

          <div class="flex items-center justify-between gap-3">
            <.ui_button
              type="button"
              size="sm"
              variant="outline"
              phx-click="agent_picker_selected_previous"
              aria-label="Previous selected agents page"
              disabled={not @selected_page.has_previous?}
            >
              Previous
            </.ui_button>
            <.ui_button
              type="button"
              size="sm"
              variant="outline"
              phx-click="agent_picker_selected_next"
              aria-label="Next selected agents page"
              disabled={not @selected_page.has_next?}
            >
              Next
            </.ui_button>
          </div>
        </div>
      <% end %>

      <:actions>
        <div class="flex w-full flex-wrap items-center justify-between gap-2">
          <.ui_button type="button" variant="ghost" phx-click="agent_picker_clear">Clear</.ui_button>
          <div class="flex items-center gap-2">
            <.ui_button type="button" variant="ghost" phx-click="agent_picker_cancel">Cancel</.ui_button>
            <.ui_button type="button" variant="primary" phx-click="agent_picker_apply">Apply</.ui_button>
          </div>
        </div>
      </:actions>
    </.ui_modal>
    """
  end

  defp picker_tab_class(active?) do
    [
      "rounded px-3 py-1.5 text-sm transition-colors",
      if(active?, do: "bg-sr-subtle font-medium text-sr-ink", else: "text-sr-muted hover:text-sr-ink")
    ]
  end

  defp agent_label(agent) do
    case Map.get(agent, :name) do
      name when is_binary(name) and name != "" -> name
      _ -> Map.get(agent, :uid, "Unknown agent")
    end
  end

  defp agent_status(agent), do: agent |> Map.get(:status, :unknown) |> to_string()

  defp agent_accessible_label(agent) do
    "#{agent_label(agent)}, UID #{Map.get(agent, :uid, "unknown")}, status #{agent_status(agent)}"
  end

  defp agent_partition(%{gateway: %{partition_id: partition_id}}) when is_binary(partition_id) and partition_id != "" do
    case Ecto.UUID.cast(partition_id) do
      {:ok, uuid} -> uuid
      :error -> partition_id
    end
  end

  defp agent_partition(_agent), do: "unassigned"

  defp agent_capabilities(agent) do
    agent
    |> Map.get(:capabilities, [])
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) or is_atom(&1)))
    |> Enum.map(&to_string/1)
    |> Enum.take(3)
  end
end
