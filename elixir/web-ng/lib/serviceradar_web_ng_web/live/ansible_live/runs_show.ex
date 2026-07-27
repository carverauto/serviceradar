defmodule ServiceRadarWebNGWeb.AnsibleLive.RunsShow do
  @moduledoc """
  Detail view of one `PlaybookRun`.

  Subscribes to `ServiceRadar.Automation.Ansible.PubSub`'s per-run
  topic so EventIngestor's `broadcast_run_updated/1` calls trigger a
  live refresh -- the operator sees state transitions and per-target
  outcomes as RunPulseWorker drains AWX events, without polling.

  Permission: `ansible.runs.view`. Per-target task drill-down is
  deferred to a follow-up; v1 shows run header + targets table +
  plays/tasks tree.
  """

  use ServiceRadarWebNGWeb, :live_view

  use Permit.Phoenix.LiveView,
    authorization_module: ServiceRadarWebNGWeb.Authorization,
    resource_module: ServiceRadar.Automation.Ansible.PlaybookRun

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.PlaybookPlay
  alias ServiceRadar.Automation.Ansible.PlaybookRun
  alias ServiceRadar.Automation.Ansible.PlaybookRunTarget
  alias ServiceRadar.Automation.Ansible.PlaybookTask
  alias ServiceRadar.Automation.Ansible.PubSub, as: AnsiblePubSub
  alias ServiceRadarWebNG.RBAC

  require Logger

  @impl true
  def event_mapping do
    Map.merge(Permit.Phoenix.LiveView.default_event_mapping(), %{
      "refresh" => :read,
      "toggle_play" => :read
    })
  end

  @impl true
  def skip_preload, do: [:show, :read]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "ansible.runs.view") do
      case load_run_bundle(id) do
        {:ok, bundle} ->
          if connected?(socket), do: AnsiblePubSub.subscribe_run(id)

          {:ok,
           socket
           |> assign(:page_title, "Run #{shorten(id)}")
           |> assign(:bundle, bundle)
           |> assign(:expanded_plays, MapSet.new())}

        {:error, :not_found} ->
          {:ok,
           socket
           |> put_flash(:error, "Run not found.")
           |> push_navigate(to: ~p"/ansible/runs")}
      end
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to view Ansible runs.")
       |> push_navigate(to: ~p"/dashboard")}
    end
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    case load_run_bundle(socket.assigns.bundle.run.id) do
      {:ok, bundle} -> {:noreply, assign(socket, :bundle, bundle)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("toggle_play", %{"id" => play_id}, socket) do
    expanded =
      if MapSet.member?(socket.assigns.expanded_plays, play_id) do
        MapSet.delete(socket.assigns.expanded_plays, play_id)
      else
        MapSet.put(socket.assigns.expanded_plays, play_id)
      end

    {:noreply, assign(socket, :expanded_plays, expanded)}
  end

  @impl true
  def handle_info({:ansible_run_updated, %{id: id}}, socket) do
    if id == socket.assigns.bundle.run.id do
      case load_run_bundle(id) do
        {:ok, bundle} -> {:noreply, assign(socket, :bundle, bundle)}
        _ -> {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-full max-w-7xl p-6 space-y-6">
      <header class="flex items-center justify-between gap-4">
        <div class="space-y-1">
          <p class="text-xs text-base-content/60">
            <.link navigate={~p"/ansible/runs"} class="link link-hover">
              ← Legacy Ansible runs
            </.link>
          </p>
          <div class="flex flex-wrap items-center gap-2">
            <h1 class="text-2xl font-semibold">Run {shorten(@bundle.run.id)}</h1>
            <.ui_badge size="sm" variant="outline">Legacy PlaybookRun</.ui_badge>
          </div>
          <p class="text-sm text-base-content/70 flex gap-3 flex-wrap">
            <.ui_badge size="sm" variant={state_badge_variant(@bundle.run.state)}>
              {@bundle.run.state}
            </.ui_badge>
            <span :if={@bundle.run.awx_job_id}>
              AWX job <code class="text-xs">{@bundle.run.awx_job_id}</code>
            </span>
            <.ui_badge :if={@bundle.run.schedule_id} size="sm" variant="ghost">scheduled</.ui_badge>
            <.ui_badge :if={!@bundle.run.schedule_id} size="sm" variant="ghost">ad-hoc</.ui_badge>
          </p>
        </div>
        <div class="flex items-center gap-2">
          <.ui_button navigate={~p"/ansible/operations"} size="sm" variant="ghost">
            Secure operations
          </.ui_button>
          <.ui_button type="button" phx-click="refresh" size="sm" variant="ghost">Refresh</.ui_button>
        </div>
      </header>

      <div class="grid grid-cols-1 md:grid-cols-3 gap-3 text-sm">
        <.stat label="Playbook" value={shorten(@bundle.run.playbook_id)} mono />
        <.stat label="Controller" value={shorten(@bundle.run.controller_id)} mono />
        <.stat label="Last event id" value={to_string(@bundle.run.last_event_id || 0)} mono />
        <.stat label="Started" value={fmt_ts(@bundle.run.started_at)} />
        <.stat label="Ended" value={fmt_ts(@bundle.run.ended_at)} />
        <.stat label="Duration" value={duration(@bundle.run)} />
      </div>

      <div :if={@bundle.run.summary} class={ui_alert_class("info")}>
        <span class="font-mono text-sm">{@bundle.run.summary}</span>
      </div>

      <section class="space-y-2">
        <h2 class="text-lg font-medium">Targets ({length(@bundle.targets)})</h2>

        <div
          :if={@bundle.targets == []}
          class="rounded-lg border border-dashed border-base-300 p-6 text-sm text-base-content/70"
        >
          No targets recorded for this run yet.
        </div>

        <div
          :if={@bundle.targets != []}
          class="overflow-x-auto rounded-lg border border-base-300 bg-base-100"
        >
          <table class={ui_table_class(size: "sm", zebra: true)}>
            <thead>
              <tr>
                <th>AWX host</th>
                <th>Device</th>
                <th>Status</th>
                <th>OK</th>
                <th>Changed</th>
                <th>Failed</th>
                <th>Skipped</th>
                <th>Unreachable</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={target <- @bundle.targets}>
                <td><code class="text-xs">{target.awx_host_name}</code></td>
                <td><code class="text-xs">{shorten(target.device_uid)}</code></td>
                <td>
                  <.ui_badge size="sm" variant={target_badge_variant(target.status)}>
                    {target.status}
                  </.ui_badge>
                </td>
                <td>{target.ok_count}</td>
                <td>{target.changed_count}</td>
                <td>{target.failed_count}</td>
                <td>{target.skipped_count}</td>
                <td>{target.unreachable_count}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section class="space-y-2">
        <h2 class="text-lg font-medium">Plays ({length(@bundle.plays)})</h2>

        <div
          :if={@bundle.plays == []}
          class="rounded-lg border border-dashed border-base-300 p-6 text-sm text-base-content/70"
        >
          No plays recorded yet. Events stream in as RunPulseWorker drains AWX events.
        </div>

        <div :for={play <- @bundle.plays} class="rounded-lg border border-base-300 bg-base-100">
          <button
            type="button"
            phx-click="toggle_play"
            phx-value-id={play.id}
            class="w-full flex items-center justify-between gap-3 p-3 text-left"
          >
            <div class="flex items-center gap-3">
              <span class="text-sm font-medium">{play.name || "(unnamed play)"}</span>
              <.ui_badge size="sm" variant={play_badge_variant(play.status)}>{play.status}</.ui_badge>
            </div>
            <div class="text-xs text-base-content/60">
              {Map.get(@bundle.tasks_by_play, play.id, []) |> length()} tasks
            </div>
          </button>

          <div
            :if={MapSet.member?(@expanded_plays, play.id)}
            class="border-t border-base-300 p-3 space-y-1"
          >
            <div
              :for={task <- Map.get(@bundle.tasks_by_play, play.id, [])}
              class="flex items-center justify-between text-xs"
            >
              <div class="flex items-center gap-2">
                <code>{task.awx_task_uuid |> String.slice(0, 8)}</code>
                <span class="font-medium">{task.name || "(unnamed task)"}</span>
                <code :if={task.action} class="text-base-content/60">{task.action}</code>
                <.ui_badge :if={task.is_handler} size="xs" variant="ghost">handler</.ui_badge>
              </div>
              <span class="text-base-content/60">{fmt_ts(task.started_at)}</span>
            </div>
            <div
              :if={Map.get(@bundle.tasks_by_play, play.id, []) == []}
              class="text-xs text-base-content/60"
            >
              No tasks recorded in this play yet.
            </div>
          </div>
        </div>
      </section>
    </div>
    """
  end

  ## Components ----------------------------------------------------------------

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :mono, :boolean, default: false

  defp stat(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-300 bg-base-100 p-3">
      <div class="text-xs uppercase tracking-wide text-base-content/60">{@label}</div>
      <div class={["mt-1 text-sm", @mono && "font-mono"]}>{@value}</div>
    </div>
    """
  end

  ## Loading -------------------------------------------------------------------

  defp load_run_bundle(id) do
    actor = SystemActor.system(:ansible_runs_show)

    case PlaybookRun.get_by_id(id, actor: actor) do
      {:ok, run} ->
        targets =
          case PlaybookRunTarget.list_for_run(run.id, actor: actor) do
            {:ok, rows} -> rows
            _ -> []
          end

        plays =
          case PlaybookPlay.list_for_run(run.id, actor: actor) do
            {:ok, rows} -> rows
            _ -> []
          end

        tasks_by_play =
          Map.new(plays, fn play ->
            case PlaybookTask.list_for_play(play.id, actor: actor) do
              {:ok, rows} -> {play.id, rows}
              _ -> {play.id, []}
            end
          end)

        {:ok, %{run: run, targets: targets, plays: plays, tasks_by_play: tasks_by_play}}

      _ ->
        {:error, :not_found}
    end
  end

  ## Helpers -------------------------------------------------------------------

  defp shorten(nil), do: "—"
  defp shorten(s) when is_binary(s) and byte_size(s) > 8, do: String.slice(s, 0, 8) <> "…"
  defp shorten(s), do: to_string(s)

  defp fmt_ts(nil), do: "—"
  defp fmt_ts(%DateTime{} = ts), do: Calendar.strftime(ts, "%Y-%m-%d %H:%M:%S UTC")
  defp fmt_ts(_), do: "—"

  defp duration(%{started_at: nil}), do: "—"

  defp duration(%{started_at: %DateTime{} = s, ended_at: nil}) do
    seconds = DateTime.diff(DateTime.utc_now(), s, :second)
    format_seconds(seconds) <> " (running)"
  end

  defp duration(%{started_at: %DateTime{} = s, ended_at: %DateTime{} = e}) do
    e |> DateTime.diff(s, :second) |> format_seconds()
  end

  defp duration(_), do: "—"

  defp format_seconds(n) when n < 60, do: "#{n}s"
  defp format_seconds(n) when n < 3600, do: "#{div(n, 60)}m #{rem(n, 60)}s"
  defp format_seconds(n), do: "#{div(n, 3600)}h #{div(rem(n, 3600), 60)}m"

  defp state_badge_variant(:succeeded), do: "success"
  defp state_badge_variant(:partial), do: "warning"
  defp state_badge_variant(:failed), do: "error"
  defp state_badge_variant(:unreachable), do: "error"
  defp state_badge_variant(:canceled), do: "ghost"
  defp state_badge_variant(:running), do: "info"
  defp state_badge_variant(:launching), do: "info"
  defp state_badge_variant(:pending), do: "ghost"
  defp state_badge_variant(_), do: "ghost"

  defp target_badge_variant(:ok), do: "success"
  defp target_badge_variant(:failed), do: "error"
  defp target_badge_variant(:unreachable), do: "error"
  defp target_badge_variant(:skipped), do: "ghost"
  defp target_badge_variant(:pending), do: "ghost"
  defp target_badge_variant(_), do: "ghost"

  defp play_badge_variant(:ok), do: "success"
  defp play_badge_variant(:failed), do: "error"
  defp play_badge_variant(_), do: "info"
end
