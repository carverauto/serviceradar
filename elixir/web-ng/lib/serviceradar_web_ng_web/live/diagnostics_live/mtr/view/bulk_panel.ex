defmodule ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.View.BulkPanel do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.View.Helpers

  alias ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.Bulk
  alias ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.Config

  attr(:bulk_jobs, :list, required: true)
  attr(:timezone, :string, default: "Etc/UTC")

  def render(assigns) do
    recent_bars = Bulk.recent_job_bars(assigns.bulk_jobs)

    assigns =
      assigns
      |> assign(:dashboard, Bulk.dashboard_stats(assigns.bulk_jobs))
      |> assign(:recent_bars, recent_bars)
      |> assign(:max_rate, recent_bars |> Enum.map(&Bulk.rate_value/1) |> Enum.max(fn -> 0.0 end))
      |> assign(:latest_history, Bulk.latest_history(assigns.bulk_jobs))
      |> assign(:latest_mix, Bulk.latest_mix(assigns.bulk_jobs))

    ~H"""
    <div :if={@bulk_jobs != []} class="overflow-x-auto">
      <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-5 gap-4 mb-4">
        <div class="sr-mtr-card p-4">
          <div class="sr-mtr-label">Active Bulk Jobs</div>
          <div class="sr-mtr-value mt-2 text-3xl">{@dashboard.active_count}</div>
        </div>
        <div class="sr-mtr-card p-4">
          <div class="sr-mtr-label">Avg Throughput</div>
          <div class="sr-mtr-value mt-2 text-3xl">{@dashboard.avg_rate}</div>
          <div class="sr-mtr-muted text-sm">targets/min</div>
        </div>
        <div class="sr-mtr-card p-4">
          <div class="sr-mtr-label">Avg Success Rate</div>
          <div class="sr-mtr-value mt-2 text-3xl">{@dashboard.avg_success_rate}%</div>
        </div>
        <div class="sr-mtr-card p-4">
          <div class="sr-mtr-label">Recent Timed Out Targets</div>
          <div class="sr-mtr-value mt-2 text-3xl">{@dashboard.timed_out_targets}</div>
        </div>
        <div class="sr-mtr-card p-4">
          <div class="sr-mtr-label">Adaptive Backoff Runs</div>
          <div class="sr-mtr-value mt-2 text-3xl">{@dashboard.throttled_count}</div>
        </div>
      </div>

      <div class="grid grid-cols-1 xl:grid-cols-2 gap-4 mb-4">
        <.throughput_panel recent_bars={@recent_bars} max_rate={@max_rate} />
        <.concurrency_panel latest_history={@latest_history} />
      </div>

      <.latest_mix_panel latest_mix={@latest_mix} />
      <.jobs_table bulk_jobs={@bulk_jobs} timezone={@timezone} />
    </div>
    """
  end

  attr(:recent_bars, :list, required: true)
  attr(:max_rate, :float, required: true)

  defp throughput_panel(assigns) do
    ~H"""
    <div class="sr-mtr-card p-4">
      <div class="flex items-center justify-between">
        <h3 class="sr-mtr-title font-semibold">Recent Throughput</h3>
        <div class="sr-mtr-muted text-xs">last {length(@recent_bars)} jobs</div>
      </div>
      <div class="mt-4 space-y-3">
        <div :for={job <- @recent_bars} class="space-y-1">
          <div class="flex items-center justify-between text-xs">
            <span class="truncate max-w-[220px]">{job.agent_id}</span>
            <span>{Bulk.rate(job)}</span>
          </div>
          <div class="sr-mtr-track h-2">
            <div
              class={[
                "h-full rounded-full transition-all",
                if(Bulk.throttled?(job), do: "bg-warning", else: "bg-sr-brand")
              ]}
              style={"width: #{Bulk.bar_width(job, @max_rate)}"}
            >
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr(:latest_history, :map, default: nil)

  defp concurrency_panel(assigns) do
    ~H"""
    <div class="sr-mtr-card p-4">
      <div class="flex items-center justify-between">
        <h3 class="sr-mtr-title font-semibold">Adaptive Concurrency</h3>
        <div class="sr-mtr-muted text-xs">
          <%= if @latest_history do %>
            {@latest_history.job.agent_id}
          <% else %>
            no history yet
          <% end %>
        </div>
      </div>
      <div :if={@latest_history} class="mt-4 space-y-3">
        <div :for={sample <- @latest_history.history} class="space-y-1">
          <div class="flex items-center justify-between text-xs">
            <span>{sample.elapsed_ms}ms</span>
            <span>{sample.concurrency}/{sample.max_concurrency}</span>
          </div>
          <div class="sr-mtr-track h-2">
            <div
              class={[
                "h-full rounded-full transition-all",
                if(sample.concurrency < sample.max_concurrency, do: "bg-warning", else: "bg-success")
              ]}
              style={"width: #{Bulk.history_bar_width(sample)}"}
            >
            </div>
          </div>
        </div>
      </div>
      <div :if={!@latest_history} class="mt-4 sr-mtr-muted text-sm">
        Run a bulk job long enough to trigger calibration windows and adaptive snapshots.
      </div>
    </div>
    """
  end

  attr(:latest_mix, :map, default: nil)

  defp latest_mix_panel(assigns) do
    ~H"""
    <div :if={@latest_mix} class="sr-mtr-panel p-4 mb-4">
      <div class="flex items-center justify-between">
        <h3 class="sr-mtr-title font-semibold">Latest Run Mix</h3>
        <div class="sr-mtr-muted text-xs">
          {@latest_mix.job.agent_id} • {Bulk.success_rate(@latest_mix.job)}% success
        </div>
      </div>
      <div class="mt-4 sr-mtr-track h-3 flex">
        <div
          class="h-full bg-success"
          style={"width: #{Bulk.mix_segment_width(@latest_mix.mix.completed_targets, @latest_mix.mix.total_targets)}"}
        >
        </div>
        <div
          class="h-full bg-warning"
          style={"width: #{Bulk.mix_segment_width(@latest_mix.mix.timed_out_targets, @latest_mix.mix.total_targets)}"}
        >
        </div>
        <div
          class="h-full bg-error"
          style={"width: #{Bulk.mix_segment_width(@latest_mix.mix.error_targets, @latest_mix.mix.total_targets)}"}
        >
        </div>
      </div>
      <div class="mt-3 grid grid-cols-1 md:grid-cols-3 gap-3 text-xs">
        <div class="sr-mtr-subpanel p-3">
          <div class="sr-mtr-label">Completed</div>
          <div class="sr-mtr-value mt-1 text-lg">{@latest_mix.mix.completed_targets}</div>
        </div>
        <div class="sr-mtr-subpanel p-3">
          <div class="sr-mtr-label">Timed Out</div>
          <div class="sr-mtr-value mt-1 text-lg">{@latest_mix.mix.timed_out_targets}</div>
        </div>
        <div class="sr-mtr-subpanel p-3">
          <div class="sr-mtr-label">Other Failures</div>
          <div class="sr-mtr-value mt-1 text-lg">{@latest_mix.mix.error_targets}</div>
        </div>
      </div>
    </div>
    """
  end

  attr(:bulk_jobs, :list, required: true)
  attr(:timezone, :string, required: true)

  defp jobs_table(assigns) do
    ~H"""
    <table class={ui_table_class(size: "sm", class: "sr-mtr-table")}>
      <thead>
        <tr>
          <th>Submitted</th>
          <th>Status</th>
          <th>Agent</th>
          <th>Targets</th>
          <th>Progress</th>
          <th>Rate</th>
          <th>Concurrency</th>
          <th>Profile</th>
          <th>Source</th>
          <th>Protocol</th>
          <th>Job</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={job <- @bulk_jobs} class="hover">
          <td class="whitespace-nowrap text-xs">
            <.user_time
              id={"mtr-bulk-job-#{job.id}-inserted-at"}
              value={job.inserted_at}
              timezone={@timezone}
              style={:compact}
              fallback="-"
            />
          </td>
          <td>
            <.ui_badge size="sm" variant={pending_status_variant(job.status)}>
              {job.status |> to_string() |> String.replace("_", " ") |> String.upcase()}
            </.ui_badge>
          </td>
          <td class="text-xs font-mono max-w-[120px] truncate" title={job.agent_id}>
            {job.agent_id}
          </td>
          <td>{Bulk.count(job, Config.payload_total_targets_key(), Bulk.count_targets(job))}</td>
          <td class="text-xs">
            {Bulk.count(job, Config.payload_completed_targets_key(), 0)}/{Bulk.count(
              job,
              Config.payload_total_targets_key(),
              Bulk.count_targets(job)
            )} complete, {Bulk.count(job, Config.payload_failed_targets_key(), 0)} failed, {Bulk.count(
              job,
              Config.payload_running_targets_key(),
              0
            )} running
            <div :if={Bulk.timeout_count(job) > 0} class="text-warning">
              {Bulk.timeout_count(job)} timed out
            </div>
          </td>
          <td class="text-xs">
            <div>{Bulk.rate(job)}</div>
            <div class="sr-mtr-muted">{Bulk.duration(job)}</div>
          </td>
          <td class="text-xs">
            <div>{Bulk.concurrency(job)}</div>
            <div :if={Bulk.throttled?(job)} class="text-warning">adaptive backoff</div>
          </td>
          <td>
            <.ui_badge size="sm" variant="ghost">
              {String.upcase(
                (job.payload || %{})[Config.payload_execution_profile_key()] ||
                  Config.execution_profile_fast()
              )}
            </.ui_badge>
          </td>
          <td class="text-xs">
            <%= if Bulk.job_query(job) != "" do %>
              <.ui_badge size="sm" variant="info">SRQL</.ui_badge>
              <div class="sr-mtr-muted mt-1 truncate max-w-[220px]" title={Bulk.job_query(job)}>
                {Bulk.job_query(job)}
              </div>
              <div class="sr-mtr-muted">limit {Bulk.job_selector_limit(job)}</div>
            <% else %>
              <.ui_badge size="sm" variant="ghost">MANUAL</.ui_badge>
            <% end %>
          </td>
          <td>
            <.ui_badge size="sm" variant="ghost">
              {String.upcase(
                (job.payload || %{})[Config.payload_protocol_key()] || Config.protocol_icmp()
              )}
            </.ui_badge>
          </td>
          <td class="text-xs sr-mtr-muted">
            <%= if Bulk.job_profile_id(job) != "" do %>
              <.link
                navigate={~p"/settings/networks/mtr/#{Bulk.job_profile_id(job)}/edit"}
                class="text-sr-brand hover:underline"
              >
                {job.id}
              </.link>
            <% else %>
              {job.id}
            <% end %>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end
end
