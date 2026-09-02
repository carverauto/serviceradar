defmodule ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.View.Summary do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.View.Helpers

  alias ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.Config

  attr(:traces, :list, required: true)
  attr(:trace_coverage, :map, required: true)
  attr(:mtr_retention_status, :map, required: true)
  attr(:timezone, :string, default: "Etc/UTC")

  def render(assigns) do
    assigns = assign(assigns, :trace_dashboard, trace_history_dashboard(assigns.traces, assigns.trace_coverage))

    ~H"""
    <div class="grid grid-cols-1 gap-4 xl:grid-cols-4">
      <div class="sr-mtr-card p-4">
        <div class="sr-mtr-label">Retained Traces</div>
        <div class="sr-mtr-value mt-2 text-3xl">{@trace_coverage.trace_count}</div>
        <div :if={Map.get(@trace_coverage, :earliest_time)} class="sr-mtr-muted text-sm">
          <.user_time
            id="mtr-coverage-earliest-time"
            value={Map.get(@trace_coverage, :earliest_time)}
            timezone={@timezone}
            style={:date}
          /> to
          <.user_time
            id="mtr-coverage-latest-time"
            value={Map.get(@trace_coverage, :latest_time)}
            timezone={@timezone}
            style={:date}
          />
        </div>
        <div :if={is_nil(Map.get(@trace_coverage, :earliest_time))} class="sr-mtr-muted text-sm">
          no retained matches
        </div>
      </div>
      <div class="sr-mtr-card p-4">
        <div class="sr-mtr-label">Retention</div>
        <div class="sr-mtr-value mt-2 text-3xl">
          {Map.get(@mtr_retention_status, :configured_days, 30)}d
        </div>
        <div class={["text-sm", retention_status_text_class(@mtr_retention_status)]}>
          {retention_status_label(@mtr_retention_status)}
        </div>
      </div>
      <div class="sr-mtr-card p-4">
        <div class="flex items-center justify-between gap-4">
          <div class="min-w-0">
            <div class="sr-mtr-label">Reachability</div>
            <div class="sr-mtr-value mt-2 text-3xl">{@trace_dashboard.success_rate}%</div>
            <div class="sr-mtr-muted text-sm">
              across {@trace_dashboard.reachability_trace_count} retained traces
            </div>
          </div>
          <div
            class={[
              "radial-progress sr-mtr-radial shrink-0 text-sm font-semibold",
              reachability_tone(@trace_dashboard.success_rate)
            ]}
            style={"--value: #{radial_value(@trace_dashboard.success_rate)};"}
            role="progressbar"
            aria-label="MTR reachability"
          >
            {radial_value(@trace_dashboard.success_rate)}%
          </div>
        </div>
      </div>
      <div class="sr-mtr-card p-4">
        <div class="sr-mtr-label">Source Agents</div>
        <div class="sr-mtr-value mt-2 text-3xl">{@trace_dashboard.agent_count}</div>
        <div class="sr-mtr-muted text-sm">agents on this page</div>
      </div>
    </div>

    <div :if={@traces != []} class="sr-mtr-panel p-4">
      <div class="flex items-center justify-between gap-3">
        <h3 class="sr-mtr-title font-semibold">Recent Availability Timeline</h3>
        <div class="sr-mtr-muted text-xs">visible page, newest left</div>
      </div>
      <div class="sr-mtr-outcome-strip mt-4" role="list" aria-label="Recent MTR trace outcomes">
        <span
          :for={{trace, trace_index} <- Enum.with_index(Enum.take(@traces, 24))}
          role="listitem"
          class={[
            "group relative sr-mtr-outcome-dot",
            if(trace["target_reached"], do: "is-reached", else: "is-failed")
          ]}
        >
          <span
            role="tooltip"
            class="pointer-events-none absolute bottom-full left-1/2 z-40 mb-2 flex w-max -translate-x-1/2 items-center gap-1 rounded border border-sr-line bg-sr-raised px-2 py-1 text-xs text-sr-ink opacity-0 shadow-sr-raised transition-opacity group-hover:opacity-100 group-focus-visible:opacity-100"
          >
            {trace[Config.payload_target_key()]} {trace_status_label(trace)} at
            <.user_time
              id={"mtr-timeline-trace-#{trace_identity(trace, trace_index)}-time"}
              value={trace["time"]}
              timezone={@timezone}
              style={:compact}
            />
          </span>
        </span>
      </div>
      <div class="mt-3 flex flex-wrap gap-3 text-xs">
        <span class="sr-mtr-muted">Page reached {@trace_dashboard.reached_count}</span>
        <span class="sr-mtr-muted">Page failed {@trace_dashboard.failed_count}</span>
        <span class="sr-mtr-muted">Visible {@trace_dashboard.trace_count}</span>
      </div>
    </div>

    <div :if={@traces != []} class="grid grid-cols-1 gap-4 xl:grid-cols-3">
      <div class="sr-mtr-panel p-4 xl:col-span-2">
        <div class="flex items-center justify-between">
          <h3 class="sr-mtr-title font-semibold">Path Depth And Reachability</h3>
          <div class="sr-mtr-muted text-xs">visible page, newest first</div>
        </div>
        <div class="mt-4 space-y-3">
          <div :for={trace <- Enum.take(@traces, 12)} class="space-y-1">
            <div class="flex items-center justify-between text-xs">
              <span class="truncate max-w-[260px] font-mono">
                {trace[Config.payload_target_key()]}
              </span>
              <span class={if trace["target_reached"], do: "text-success", else: "text-error"}>
                {trace["total_hops"] || 0} hops
              </span>
            </div>
            <div class="sr-mtr-track h-2">
              <div
                class={[
                  "h-full rounded-full transition-all",
                  if(trace["target_reached"], do: "bg-success", else: "bg-error")
                ]}
                style={"width: #{trace_hop_width(trace, @trace_dashboard.max_hops)}"}
              >
              </div>
            </div>
          </div>
        </div>
      </div>
      <div class="sr-mtr-card p-4">
        <div class="flex items-center justify-between">
          <h3 class="sr-mtr-title font-semibold">Source Agent Mix</h3>
          <div class="sr-mtr-muted text-xs">agents running traces</div>
        </div>
        <div class="mt-4 space-y-3">
          <div :for={agent <- @trace_dashboard.agent_mix} class="space-y-1">
            <div class="flex items-center justify-between text-xs">
              <span class="truncate max-w-[190px] font-mono">{agent.agent_id}</span>
              <span>{agent.count}</span>
            </div>
            <div class="sr-mtr-track h-2">
              <div class="h-full rounded-full bg-info" style={"width: #{agent.width}"}></div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp trace_identity(trace, index) do
    Enum.find(
      [Map.get(trace, "id"), Map.get(trace, "trace_id"), Map.get(trace, :id), Map.get(trace, :trace_id)],
      index,
      &(&1 not in [nil, ""])
    )
  end
end
