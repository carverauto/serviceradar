defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.Index.View.LeaseHorizons do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  attr :horizons, :list, default: []
  attr :now, :any, default: nil

  def summary(assigns) do
    summary = summarize(assigns.horizons, assigns.now || DateTime.utc_now())
    assigns = assign(assigns, :summary, summary)

    ~H"""
    <div class="space-y-1">
      <.ui_badge variant={@summary.variant} size="sm">{@summary.label}</.ui_badge>
      <div :if={@summary.detail} class="text-xs text-sr-muted">{@summary.detail}</div>
    </div>
    """
  end

  attr :group_id, :string, required: true
  attr :horizons, :list, default: []
  attr :agents, :map, default: %{}
  attr :timezone, :string, required: true
  attr :now, :any, default: nil

  def panel(assigns) do
    assigns = assign(assigns, :now, assigns.now || DateTime.utc_now())

    ~H"""
    <.ui_panel>
      <:header>
        <div>
          <div class="text-sm font-semibold">Schedule Lease Horizon</div>
          <p class="mt-1 text-xs font-normal text-sr-muted">
            How long each agent can keep sweeping from its last acknowledged lease if core
            becomes unavailable.
          </p>
        </div>
      </:header>

      <p :if={@horizons == []} class="text-sm text-sr-muted">
        No schedule lease has been delivered for this group.
      </p>

      <div :if={@horizons != []} id={"sweep-lease-horizons-#{@group_id}"} class="sr-ui-table-shell">
        <table class={ui_table_class(size: "sm", class: "min-w-[760px]")}>
          <thead>
            <tr>
              <th>Agent</th>
              <th>Lease status</th>
              <th>Remaining</th>
              <th>Acknowledged through</th>
              <th>Slots</th>
              <th>Acknowledged</th>
            </tr>
          </thead>
          <tbody>
            <%= for horizon <- @horizons do %>
              <tr
                data-sweep-lease-agent={horizon.agent_id}
                data-sweep-lease-status={horizon.status}
              >
                <td>
                  <div class="font-medium text-sr-ink">{agent_name(horizon, @agents)}</div>
                  <div
                    :if={agent_name(horizon, @agents) != horizon.agent_id}
                    class="font-mono text-xs text-sr-muted"
                  >
                    {horizon.agent_id}
                  </div>
                </td>
                <td>
                  <.ui_badge variant={status_variant(horizon.status)} size="sm">
                    {status_label(horizon.status)}
                  </.ui_badge>
                  <div :if={horizon.error} class="mt-1 max-w-64 text-xs text-error">
                    {horizon.error}
                  </div>
                </td>
                <td>{format_remaining(horizon.acknowledged_through, @now)}</td>
                <td>
                  <.user_time
                    id={"sweep-lease-through-#{horizon.producer_assignment_id}"}
                    value={horizon.acknowledged_through}
                    timezone={@timezone}
                    style={:compact}
                    fallback="—"
                  />
                </td>
                <td>{horizon.acknowledged_slot_count || "—"}</td>
                <td>
                  <.user_time
                    id={"sweep-lease-acked-#{horizon.producer_assignment_id}"}
                    value={horizon.acknowledged_at}
                    timezone={@timezone}
                    style={:compact}
                    fallback="—"
                  />
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </.ui_panel>
    """
  end

  defp summarize([], _now), do: %{variant: "ghost", label: "Not leased", detail: nil}

  defp summarize(horizons, now) do
    agent_detail = "#{length(horizons)} #{if length(horizons) == 1, do: "agent", else: "agents"} reporting"
    horizon_ends = horizons |> Enum.map(& &1.acknowledged_through) |> Enum.reject(&is_nil/1)
    earliest_end = Enum.min(horizon_ends, DateTime, fn -> nil end)

    cond do
      Enum.any?(horizons, &(&1.status == :refused)) ->
        %{variant: "error", label: "Lease refused", detail: agent_detail}

      Enum.any?(horizons, &(&1.status == :acknowledgement_overdue)) ->
        %{variant: "error", label: "Ack overdue", detail: remaining_detail(earliest_end, now, agent_detail)}

      not is_nil(earliest_end) and DateTime.compare(earliest_end, now) != :gt ->
        %{variant: "warning", label: "Horizon exhausted", detail: agent_detail}

      not is_nil(earliest_end) ->
        variant =
          if Enum.any?(horizons, &(&1.status == :awaiting_acknowledgement)),
            do: "warning",
            else: "success"

        %{variant: variant, label: format_remaining(earliest_end, now), detail: agent_detail}

      Enum.any?(horizons, &(&1.status == :acknowledged)) ->
        %{variant: "info", label: "Acknowledged", detail: "0 slots"}

      true ->
        %{variant: "warning", label: "Awaiting ack", detail: agent_detail}
    end
  end

  defp remaining_detail(nil, _now, agent_detail), do: agent_detail

  defp remaining_detail(earliest_end, now, agent_detail) do
    "#{format_remaining(earliest_end, now)} · #{agent_detail}"
  end

  def format_remaining(nil, %DateTime{}), do: "—"

  def format_remaining(%DateTime{} = acknowledged_through, %DateTime{} = now) do
    seconds = DateTime.diff(acknowledged_through, now, :second)

    cond do
      seconds <= 0 -> "Exhausted"
      seconds < 60 -> "#{seconds}s left"
      seconds < 3600 -> "#{div(seconds, 60)}m left"
      seconds < 86_400 -> format_hours(seconds)
      true -> format_days(seconds)
    end
  end

  defp format_hours(seconds) do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)

    if minutes == 0, do: "#{hours}h left", else: "#{hours}h #{minutes}m left"
  end

  defp format_days(seconds) do
    days = div(seconds, 86_400)
    hours = div(rem(seconds, 86_400), 3600)

    if hours == 0, do: "#{days}d left", else: "#{days}d #{hours}h left"
  end

  defp agent_name(horizon, agents) do
    case Map.get(agents, horizon.agent_id) do
      %{name: name} when is_binary(name) and name != "" -> name
      _agent -> horizon.agent_id
    end
  end

  defp status_label(:acknowledged), do: "Current"
  defp status_label(:awaiting_acknowledgement), do: "Awaiting ack"
  defp status_label(:acknowledgement_overdue), do: "Ack overdue"
  defp status_label(:refused), do: "Refused"
  defp status_label(_status), do: "Unknown"

  defp status_variant(:acknowledged), do: "success"
  defp status_variant(:awaiting_acknowledgement), do: "warning"
  defp status_variant(:acknowledgement_overdue), do: "error"
  defp status_variant(:refused), do: "error"
  defp status_variant(_status), do: "ghost"
end
