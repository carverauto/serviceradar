defmodule ServiceRadarWebNGWeb.Settings.DataRetentionLive do
  @moduledoc """
  Settings -> System -> Data retention: how many days the StarRocks warehouse
  keeps of each telemetry dataset.

  Viewing needs `settings.data_retention.view` (or `.manage`); changing a value
  needs `settings.data_retention.manage`. A save is stored in CNPG and applied to
  the warehouse by core without a restart; the page shows the last applied value,
  status and time per dataset, and refreshes while any dataset is pending and
  an applier is actively running.
  """

  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Analytics.StarRocks.Env, as: StarRocksEnv
  alias ServiceRadar.Analytics.StarRocks.RetentionSettings
  alias ServiceRadar.Observability.WarehouseRetentionNotifier
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.Shell

  @path "/settings/data-retention"
  @refresh_ms 5_000
  @pending_stale_threshold_seconds 300

  @labels %{
    flows: {"Network flows", "NetFlow, sFlow and IPFIX records"},
    metrics: {"Metrics", "Interface, SNMP and sysmon time series"},
    logs: {"Logs", "Collected and OTel logs"},
    events: {"Events", "OCSF events"},
    mtr: {"MTR", "MTR traces and their hops, expired together"},
    otel: {"OTel metrics", "OTel metric samples and points"},
    traces: {"OTel traces", "Spans and trace summaries"},
    bmp: {"BMP routing", "BMP routing events"},
    attribution: {"Process attribution", "Observations the flow correlator joins flows to"}
  }

  @doc "Age of a pending retention change in seconds."
  @spec pending_age_seconds(map(), DateTime.t()) :: non_neg_integer() | nil
  def pending_age_seconds(%{last_applied_status: "pending"} = entry, %DateTime{} = now) do
    case entry.updated_at || entry.inserted_at do
      %DateTime{} = dt -> max(0, DateTime.diff(now, dt, :second))
      _ -> 0
    end
  end

  def pending_age_seconds(_entry, _now), do: nil

  @doc "Whether a pending retention change has exceeded the stale threshold (5 minutes)."
  @spec stale_pending?(map(), DateTime.t()) :: boolean()
  def stale_pending?(entry, now \\ DateTime.utc_now())

  def stale_pending?(%{last_applied_status: "pending", stored?: true, tables: [_ | _]} = entry, %DateTime{} = now) do
    case pending_age_seconds(entry, now) do
      nil -> false
      age -> age >= @pending_stale_threshold_seconds
    end
  end

  def stale_pending?(_entry, _now), do: false

  @doc "Formats a duration in seconds into a human-readable string."
  @spec format_age(integer() | nil) :: String.t() | nil
  def format_age(seconds) when is_integer(seconds) and seconds >= 0 do
    cond do
      seconds < 60 ->
        "< 1m"

      seconds < 3600 ->
        "#{div(seconds, 60)}m"

      true ->
        hours = div(seconds, 3600)
        mins = div(rem(seconds, 3600), 60)
        if mins > 0, do: "#{hours}h #{mins}m", else: "#{hours}h"
    end
  end

  def format_age(_), do: nil

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns[:current_scope]
    can_manage? = scope != nil and RBAC.can?(scope, "settings.data_retention.manage")
    can_view? = scope != nil and (can_manage? or RBAC.can?(scope, "settings.data_retention.view"))

    if can_view? do
      warehouse_enabled? =
        case socket.assigns[:warehouse_enabled?] do
          nil -> StarRocksEnv.config()[:enabled] == true
          val -> val
        end

      initial_health =
        case socket.assigns[:applier_health_override] do
          %{running?: _} = health -> health
          _ -> %{running?: false, node: nil, last_reconciled_at: nil, last_outcome: nil}
        end

      socket =
        socket
        |> assign(:page_title, "Data retention")
        |> assign(:current_path, @path)
        |> assign(:can_manage?, can_manage?)
        |> assign(:warehouse_enabled?, warehouse_enabled?)
        |> assign(:entries, [])
        |> assign(:drafts, %{})
        |> assign(:errors, %{})
        |> assign(:load_error, nil)
        |> assign(:has_pending?, false)
        |> assign(:has_stale_pending?, false)
        |> assign(:now, DateTime.utc_now())
        |> assign(:applier_health, initial_health)

      if connected?(socket) do
        try do
          Phoenix.PubSub.subscribe(ServiceRadar.PubSub, WarehouseRetentionNotifier.topic())
        rescue
          _ -> :ok
        end

        {:ok, load(socket)}
      else
        {:ok, socket}
      end
    else
      {:ok,
       socket
       |> put_flash(:error, "Not authorized to view data retention settings")
       |> redirect(to: ~p"/settings/profile")}
    end
  end

  @impl true
  def handle_event("validate", %{"dataset" => dataset, "days" => days}, socket) do
    {:noreply,
     socket
     |> assign(:drafts, Map.put(socket.assigns.drafts, dataset, days))
     |> assign(
       :errors,
       put_error(socket.assigns.errors, dataset, draft_error(socket, dataset, days))
     )}
  end

  def handle_event("save", %{"dataset" => dataset, "days" => days}, socket) do
    cond do
      not socket.assigns.can_manage? ->
        {:noreply, put_flash(socket, :error, "Not authorized to change data retention")}

      not socket.assigns.warehouse_enabled? ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Data retention is unavailable because the StarRocks warehouse is disabled"
         )}

      true ->
        save(socket, dataset, days)
    end
  end

  @impl true
  def handle_info({:retention_applier_heartbeat, health}, socket) do
    socket =
      socket
      |> assign(:applier_health, Map.put(health, :running?, true))
      |> assign(:now, DateTime.utc_now())

    if socket.assigns[:has_pending?] do
      {:noreply, load(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:warehouse_retention_changed, _dataset}, socket) do
    {:noreply, load(socket)}
  end

  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  defp save(socket, dataset, days) do
    case parse_days(days) do
      {:ok, value} ->
        case save_setting(socket, dataset, value) do
          {:ok, _setting} ->
            {:noreply,
             socket
             |> assign(:drafts, Map.delete(socket.assigns.drafts, dataset))
             |> assign(:errors, Map.delete(socket.assigns.errors, dataset))
             |> put_flash(:info, "Saved #{label(dataset)} retention; applying to the warehouse")
             |> load()}

          {:error, reason} ->
            {:noreply,
             assign(
               socket,
               :errors,
               Map.put(socket.assigns.errors, dataset, format_error(reason))
             )}
        end

      {:error, message} ->
        {:noreply, assign(socket, :errors, Map.put(socket.assigns.errors, dataset, message))}
    end
  end

  defp save_setting(socket, dataset, value) do
    case socket.assigns[:save_fn] do
      fun when is_function(fun, 2) ->
        fun.(dataset, value)

      _ ->
        RetentionSettings.save(dataset, value, scope: socket.assigns.current_scope)
    end
  end

  defp load(socket) do
    applier_health = fetch_applier_health(socket)
    now = DateTime.utc_now()

    case list_entries(socket) do
      {:ok, entries} ->
        has_pending? =
          Enum.any?(
            entries,
            &(&1.stored? and &1.last_applied_status == "pending" and &1.tables != [])
          )

        has_stale_pending? = Enum.any?(entries, &stale_pending?(&1, now))

        if socket.assigns.warehouse_enabled? and applier_health.running? and has_pending? do
          Process.send_after(self(), :refresh, @refresh_ms)
        end

        socket
        |> assign(:entries, entries)
        |> assign(:applier_health, applier_health)
        |> assign(:has_pending?, has_pending?)
        |> assign(:has_stale_pending?, has_stale_pending?)
        |> assign(:now, now)
        |> assign(:load_error, nil)

      {:error, reason} ->
        socket
        |> assign(:applier_health, applier_health)
        |> assign(:now, now)
        |> assign(:load_error, format_error(reason))
    end
  end

  defp list_entries(socket) do
    case socket.assigns[:entries_override] do
      entries when is_list(entries) ->
        {:ok, entries}

      _ ->
        RetentionSettings.list(scope: socket.assigns.current_scope)
    end
  end

  defp fetch_applier_health(socket) do
    case socket.assigns[:applier_health_override] do
      %{running?: _} = health ->
        health

      _ ->
        case Application.get_env(:serviceradar_web_ng, :retention_applier_health_fn) do
          fun when is_function(fun, 0) -> fun.()
          _ -> RetentionSettings.applier_health()
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <Shell.settings_chrome
        current_path={@current_path}
        current_scope={@current_scope}
        active_view={@settings_active_view}
        active_category={@settings_active_category}
        breadcrumbs={@settings_breadcrumbs}
        nav_tree={@settings_nav_tree}
        palette={@settings_palette}
        stats={@settings_stats}
      >
        <section class="space-y-4">
          <div>
            <div class="flex flex-wrap items-center justify-between gap-2">
              <h1 class="text-xl font-semibold">Data retention</h1>
              <div
                :if={@warehouse_enabled?}
                class="flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-sr-muted"
                id="retention-applier-status"
              >
                <span class="flex items-center gap-1.5 font-medium">
                  <span class={[
                    "inline-block h-2 w-2 rounded-full",
                    if(@applier_health.running?, do: "bg-emerald-500", else: "bg-amber-500")
                  ]}></span>
                  <span id="retention-applier-running-state">
                    {if @applier_health.running?, do: "Applier running", else: "No applier running"}
                  </span>
                </span>
                <span
                  :if={@applier_health.running? and @applier_health.node}
                  id="retention-applier-node"
                >
                  Node: {@applier_health.node}
                </span>
                <span
                  :if={@applier_health.last_reconciled_at}
                  id="retention-applier-last-reconciled"
                >
                  Last reconciled:
                  <.user_time
                    id="retention-applier-reconciled-at"
                    value={@applier_health.last_reconciled_at}
                    timezone={user_timezone(@current_scope)}
                    style={:compact}
                  />
                  <span :if={@applier_health.last_outcome} class="capitalize">
                    ({@applier_health.last_outcome})
                  </span>
                </span>
              </div>
            </div>
            <p class="text-sm text-sr-muted mt-1">
              Days of each telemetry dataset the warehouse keeps. Tables are partitioned by day,
              so a shorter value drops the oldest days at once and they cannot be recovered.
              Changes apply without a restart.
            </p>
          </div>

          <.ui_alert
            :if={not @warehouse_enabled?}
            variant="warning"
            id="retention-warehouse-disabled"
          >
            <div class="font-medium">
              Data retention is unavailable because StarRocks analytics is disabled.
            </div>
            <div class="text-xs mt-1">
              To enable retention, set
              <code class="font-mono bg-sr-surface/60 px-1 py-0.5 rounded">analytics.starrocks.enabled: true</code>
              in your ServiceRadar configuration and ensure the StarRocks warehouse is running. Retention settings cannot be saved while the warehouse is disabled.
            </div>
          </.ui_alert>

          <.ui_alert
            :if={@warehouse_enabled? and not @applier_health.running?}
            variant="warning"
            id="retention-no-applier-alert"
          >
            <div class="font-medium">No retention applier is running</div>
            <div class="text-xs mt-1">
              No ServiceRadar core instance is currently running the retention applier. Retention changes will not be applied to the StarRocks warehouse until core is running.
            </div>
          </.ui_alert>

          <.ui_alert
            :if={@warehouse_enabled? and @has_stale_pending?}
            variant="warning"
            id="retention-stale-pending-alert"
          >
            <div class="font-medium">
              One or more retention settings have been pending for more than 5 minutes.
            </div>
            <div class="text-xs mt-1">
              Likely causes: the StarRocks warehouse is unreachable, a schema change is in progress, or no core instance is running the retention applier.
            </div>
          </.ui_alert>

          <.ui_alert :if={@load_error} variant="error" id="retention-load-error">
            Could not load retention settings: {@load_error}
          </.ui_alert>

          <div class="overflow-x-auto rounded-xl border border-sr-line bg-sr-surface">
            <table class={ui_table_class(class: "w-full")} id="retention-settings">
              <thead>
                <tr>
                  <th>Dataset</th>
                  <th>Retention</th>
                  <th>Seed default</th>
                  <th>Last applied</th>
                  <th>Changed</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={entry <- @entries} id={"retention-#{entry.dataset}"}>
                  <td class="align-top">
                    <div class="font-medium">{label(entry.dataset)}</div>
                    <div class="text-xs text-sr-muted">{description(entry.dataset)}</div>
                    <div :if={entry.tables != []} class="font-mono text-xs text-sr-muted">
                      {Enum.join(entry.tables, ", ")}
                    </div>
                  </td>
                  <td class="align-top">
                    <form
                      :if={@can_manage?}
                      id={"retention-form-#{entry.dataset}"}
                      phx-change="validate"
                      phx-submit="save"
                      class="flex items-start gap-2"
                    >
                      <input type="hidden" name="dataset" value={entry.dataset} />
                      <div>
                        <input
                          type="number"
                          name="days"
                          min={entry.min_days}
                          value={Map.get(@drafts, Atom.to_string(entry.dataset), entry.days)}
                          disabled={not @warehouse_enabled?}
                          class={ui_field_class(size: "sm", class: "w-28")}
                          aria-label={"#{label(entry.dataset)} retention in days"}
                        />
                        <.retention_hints entry={entry} drafts={@drafts} errors={@errors} />
                      </div>
                      <.ui_button
                        type="submit"
                        size="sm"
                        variant="primary"
                        disabled={not @warehouse_enabled?}
                      >
                        Save
                      </.ui_button>
                    </form>
                    <div :if={not @can_manage?}>
                      {entry.days} days <.retention_hints entry={entry} drafts={%{}} errors={%{}} />
                    </div>
                  </td>
                  <td class="align-top text-sm">
                    <span :if={entry.seed_days}>{entry.seed_days} days</span>
                    <span :if={!entry.seed_days} class="text-sr-muted">
                      {entry.default_days} days (product default)
                    </span>
                  </td>
                  <td class="align-top text-sm">
                    <.applied_status
                      entry={entry}
                      timezone={user_timezone(@current_scope)}
                      warehouse_enabled={@warehouse_enabled?}
                      now={@now}
                    />
                  </td>
                  <td class="align-top text-xs text-sr-muted">
                    <div :if={entry.updated_by}>{entry.updated_by}</div>
                    <div :if={entry.updated_at}>
                      <.user_time
                        id={"retention-#{entry.dataset}-updated-at"}
                        value={entry.updated_at}
                        timezone={user_timezone(@current_scope)}
                        style={:compact}
                      />
                    </div>
                    <div :if={!entry.updated_by and !entry.updated_at}>Not changed since seeding</div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end

  attr(:entry, :map, required: true)
  attr(:drafts, :map, required: true)
  attr(:errors, :map, required: true)

  defp retention_hints(assigns) do
    key = Atom.to_string(assigns.entry.dataset)

    assigns =
      assigns
      |> assign(:error, Map.get(assigns.errors, key))
      |> assign(:warning?, draft_warning?(assigns.entry, Map.get(assigns.drafts, key)))

    ~H"""
    <p :if={@error} class="mt-1 text-xs text-red-600 dark:text-red-300">{@error}</p>
    <p :if={!@error and @warning?} class="mt-1 text-xs text-amber-700 dark:text-amber-300">
      More than twice the {@entry.default_days}-day default; expect proportionally more warehouse storage.
    </p>
    <p :if={@entry.min_partitions > @entry.min_days} class="mt-1 text-xs text-sr-muted">
      Minimum {@entry.min_days} day; at least {@entry.min_partitions} daily partitions are kept.
    </p>
    """
  end

  attr(:entry, :map, required: true)
  attr(:timezone, :string, required: true)
  attr(:warehouse_enabled, :boolean, default: true)
  attr(:now, :any, default: nil)

  defp applied_status(assigns) do
    assigns = assign_new(assigns, :now, fn -> DateTime.utc_now() end)

    ~H"""
    <div
      :if={not @warehouse_enabled}
      class="space-y-1"
      id={"retention-#{@entry.dataset}-applied-status"}
    >
      <.ui_badge variant="ghost">
        unavailable
      </.ui_badge>
      <div class="text-xs text-sr-muted">
        StarRocks warehouse is disabled
      </div>
    </div>
    <div
      :if={@warehouse_enabled and !@entry.stored?}
      class="text-sr-muted"
      id={"retention-#{@entry.dataset}-applied-status"}
    >
      Not stored yet; core seeds it at start
    </div>
    <div
      :if={@warehouse_enabled and @entry.stored?}
      class="space-y-1"
      id={"retention-#{@entry.dataset}-applied-status"}
    >
      <div class="flex items-center gap-1.5 flex-wrap">
        <.ui_badge variant={status_variant(@entry.last_applied_status)}>
          {@entry.last_applied_status}
        </.ui_badge>
        <span
          :if={
            @entry.last_applied_status == "pending" and
              format_age(pending_age_seconds(@entry, @now))
          }
          class="text-xs text-sr-muted"
          id={"retention-#{@entry.dataset}-pending-age"}
        >
          (for {format_age(pending_age_seconds(@entry, @now))})
        </span>
      </div>
      <div
        :if={@entry.last_applied_status == "pending" and stale_pending?(@entry, @now)}
        class="text-xs text-amber-700 dark:text-amber-300 font-medium"
        id={"retention-#{@entry.dataset}-stale-warning"}
      >
        Pending over 5m: warehouse may be unreachable, schema change running, or no applier running.
      </div>
      <div :if={@entry.last_applied_days}>
        {@entry.last_applied_days} days
        <span :if={@entry.last_applied_at} class="text-xs text-sr-muted">
          at
          <.user_time
            id={"retention-#{@entry.dataset}-applied-at"}
            value={@entry.last_applied_at}
            timezone={@timezone}
            style={:compact}
          />
        </span>
      </div>
      <div :if={@entry.last_applied_error} class="text-xs text-sr-muted">
        {@entry.last_applied_error}
      </div>
    </div>
    """
  end

  defp draft_error(socket, dataset, days) do
    entry = Enum.find(socket.assigns.entries, &(Atom.to_string(&1.dataset) == dataset))

    case {entry, parse_days(days)} do
      {nil, _} ->
        nil

      {_entry, {:error, message}} ->
        message

      {entry, {:ok, value}} when value < entry.min_days ->
        "Minimum is #{entry.min_days} #{days_word(entry.min_days)}"

      _ ->
        nil
    end
  end

  defp draft_warning?(_entry, nil), do: false

  defp draft_warning?(entry, draft) do
    case parse_days(draft) do
      {:ok, value} -> value > entry.default_days * 2
      {:error, _} -> false
    end
  end

  defp status_variant("applied"), do: "success"
  defp status_variant("failed"), do: "error"
  defp status_variant("unavailable"), do: "ghost"
  defp status_variant(_status), do: "warning"

  defp put_error(errors, dataset, nil), do: Map.delete(errors, dataset)
  defp put_error(errors, dataset, message), do: Map.put(errors, dataset, message)

  defp parse_days(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> {:ok, int}
      _ -> {:error, "Enter a whole number of days"}
    end
  end

  defp parse_days(_value), do: {:error, "Enter a whole number of days"}

  defp days_word(1), do: "day"
  defp days_word(_n), do: "days"

  defp label(dataset) when is_binary(dataset) do
    case Enum.find(Map.keys(@labels), &(Atom.to_string(&1) == dataset)) do
      nil -> dataset
      key -> label(key)
    end
  end

  defp label(dataset), do: @labels |> Map.get(dataset, {to_string(dataset), ""}) |> elem(0)
  defp description(dataset), do: @labels |> Map.get(dataset, {"", ""}) |> elem(1)

  defp user_timezone(%{user: %{timezone: timezone}}) when is_binary(timezone) and timezone != "", do: timezone

  defp user_timezone(_current_scope), do: "Etc/UTC"

  defp format_error(%{__exception__: true} = error), do: Exception.message(error)
  defp format_error(message) when is_binary(message), do: message
  defp format_error(reason), do: inspect(reason)
end
