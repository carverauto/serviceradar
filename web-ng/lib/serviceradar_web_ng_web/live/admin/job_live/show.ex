defmodule ServiceRadarWebNGWeb.Admin.JobLive.Show do
  @moduledoc """
  LiveView for displaying detailed job information.

  Shows full job details including:
  - Job configuration (cron, queue, worker/resource info)
  - Recent execution history with expanded details
  - Execution statistics and charts
  - Job actions (trigger manual run)
  """
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.AdminComponents

  alias ServiceRadarWebNG.Jobs.JobCatalog

  @refresh_intervals [
    {5, "5s"},
    {10, "10s"},
    {30, "30s"},
    {60, "1m"},
    {0, "Off"}
  ]

  @impl true
  def mount(%{"id" => encoded_id}, _session, socket) do
    case decode_job_id(encoded_id) do
      {:ok, id} ->
        case JobCatalog.get_job(id) do
          {:ok, job} ->
            {:ok, assign_job(socket, job)}

          {:error, :not_found} ->
            {:ok,
             socket
             |> put_flash(:error, "Job not found")
             |> push_navigate(to: ~p"/admin/jobs")}
        end

      :error ->
        {:ok,
         socket
         |> put_flash(:error, "Invalid job ID")
         |> push_navigate(to: ~p"/admin/jobs")}
    end
  end

  @impl true
  def handle_info(:refresh, socket) do
    socket =
      case JobCatalog.get_job(socket.assigns.job.id) do
        {:ok, job} -> assign_job(socket, job)
        {:error, :not_found} -> put_flash(socket, :error, "Job no longer exists")
      end

    socket =
      if socket.assigns.refresh_interval > 0 do
        schedule_refresh(socket)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    case JobCatalog.get_job(socket.assigns.job.id) do
      {:ok, job} -> {:noreply, assign_job(socket, job)}
      {:error, :not_found} -> {:noreply, put_flash(socket, :error, "Job no longer exists")}
    end
  end

  def handle_event("set_refresh_interval", %{"interval" => interval}, socket) do
    interval = String.to_integer(interval)

    socket =
      socket
      |> cancel_refresh_timer()
      |> assign(:refresh_interval, interval)

    socket =
      if interval > 0 do
        schedule_refresh(socket)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("trigger_job", _params, socket) do
    job = socket.assigns.job

    case JobCatalog.trigger_job(job) do
      {:ok, _oban_job} ->
        {:noreply,
         socket
         |> put_flash(:info, "Job '#{job.name}' triggered successfully")
         |> assign_job(job)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to trigger job: #{inspect(reason)}")}
    end
  end

  def handle_event("set_chart_hours", %{"hours" => hours}, socket) do
    hours = String.to_integer(hours)

    socket =
      socket
      |> assign(:chart_hours, hours)
      |> load_chart_data()

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-6xl p-6 space-y-6">
        <.admin_nav current_path="/admin/jobs" />

        <div class="flex flex-wrap items-center justify-between gap-4">
          <div class="flex items-center gap-3">
            <.ui_button variant="ghost" size="sm" navigate={~p"/admin/jobs"}>
              <.icon name="hero-arrow-left" class="size-4" />
            </.ui_button>
            <div>
              <h1 class="text-2xl font-semibold text-base-content">{@job.name}</h1>
              <p class="text-sm text-base-content/60">
                {@job.description}
              </p>
            </div>
          </div>
          <div class="flex items-center gap-2">
            <.ui_badge variant={source_variant(@job.source)} size="sm">
              {source_label(@job.source)}
            </.ui_badge>
            <.ui_badge variant={if @job.enabled, do: "success", else: "warning"} size="sm">
              {if @job.enabled, do: "Enabled", else: "Paused"}
            </.ui_badge>
            <div class="flex items-center gap-1 text-xs text-base-content/60">
              <.icon
                name="hero-arrow-path"
                class={["size-3", @refresh_interval > 0 && "animate-spin"]}
              />
              <select
                class="select select-xs select-ghost"
                phx-change="set_refresh_interval"
                name="interval"
              >
                <%= for {seconds, label} <- @refresh_intervals do %>
                  <option value={seconds} selected={@refresh_interval == seconds}>{label}</option>
                <% end %>
              </select>
            </div>
            <.ui_button variant="ghost" size="sm" phx-click="refresh">
              <.icon name="hero-arrow-path" class="size-4" />
            </.ui_button>
          </div>
        </div>

        <div class="grid gap-6 lg:grid-cols-3">
          <div class="lg:col-span-2 space-y-6">
            <.ui_panel>
              <:header>
                <div class="text-sm font-semibold">Job Configuration</div>
              </:header>
              <div class="grid gap-4 sm:grid-cols-2">
                <.detail_item label="Schedule (Cron)" value={@job.cron || "Not scheduled"} mono />
                <.detail_item label="Queue" value={to_string(@job.queue)} mono />
                <.detail_item label="Last Run" value={format_datetime(@job.last_run_at)} />
                <.detail_item label="Next Run" value={format_datetime(@job.next_run_at)} />

                <%= if @job.worker do %>
                  <div class="sm:col-span-2">
                    <.detail_item label="Worker Module" value={inspect(@job.worker)} mono />
                  </div>
                <% end %>

                <%= if @job.resource do %>
                  <.detail_item
                    label="Resource"
                    value={inspect(@job.resource) |> String.replace("Elixir.", "")}
                    mono
                  />
                  <.detail_item label="Action" value={to_string(@job.action)} mono />
                <% end %>
              </div>
            </.ui_panel>

            <%= if @job.worker do %>
              <.ui_panel>
                <:header>
                  <div>
                    <div class="text-sm font-semibold">Execution History</div>
                    <p class="text-xs text-base-content/60">
                      Last {@chart_hours} hours
                    </p>
                  </div>
                  <select
                    class="select select-xs select-bordered"
                    phx-change="set_chart_hours"
                    name="hours"
                  >
                    <option value="6" selected={@chart_hours == 6}>6 hours</option>
                    <option value="12" selected={@chart_hours == 12}>12 hours</option>
                    <option value="24" selected={@chart_hours == 24}>24 hours</option>
                    <option value="48" selected={@chart_hours == 48}>48 hours</option>
                    <option value="168" selected={@chart_hours == 168}>7 days</option>
                  </select>
                </:header>

                <%= if @chart_data == [] do %>
                  <div class="rounded-xl border border-dashed border-base-200 bg-base-100 p-6 text-center">
                    <.icon name="hero-chart-bar" class="size-8 mx-auto text-base-content/30" />
                    <div class="mt-2 text-sm font-semibold text-base-content/70">No data</div>
                    <p class="mt-1 text-xs text-base-content/50">
                      No executions in the selected time period.
                    </p>
                  </div>
                <% else %>
                  <.execution_chart data={@chart_data} max_value={@chart_max} />
                <% end %>
              </.ui_panel>
            <% end %>

            <.ui_panel>
              <:header>
                <div>
                  <div class="text-sm font-semibold">Recent Runs</div>
                  <p class="text-xs text-base-content/60">
                    Last {@recent_runs_limit} executions
                  </p>
                </div>
              </:header>

              <%= if @recent_runs == [] do %>
                <div class="rounded-xl border border-dashed border-base-200 bg-base-100 p-6 text-center">
                  <.icon name="hero-clock" class="size-8 mx-auto text-base-content/30" />
                  <div class="mt-2 text-sm font-semibold text-base-content/70">No runs yet</div>
                  <p class="mt-1 text-xs text-base-content/50">
                    This job hasn't executed any runs yet.
                  </p>
                </div>
              <% else %>
                <div class="overflow-x-auto">
                  <table class="table table-sm">
                    <thead>
                      <tr class="text-[11px] uppercase tracking-wide text-base-content/50">
                        <th>State</th>
                        <th>Enqueued</th>
                        <th>Started</th>
                        <th>Completed</th>
                        <th>Duration</th>
                        <th>Attempts</th>
                      </tr>
                    </thead>
                    <tbody>
                      <%= for run <- @recent_runs do %>
                        <tr class="hover:bg-base-200/30">
                          <td>
                            <.ui_badge variant={run_state_variant(run.state)} size="xs">
                              {run_state_label(run.state)}
                            </.ui_badge>
                          </td>
                          <td class="font-mono text-xs text-base-content/70">
                            {format_datetime(run.inserted_at)}
                          </td>
                          <td class="font-mono text-xs text-base-content/70">
                            {format_datetime(run.attempted_at)}
                          </td>
                          <td class="font-mono text-xs text-base-content/70">
                            {format_datetime(run.completed_at)}
                          </td>
                          <td class="text-xs text-base-content/70">
                            {format_duration(run)}
                          </td>
                          <td class="text-xs text-base-content/70 text-center">
                            {run.attempt}/{run.max_attempts}
                          </td>
                        </tr>
                        <%= if run.errors && run.errors != [] do %>
                          <tr class="bg-error/5">
                            <td colspan="6" class="py-2">
                              <div class="text-xs">
                                <div class="font-semibold text-error mb-1">Error Details</div>
                                <pre class="bg-base-200 p-2 rounded text-[11px] overflow-x-auto max-h-32"><%= format_errors(run.errors) %></pre>
                              </div>
                            </td>
                          </tr>
                        <% end %>
                      <% end %>
                    </tbody>
                  </table>
                </div>
              <% end %>
            </.ui_panel>
          </div>

          <div class="space-y-6">
            <.ui_panel>
              <:header>
                <div class="text-sm font-semibold">Quick Actions</div>
              </:header>
              <div class="space-y-2">
                <.ui_button
                  variant="primary"
                  size="sm"
                  class="w-full"
                  phx-click="trigger_job"
                >
                  <.icon name="hero-play" class="size-4" /> Trigger Now
                </.ui_button>
                <.ui_button variant="outline" size="sm" class="w-full" href={~p"/admin/oban"}>
                  <.icon name="hero-queue-list" class="size-4" /> View in Oban Web
                </.ui_button>
                <.ui_button variant="ghost" size="sm" class="w-full" navigate={~p"/admin/jobs"}>
                  <.icon name="hero-arrow-left" class="size-4" /> Back to Jobs List
                </.ui_button>
              </div>
            </.ui_panel>

            <.ui_panel>
              <:header>
                <div class="text-sm font-semibold">Execution Stats</div>
                <span class="text-xs text-base-content/60">Last {@chart_hours}h</span>
              </:header>
              <div class="space-y-4">
                <div class="grid grid-cols-2 gap-3">
                  <div class="rounded-lg border border-base-200/60 bg-base-200/30 p-3 text-center">
                    <div class="text-[11px] uppercase tracking-wide text-base-content/60">
                      Total Runs
                    </div>
                    <div class="mt-1 text-xl font-bold text-base-content">
                      {@stats.total}
                    </div>
                  </div>
                  <div class="rounded-lg border border-success/30 bg-success/10 p-3 text-center">
                    <div class="text-[11px] uppercase tracking-wide text-success/80">
                      Completed
                    </div>
                    <div class="mt-1 text-xl font-bold text-success">
                      {@stats.completed}
                    </div>
                  </div>
                  <div class="rounded-lg border border-error/30 bg-error/10 p-3 text-center">
                    <div class="text-[11px] uppercase tracking-wide text-error/80">
                      Failed
                    </div>
                    <div class="mt-1 text-xl font-bold text-error">
                      {@stats.failed}
                    </div>
                  </div>
                  <div class="rounded-lg border border-warning/30 bg-warning/10 p-3 text-center">
                    <div class="text-[11px] uppercase tracking-wide text-warning/80">
                      Retried
                    </div>
                    <div class="mt-1 text-xl font-bold text-warning">
                      {@stats.retried}
                    </div>
                  </div>
                </div>

                <%= if @stats.total > 0 do %>
                  <div class="text-xs text-base-content/60 space-y-1">
                    <div class="flex justify-between">
                      <span>Success Rate</span>
                      <span class="font-semibold text-base-content">
                        {Float.round(@stats.completed / @stats.total * 100, 1)}%
                      </span>
                    </div>
                    <%= if @stats.avg_duration do %>
                      <div class="flex justify-between">
                        <span>Avg Duration</span>
                        <span class="font-semibold text-base-content">
                          {format_ms(@stats.avg_duration)}
                        </span>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>
            </.ui_panel>

            <.ui_panel>
              <:header>
                <div class="text-sm font-semibold">Job ID</div>
              </:header>
              <code class="text-xs font-mono bg-base-200 p-2 rounded block break-all">
                {@job.id}
              </code>
            </.ui_panel>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp execution_chart(assigns) do
    # Calculate chart dimensions
    bar_width = 100 / max(length(assigns.data), 1)
    max_val = max(assigns.max_value, 1)

    assigns =
      assigns
      |> assign(:bar_width, bar_width)
      |> assign(:max_val, max_val)

    ~H"""
    <div class="space-y-2">
      <div class="h-32 relative">
        <svg class="w-full h-full" viewBox="0 0 100 100" preserveAspectRatio="none">
          <!-- Grid lines -->
          <line
            x1="0"
            y1="25"
            x2="100"
            y2="25"
            stroke="currentColor"
            stroke-opacity="0.1"
            stroke-width="0.5"
          />
          <line
            x1="0"
            y1="50"
            x2="100"
            y2="50"
            stroke="currentColor"
            stroke-opacity="0.1"
            stroke-width="0.5"
          />
          <line
            x1="0"
            y1="75"
            x2="100"
            y2="75"
            stroke="currentColor"
            stroke-opacity="0.1"
            stroke-width="0.5"
          />
          
    <!-- Bars -->
          <%= for {bucket, idx} <- Enum.with_index(@data) do %>
            <% x = idx * @bar_width %>
            <% completed_height = bucket.completed / @max_val * 100 %>
            <% failed_height = bucket.failed / @max_val * 100 %>
            
    <!-- Completed (green) -->
            <rect
              x={x + @bar_width * 0.1}
              y={100 - completed_height}
              width={@bar_width * 0.35}
              height={completed_height}
              class="fill-success"
              rx="1"
            >
              <title>Completed: {bucket.completed}</title>
            </rect>
            
    <!-- Failed (red) -->
            <rect
              x={x + @bar_width * 0.55}
              y={100 - failed_height}
              width={@bar_width * 0.35}
              height={max(failed_height, 0)}
              class="fill-error"
              rx="1"
            >
              <title>Failed: {bucket.failed}</title>
            </rect>
          <% end %>
        </svg>
      </div>
      
    <!-- Legend -->
      <div class="flex items-center justify-center gap-4 text-xs text-base-content/60">
        <div class="flex items-center gap-1">
          <div class="w-3 h-3 rounded bg-success"></div>
          <span>Completed</span>
        </div>
        <div class="flex items-center gap-1">
          <div class="w-3 h-3 rounded bg-error"></div>
          <span>Failed</span>
        </div>
      </div>
      
    <!-- Time axis -->
      <div class="flex justify-between text-[10px] text-base-content/40 px-1">
        <%= if length(@data) > 0 do %>
          <span>{format_chart_time(List.first(@data).hour)}</span>
          <span>{format_chart_time(List.last(@data).hour)}</span>
        <% end %>
      </div>
    </div>
    """
  end

  defp format_chart_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%m/%d %H:%M")
  end

  defp format_chart_time(_), do: ""

  defp detail_item(assigns) do
    assigns = assign_new(assigns, :mono, fn -> false end)

    ~H"""
    <div>
      <div class="text-[11px] uppercase tracking-wide text-base-content/60">{@label}</div>
      <div class={[
        "mt-1 text-sm text-base-content",
        @mono && "font-mono text-xs"
      ]}>
        {@value}
      </div>
    </div>
    """
  end

  defp assign_job(socket, job) do
    recent_runs =
      if job.worker do
        JobCatalog.get_recent_runs(job.worker, limit: 20)
      else
        []
      end

    stats = calculate_stats(recent_runs)

    socket
    |> assign(:page_title, job.name)
    |> assign(:job, job)
    |> assign(:recent_runs, recent_runs)
    |> assign(:recent_runs_limit, 20)
    |> assign(:stats, stats)
    |> assign(:refresh_interval, 0)
    |> assign(:refresh_intervals, @refresh_intervals)
    |> assign(:refresh_timer, nil)
    |> assign(:chart_hours, 24)
    |> load_chart_data()
  end

  defp load_chart_data(socket) do
    job = socket.assigns.job
    hours = socket.assigns.chart_hours

    chart_data =
      if job.worker do
        JobCatalog.get_execution_stats(job.worker, hours: hours)
      else
        []
      end

    # Calculate max value for chart scaling
    max_value =
      chart_data
      |> Enum.map(fn b -> max(b.completed, b.failed) end)
      |> Enum.max(fn -> 0 end)

    socket
    |> assign(:chart_data, chart_data)
    |> assign(:chart_max, max_value)
  end

  defp calculate_stats(runs) do
    total = length(runs)

    completed =
      Enum.count(runs, fn run ->
        state = normalize_state(run.state)
        state == :completed
      end)

    failed =
      Enum.count(runs, fn run ->
        state = normalize_state(run.state)
        state in [:discarded, :cancelled]
      end)

    retried =
      Enum.count(runs, fn run ->
        run.attempt > 1
      end)

    durations =
      runs
      |> Enum.filter(fn run ->
        run.completed_at && run.attempted_at
      end)
      |> Enum.map(fn run ->
        DateTime.diff(run.completed_at, run.attempted_at, :millisecond)
      end)

    avg_duration =
      if durations != [] do
        Enum.sum(durations) / length(durations)
      else
        nil
      end

    %{
      total: total,
      completed: completed,
      failed: failed,
      retried: retried,
      avg_duration: avg_duration
    }
  end

  defp schedule_refresh(socket) do
    interval_ms = socket.assigns.refresh_interval * 1000
    timer = Process.send_after(self(), :refresh, interval_ms)
    assign(socket, :refresh_timer, timer)
  end

  defp cancel_refresh_timer(socket) do
    if socket.assigns.refresh_timer do
      Process.cancel_timer(socket.assigns.refresh_timer)
    end

    assign(socket, :refresh_timer, nil)
  end

  defp normalize_state(state) when is_atom(state), do: state

  defp normalize_state(state) when is_binary(state) do
    try do
      String.to_existing_atom(state)
    rescue
      _ -> :unknown
    end
  end

  defp normalize_state(_), do: :unknown

  defp decode_job_id(encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, id} -> {:ok, id}
      :error -> :error
    end
  end

  defp source_label(:cron_plugin), do: "Cron"
  defp source_label(:ash_oban), do: "AshOban"
  defp source_label(_), do: "Unknown"

  defp source_variant(:cron_plugin), do: "info"
  defp source_variant(:ash_oban), do: "accent"
  defp source_variant(_), do: "ghost"

  defp format_datetime(nil), do: "—"

  defp format_datetime(%NaiveDateTime{} = dt) do
    dt
    |> DateTime.from_naive!("Etc/UTC")
    |> format_datetime()
  end

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end

  defp format_duration(%{completed_at: nil}), do: "—"
  defp format_duration(%{attempted_at: nil}), do: "—"

  defp format_duration(%{completed_at: completed, attempted_at: started}) do
    diff_ms = DateTime.diff(completed, started, :millisecond)
    format_ms(diff_ms)
  end

  defp format_ms(nil), do: "—"

  defp format_ms(ms) when ms < 1000, do: "#{round(ms)}ms"
  defp format_ms(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"
  defp format_ms(ms), do: "#{Float.round(ms / 60_000, 1)}m"

  defp format_errors(nil), do: "No error details"
  defp format_errors([]), do: "No error details"

  defp format_errors(errors) when is_list(errors) do
    Enum.map_join(errors, "\n", fn error ->
      case error do
        %{"error" => msg, "at" => at} ->
          "#{at}: #{msg}"

        %{"error" => msg} ->
          msg

        msg when is_binary(msg) ->
          msg

        other ->
          inspect(other)
      end
    end)
  end

  defp format_errors(error), do: inspect(error)

  defp run_state_label(state) do
    state
    |> normalize_state()
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp run_state_variant(state) do
    case normalize_state(state) do
      :completed -> "success"
      :executing -> "info"
      :available -> "info"
      :scheduled -> "info"
      :retryable -> "warning"
      :discarded -> "error"
      :cancelled -> "warning"
      _ -> "ghost"
    end
  end
end
