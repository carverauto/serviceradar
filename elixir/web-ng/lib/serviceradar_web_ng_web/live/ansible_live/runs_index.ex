defmodule ServiceRadarWebNGWeb.AnsibleLive.RunsIndex do
  @moduledoc """
  Browser for `PlaybookRun` history.

  Lists recent runs with state pill, playbook id, controller, started/
  ended timestamps, and (when present) a link to the schedule that fired
  them. Filterable by run state via a dropdown. Static for now — live
  PubSub updates land in a follow-up commit once `EventIngestor` is
  broadcasting on state transitions.

  Permission: `ansible.runs.view`.
  """

  use ServiceRadarWebNGWeb, :live_view

  use Permit.Phoenix.LiveView,
    authorization_module: ServiceRadarWebNGWeb.Authorization,
    resource_module: ServiceRadar.Automation.Ansible.PlaybookRun

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.PlaybookRun
  alias ServiceRadarWebNG.RBAC

  require Ash.Query

  @page_limit 100
  @state_filters ~w(all pending launching running succeeded partial failed unreachable canceled)

  @impl true
  def event_mapping do
    Map.merge(Permit.Phoenix.LiveView.default_event_mapping(), %{
      "filter_state" => :read,
      "refresh" => :read
    })
  end

  @impl true
  def skip_preload, do: [:index, :read]

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "ansible.runs.view") do
      runs = list_runs("all")

      {:ok,
       socket
       |> assign(:page_title, "Ansible Runs")
       |> assign(:state_filter, "all")
       |> assign(:state_filters, @state_filters)
       |> assign(:run_count, length(runs))
       |> stream(:runs, runs, reset: true)}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to view Ansible runs.")
       |> push_navigate(to: ~p"/dashboard")}
    end
  end

  @impl true
  def handle_event("filter_state", %{"state" => state}, socket) when state in @state_filters do
    runs = list_runs(state)

    {:noreply,
     socket
     |> assign(:state_filter, state)
     |> assign(:run_count, length(runs))
     |> stream(:runs, runs, reset: true)}
  end

  def handle_event("refresh", _params, socket) do
    runs = list_runs(socket.assigns.state_filter)

    {:noreply,
     socket
     |> assign(:run_count, length(runs))
     |> stream(:runs, runs, reset: true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-full max-w-7xl p-6 space-y-4">
      <header class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-semibold">Ansible Runs</h1>
          <p class="text-sm text-base-content/70">
            {@run_count} run{if @run_count == 1, do: "", else: "s"} shown
            (filter: {@state_filter}, capped at {@page_limit}).
          </p>
        </div>
        <button type="button" class="btn btn-sm btn-ghost" phx-click="refresh">Refresh</button>
      </header>

      <div class="flex flex-wrap items-center gap-2">
        <span class="text-sm text-base-content/60 mr-1">Filter:</span>
        <button
          :for={state <- @state_filters}
          type="button"
          phx-click="filter_state"
          phx-value-state={state}
          class={["btn btn-xs", state == @state_filter && "btn-primary"]}
        >
          {state}
        </button>
      </div>

      <div :if={@run_count == 0} class="rounded-lg border border-dashed border-base-300 p-8 text-center text-sm text-base-content/70">
        No runs match the current filter.
      </div>

      <div :if={@run_count > 0} class="overflow-x-auto rounded-lg border border-base-300 bg-base-100">
        <table class="table table-zebra">
          <thead>
            <tr>
              <th>State</th>
              <th>Playbook</th>
              <th>Controller</th>
              <th>Started</th>
              <th>Ended</th>
              <th>AWX Job</th>
              <th>Source</th>
              <th></th>
            </tr>
          </thead>
          <tbody id="ansible-runs" phx-update="stream">
            <tr :for={{id, run} <- @runs} id={id}>
              <td>
                <span class={["badge", state_badge_class(run.state)]}>{run.state}</span>
              </td>
              <td><code class="text-xs">{shorten(run.playbook_id)}</code></td>
              <td><code class="text-xs">{shorten(run.controller_id)}</code></td>
              <td class="whitespace-nowrap">{fmt_ts(run.started_at)}</td>
              <td class="whitespace-nowrap">{fmt_ts(run.ended_at)}</td>
              <td>{run.awx_job_id}</td>
              <td>
                <span :if={run.schedule_id} class="badge badge-ghost">schedule</span>
                <span :if={!run.schedule_id} class="badge badge-ghost">ad-hoc</span>
              </td>
              <td>
                <span class="text-xs text-base-content/50">detail page wip</span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  ## Helpers -------------------------------------------------------------------

  defp list_runs("all") do
    query =
      PlaybookRun
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(@page_limit)

    case Ash.read(query, actor: actor()) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  defp list_runs(state) when is_binary(state) do
    atom = String.to_existing_atom(state)

    query =
      PlaybookRun
      |> Ash.Query.filter(state == ^atom)
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(@page_limit)

    case Ash.read(query, actor: actor()) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  defp actor, do: SystemActor.system(:ansible_runs_index)

  defp state_badge_class(:succeeded), do: "badge-success"
  defp state_badge_class(:partial), do: "badge-warning"
  defp state_badge_class(:failed), do: "badge-error"
  defp state_badge_class(:unreachable), do: "badge-error"
  defp state_badge_class(:canceled), do: "badge-neutral"
  defp state_badge_class(:running), do: "badge-info"
  defp state_badge_class(:launching), do: "badge-info"
  defp state_badge_class(:pending), do: "badge-ghost"
  defp state_badge_class(_), do: "badge-ghost"

  defp fmt_ts(nil), do: "—"
  defp fmt_ts(%DateTime{} = ts), do: Calendar.strftime(ts, "%Y-%m-%d %H:%M:%S")
  defp fmt_ts(_), do: "—"

  defp shorten(nil), do: "—"
  defp shorten(s) when is_binary(s) and byte_size(s) > 8, do: String.slice(s, 0, 8) <> "…"
  defp shorten(s), do: to_string(s)
end
