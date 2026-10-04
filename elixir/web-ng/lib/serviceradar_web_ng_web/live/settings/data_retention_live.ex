defmodule ServiceRadarWebNGWeb.Settings.DataRetentionLive do
  @moduledoc """
  Settings -> System -> Data retention: how many days the StarRocks warehouse
  keeps of each telemetry dataset.

  Viewing needs `settings.data_retention.view` (or `.manage`); changing a value
  needs `settings.data_retention.manage`. A save is stored in CNPG and applied to
  the warehouse by core without a restart; the page shows the last applied value,
  status and time per dataset, and refreshes while any dataset is pending.
  """

  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Analytics.StarRocks.Env, as: StarRocksEnv
  alias ServiceRadar.Analytics.StarRocks.RetentionSettings
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.Shell

  @path "/settings/data-retention"
  @refresh_ms 5_000

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

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    can_manage? = RBAC.can?(scope, "settings.data_retention.manage")

    if can_manage? or RBAC.can?(scope, "settings.data_retention.view") do
      socket =
        socket
        |> assign(:page_title, "Data retention")
        |> assign(:current_path, @path)
        |> assign(:can_manage?, can_manage?)
        |> assign(:warehouse_enabled?, StarRocksEnv.config()[:enabled] == true)
        |> assign(:entries, [])
        |> assign(:drafts, %{})
        |> assign(:errors, %{})
        |> assign(:load_error, nil)

      {:ok, if(connected?(socket), do: load(socket), else: socket)}
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
     |> assign(:errors, put_error(socket.assigns.errors, dataset, draft_error(socket, dataset, days)))}
  end

  def handle_event("save", %{"dataset" => dataset, "days" => days}, socket) do
    if socket.assigns.can_manage? do
      save(socket, dataset, days)
    else
      {:noreply, put_flash(socket, :error, "Not authorized to change data retention")}
    end
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  defp save(socket, dataset, days) do
    case parse_days(days) do
      {:ok, value} ->
        case RetentionSettings.save(dataset, value, scope: socket.assigns.current_scope) do
          {:ok, _setting} ->
            {:noreply,
             socket
             |> assign(:drafts, Map.delete(socket.assigns.drafts, dataset))
             |> assign(:errors, Map.delete(socket.assigns.errors, dataset))
             |> put_flash(:info, "Saved #{label(dataset)} retention; applying to the warehouse")
             |> load()}

          {:error, reason} ->
            {:noreply, assign(socket, :errors, Map.put(socket.assigns.errors, dataset, format_error(reason)))}
        end

      {:error, message} ->
        {:noreply, assign(socket, :errors, Map.put(socket.assigns.errors, dataset, message))}
    end
  end

  defp load(socket) do
    case RetentionSettings.list(scope: socket.assigns.current_scope) do
      {:ok, entries} ->
        if Enum.any?(entries, &(&1.stored? and &1.last_applied_status == "pending")) do
          Process.send_after(self(), :refresh, @refresh_ms)
        end

        socket
        |> assign(:entries, entries)
        |> assign(:load_error, nil)

      {:error, reason} ->
        assign(socket, :load_error, format_error(reason))
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
            <h1 class="text-xl font-semibold">Data retention</h1>
            <p class="text-sm text-sr-muted">
              Days of each telemetry dataset the warehouse keeps. Tables are partitioned by day,
              so a shorter value drops the oldest days at once and they cannot be recovered.
              Changes apply without a restart.
            </p>
          </div>

          <.ui_alert :if={not @warehouse_enabled?} variant="ghost" id="retention-warehouse-disabled">
            The StarRocks warehouse is not enabled. These settings are stored now and apply when it is.
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
                          class={ui_field_class(size: "sm", class: "w-28")}
                          aria-label={"#{label(entry.dataset)} retention in days"}
                        />
                        <.retention_hints entry={entry} drafts={@drafts} errors={@errors} />
                      </div>
                      <.ui_button type="submit" size="sm" variant="primary">Save</.ui_button>
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
                    <.applied_status entry={entry} timezone={user_timezone(@current_scope)} />
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

  attr :entry, :map, required: true
  attr :drafts, :map, required: true
  attr :errors, :map, required: true

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

  attr :entry, :map, required: true
  attr :timezone, :string, required: true

  defp applied_status(assigns) do
    ~H"""
    <div :if={!@entry.stored?} class="text-sr-muted">Not stored yet; core seeds it at start</div>
    <div :if={@entry.stored?} class="space-y-1">
      <.ui_badge variant={status_variant(@entry.last_applied_status)}>
        {@entry.last_applied_status}
      </.ui_badge>
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
      {nil, _} -> nil
      {_entry, {:error, message}} -> message
      {entry, {:ok, value}} when value < entry.min_days -> "Minimum is #{entry.min_days} #{days_word(entry.min_days)}"
      _ -> nil
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
