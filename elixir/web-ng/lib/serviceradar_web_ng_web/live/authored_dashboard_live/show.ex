defmodule ServiceRadarWebNGWeb.AuthoredDashboardLive.Show do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Dashboards.AuthoredDashboard
  alias ServiceRadarWebNG.Dashboards

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Dashboard")
     |> assign(:current_path, nil)
     |> assign(:dashboard, nil)
     |> assign(:panel_results, %{})
     |> assign(:loading?, connected?(socket))}
  end

  @impl true
  def handle_params(%{"dashboard_id" => dashboard_id}, _uri, socket) do
    scope = socket.assigns.current_scope

    socket =
      if connected?(socket) do
        start_async(socket, {:load_dashboard, dashboard_id}, fn ->
          with {:ok, %AuthoredDashboard{} = dashboard} <-
                 Dashboards.get_authored_dashboard(scope, dashboard_id, load: [:panels, :report_schedules]) do
            panels = Enum.sort_by(dashboard.panels || [], &{&1.position, &1.inserted_at})

            results =
              Map.new(panels, fn panel ->
                {panel.id, Dashboards.preview_authored_query(scope, panel.srql_query, limit: 250)}
              end)

            {:ok, dashboard, panels, results}
          end
        end)
      else
        socket
      end

    {:noreply, assign(socket, :current_path, "/dashboard/#{dashboard_id}")}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, push_navigate(socket, to: ~p"/analytics")}
  end

  @impl true
  def handle_async({:load_dashboard, _dashboard_id}, {:ok, {:ok, dashboard, panels, results}}, socket) do
    dashboard = Map.put(dashboard, :panels, panels)

    {:noreply,
     socket
     |> assign(:dashboard, dashboard)
     |> assign(:panel_results, results)
     |> assign(:page_title, dashboard.title)
     |> assign(:loading?, false)}
  end

  def handle_async({:load_dashboard, _dashboard_id}, {:ok, {:error, :not_found}}, socket) do
    {:noreply,
     socket
     |> assign(:loading?, false)
     |> put_flash(:error, "Dashboard not found")
     |> push_navigate(to: ~p"/analytics")}
  end

  def handle_async({:load_dashboard, _dashboard_id}, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:loading?, false)
     |> put_flash(:error, "Could not load dashboard: #{format_error(reason)}")}
  end

  def handle_async({:load_dashboard, _dashboard_id}, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:loading?, false)
     |> put_flash(:error, "Could not load dashboard: #{format_error(reason)}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      shell={:operations}
    >
      <div class="mx-auto flex w-full max-w-7xl flex-col gap-6 px-4 py-6 sm:px-6 lg:px-8">
        <section class="flex flex-col gap-3 border-b border-base-300 pb-5 lg:flex-row lg:items-end lg:justify-between">
          <div>
            <p class="text-sm font-medium text-primary">Dashboard</p>
            <h1 class="mt-1 text-2xl font-semibold tracking-normal">
              {if @dashboard, do: @dashboard.title, else: "Loading dashboard"}
            </h1>
            <p class="mt-2 max-w-3xl text-sm text-base-content/65">
              {if @dashboard,
                do: @dashboard.description || "SRQL-authored dashboard",
                else: "Loading saved SRQL panels."}
            </p>
          </div>
          <.link navigate={~p"/analytics"} class="btn btn-sm">
            <.icon name="hero-pencil-square" class="size-4" /> Dashboard Creator
          </.link>
        </section>

        <div
          :if={@loading?}
          class="rounded-lg border border-base-300 bg-base-100 p-6 text-sm text-base-content/60"
        >
          Loading dashboard panels...
        </div>

        <div
          :if={(!@loading? and @dashboard) && Enum.empty?(@dashboard.panels || [])}
          class="rounded-lg border border-base-300 bg-base-100 p-6 text-sm text-base-content/60"
        >
          This dashboard does not have any panels yet.
        </div>

        <section
          :if={!@loading? and @dashboard}
          class="grid grid-cols-1 gap-4 xl:grid-cols-2"
        >
          <.panel_result
            :for={panel <- @dashboard.panels || []}
            panel={panel}
            result={Map.get(@panel_results, panel.id)}
          />
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp panel_result(%{result: {:ok, preview}} = assigns) do
    assigns =
      assigns
      |> assign(:rows, preview.rows)
      |> assign(:fields, preview.fields)

    ~H"""
    <article class="rounded-lg border border-base-300 bg-base-100">
      <div class="flex flex-col gap-2 border-b border-base-300 px-4 py-3 sm:flex-row sm:items-center sm:justify-between">
        <div class="min-w-0">
          <h2 class="truncate text-sm font-semibold">{@panel.title}</h2>
          <p class="mt-1 truncate font-mono text-xs text-base-content/45">{@panel.srql_query}</p>
        </div>
        <span class="badge badge-outline">{@panel.visual_type}</span>
      </div>
      <div class="p-4">
        <.render_visual panel={@panel} rows={@rows} fields={@fields} />
      </div>
    </article>
    """
  end

  defp panel_result(%{result: {:error, reason}} = assigns) do
    assigns = assign(assigns, :message, format_error(reason))

    ~H"""
    <article class="rounded-lg border border-error/30 bg-base-100">
      <div class="border-b border-error/20 px-4 py-3">
        <h2 class="text-sm font-semibold">{@panel.title}</h2>
      </div>
      <div class="p-4 text-sm text-error">{@message}</div>
    </article>
    """
  end

  defp panel_result(assigns) do
    ~H"""
    <article class="rounded-lg border border-base-300 bg-base-100 p-4 text-sm text-base-content/60">
      {@panel.title}
    </article>
    """
  end

  defp render_visual(%{panel: %{visual_type: type}} = assigns) when type in [:stat, "stat"] do
    value = stat_value(assigns.rows, assigns.fields)
    assigns = assign(assigns, :value, value)

    ~H"""
    <div class="flex min-h-32 items-center">
      <div>
        <div class="text-4xl font-semibold tracking-normal">{@value}</div>
        <div class="mt-2 text-sm text-base-content/55">{first_numeric_field(@fields) || "value"}</div>
      </div>
    </div>
    """
  end

  defp render_visual(%{panel: %{visual_type: type}} = assigns) when type in [:bar, "bar", :category, "category"] do
    assigns = assign(assigns, :bars, bars(assigns.rows, assigns.fields))

    ~H"""
    <div class="space-y-3">
      <div :for={bar <- @bars} class="space-y-1">
        <div class="flex items-center justify-between gap-3 text-xs">
          <span class="truncate">{bar.label}</span>
          <span class="font-mono text-base-content/60">{bar.value}</span>
        </div>
        <progress class="progress progress-primary h-2" value={bar.percent} max="100"></progress>
      </div>
      <.empty_rows :if={@bars == []} />
    </div>
    """
  end

  defp render_visual(%{panel: %{visual_type: type}} = assigns) when type in [:line, "line", :area, "area"] do
    assigns = assign(assigns, :points, sparkline_points(assigns.rows, assigns.fields))

    ~H"""
    <div class="h-48 rounded-lg border border-base-200 bg-base-200/30 p-3">
      <svg
        viewBox="0 0 100 40"
        preserveAspectRatio="none"
        class="h-full w-full"
        role="img"
        aria-label="Time series"
      >
        <polyline
          :if={@points != ""}
          points={@points}
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          class="text-primary"
        />
      </svg>
      <.empty_rows :if={@points == ""} />
    </div>
    """
  end

  defp render_visual(assigns) do
    ~H"""
    <div class="overflow-x-auto rounded-lg border border-base-300">
      <table class="table table-sm">
        <thead>
          <tr>
            <th :for={field <- @fields}>{field.name}</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- Enum.take(@rows, 100)}>
            <td :for={field <- @fields} class="max-w-64 truncate">
              {format_value(Map.get(row, field.name))}
            </td>
          </tr>
        </tbody>
      </table>
      <.empty_rows :if={@rows == []} />
    </div>
    """
  end

  defp empty_rows(assigns) do
    ~H"""
    <div class="flex min-h-24 items-center justify-center text-sm text-base-content/55">
      No rows returned.
    </div>
    """
  end

  defp stat_value([row | _], fields) do
    key = first_numeric_field(fields)
    format_value(if key, do: Map.get(row, key))
  end

  defp stat_value(_rows, _fields), do: "No data"

  defp bars(rows, fields) do
    label_key = first_string_field(fields)
    value_key = first_numeric_field(fields)

    values =
      if label_key && value_key do
        rows
        |> Enum.take(12)
        |> Enum.map(fn row ->
          %{label: format_value(Map.get(row, label_key)), value: numeric(Map.get(row, value_key))}
        end)
      else
        []
      end

    max_value = values |> Enum.map(& &1.value) |> Enum.max(fn -> 0 end)

    Enum.map(values, fn item ->
      percent = if max_value > 0, do: item.value / max_value * 100, else: 0
      Map.put(item, :percent, percent)
    end)
  end

  defp sparkline_points(rows, fields) do
    value_key = first_numeric_field(fields)

    values =
      rows
      |> Enum.take(80)
      |> Enum.map(fn row -> numeric(Map.get(row, value_key)) end)
      |> Enum.reject(&is_nil/1)

    case values do
      [] ->
        ""

      [_single] ->
        "0,20 100,20"

      values ->
        min_value = Enum.min(values)
        max_value = Enum.max(values)
        spread = max(max_value - min_value, 1.0)
        last_index = max(length(values) - 1, 1)

        values
        |> Enum.with_index()
        |> Enum.map_join(" ", fn {value, index} ->
          x = index / last_index * 100
          y = 40 - (value - min_value) / spread * 36 - 2
          "#{Float.round(x, 2)},#{Float.round(y, 2)}"
        end)
    end
  end

  defp first_numeric_field(fields), do: first_field_of_type(fields, :number)
  defp first_string_field(fields), do: first_field_of_type(fields, :string)

  defp first_field_of_type(fields, type) do
    Enum.find_value(fields, fn field ->
      if field.type == type, do: field.name
    end)
  end

  defp numeric(value) when is_integer(value), do: value * 1.0
  defp numeric(value) when is_float(value), do: value

  defp numeric(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp numeric(_value), do: nil

  defp format_value(%DateTime{} = value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M:%S")
  defp format_value(%NaiveDateTime{} = value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M:%S")
  defp format_value(value) when is_binary(value), do: value
  defp format_value(value) when is_integer(value), do: Integer.to_string(value)
  defp format_value(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp format_value(value) when is_boolean(value), do: to_string(value)
  defp format_value(nil), do: ""
  defp format_value(value), do: inspect(value)

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
