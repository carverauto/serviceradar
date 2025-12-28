defmodule ServiceRadarWebNGWeb.Admin.JobLive.Index do
  @moduledoc """
  LiveView for managing job schedules.

  Displays jobs from multiple sources:
  - Oban.Plugins.Cron (config-based system maintenance jobs)
  - AshOban triggers (resource-based scheduled actions)
  """
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.AdminComponents

  alias ServiceRadarWebNG.Jobs.JobCatalog

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_jobs(socket)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, assign_jobs(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-6xl p-6 space-y-6">
        <.admin_nav current_path="/admin/jobs" />

        <div class="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold text-base-content">Job Scheduler</h1>
            <p class="text-sm text-base-content/60">
              View configured background jobs and their execution status.
            </p>
          </div>
          <div class="flex gap-2">
            <.ui_button variant="ghost" size="sm" phx-click="refresh">
              Refresh
            </.ui_button>
            <.ui_button variant="outline" size="sm" href={~p"/admin/oban"}>
              Open Oban Web
            </.ui_button>
          </div>
        </div>

        <div class="grid gap-4 md:grid-cols-3">
          <.ui_panel class="md:col-span-2">
            <:header>
              <div>
                <div class="text-sm font-semibold">Scheduler Status</div>
                <p class="text-xs text-base-content/60">Leader and configuration overview.</p>
              </div>
            </:header>
            <div class="grid gap-3 sm:grid-cols-3">
              <div class="rounded-lg border border-base-200/60 bg-base-200/30 p-3">
                <div class="text-[11px] uppercase tracking-wide text-base-content/60">
                  Leader Node
                </div>
                <div class="mt-1 text-sm font-semibold text-base-content">
                  {@leader_node || "Unknown"}
                </div>
              </div>
              <div class="rounded-lg border border-base-200/60 bg-base-200/30 p-3">
                <div class="text-[11px] uppercase tracking-wide text-base-content/60">
                  Cron Jobs
                </div>
                <div class="mt-1 text-sm font-semibold text-base-content">
                  {@cron_job_count}
                </div>
              </div>
              <div class="rounded-lg border border-base-200/60 bg-base-200/30 p-3">
                <div class="text-[11px] uppercase tracking-wide text-base-content/60">
                  AshOban Triggers
                </div>
                <div class="mt-1 text-sm font-semibold text-base-content">
                  {@ash_oban_count}
                </div>
              </div>
            </div>
          </.ui_panel>

          <.ui_panel>
            <:header>
              <div class="text-sm font-semibold">Configuration</div>
            </:header>
            <div class="space-y-2 text-xs text-base-content/70">
              <p>
                <strong>Cron jobs</strong> are defined in config and run on a fixed schedule.
              </p>
              <p>
                <strong>AshOban triggers</strong> execute actions on Ash resources based on queries.
              </p>
              <p>Use Oban Web for detailed job monitoring and management.</p>
            </div>
          </.ui_panel>
        </div>

        <.ui_panel>
          <:header>
            <div>
              <div class="text-sm font-semibold">Scheduled Jobs</div>
              <p class="text-xs text-base-content/60">
                All configured background jobs and their schedules.
              </p>
            </div>
          </:header>

          <div class="space-y-4">
            <%= if @jobs == [] do %>
              <div class="rounded-xl border border-dashed border-base-200 bg-base-100 p-8 text-center">
                <div class="text-sm font-semibold text-base-content">No jobs configured</div>
                <p class="mt-1 text-xs text-base-content/60">
                  Configure jobs in your application config or add AshOban triggers to resources.
                </p>
              </div>
            <% else %>
              <%= for job <- @jobs do %>
                <div class="rounded-xl border border-base-200/70 bg-base-100 p-4">
                  <div class="flex flex-wrap items-center justify-between gap-3">
                    <div class="min-w-0">
                      <div class="flex items-center gap-2">
                        <div class="text-sm font-semibold text-base-content">
                          {job.name}
                        </div>
                        <.ui_badge variant={source_variant(job.source)} size="xs">
                          {source_label(job.source)}
                        </.ui_badge>
                      </div>
                      <p class="text-xs text-base-content/60">
                        {job.description}
                      </p>
                    </div>
                    <div class="flex items-center gap-2">
                      <.ui_badge variant={if job.enabled, do: "success", else: "warning"} size="xs">
                        {if job.enabled, do: "Enabled", else: "Paused"}
                      </.ui_badge>
                    </div>
                  </div>

                  <div class="mt-4 grid gap-4 lg:grid-cols-2">
                    <div class="space-y-2 text-xs text-base-content/60">
                      <div class="flex items-center justify-between">
                        <span>Cron</span>
                        <span class="font-mono text-base-content">{job.cron || "—"}</span>
                      </div>
                      <div class="flex items-center justify-between">
                        <span>Queue</span>
                        <span class="font-mono text-base-content">{job.queue}</span>
                      </div>
                      <div class="flex items-center justify-between">
                        <span>Last Run</span>
                        <span class="font-mono text-base-content">
                          {format_datetime(job.last_run_at)}
                        </span>
                      </div>
                      <div class="flex items-center justify-between">
                        <span>Next Run</span>
                        <span class="font-mono text-base-content">
                          {format_datetime(job.next_run_at)}
                        </span>
                      </div>
                    </div>

                    <div class="space-y-2 text-xs text-base-content/60">
                      <%= if job.worker do %>
                        <div class="flex items-center justify-between">
                          <span>Worker</span>
                          <span class="font-mono text-base-content text-[11px]">
                            {inspect(job.worker) |> String.slice(0..50)}
                          </span>
                        </div>
                      <% end %>
                      <%= if job.resource do %>
                        <div class="flex items-center justify-between">
                          <span>Resource</span>
                          <span class="font-mono text-base-content text-[11px]">
                            {inspect(job.resource) |> String.replace("Elixir.", "")}
                          </span>
                        </div>
                      <% end %>
                      <%= if job.action do %>
                        <div class="flex items-center justify-between">
                          <span>Action</span>
                          <span class="font-mono text-base-content">{job.action}</span>
                        </div>
                      <% end %>
                    </div>
                  </div>

                  <%= if job.worker do %>
                    <div class="mt-4 border-t border-base-200/60 pt-4">
                      <div class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                        Recent runs
                      </div>
                      <.render_recent_runs job={job} recent_runs={@recent_runs[job.id] || []} />
                    </div>
                  <% end %>
                </div>
              <% end %>
            <% end %>
          </div>
        </.ui_panel>
      </div>
    </Layouts.app>
    """
  end

  defp render_recent_runs(assigns) do
    ~H"""
    <%= if @recent_runs == [] do %>
      <p class="mt-2 text-xs text-base-content/60">No runs yet.</p>
    <% else %>
      <div class="mt-2 overflow-x-auto rounded-lg border border-base-200/60">
        <table class="table table-xs">
          <thead>
            <tr class="text-[11px] uppercase tracking-wide text-base-content/50">
              <th>State</th>
              <th>Enqueued</th>
              <th>Completed</th>
              <th>Queue</th>
              <th>Attempts</th>
            </tr>
          </thead>
          <tbody>
            <%= for run <- @recent_runs do %>
              <tr>
                <td>
                  <.ui_badge variant={run_state_variant(run.state)} size="xs">
                    {run_state_label(run.state)}
                  </.ui_badge>
                </td>
                <td class="font-mono text-xs text-base-content">
                  {format_datetime(run.inserted_at)}
                </td>
                <td class="font-mono text-xs text-base-content">
                  {format_datetime(run.completed_at)}
                </td>
                <td class="text-xs text-base-content/70">{run.queue}</td>
                <td class="text-xs text-base-content/70">{run.attempt}</td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    <% end %>
    """
  end

  defp assign_jobs(socket) do
    jobs = JobCatalog.list_all_jobs()

    # Get recent runs for each job with a worker
    recent_runs =
      jobs
      |> Enum.filter(& &1.worker)
      |> Map.new(fn job ->
        {job.id, JobCatalog.get_recent_runs(job.worker, limit: 5)}
      end)

    cron_count = Enum.count(jobs, &(&1.source == :cron_plugin))
    ash_oban_count = Enum.count(jobs, &(&1.source == :ash_oban))

    leader = get_leader_node()

    socket
    |> assign(:page_title, "Job Scheduler")
    |> assign(:jobs, jobs)
    |> assign(:recent_runs, recent_runs)
    |> assign(:cron_job_count, cron_count)
    |> assign(:ash_oban_count, ash_oban_count)
    |> assign(:leader_node, leader)
  end

  defp get_leader_node do
    try do
      Oban.Peer.get_leader()
    rescue
      _ -> nil
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

  defp run_state_label(state) when is_atom(state) do
    state
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp run_state_label(state) when is_binary(state) do
    state
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp run_state_label(state), do: to_string(state)

  defp run_state_variant(state) do
    state_atom =
      case state do
        s when is_atom(s) -> s
        s when is_binary(s) -> String.to_existing_atom(s)
        _ -> :unknown
      end

    case state_atom do
      :completed -> "success"
      :executing -> "info"
      :available -> "info"
      :scheduled -> "info"
      :retryable -> "warning"
      :discarded -> "error"
      :cancelled -> "warning"
      _ -> "ghost"
    end
  rescue
    _ -> "ghost"
  end
end
