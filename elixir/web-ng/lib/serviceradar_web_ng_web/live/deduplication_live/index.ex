defmodule ServiceRadarWebNGWeb.DeduplicationLive.Index do
  @moduledoc """
  Review queue for identity de-duplication tasks.

  Identity reconciliation opens one task for every set of devices it refused to merge on its
  own. The queue lists them with their devices and the decisions behind them. Anyone with
  `devices.view` can read it; operators and admins merge a task's devices into one they choose,
  mark them distinct, dismiss the task, or reopen a dismissed one.

  Each event re-checks the caller's permission, and every resolution re-reads the task, so the
  submitted form never decides which task or state an action applies to. Resolutions made in
  another session arrive through `ServiceRadar.Inventory.DeduplicationTaskNotifier` and refresh
  the queue.
  """

  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNG.DeduplicationQueue
  alias ServiceRadarWebNG.RBAC

  require Logger

  @status_filters ~w(open dismissed merged distinct all)
  @status_atoms %{
    "open" => :open,
    "dismissed" => :dismissed,
    "merged" => :merged,
    "distinct" => :distinct,
    "all" => :all
  }

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "devices.view") do
      if connected?(socket), do: DeduplicationQueue.subscribe()

      socket =
        socket
        |> assign(:page_title, "De-duplication tasks")
        |> assign(:status_filter, "open")
        |> assign(:status_filters, @status_filters)
        |> assign(:can_resolve, DeduplicationQueue.can_resolve?(scope))
        |> assign(:page_limit, DeduplicationQueue.page_limit())
        |> assign(:task_count, 0)
        |> assign(:loaded, false)
        |> assign(:load_error, nil)
        |> assign(:selected, nil)
        |> stream(:tasks, [], reset: true)

      {:ok, if(connected?(socket), do: load_tasks(socket), else: socket)}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to view devices.")
       |> push_navigate(to: ~p"/dashboard")}
    end
  end

  @impl true
  def handle_event("filter", %{"status" => status}, socket) when status in @status_filters do
    with_read(socket, fn socket ->
      socket |> assign(:status_filter, status) |> load_tasks()
    end)
  end

  def handle_event("filter", _params, socket), do: {:noreply, socket}

  def handle_event("refresh", _params, socket) do
    with_read(socket, &(&1 |> load_tasks() |> reload_selected()))
  end

  def handle_event("select", %{"id" => id}, socket) when is_binary(id) do
    with_read(socket, &select_task(&1, id))
  end

  def handle_event("close", _params, socket) do
    with_read(socket, &assign(&1, :selected, nil))
  end

  def handle_event("resolve", %{"task_id" => id, "op" => op} = params, socket)
      when op in ["merge", "distinct", "dismiss"] and is_binary(id) do
    with_resolve(socket, id, fn scope, task ->
      note = params["note"]

      case op do
        "merge" -> DeduplicationQueue.merge(scope, task, params["survivor"] || "", note)
        "distinct" -> DeduplicationQueue.mark_distinct(scope, task, note)
        "dismiss" -> DeduplicationQueue.dismiss(scope, task, note)
      end
    end)
  end

  def handle_event("resolve", _params, socket), do: {:noreply, socket}

  def handle_event("reopen", %{"id" => id}, socket) when is_binary(id) do
    with_resolve(socket, id, &DeduplicationQueue.reopen/2)
  end

  @impl true
  def handle_info({:deduplication_task_updated, %{id: id}}, socket) do
    socket = load_tasks(socket)

    socket =
      case socket.assigns.selected do
        %{task: %{id: ^id}} -> reload_selected(socket)
        _ -> socket
      end

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # -- authorization ----------------------------------------------------------------------

  # Reads need devices.view on every event, not only at mount: a role change takes effect on
  # the next event rather than the next page load.
  defp with_read(socket, fun) do
    if RBAC.can?(socket.assigns.current_scope, "devices.view") do
      {:noreply, fun.(socket)}
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to view devices.")}
    end
  end

  # Resolutions re-read the task by id and let the core action check the caller against that
  # record; the button being visible is not the authorization.
  defp with_resolve(socket, id, action) do
    scope = socket.assigns.current_scope

    result =
      if DeduplicationQueue.can_resolve?(scope) and RBAC.can?(scope, "devices.view") do
        with {:ok, task} <- DeduplicationQueue.get_task(scope, id) do
          action.(scope, task)
        end
      else
        {:error, :forbidden}
      end

    case result do
      {:ok, task} ->
        {:noreply,
         socket
         |> put_flash(:info, resolved_message(task))
         |> load_tasks()
         |> select_task(task.id)}

      {:error, reason} ->
        Logger.info("De-duplication task #{id} action refused: #{inspect(reason, limit: 5)}")

        {:noreply,
         socket
         |> put_flash(:error, DeduplicationQueue.error_message(reason))
         |> reload_selected()}
    end
  end

  defp resolved_message(%{status: :merged, merged_into: survivor}), do: "Merged the task's devices into #{survivor}."

  defp resolved_message(%{status: :distinct}), do: "Marked the devices distinct; they will not be merged automatically."

  defp resolved_message(%{status: :dismissed}), do: "Dismissed the task."
  defp resolved_message(%{status: :open}), do: "Reopened the task."

  # -- loading ----------------------------------------------------------------------------

  defp load_tasks(socket) do
    status = Map.fetch!(@status_atoms, socket.assigns.status_filter)

    case DeduplicationQueue.list_tasks(socket.assigns.current_scope, status) do
      {:ok, tasks} ->
        socket
        |> assign(:task_count, length(tasks))
        |> assign(:loaded, true)
        |> assign(:load_error, nil)
        |> stream(:tasks, tasks, reset: true)

      {:error, reason} ->
        Logger.warning("Could not load de-duplication tasks: #{inspect(reason, limit: 5)}")

        socket
        |> assign(:task_count, 0)
        |> assign(:loaded, true)
        |> assign(:load_error, "De-duplication tasks could not be loaded.")
        |> stream(:tasks, [], reset: true)
    end
  end

  defp reload_selected(%{assigns: %{selected: %{task: %{id: id}}}} = socket), do: select_task(socket, id)
  defp reload_selected(socket), do: socket

  defp select_task(socket, id) do
    scope = socket.assigns.current_scope

    with {:ok, task} <- DeduplicationQueue.get_task(scope, id),
         {:ok, devices} <- DeduplicationQueue.devices(scope, task.device_uids),
         {:ok, decisions} <- DeduplicationQueue.decisions(scope, task) do
      assign(socket, :selected, %{task: task, devices: devices, decisions: decisions})
    else
      {:error, reason} ->
        socket
        |> assign(:selected, nil)
        |> put_flash(:error, DeduplicationQueue.error_message(reason))
    end
  end

  # -- rendering --------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path="/devices/deduplication"
      page_title={@page_title}
      shell={:operations}
    >
      <div id="deduplication-queue" class="mx-auto w-full max-w-7xl space-y-5 p-6">
        <header class="flex flex-wrap items-start justify-between gap-4">
          <div class="max-w-3xl space-y-1">
            <h1 class="text-2xl font-semibold">De-duplication tasks</h1>
            <p class="text-sm text-sr-muted">
              Device sets identity reconciliation would not merge on its own. Merge them into one
              device, mark them as different devices, or dismiss the task.
              <span :if={not @can_resolve}>Operators resolve tasks; you can review them.</span>
            </p>
          </div>
          <.ui_button type="button" phx-click="refresh" size="sm" variant="neutral">
            <.icon name="hero-arrow-path" class="size-4" /> Refresh
          </.ui_button>
        </header>

        <div class="flex flex-wrap items-center gap-2" aria-label="Task status filter">
          <span class="mr-1 text-sm text-sr-muted">Status:</span>
          <.ui_button
            :for={status <- @status_filters}
            id={"dedup-filter-#{status}"}
            type="button"
            phx-click="filter"
            phx-value-status={status}
            size="xs"
            variant={if(status == @status_filter, do: "primary", else: "ghost")}
            active={status == @status_filter}
          >
            {status}
          </.ui_button>
          <span class="ml-2 text-xs text-sr-muted">
            {@task_count} shown{if @task_count >= @page_limit, do: " (most recent #{@page_limit})"}
          </span>
        </div>

        <div :if={@load_error} role="alert" class={ui_alert_class("error")}>
          <.icon name="hero-exclamation-circle" class="size-5" />
          <span>{@load_error}</span>
        </div>

        <div :if={not @loaded} role="status" class="flex items-center gap-2 p-4 text-sm text-sr-muted">
          <.ui_spinner size="sm" /> Loading de-duplication tasks…
        </div>

        <div
          :if={@loaded and @task_count == 0 and is_nil(@load_error)}
          id="dedup-empty"
          role="status"
          class="rounded-sr-surface border border-dashed border-sr-line p-8 text-center text-sm text-sr-muted"
        >
          No {if @status_filter == "all", do: "", else: @status_filter} de-duplication tasks.
        </div>

        <.task_detail
          :if={@selected}
          selected={@selected}
          can_resolve={@can_resolve}
          timezone={timezone(@current_scope)}
        />

        <div :if={@task_count > 0} class="overflow-x-auto border border-sr-line bg-sr-surface">
          <table class={ui_table_class(zebra: true)}>
            <thead>
              <tr>
                <th>Status</th>
                <th>Devices</th>
                <th>Why it was not merged</th>
                <th>Occurrences</th>
                <th>Last decided</th>
                <th></th>
              </tr>
            </thead>
            <tbody id="dedup-tasks" phx-update="stream">
              <tr :for={{dom_id, task} <- @streams.tasks} id={dom_id}>
                <td><.status_badge status={task.status} /></td>
                <td>
                  <span class="text-xs text-sr-muted">{length(task.device_uids)} devices</span>
                  <code :for={uid <- task.device_uids} class="block max-w-72 truncate text-xs">
                    {uid}
                  </code>
                </td>
                <td>
                  <code class="text-xs">{task.last_decision_kind}</code>
                  <span class="block text-xs text-sr-muted">{task.last_reason}</span>
                </td>
                <td>{task.occurrence_count}</td>
                <td class="whitespace-nowrap">
                  <.user_time
                    id={"dedup-task-#{task.id}-last-decided"}
                    value={task.last_decided_at}
                    timezone={timezone(@current_scope)}
                    style={:compact}
                  />
                </td>
                <td>
                  <.ui_button
                    id={"dedup-review-#{task.id}"}
                    type="button"
                    phx-click="select"
                    phx-value-id={task.id}
                    size="xs"
                    variant="neutral"
                  >
                    Review
                  </.ui_button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :selected, :map, required: true
  attr :can_resolve, :boolean, required: true
  attr :timezone, :string, required: true

  defp task_detail(assigns) do
    assigns =
      assigns
      |> assign(:task, assigns.selected.task)
      |> assign(:devices, assigns.selected.devices)
      |> assign(:decisions, assigns.selected.decisions)

    ~H"""
    <.ui_panel id="dedup-task-detail">
      <:header>
        <div class="space-y-1">
          <div class="flex items-center gap-2">
            <.status_badge status={@task.status} />
            <span class="font-semibold">{length(@task.device_uids)} devices</span>
            <code class="text-xs text-sr-muted">{@task.id}</code>
          </div>
          <p class="text-sm text-sr-muted">
            Opened by a <code>{@task.category}</code>
            decision; the latest was <code>{@task.last_decision_kind}</code>
            ({@task.last_reason}), seen {@task.occurrence_count} time{if @task.occurrence_count == 1,
              do: "",
              else: "s"}.
          </p>
          <p :if={@task.status != :open} id="dedup-task-resolution" class="text-sm">
            {String.capitalize(to_string(@task.status))} by {@task.resolved_by || "unknown"}
            <.user_time
              id={"dedup-task-#{@task.id}-resolved-at"}
              value={@task.resolved_at}
              timezone={@timezone}
              style={:compact}
            />
            <span :if={@task.merged_into}>into <code>{@task.merged_into}</code></span>
            <span :if={@task.resolution_note}>: {@task.resolution_note}</span>
          </p>
        </div>
        <.ui_button type="button" phx-click="close" size="xs" variant="ghost" aria-label="Close">
          <.icon name="hero-x-mark" class="size-4" />
        </.ui_button>
      </:header>

      <form id="dedup-resolve-form" phx-submit="resolve" class="space-y-4">
        <input type="hidden" name="task_id" value={@task.id} />

        <table class={ui_table_class()}>
          <thead>
            <tr>
              <th :if={@task.status == :open and @can_resolve}>Keep</th>
              <th>Device</th>
              <th>Hostname</th>
              <th>IP</th>
              <th>MAC</th>
              <th>State</th>
            </tr>
          </thead>
          <tbody id="dedup-task-devices">
            <tr :for={uid <- @task.device_uids} id={"dedup-device-#{uid}"}>
              <td :if={@task.status == :open and @can_resolve}>
                <input
                  type="radio"
                  name="survivor"
                  value={uid}
                  aria-label={"Keep #{uid}"}
                  class="radio radio-sm"
                />
              </td>
              <td>
                <.link navigate={~p"/devices/#{uid}"} class="font-mono text-xs underline">{uid}</.link>
              </td>
              <td>{device_field(@devices, uid, :hostname)}</td>
              <td><code class="text-xs">{device_field(@devices, uid, :ip)}</code></td>
              <td><code class="text-xs">{device_field(@devices, uid, :mac)}</code></td>
              <td>{device_state(@devices, uid)}</td>
            </tr>
          </tbody>
        </table>

        <div :if={@task.status == :open and @can_resolve} class="flex flex-wrap items-end gap-2">
          <label class="flex min-w-64 flex-1 flex-col gap-1 text-sm">
            <span class="text-sr-muted">Note (optional)</span>
            <input
              type="text"
              name="note"
              maxlength="500"
              class="rounded-sr-control border border-sr-line bg-sr-surface px-2 py-1 text-sm"
            />
          </label>
          <.ui_button
            id="dedup-merge"
            type="submit"
            name="op"
            value="merge"
            size="sm"
            variant="primary"
            data-confirm="Merge every other device into the one selected to keep?"
          >
            Merge into selected
          </.ui_button>
          <.ui_button
            id="dedup-distinct"
            type="submit"
            name="op"
            value="distinct"
            size="sm"
            variant="outline"
          >
            Mark distinct
          </.ui_button>
          <.ui_button
            id="dedup-dismiss"
            type="submit"
            name="op"
            value="dismiss"
            size="sm"
            variant="ghost"
          >
            Dismiss
          </.ui_button>
        </div>
      </form>

      <div :if={@task.status == :dismissed and @can_resolve} class="mt-3">
        <.ui_button
          id="dedup-reopen"
          type="button"
          phx-click="reopen"
          phx-value-id={@task.id}
          size="sm"
          variant="outline"
        >
          Reopen
        </.ui_button>
      </div>

      <section class="mt-5 space-y-2">
        <h2 class="text-sm font-semibold">Decisions about these devices</h2>
        <p :if={@decisions == []} class="text-sm text-sr-muted">
          No decision rows name exactly this set.
        </p>
        <ul id="dedup-task-decisions" class="space-y-2">
          <li
            :for={decision <- @decisions}
            id={"dedup-decision-#{decision.id}"}
            class="rounded-sr-control border border-sr-line p-2 text-sm"
          >
            <code>{decision.decision_kind}</code>
            <span class="text-sr-muted">{decision.reason}</span>
            <span :if={decision.subject}>about <code>{decision.subject}</code></span>
            <span class="text-xs text-sr-muted">
              seen {decision.occurrence_count}x, last
              <.user_time
                id={"dedup-decision-#{decision.id}-last"}
                value={decision.last_decided_at}
                timezone={@timezone}
                style={:compact}
              />
            </span>
            <pre :if={decision.evidence != %{}} class="mt-1 overflow-x-auto text-xs">{pretty(decision.evidence)}</pre>
          </li>
        </ul>
      </section>
    </.ui_panel>
    """
  end

  attr :status, :atom, required: true

  defp status_badge(assigns) do
    ~H"""
    <.ui_badge size="sm" variant={status_variant(@status)}>{@status}</.ui_badge>
    """
  end

  defp status_variant(:open), do: "warning"
  defp status_variant(:merged), do: "success"
  defp status_variant(:distinct), do: "info"
  defp status_variant(_status), do: "ghost"

  defp device_field(devices, uid, field) do
    case Map.get(devices, uid) do
      nil -> "—"
      device -> Map.get(device, field) || "—"
    end
  end

  defp device_state(devices, uid) do
    case Map.get(devices, uid) do
      nil -> "not found"
      %{deleted_at: nil} -> "live"
      %{deleted_reason: reason} when is_binary(reason) -> "deleted (#{reason})"
      _device -> "deleted"
    end
  end

  defp pretty(evidence), do: Jason.encode!(evidence, pretty: true)

  defp timezone(%{user: %{timezone: timezone}}) when is_binary(timezone), do: timezone
  defp timezone(_scope), do: "Etc/UTC"
end
