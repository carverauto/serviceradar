defmodule ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.View.Modals do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.View.Helpers

  alias ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.Config

  attr(:show, :boolean, required: true)
  attr(:mtr_error, :any, default: nil)
  attr(:mtr_form, :any, required: true)
  attr(:mtr_agents, :list, required: true)

  def mtr_modal(assigns) do
    ~H"""
    <.ui_modal id="mtr-run-modal" open={@show} on_cancel="close_mtr_modal">
      <:title>Run MTR Trace</:title>

      <div :if={@mtr_error} class={ui_alert_class(variant: "error")}>
        <span>{@mtr_error}</span>
      </div>

      <.form for={@mtr_form} phx-submit="run_mtr" class="space-y-3">
        <div class="flex flex-col gap-1.5">
          <label class="flex items-center justify-between gap-2">
            <span class="text-sm font-medium text-sr-ink">Target (hostname or IP)</span>
          </label>
          <input
            type="text"
            name="mtr[target]"
            value={@mtr_form[Config.payload_target_key()].value}
            placeholder="e.g. 8.8.8.8 or google.com"
            class={ui_field_class()}
            required
          />
        </div>

        <div class="flex flex-col gap-1.5">
          <label class="flex items-center justify-between gap-2">
            <span class="text-sm font-medium text-sr-ink">Agent</span>
          </label>
          <select name="mtr[agent_id]" class={ui_field_class()} required>
            <option value="">Select an agent...</option>
            <%= for agent <- @mtr_agents do %>
              <option value={agent_id(agent)}>{agent_label(agent)}</option>
            <% end %>
          </select>
          <label :if={@mtr_agents == []} class="flex items-center justify-between gap-2">
            <span class="text-xs text-sr-muted text-amber-600 dark:text-amber-300">
              No agents connected
            </span>
          </label>
        </div>

        <div class="flex flex-col gap-1.5">
          <label class="flex items-center justify-between gap-2">
            <span class="text-sm font-medium text-sr-ink">Protocol</span>
          </label>
          <select name="mtr[protocol]" class={ui_field_class()}>
            <option value={Config.protocol_icmp()} selected>ICMP</option>
            <option value={Config.protocol_udp()}>UDP</option>
            <option value={Config.protocol_tcp()}>TCP</option>
          </select>
        </div>

        <div class="flex justify-end gap-2 pt-1">
          <.ui_button type="button" phx-click="close_mtr_modal" size="sm" variant="neutral">
            Cancel
          </.ui_button>
          <.ui_button type="submit" size="sm" variant="primary">Queue Trace</.ui_button>
        </div>
      </.form>
    </.ui_modal>
    """
  end

  attr(:show, :boolean, required: true)
  attr(:bulk_mtr_error, :any, default: nil)
  attr(:bulk_mtr_form, :any, required: true)
  attr(:mtr_agents, :list, required: true)

  def bulk_mtr_modal(assigns) do
    ~H"""
    <.ui_modal id="mtr-bulk-modal" open={@show} size="md" on_cancel="close_bulk_mtr_modal">
      <:title>Run Bulk MTR</:title>

      <div :if={@bulk_mtr_error} class={ui_alert_class(variant: "error")}>
        <span>{@bulk_mtr_error}</span>
      </div>

      <.form for={@bulk_mtr_form} phx-submit="run_bulk_mtr" class="space-y-3">
        <.bulk_target_fields bulk_mtr_form={@bulk_mtr_form} />
        <div class="grid grid-cols-1 gap-3 md:grid-cols-3">
          <.bulk_selector_fields bulk_mtr_form={@bulk_mtr_form} mtr_agents={@mtr_agents} />
          <.bulk_profile_fields bulk_mtr_form={@bulk_mtr_form} />
        </div>
        <div class="flex justify-end gap-2 pt-1">
          <.ui_button type="button" phx-click="close_bulk_mtr_modal" size="sm" variant="neutral">
            Cancel
          </.ui_button>
          <.ui_button type="submit" size="sm" variant="soft">Queue Bulk Job</.ui_button>
        </div>
      </.form>
    </.ui_modal>
    """
  end

  attr(:bulk_mtr_form, :any, required: true)

  defp bulk_target_fields(assigns) do
    ~H"""
    <div class="flex flex-col gap-1.5 mb-3">
      <label class="flex items-center justify-between gap-2">
        <span class="text-sm font-medium text-sr-ink">SRQL Query</span>
      </label>
      <input
        type="text"
        name="bulk_mtr[target_query]"
        value={@bulk_mtr_form[Config.payload_target_query_key()].value}
        placeholder="in:devices tags.role:edge"
        class={ui_field_class()}
      />
      <label class="flex items-center justify-between gap-2">
        <span class="text-xs text-sr-muted">
          Optional. When present, ServiceRadar reruns the SRQL query at submit time and queues the current matching targets.
        </span>
      </label>
    </div>

    <div class="flex flex-col gap-1.5 mb-3">
      <label class="flex items-center justify-between gap-2">
        <span class="text-sm font-medium text-sr-ink">Targets</span>
      </label>
      <textarea
        name="bulk_mtr[targets]"
        class={ui_field_class(class: "min-h-48 py-2.5")}
        placeholder="One hostname or IP per line"
      ><%= @bulk_mtr_form["targets"].value %></textarea>
      <label class="flex items-center justify-between gap-2">
        <span class="text-xs text-sr-muted">
          Optional when using SRQL. Manual targets are used only when the SRQL query field is blank.
        </span>
      </label>
    </div>
    """
  end

  attr(:bulk_mtr_form, :any, required: true)
  attr(:mtr_agents, :list, required: true)

  defp bulk_selector_fields(assigns) do
    ~H"""
    <div class="flex flex-col gap-1.5">
      <label class="flex items-center justify-between gap-2">
        <span class="text-sm font-medium text-sr-ink">Selector Limit</span>
      </label>
      <input
        type="number"
        min="1"
        max="5000"
        name="bulk_mtr[selector_limit]"
        value={@bulk_mtr_form[Config.payload_selector_limit_key()].value}
        class={ui_field_class()}
      />
    </div>

    <div class="flex flex-col gap-1.5">
      <label class="flex items-center justify-between gap-2">
        <span class="text-sm font-medium text-sr-ink">Agent</span>
      </label>
      <select name="bulk_mtr[agent_id]" class={ui_field_class()} required>
        <option value="">Select an agent...</option>
        <%= for agent <- @mtr_agents do %>
          <option value={agent_id(agent)}>{agent_label(agent)}</option>
        <% end %>
      </select>
    </div>

    <div class="flex flex-col gap-1.5">
      <label class="flex items-center justify-between gap-2">
        <span class="text-sm font-medium text-sr-ink">Protocol</span>
      </label>
      <select name="bulk_mtr[protocol]" class={ui_field_class()}>
        <option
          value={Config.protocol_icmp()}
          selected={@bulk_mtr_form[Config.payload_protocol_key()].value == Config.protocol_icmp()}
        >
          ICMP
        </option>
        <option
          value={Config.protocol_udp()}
          selected={@bulk_mtr_form[Config.payload_protocol_key()].value == Config.protocol_udp()}
        >
          UDP
        </option>
        <option
          value={Config.protocol_tcp()}
          selected={@bulk_mtr_form[Config.payload_protocol_key()].value == Config.protocol_tcp()}
        >
          TCP
        </option>
      </select>
    </div>
    """
  end

  attr(:bulk_mtr_form, :any, required: true)

  defp bulk_profile_fields(assigns) do
    ~H"""
    <div class="flex flex-col gap-1.5">
      <label class="flex items-center justify-between gap-2">
        <span class="text-sm font-medium text-sr-ink">Execution Profile</span>
      </label>
      <select name="bulk_mtr[execution_profile]" class={ui_field_class()}>
        <option
          value={Config.execution_profile_fast()}
          selected={
            @bulk_mtr_form[Config.payload_execution_profile_key()].value ==
              Config.execution_profile_fast()
          }
        >
          Fast
        </option>
        <option
          value={Config.execution_profile_balanced()}
          selected={
            @bulk_mtr_form[Config.payload_execution_profile_key()].value ==
              Config.execution_profile_balanced()
          }
        >
          Balanced
        </option>
        <option
          value={Config.execution_profile_deep()}
          selected={
            @bulk_mtr_form[Config.payload_execution_profile_key()].value ==
              Config.execution_profile_deep()
          }
        >
          Deep
        </option>
      </select>
    </div>

    <div class="flex flex-col gap-1.5">
      <label class="flex items-center justify-between gap-2">
        <span class="text-sm font-medium text-sr-ink">Concurrency</span>
      </label>
      <input
        type="number"
        min="1"
        max="256"
        name="bulk_mtr[concurrency]"
        value={@bulk_mtr_form[Config.payload_concurrency_key()].value}
        class={ui_field_class()}
      />
    </div>
    """
  end
end
