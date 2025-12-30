defmodule ServiceRadarWebNGWeb.Admin.JobLive.Index do
  @moduledoc """
  LiveView for the job scheduler list view.

  Displays a compact list of jobs from multiple sources:
  - Oban.Plugins.Cron (config-based system maintenance jobs)
  - AshOban triggers (resource-based scheduled actions)

  Supports search, filtering, sorting, pagination, and auto-refresh.
  """
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.AdminComponents

  alias ServiceRadarWebNG.Jobs.JobCatalog

  @default_per_page 20
  @refresh_intervals [
    {5, "5s"},
    {10, "10s"},
    {30, "30s"},
    {60, "1m"},
    {0, "Off"}
  ]

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
  def handle_info(:refresh, socket) do
    socket = load_jobs(socket)

    # Schedule next refresh if auto-refresh is enabled
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
    {:noreply, load_jobs(socket)}
  end

  def handle_event("search", %{"search" => search}, socket) do
    {:noreply,
     socket
     |> assign(:search, search)
     |> assign(:page, 1)
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
     |> assign(:page, 1)
     |> load_jobs()}
  end

  def handle_event("sort", %{"field" => field}, socket) do
    field_atom = String.to_existing_atom(field)
    current_sort = socket.assigns.sort_by
    current_dir = socket.assigns.sort_dir

    {new_sort, new_dir} =
      if current_sort == field_atom do
        # Toggle direction
        {field_atom, if(current_dir == :asc, do: :desc, else: :asc)}
      else
        # New field, default to asc
        {field_atom, :asc}
      end

    {:noreply,
     socket
     |> assign(:sort_by, new_sort)
     |> assign(:sort_dir, new_dir)
     |> load_jobs()}
  end

  def handle_event("page", %{"page" => page}, socket) do
    page = String.to_integer(page)

    {:noreply,
     socket
     |> assign(:page, page)
     |> load_jobs()}
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

  def handle_event("trigger_job", %{"id" => encoded_id}, socket) do
    with {:ok, id} <- decode_job_id(encoded_id),
         {:ok, job} <- JobCatalog.get_job(id),
         {:ok, _oban_job} <- JobCatalog.trigger_job(job) do
      {:noreply,
       socket
       |> put_flash(:info, "Job '#{job.name}' triggered successfully")
       |> load_jobs()}
    else
      :error ->
        {:noreply, put_flash(socket, :error, "Invalid job ID")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Job not found")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to trigger job: #{inspect(reason)}")}
    end
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
          <div class="flex items-center gap-2">
            <div class="flex items-center gap-1 text-xs text-base-content/60">
              <.icon name="hero-arrow-path" class={["size-3", @refresh_interval > 0 && "animate-spin"]} />
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
                    <th class="cursor-pointer hover:text-base-content" phx-click="sort" phx-value-field="name">
                      <div class="flex items-center gap-1">
                        Job
                        <.sort_indicator field={:name} sort_by={@sort_by} sort_dir={@sort_dir} />
                      </div>
                    </th>
                    <th class="cursor-pointer hover:text-base-content" phx-click="sort" phx-value-field="source">
                      <div class="flex items-center gap-1">
                        Source
                        <.sort_indicator field={:source} sort_by={@sort_by} sort_dir={@sort_dir} />
                      </div>
                    </th>
                    <th>Status</th>
                    <th class="cursor-pointer hover:text-base-content" phx-click="sort" phx-value-field="cron">
                      <div class="flex items-center gap-1">
                        Schedule
                        <.sort_indicator field={:cron} sort_by={@sort_by} sort_dir={@sort_dir} />
                      </div>
                    </th>
                    <th class="cursor-pointer hover:text-base-content" phx-click="sort" phx-value-field="last_run_at">
                      <div class="flex items-center gap-1">
                        Last Run
                        <.sort_indicator field={:last_run_at} sort_by={@sort_by} sort_dir={@sort_dir} />
                      </div>
                    </th>
                    <th class="cursor-pointer hover:text-base-content" phx-click="sort" phx-value-field="next_run_at">
                      <div class="flex items-center gap-1">
                        Next Run
                        <.sort_indicator field={:next_run_at} sort_by={@sort_by} sort_dir={@sort_dir} />
                      </div>
                    </th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  <%= for job <- @jobs do %>
                    <tr class="hover:bg-base-200/30">
                      <td class="cursor-pointer" phx-click={JS.navigate(~p"/admin/jobs/#{encode_job_id(job.id)}")}>
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
                        <div class="flex items-center gap-1">
                          <.ui_button
                            variant="ghost"
                            size="xs"
                            phx-click="trigger_job"
                            phx-value-id={encode_job_id(job.id)}
                            title="Trigger now"
                          >
                            <.icon name="hero-play" class="size-4" />
                          </.ui_button>
                          <.ui_button
                            variant="ghost"
                            size="xs"
                            navigate={~p"/admin/jobs/#{encode_job_id(job.id)}"}
                          >
                            <.icon name="hero-chevron-right" class="size-4" />
                          </.ui_button>
                        </div>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>

              <.pagination
                :if={@total_pages > 1}
                page={@page}
                total_pages={@total_pages}
                total_count={@filtered_count}
              />
            <% end %>
          </div>
        </.ui_panel>
      </div>
    </Layouts.app>
    """
  end

  defp sort_indicator(assigns) do
    ~H"""
    <%= if @sort_by == @field do %>
      <.icon name={if @sort_dir == :asc, do: "hero-chevron-up", else: "hero-chevron-down"} class="size-3" />
    <% else %>
      <.icon name="hero-chevron-up-down" class="size-3 opacity-30" />
    <% end %>
    """
  end

  defp pagination(assigns) do
    ~H"""
    <div class="flex items-center justify-between border-t border-base-200/60 pt-4 mt-4">
      <div class="text-xs text-base-content/60">
        Showing page {@page} of {@total_pages} ({@total_count} total)
      </div>
      <div class="flex items-center gap-1">
        <.ui_button
          variant="ghost"
          size="xs"
          phx-click="page"
          phx-value-page={@page - 1}
          disabled={@page <= 1}
        >
          <.icon name="hero-chevron-left" class="size-4" />
        </.ui_button>

        <%= for page_num <- visible_pages(@page, @total_pages) do %>
          <%= if page_num == :ellipsis do %>
            <span class="px-2 text-base-content/40">...</span>
          <% else %>
            <.ui_button
              variant={if page_num == @page, do: "primary", else: "ghost"}
              size="xs"
              phx-click="page"
              phx-value-page={page_num}
            >
              {page_num}
            </.ui_button>
          <% end %>
        <% end %>

        <.ui_button
          variant="ghost"
          size="xs"
          phx-click="page"
          phx-value-page={@page + 1}
          disabled={@page >= @total_pages}
        >
          <.icon name="hero-chevron-right" class="size-4" />
        </.ui_button>
      </div>
    </div>
    """
  end

  defp visible_pages(_current, total) when total <= 7 do
    Enum.to_list(1..total)
  end

  defp visible_pages(current, total) do
    cond do
      current <= 4 ->
        Enum.to_list(1..5) ++ [:ellipsis, total]

      current >= total - 3 ->
        [1, :ellipsis] ++ Enum.to_list((total - 4)..total)

      true ->
        [1, :ellipsis] ++ Enum.to_list((current - 1)..(current + 1)) ++ [:ellipsis, total]
    end
  end

  defp assign_defaults(socket) do
    socket
    |> assign(:page_title, "Job Scheduler")
    |> assign(:search, "")
    |> assign(:filter_source, nil)
    |> assign(:sort_by, nil)
    |> assign(:sort_dir, :asc)
    |> assign(:page, 1)
    |> assign(:per_page, @default_per_page)
    |> assign(:refresh_interval, 0)
    |> assign(:refresh_intervals, @refresh_intervals)
    |> assign(:refresh_timer, nil)
    |> load_jobs()
  end

  defp load_jobs(socket) do
    filters = [
      source: socket.assigns.filter_source,
      search: socket.assigns.search,
      sort_by: socket.assigns.sort_by,
      sort_dir: socket.assigns.sort_dir,
      page: socket.assigns.page,
      per_page: socket.assigns.per_page
    ]

    {jobs, filtered_count} = JobCatalog.list_jobs(filters)
    all_jobs = JobCatalog.list_all_jobs()

    cron_count = Enum.count(all_jobs, &(&1.source == :cron_plugin))
    ash_oban_count = Enum.count(all_jobs, &(&1.source == :ash_oban))

    total_pages = ceil(filtered_count / socket.assigns.per_page)
    leader = get_leader_node()

    socket
    |> assign(:jobs, jobs)
    |> assign(:filtered_count, filtered_count)
    |> assign(:total_count, length(all_jobs))
    |> assign(:total_pages, total_pages)
    |> assign(:cron_job_count, cron_count)
    |> assign(:ash_oban_count, ash_oban_count)
    |> assign(:leader_node, leader)
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

  defp encode_job_id(id), do: Base.url_encode64(id, padding: false)

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
