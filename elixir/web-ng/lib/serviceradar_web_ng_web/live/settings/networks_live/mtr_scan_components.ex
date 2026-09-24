defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.MtrScanComponents do
  @moduledoc """
  Active Scans rows for MTR bulk jobs, drawn next to the sweep execution rows.
  """
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.Settings.NetworksLive.ActiveScansComponents, only: [format_duration: 1, relative_time: 1]

  alias ServiceRadarWebNGWeb.Settings.NetworksLive.Index.MtrJobs

  attr :job, :map, required: true
  attr :timezone, :string, required: true

  def mtr_running_card(assigns) do
    ~H"""
    <div id={"mtr-running-job-#{@job.id}"} class="bg-sr-subtle/30 rounded-lg p-4 border border-sr-line">
      <div class="flex items-start justify-between">
        <div class="flex items-center gap-3">
          <.ui_spinner size="sm" />
          <div>
            <div class="font-medium flex items-center gap-2">
              <.ui_badge size="sm" variant="info">MTR</.ui_badge>
              {@job.name}
            </div>
            <div class="text-xs text-sr-muted flex items-center gap-2">
              <span :if={@job.agent_id}>
                <.icon name="hero-server" class="size-3 inline" />
                {@job.agent_id}
              </span>
              <span>{MtrJobs.protocol_label(@job)}</span>
              <span>
                Started
                <.relative_time
                  id={"settings-active-mtr-#{@job.id}-started-at"}
                  value={@job.started_at}
                  timezone={@timezone}
                />
              </span>
            </div>
          </div>
        </div>
        <div class="text-right text-xs text-sr-muted">
          <div class="text-sm font-mono text-sr-ink">{MtrJobs.status_label(@job)}</div>
          <div>
            <span class="text-success">{@job.completed}</span>
            <span :if={@job.failed > 0} class="text-error ml-1">/ {@job.failed} failed</span>
            <span>of {@job.total} traces</span>
          </div>
        </div>
      </div>
      <div class="mt-3 h-1.5 bg-sr-control rounded-full overflow-hidden">
        <div class="h-full bg-info transition-all duration-300" style={"width: #{@job.progress_percent}%"}>
        </div>
      </div>
    </div>
    """
  end

  attr :job, :map, required: true
  attr :timezone, :string, required: true

  def mtr_recent_row(assigns) do
    ~H"""
    <tr id={"mtr-recent-job-#{@job.id}"} class="hover:bg-sr-subtle/40">
      <td>
        <.ui_badge size="sm" variant={MtrJobs.status_variant(@job)}>{MtrJobs.status_label(@job)}</.ui_badge>
      </td>
      <td>
        <div class="font-medium">{@job.name}</div>
        <div :if={@job.agent_id} class="text-xs text-sr-muted">{@job.agent_id}</div>
      </td>
      <td class="text-xs">{MtrJobs.protocol_label(@job)}</td>
      <td class="text-xs text-sr-muted">
        <.relative_time
          id={"settings-active-mtr-#{@job.id}-recent-started-at"}
          value={@job.started_at}
          timezone={@timezone}
        />
      </td>
      <td class="font-mono text-xs">{format_duration(@job.duration_ms)}</td>
      <td class="text-xs">
        {@job.completed} / {@job.total}
        <span :if={@job.failed > 0} class="text-error">({@job.failed} failed<span :if={@job.timed_out > 0}>, {@job.timed_out} timed out</span>)</span>
      </td>
      <td class="text-xs">
        <span :if={not is_nil(@job.reached)}>{@job.reached}</span>
        <span :if={is_nil(@job.reached)} class="text-sr-muted" title="Reported by agents from this release on">-</span>
      </td>
      <td>
        <.link
          navigate={~p"/diagnostics/mtr?#{%{agent: @job.agent_id}}"}
          class="text-xs link"
        >
          Traces
        </.link>
      </td>
    </tr>
    """
  end
end
