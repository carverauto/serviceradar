defmodule ServiceRadarWebNGWeb.AuthoredDashboardLive.Index do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNG.Dashboards
  alias ServiceRadarWebNG.RBAC

  @current_path "/analytics"
  @default_query ~s|in:services time:last_1h sort:timestamp:desc limit:25|
  @visibility_options [{"Private", "private"}, {"Shared", "shared"}, {"Public", "public"}]

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    socket =
      socket
      |> assign(:page_title, "Analytics")
      |> assign(:current_path, @current_path)
      |> assign(:dashboards, [])
      |> assign(:loading_dashboards?, connected?(socket))
      |> assign(:preview, nil)
      |> assign(:selected_visuals, [:table])
      |> assign(:visual_options, Dashboards.authored_visual_options())
      |> assign(:visibility_options, @visibility_options)
      |> assign(:can_manage?, can_manage?(scope))
      |> assign(:dashboard_params, default_dashboard_params())
      |> assign_form()

    socket =
      if connected?(socket) do
        start_async(socket, :load_dashboards, fn ->
          Dashboards.list_authored_dashboards(scope, %{status: [:draft, :active]})
        end)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_async(:load_dashboards, {:ok, dashboards}, socket) do
    {:noreply, assign(socket, dashboards: dashboards, loading_dashboards?: false)}
  end

  def handle_async(:load_dashboards, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:loading_dashboards?, false)
     |> put_flash(:error, "Could not load dashboards: #{format_error(reason)}")}
  end

  @impl true
  def handle_event("validate", %{"dashboard" => params}, socket) do
    params = merge_params(socket.assigns.dashboard_params, params)

    {:noreply,
     socket
     |> assign(:dashboard_params, params)
     |> assign(:preview, nil)
     |> assign_form()}
  end

  def handle_event("preview", %{"dashboard" => params}, socket) do
    preview_query(socket, merge_params(socket.assigns.dashboard_params, params))
  end

  def handle_event("preview", _params, socket) do
    preview_query(socket, socket.assigns.dashboard_params)
  end

  def handle_event("save", %{"dashboard" => params}, socket) do
    scope = socket.assigns.current_scope
    params = merge_params(socket.assigns.dashboard_params, params)

    with :ok <- authorize_manage(socket),
         {:ok, preview} <- Dashboards.preview_authored_query(scope, params["srql_query"]),
         {:ok, dashboard_attrs, panel_attrs} <- attrs_from_params(params, preview),
         {:ok, dashboard} <- Dashboards.create_authored_dashboard(scope, dashboard_attrs),
         {:ok, _panel} <-
           Dashboards.create_authored_panel(
             scope,
             Map.put(panel_attrs, :dashboard_id, dashboard.id)
           ) do
      {:noreply,
       socket
       |> put_flash(:info, "Saved dashboard")
       |> push_navigate(to: ~p"/dashboard/#{dashboard.id}")}
    else
      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:dashboard_params, params)
         |> assign_form()
         |> put_flash(:error, "Save failed: #{format_error(reason)}")}
    end
  end

  def handle_event("archive", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    with :ok <- authorize_manage(socket),
         {:ok, dashboard} <- Dashboards.get_authored_dashboard(scope, id, load: []),
         {:ok, _dashboard} <- Dashboards.archive_authored_dashboard(scope, dashboard) do
      {:noreply,
       socket
       |> put_flash(:info, "Archived dashboard")
       |> assign(
         :dashboards,
         Dashboards.list_authored_dashboards(scope, %{status: [:draft, :active]})
       )}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Archive failed: #{format_error(reason)}")}
    end
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
            <p class="text-sm font-medium text-primary">Analytics</p>
            <h1 class="mt-1 text-2xl font-semibold tracking-normal">Dashboard Creator</h1>
            <p class="mt-2 max-w-3xl text-sm text-base-content/65">
              Build saved dashboards from bounded SRQL queries and render them at stable dashboard URLs.
            </p>
          </div>
          <.link navigate={~p"/dashboard"} class="btn btn-sm btn-ghost">
            <.icon name="hero-squares-2x2" class="size-4" /> Operations
          </.link>
        </section>

        <div class="grid grid-cols-1 gap-6 xl:grid-cols-[minmax(0,0.95fr)_minmax(440px,1.05fr)]">
          <section class="rounded-lg border border-base-300 bg-base-100">
            <div class="border-b border-base-300 px-4 py-3">
              <h2 class="text-sm font-semibold">Saved Dashboards</h2>
              <p class="text-xs text-base-content/55">
                Opened by ID through /dashboard/:dashboard_id.
              </p>
            </div>
            <div class="divide-y divide-base-200">
              <div :if={@loading_dashboards?} class="p-4 text-sm text-base-content/60">
                Loading dashboards...
              </div>
              <div
                :if={!@loading_dashboards? and @dashboards == []}
                class="p-4 text-sm text-base-content/60"
              >
                No authored dashboards yet.
              </div>
              <div
                :for={dashboard <- @dashboards}
                class="flex flex-col gap-3 p-4 sm:flex-row sm:items-center sm:justify-between"
              >
                <div class="min-w-0">
                  <div class="flex flex-wrap items-center gap-2">
                    <.link
                      navigate={~p"/dashboard/#{dashboard.id}"}
                      class="font-medium hover:text-primary"
                    >
                      {dashboard.title}
                    </.link>
                    <span class="badge badge-sm badge-outline">{dashboard.status}</span>
                    <span class="badge badge-sm">{dashboard.visibility}</span>
                  </div>
                  <p class="mt-1 truncate text-xs text-base-content/55">
                    {dashboard.description || "No description"}
                  </p>
                  <p class="mt-1 font-mono text-xs text-base-content/45">
                    /dashboard/{dashboard.id}
                  </p>
                </div>
                <div class="flex shrink-0 gap-2">
                  <.link navigate={~p"/dashboard/#{dashboard.id}"} class="btn btn-xs">
                    <.icon name="hero-arrow-top-right-on-square" class="size-4" /> Open
                  </.link>
                  <button
                    :if={@can_manage?}
                    type="button"
                    class="btn btn-xs btn-error btn-outline"
                    phx-click="archive"
                    phx-value-id={dashboard.id}
                  >
                    <.icon name="hero-archive-box" class="size-4" /> Archive
                  </button>
                </div>
              </div>
            </div>
          </section>

          <section class="rounded-lg border border-base-300 bg-base-100">
            <div class="border-b border-base-300 px-4 py-3">
              <h2 class="text-sm font-semibold">New Dashboard</h2>
              <p class="text-xs text-base-content/55">
                Preview the SRQL result, then save it as a dashboard panel.
              </p>
            </div>

            <.form
              for={@dashboard_form}
              as={:dashboard}
              phx-change="validate"
              phx-submit="save"
              class="space-y-4 p-4"
            >
              <.input field={@dashboard_form[:title]} type="text" label="Title" />
              <.input field={@dashboard_form[:description]} type="text" label="Description" />
              <.input
                field={@dashboard_form[:visibility]}
                type="select"
                label="Visibility"
                options={@visibility_options}
              />
              <.input field={@dashboard_form[:panel_title]} type="text" label="Panel title" />
              <.input field={@dashboard_form[:srql_query]} type="textarea" label="SRQL query" />
              <.input
                field={@dashboard_form[:visual_type]}
                type="select"
                label="Visual"
                options={visual_select_options(@visual_options, @selected_visuals)}
              />

              <div class="flex flex-wrap gap-2">
                <button type="button" class="btn btn-sm" phx-click="preview">
                  <.icon name="hero-eye" class="size-4" /> Preview
                </button>
                <button type="submit" class="btn btn-sm btn-primary" disabled={!@can_manage?}>
                  <.icon name="hero-bookmark-square" class="size-4" /> Save Dashboard
                </button>
              </div>
            </.form>

            <div class="border-t border-base-300 p-4">
              <.preview_result preview={@preview} visual_options={@visual_options} />
            </div>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp preview_result(%{preview: nil} = assigns) do
    ~H"""
    <div class="flex min-h-32 items-center justify-center rounded-lg border border-dashed border-base-300 text-sm text-base-content/55">
      Run preview to inspect returned fields and compatible visuals.
    </div>
    """
  end

  defp preview_result(%{preview: {:error, reason}} = assigns) do
    assigns = assign(assigns, :message, format_error(reason))

    ~H"""
    <div class="rounded-lg border border-error/30 bg-error/10 p-4 text-sm text-error">
      {@message}
    </div>
    """
  end

  defp preview_result(%{preview: {:ok, preview}} = assigns) do
    assigns =
      assigns
      |> assign(:preview_data, preview)
      |> assign(:fields, preview.fields)
      |> assign(:rows, Enum.take(preview.rows, 5))
      |> assign(:compatible, preview.compatible_visuals)

    ~H"""
    <div class="space-y-4">
      <div class="flex flex-wrap gap-2">
        <span class="badge badge-outline">{@preview_data.row_count} rows</span>
        <span :for={visual <- @compatible} class="badge badge-primary badge-outline">
          {visual}
        </span>
      </div>

      <div>
        <h3 class="text-xs font-semibold uppercase text-base-content/55">Fields</h3>
        <div class="mt-2 flex flex-wrap gap-2">
          <span :for={field <- @fields} class="badge badge-ghost">
            {field.name}: {field.type}
          </span>
        </div>
      </div>

      <div class="overflow-x-auto rounded-lg border border-base-300">
        <table class="table table-xs">
          <thead>
            <tr>
              <th :for={field <- @fields}>{field.name}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @rows}>
              <td :for={field <- @fields} class="max-w-48 truncate">
                {format_value(Map.get(row, field.name))}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp preview_query(socket, params) do
    case Dashboards.preview_authored_query(socket.assigns.current_scope, params["srql_query"]) do
      {:ok, preview} ->
        selected_visuals = preview.compatible_visuals

        params =
          Map.put(params, "visual_type", selected_visual(params["visual_type"], selected_visuals))

        {:noreply,
         socket
         |> assign(:dashboard_params, params)
         |> assign(:preview, {:ok, preview})
         |> assign(:selected_visuals, selected_visuals)
         |> assign_form()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:dashboard_params, params)
         |> assign(:preview, {:error, reason})
         |> assign(:selected_visuals, [:table])
         |> assign_form()}
    end
  end

  defp attrs_from_params(params, preview) do
    title = required(params["title"], :title)
    panel_title = required(params["panel_title"], :panel_title)
    query = required(params["srql_query"], :srql_query)
    visual = selected_visual(params["visual_type"], preview.compatible_visuals)

    with {:ok, title} <- title,
         {:ok, panel_title} <- panel_title,
         {:ok, query} <- query do
      {:ok,
       %{
         title: title,
         description: optional(params["description"]),
         status: :active,
         visibility: normalize_visibility(params["visibility"])
       },
       %{
         title: panel_title,
         srql_query: query,
         visual_type: visual,
         field_metadata: %{
           fields: preview.fields,
           compatible_visuals: preview.compatible_visuals
         }
       }}
    end
  end

  defp default_dashboard_params do
    %{
      "title" => "Service Health",
      "description" => "",
      "visibility" => "private",
      "panel_title" => "Recent service checks",
      "srql_query" => @default_query,
      "visual_type" => "table"
    }
  end

  defp assign_form(socket) do
    assign(socket, :dashboard_form, to_form(socket.assigns.dashboard_params, as: :dashboard))
  end

  defp merge_params(current, incoming) do
    Map.merge(current || %{}, incoming || %{})
  end

  defp visual_select_options(options, compatible) do
    compatible = MapSet.new(compatible)

    options
    |> Enum.filter(&MapSet.member?(compatible, &1.type))
    |> Enum.map(&{&1.label, Atom.to_string(&1.type)})
  end

  defp selected_visual(value, compatible) when is_binary(value) do
    if Enum.any?(compatible, &(Atom.to_string(&1) == value)) do
      value
    else
      compatible |> List.first(:table) |> Atom.to_string()
    end
  end

  defp selected_visual(value, compatible) when is_atom(value),
    do: selected_visual(Atom.to_string(value), compatible)

  defp selected_visual(_value, compatible),
    do: compatible |> List.first(:table) |> Atom.to_string()

  defp required(value, field) do
    case optional(value) do
      nil -> {:error, {:required, field}}
      value -> {:ok, value}
    end
  end

  defp optional(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp optional(_value), do: nil

  defp can_manage?(scope), do: RBAC.can?(scope, "analytics.dashboards.create")

  defp normalize_visibility(value) when value in ~w(private shared public), do: value
  defp normalize_visibility(_value), do: "private"

  defp authorize_manage(socket) do
    if socket.assigns.can_manage?, do: :ok, else: {:error, :forbidden}
  end

  defp format_value(%DateTime{} = value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M:%S")
  defp format_value(%NaiveDateTime{} = value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M:%S")
  defp format_value(value) when is_binary(value), do: value
  defp format_value(value) when is_number(value), do: to_string(value)
  defp format_value(value) when is_boolean(value), do: to_string(value)
  defp format_value(nil), do: ""
  defp format_value(value), do: inspect(value)

  defp format_error({:required, field}), do: "#{field} is required"
  defp format_error(:empty_query), do: "SRQL query is required"
  defp format_error(:forbidden), do: "Not authorized to manage analytics dashboards"
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
