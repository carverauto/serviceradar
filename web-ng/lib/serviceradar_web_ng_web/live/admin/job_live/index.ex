defmodule ServiceRadarWebNGWeb.Admin.JobLive.Index do
  @moduledoc """
  LiveView for the job scheduler list view.

  Displays a compact list of jobs from multiple sources:
  - Oban.Plugins.Cron (config-based system maintenance jobs)
  - AshOban triggers (resource-based scheduled actions)

  Supports search and filtering. Click a job to see details.
  """
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.AdminComponents

  alias ServiceRadarWebNG.Jobs.JobCatalog

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_defaults(socket)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params), do: socket

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_jobs(socket)}
  end

  def handle_event("search", %{"search" => search}, socket) do
    {:noreply,
     socket
     |> assign(:search, search)
     |> load_jobs()}
  end

  def handle_event("filter", %{"source" => source}, socket) do
    source_atom =
      case source do
        "" -> nil
        "cron_plugin" -> :cron_plugin
        "ash_oban" -> :ash_oban
        _ -> nil
      end

    {:noreply,
     socket
     |> assign(:filter_source, source_atom)
     |> load_jobs()}
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
              <.icon name="hero-arrow-path" class="size-4" /> Refresh
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
                {@total_count} job(s) configured
              </p>
            </div>
            <div class="flex flex-wrap gap-2">
              <form phx-change="search" class="flex-1 min-w-[200px]">
                <input
                  type="text"
                  name="search"
                  value={@search}
                  placeholder="Search jobs..."
                  class="input input-sm input-bordered w-full"
                  phx-debounce="300"
                />
              </form>
              <form phx-change="filter">
                <select name="source" class="select select-sm select-bordered">
                  <option value="">All Sources</option>
                  <option value="cron_plugin" selected={@filter_source == :cron_plugin}>
                    Cron Jobs
                  </option>
                  <option value="ash_oban" selected={@filter_source == :ash_oban}>
                    AshOban Triggers
                  </option>
                </select>
              </form>
            </div>
          </:header>

          <div class="overflow-x-auto">
            <%= if @jobs == [] do %>
              <div class="rounded-xl border border-dashed border-base-200 bg-base-100 p-8 text-center">
                <div class="text-sm font-semibold text-base-content">
                  <%= if @search != "" or @filter_source do %>
                    No jobs match your filters
                  <% else %>
                    No jobs configured
                  <% end %>
                </div>
                <p class="mt-1 text-xs text-base-content/60">
                  <%= if @search != "" or @filter_source do %>
                    Try adjusting your search or filter criteria.
                  <% else %>
                    Configure jobs in your application config or add AshOban triggers to resources.
                  <% end %>
                </p>
              </div>
            <% else %>
              <table class="table table-sm">
                <thead>
                  <tr class="text-xs uppercase tracking-wide text-base-content/60">
                    <th>Job</th>
                    <th>Source</th>
                    <th>Status</th>
                    <th>Schedule</th>
                    <th>Last Run</th>
                    <th>Next Run</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  <%= for job <- @jobs do %>
                    <tr class="hover:bg-base-200/30 cursor-pointer" phx-click={JS.navigate(~p"/admin/jobs/#{encode_job_id(job.id)}")}>
                      <td>
                        <div class="font-medium text-base-content">{job.name}</div>
                        <div class="text-xs text-base-content/60 max-w-[250px] truncate">
                          {job.description}
                        </div>
                      </td>
                      <td>
                        <.ui_badge variant={source_variant(job.source)} size="xs">
                          {source_label(job.source)}
                        </.ui_badge>
                      </td>
                      <td>
                        <.ui_badge variant={if job.enabled, do: "success", else: "warning"} size="xs">
                          {if job.enabled, do: "Enabled", else: "Paused"}
                        </.ui_badge>
                      </td>
                      <td class="font-mono text-xs text-base-content/70">
                        {job.cron || "—"}
                      </td>
                      <td class="text-xs text-base-content/70">
                        {format_datetime_short(job.last_run_at)}
                      </td>
                      <td class="text-xs text-base-content/70">
                        {format_datetime_short(job.next_run_at)}
                      </td>
                      <td>
                        <.ui_button
                          variant="ghost"
                          size="xs"
                          navigate={~p"/admin/jobs/#{encode_job_id(job.id)}"}
                        >
                          <.icon name="hero-chevron-right" class="size-4" />
                        </.ui_button>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            <% end %>
          </div>
        </.ui_panel>
      </div>
    </Layouts.app>
    """
  end

  defp assign_defaults(socket) do
    socket
    |> assign(:page_title, "Job Scheduler")
    |> assign(:search, "")
    |> assign(:filter_source, nil)
    |> load_jobs()
  end

  defp load_jobs(socket) do
    filters = [
      source: socket.assigns.filter_source,
      search: socket.assigns.search
    ]

    jobs = JobCatalog.list_jobs(filters)
    all_jobs = JobCatalog.list_all_jobs()

    cron_count = Enum.count(all_jobs, &(&1.source == :cron_plugin))
    ash_oban_count = Enum.count(all_jobs, &(&1.source == :ash_oban))

    leader = get_leader_node()

    socket
    |> assign(:jobs, jobs)
    |> assign(:total_count, length(all_jobs))
    |> assign(:cron_job_count, cron_count)
    |> assign(:ash_oban_count, ash_oban_count)
    |> assign(:leader_node, leader)
  end

  defp get_leader_node do
    try do
      case ServiceRadar.Cluster.ClusterStatus.find_coordinator() do
        nil ->
          nil

        coordinator_node ->
          case :rpc.call(coordinator_node, Oban.Peer, :get_leader, []) do
            leader when is_binary(leader) -> leader
            _ -> nil
          end
      end
    rescue
      _ -> nil
    end
  end

  # Encode job ID for URL (handles colons in IDs)
  defp encode_job_id(id), do: Base.url_encode64(id, padding: false)

  defp source_label(:cron_plugin), do: "Cron"
  defp source_label(:ash_oban), do: "AshOban"
  defp source_label(_), do: "Unknown"

  defp source_variant(:cron_plugin), do: "info"
  defp source_variant(:ash_oban), do: "accent"
  defp source_variant(_), do: "ghost"

  defp format_datetime_short(nil), do: "—"

  defp format_datetime_short(%NaiveDateTime{} = dt) do
    dt
    |> DateTime.from_naive!("Etc/UTC")
    |> format_datetime_short()
  end

  defp format_datetime_short(%DateTime{} = dt) do
    now = DateTime.utc_now()
    diff_seconds = DateTime.diff(now, dt)
    diff_minutes = div(diff_seconds, 60)
    diff_hours = div(diff_minutes, 60)
    diff_days = div(diff_hours, 24)

    cond do
      diff_seconds < 0 ->
        # Future time - show relative
        future_seconds = abs(diff_seconds)
        future_minutes = div(future_seconds, 60)
        future_hours = div(future_minutes, 60)

        cond do
          future_minutes < 1 -> "in <1m"
          future_minutes < 60 -> "in #{future_minutes}m"
          future_hours < 24 -> "in #{future_hours}h"
          true -> Calendar.strftime(dt, "%m/%d %H:%M")
        end

      diff_minutes < 1 ->
        "<1m ago"

      diff_minutes < 60 ->
        "#{diff_minutes}m ago"

      diff_hours < 24 ->
        "#{diff_hours}h ago"

      diff_days < 7 ->
        "#{diff_days}d ago"

      true ->
        Calendar.strftime(dt, "%m/%d %H:%M")
    end
  end
end
