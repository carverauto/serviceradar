defmodule ServiceRadarWebNGWeb.Admin.JobLive.Index do
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNG.Jobs

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_entries(socket)}
  end

  @impl true
  def handle_event("validate", %{"id" => id, "schedule" => params}, socket) do
    {_entry, schedule} = lookup_entry(socket, id)
    changeset = Jobs.change_schedule(schedule, params) |> Map.put(:action, :validate)
    form = to_form(changeset, as: :schedule)

    {:noreply, assign(socket, :forms, Map.put(socket.assigns.forms, schedule.id, form))}
  end

  @impl true
  def handle_event("save", %{"id" => id, "schedule" => params}, socket) do
    {_entry, schedule} = lookup_entry(socket, id)

    case Jobs.update_schedule(schedule, params) do
      {:ok, _schedule} ->
        {:noreply,
         socket
         |> put_flash(:info, "Schedule updated.")
         |> assign_entries()}

      {:error, changeset} ->
        form = to_form(%{changeset | action: :validate}, as: :schedule)

        {:noreply,
         socket
         |> put_flash(:error, "Failed to update schedule.")
         |> assign(:forms, Map.put(socket.assigns.forms, schedule.id, form))}
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :entries, assigns.entries || [])

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-6xl p-6 space-y-6">
        <div class="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold text-base-content">Job Scheduler</h1>
            <p class="text-sm text-base-content/60">
              Manage recurring background jobs and scheduling cadence.
            </p>
          </div>
          <.ui_button variant="outline" size="sm" href={~p"/admin/oban"}>
            Open Oban Web
          </.ui_button>
        </div>

        <div class="grid gap-4 md:grid-cols-3">
          <.ui_panel class="md:col-span-2">
            <:header>
              <div>
                <div class="text-sm font-semibold">Scheduler Status</div>
                <p class="text-xs text-base-content/60">Leader and last observed state.</p>
              </div>
            </:header>
            <div class="grid gap-3 sm:grid-cols-2">
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
                  Scheduler Mode
                </div>
                <div class="mt-1 text-sm font-semibold text-base-content">Oban Peer Leader</div>
              </div>
            </div>
          </.ui_panel>

          <.ui_panel>
            <:header>
              <div class="text-sm font-semibold">Quick Notes</div>
            </:header>
            <div class="space-y-2 text-xs text-base-content/70">
              <p>Changes apply immediately without restarting the app.</p>
              <p>Use cron expressions with UTC timezone by default.</p>
              <p>Leader election prevents duplicate schedule inserts.</p>
            </div>
          </.ui_panel>
        </div>

        <.ui_panel>
          <:header>
            <div>
              <div class="text-sm font-semibold">Scheduled Jobs</div>
              <p class="text-xs text-base-content/60">
                Update the cron cadence or toggle jobs on/off.
              </p>
            </div>
          </:header>

          <div class="space-y-4">
            <%= if @entries == [] do %>
              <div class="rounded-xl border border-dashed border-base-200 bg-base-100 p-8 text-center">
                <div class="text-sm font-semibold text-base-content">No schedules found</div>
                <p class="mt-1 text-xs text-base-content/60">
                  Run migrations to seed the default trace refresh schedule.
                </p>
              </div>
            <% else %>
              <%= for entry <- @entries do %>
                <div class="rounded-xl border border-base-200/70 bg-base-100 p-4">
                  <div class="flex flex-wrap items-center justify-between gap-3">
                    <div class="min-w-0">
                      <div class="text-sm font-semibold text-base-content">
                        {entry_title(entry)}
                      </div>
                      <p class="text-xs text-base-content/60">
                        {entry_description(entry)}
                      </p>
                    </div>
                    <div class="flex items-center gap-2">
                      <.ui_badge variant={entry_status_variant(entry)} size="xs">
                        {entry_status_label(entry)}
                      </.ui_badge>
                    </div>
                  </div>

                  <div class="mt-4 grid gap-4 lg:grid-cols-3">
                    <div class="space-y-2 text-xs text-base-content/60">
                      <div class="flex items-center justify-between">
                        <span>Last Enqueued</span>
                        <span class="font-mono text-base-content">
                          {format_datetime(entry.schedule.last_enqueued_at)}
                        </span>
                      </div>
                      <div class="flex items-center justify-between">
                        <span>Next Run</span>
                        <span class="font-mono text-base-content">
                          {format_datetime(entry.next_run_at)}
                        </span>
                      </div>
                      <div class="flex items-center justify-between">
                        <span>Timezone</span>
                        <span class="font-mono text-base-content">
                          {entry.schedule.timezone || "Etc/UTC"}
                        </span>
                      </div>
                    </div>

                    <div class="lg:col-span-2">
                      <.form
                        for={@forms[entry.schedule.id]}
                        id={"schedule-form-#{entry.schedule.id}"}
                        phx-change="validate"
                        phx-submit="save"
                        phx-value-id={entry.schedule.id}
                        class="grid gap-2 sm:grid-cols-3 sm:items-end"
                      >
                        <div class="sm:col-span-2">
                          <.input
                            field={@forms[entry.schedule.id][:cron]}
                            type="text"
                            label="Cron schedule"
                            placeholder="*/2 * * * *"
                          />
                        </div>
                        <div>
                          <.input
                            field={@forms[entry.schedule.id][:enabled]}
                            type="checkbox"
                            label="Enabled"
                          />
                        </div>
                        <div class="sm:col-span-3 flex justify-end">
                          <.ui_button variant="primary" size="sm" type="submit">
                            Save changes
                          </.ui_button>
                        </div>
                      </.form>
                    </div>
                  </div>

                  <div class="mt-4 border-t border-base-200/60 pt-4">
                    <div class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                      Recent runs
                    </div>
                    <%= if entry.recent_runs == [] do %>
                      <p class="mt-2 text-xs text-base-content/60">No runs yet.</p>
                    <% else %>
                      <div class="mt-2 overflow-x-auto rounded-lg border border-base-200/60">
                        <table class="table table-xs">
                          <thead>
                            <tr class="text-[11px] uppercase tracking-wide text-base-content/50">
                              <th>State</th>
                              <th>Enqueued</th>
                              <th>Attempted</th>
                              <th>Completed</th>
                              <th>Queue</th>
                              <th>Attempts</th>
                            </tr>
                          </thead>
                          <tbody>
                            <%= for run <- entry.recent_runs do %>
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
                                  {format_datetime(run.attempted_at)}
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
                  </div>
                </div>
              <% end %>
            <% end %>
          </div>
        </.ui_panel>
      </div>
    </Layouts.app>
    """
  end

  defp assign_entries(socket) do
    entries = Jobs.list_schedule_entries(run_limit: 5)
    forms = forms_for_entries(entries)
    leader = Oban.Peer.get_leader()

    socket
    |> assign(:page_title, "Job Scheduler")
    |> assign(:entries, entries)
    |> assign(:forms, forms)
    |> assign(:leader_node, leader)
    |> assign(:entry_index, index_entries(entries))
  end

  defp forms_for_entries(entries) do
    Map.new(entries, fn entry ->
      changeset = Jobs.change_schedule(entry.schedule)
      {entry.schedule.id, to_form(changeset, as: :schedule)}
    end)
  end

  defp index_entries(entries) do
    Map.new(entries, fn entry -> {entry.schedule.id, entry} end)
  end

  defp lookup_entry(socket, id) do
    schedule_id = parse_id(id)
    entry = Map.get(socket.assigns.entry_index, schedule_id)
    {entry, entry.schedule}
  end

  defp parse_id(id) when is_integer(id), do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, _} -> parsed
      _ -> 0
    end
  end

  defp entry_title(%{job: %{label: label}}), do: label
  defp entry_title(%{schedule: schedule}), do: schedule.job_key

  defp entry_description(%{job: %{description: description}}), do: description
  defp entry_description(_), do: "No description available."

  defp entry_status_label(%{schedule: schedule}) do
    if schedule.enabled, do: "Enabled", else: "Paused"
  end

  defp entry_status_variant(%{schedule: schedule}) do
    if schedule.enabled, do: "success", else: "warning"
  end

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

  defp run_state_label(state), do: state

  defp run_state_variant(state) do
    case state do
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
