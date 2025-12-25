defmodule ServiceRadarWebNGWeb.Admin.JobLive.Index do
  @moduledoc """
  LiveView for managing job schedules.

  Uses AshPhoenix.Form for form handling with the JobSchedule Ash resource.
  """
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.AdminComponents

  alias ServiceRadarWebNG.Jobs
  alias ServiceRadar.Jobs.JobSchedule

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_entries(socket)}
  end

  @impl true
  def handle_event("validate", %{"id" => id, "schedule" => params}, socket) do
    schedule_id = parse_id(id)

    ash_form = Map.get(socket.assigns.ash_forms, schedule_id)

    if ash_form do
      updated_form = AshPhoenix.Form.validate(ash_form, params)

      {:noreply,
       socket
       |> assign(:ash_forms, Map.put(socket.assigns.ash_forms, schedule_id, updated_form))
       |> assign(:forms, Map.put(socket.assigns.forms, schedule_id, to_form(updated_form)))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("save", %{"id" => id, "schedule" => params}, socket) do
    schedule_id = parse_id(id)

    ash_form = Map.get(socket.assigns.ash_forms, schedule_id)

    if ash_form do
      case AshPhoenix.Form.submit(ash_form, params: params) do
        {:ok, _updated_schedule} ->
          # Refresh the scheduler after successful update
          Jobs.refresh_scheduler()

          {:noreply,
           socket
           |> put_flash(:info, "Schedule updated.")
           |> assign_entries()}

        {:error, updated_form} ->
          {:noreply,
           socket
           |> put_flash(:error, "Failed to update schedule.")
           |> assign(:ash_forms, Map.put(socket.assigns.ash_forms, schedule_id, updated_form))
           |> assign(:forms, Map.put(socket.assigns.forms, schedule_id, to_form(updated_form)))}
      end
    else
      {:noreply, put_flash(socket, :error, "Schedule not found")}
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :entries, assigns.entries || [])

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-6xl p-6 space-y-6">
        <.admin_nav current_path="/admin/jobs" />

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
    {ash_forms, forms} = build_ash_forms_for_entries(entries)
    leader = Oban.Peer.get_leader()

    socket
    |> assign(:page_title, "Job Scheduler")
    |> assign(:entries, entries)
    |> assign(:ash_forms, ash_forms)
    |> assign(:forms, forms)
    |> assign(:leader_node, leader)
    |> assign(:entry_index, index_entries(entries))
  end

  # Build AshPhoenix.Form for each schedule entry
  defp build_ash_forms_for_entries(entries) do
    # Load all Ash JobSchedule resources
    ash_schedules = load_ash_schedules()

    # Create a map from id to Ash schedule
    ash_by_id = Map.new(ash_schedules, fn s -> {s.id, s} end)

    # Build forms for each entry
    {ash_forms, forms} =
      Enum.reduce(entries, {%{}, %{}}, fn entry, {ash_acc, form_acc} ->
        schedule_id = entry.schedule.id

        case Map.get(ash_by_id, schedule_id) do
          nil ->
            # No Ash resource found - skip (shouldn't happen normally)
            {ash_acc, form_acc}

          ash_schedule ->
            ash_form = build_update_form(ash_schedule)
            phoenix_form = to_form(ash_form)

            {
              Map.put(ash_acc, schedule_id, ash_form),
              Map.put(form_acc, schedule_id, phoenix_form)
            }
        end
      end)

    {ash_forms, forms}
  end

  # Load all JobSchedule Ash resources
  defp load_ash_schedules do
    case Ash.read(JobSchedule, authorize?: false) do
      {:ok, schedules} -> schedules
      {:error, _} -> []
    end
  end

  # Build AshPhoenix.Form for updating a JobSchedule
  defp build_update_form(ash_schedule) do
    AshPhoenix.Form.for_update(ash_schedule, :update,
      domain: ServiceRadar.Jobs,
      as: "schedule"
    )
  end

  defp index_entries(entries) do
    Map.new(entries, fn entry -> {entry.schedule.id, entry} end)
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
