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
    <div :if={@show} class="modal modal-open">
      <div class="modal-box">
        <h3 class="font-bold text-lg mb-4">Run MTR Trace</h3>

        <div :if={@mtr_error} class="alert alert-error mb-4">
          <span>{@mtr_error}</span>
        </div>

        <.form for={@mtr_form} phx-submit="run_mtr">
          <div class="form-control mb-3">
            <label class="label"><span class="label-text">Target (hostname or IP)</span></label>
            <input
              type="text"
              name="mtr[target]"
              value={@mtr_form[Config.payload_target_key()].value}
              placeholder="e.g. 8.8.8.8 or google.com"
              class="input input-bordered"
              required
            />
          </div>

          <div class="form-control mb-3">
            <label class="label"><span class="label-text">Agent</span></label>
            <select name="mtr[agent_id]" class="select select-bordered" required>
              <option value="">Select an agent...</option>
              <%= for agent <- @mtr_agents do %>
                <option value={agent_id(agent)}>{agent_label(agent)}</option>
              <% end %>
            </select>
            <label :if={@mtr_agents == []} class="label">
              <span class="label-text-alt text-warning">No agents connected</span>
            </label>
          </div>

          <div class="form-control mb-4">
            <label class="label"><span class="label-text">Protocol</span></label>
            <select name="mtr[protocol]" class="select select-bordered">
              <option value={Config.protocol_icmp()} selected>ICMP</option>
              <option value={Config.protocol_udp()}>UDP</option>
              <option value={Config.protocol_tcp()}>TCP</option>
            </select>
          </div>

          <div class="modal-action">
            <button type="button" phx-click="close_mtr_modal" class="btn">Cancel</button>
            <button type="submit" class="btn btn-primary">Queue Trace</button>
          </div>
        </.form>
      </div>
      <div class="modal-backdrop" phx-click="close_mtr_modal"></div>
    </div>
    """
  end

  attr(:show, :boolean, required: true)
  attr(:bulk_mtr_error, :any, default: nil)
  attr(:bulk_mtr_form, :any, required: true)
  attr(:mtr_agents, :list, required: true)

  def bulk_mtr_modal(assigns) do
    ~H"""
    <div :if={@show} class="modal modal-open">
      <div class="modal-box max-w-2xl">
        <h3 class="font-bold text-lg mb-4">Run Bulk MTR</h3>

        <div :if={@bulk_mtr_error} class="alert alert-error mb-4">
          <span>{@bulk_mtr_error}</span>
        </div>

        <.form for={@bulk_mtr_form} phx-submit="run_bulk_mtr">
          <.bulk_target_fields bulk_mtr_form={@bulk_mtr_form} />
          <div class="grid grid-cols-1 md:grid-cols-3 gap-3">
            <.bulk_selector_fields bulk_mtr_form={@bulk_mtr_form} mtr_agents={@mtr_agents} />
            <.bulk_profile_fields bulk_mtr_form={@bulk_mtr_form} />
          </div>
          <div class="modal-action">
            <button type="button" phx-click="close_bulk_mtr_modal" class="btn">Cancel</button>
            <button type="submit" class="btn btn-secondary">Queue Bulk Job</button>
          </div>
        </.form>
      </div>
      <div class="modal-backdrop" phx-click="close_bulk_mtr_modal"></div>
    </div>
    """
  end

  attr(:bulk_mtr_form, :any, required: true)

  defp bulk_target_fields(assigns) do
    ~H"""
    <div class="form-control mb-3">
      <label class="label"><span class="label-text">SRQL Query</span></label>
      <input
        type="text"
        name="bulk_mtr[target_query]"
        value={@bulk_mtr_form[Config.payload_target_query_key()].value}
        placeholder="in:devices tags.role:edge"
        class="input input-bordered"
      />
      <label class="label">
        <span class="label-text-alt">
          Optional. When present, ServiceRadar reruns the SRQL query at submit time and queues the current matching targets.
        </span>
      </label>
    </div>

    <div class="form-control mb-3">
      <label class="label"><span class="label-text">Targets</span></label>
      <textarea
        name="bulk_mtr[targets]"
        class="textarea textarea-bordered min-h-48"
        placeholder="One hostname or IP per line"
      ><%= @bulk_mtr_form["targets"].value %></textarea>
      <label class="label">
        <span class="label-text-alt">
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
    <div class="form-control">
      <label class="label"><span class="label-text">Selector Limit</span></label>
      <input
        type="number"
        min="1"
        max="5000"
        name="bulk_mtr[selector_limit]"
        value={@bulk_mtr_form[Config.payload_selector_limit_key()].value}
        class="input input-bordered"
      />
    </div>

    <div class="form-control">
      <label class="label"><span class="label-text">Agent</span></label>
      <select name="bulk_mtr[agent_id]" class="select select-bordered" required>
        <option value="">Select an agent...</option>
        <%= for agent <- @mtr_agents do %>
          <option value={agent_id(agent)}>{agent_label(agent)}</option>
        <% end %>
      </select>
    </div>

    <div class="form-control">
      <label class="label"><span class="label-text">Protocol</span></label>
      <select name="bulk_mtr[protocol]" class="select select-bordered">
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
    <div class="form-control">
      <label class="label"><span class="label-text">Execution Profile</span></label>
      <select name="bulk_mtr[execution_profile]" class="select select-bordered">
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

    <div class="form-control">
      <label class="label"><span class="label-text">Concurrency</span></label>
      <input
        type="number"
        min="1"
        max="256"
        name="bulk_mtr[concurrency]"
        value={@bulk_mtr_form[Config.payload_concurrency_key()].value}
        class="input input-bordered"
      />
    </div>
    """
  end
end
