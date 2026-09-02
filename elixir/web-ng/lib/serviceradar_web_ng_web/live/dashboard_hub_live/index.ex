defmodule ServiceRadarWebNGWeb.DashboardHubLive.Index do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Dashboards.AuthoredDashboard
  alias ServiceRadar.Dashboards.DashboardInstance
  alias ServiceRadarWebNG.Dashboards
  alias ServiceRadarWebNGWeb.SRQL.Builder, as: SRQLBuilder

  @current_path "/dashboards"
  @system_default_slug "service-availability-noc"
  @default_query "in:dashboards limit:100"

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Dashboards")
      |> assign(:current_path, @current_path)
      |> assign(:loading?, connected?(socket))
      |> assign(:items, [])
      |> assign(:preferences, %{})
      |> assign(:default_item, nil)
      |> assign(:system_default_missing?, false)
      |> assign(:system_default_slug, @system_default_slug)
      |> assign(:srql, dashboard_srql(@default_query, @current_path))

    {:ok, socket}
  end

  @impl true
  def handle_async(:load_dashboards, {:ok, result}, socket) do
    {:noreply,
     socket
     |> assign(:items, result.items)
     |> assign(:preferences, result.preferences)
     |> assign(:default_item, result.default_item)
     |> assign(:system_default_missing?, result.system_default_missing?)
     |> assign(:loading?, false)}
  end

  def handle_async(:load_dashboards, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:loading?, false)
     |> put_flash(:error, "Could not load dashboards: #{inspect(reason)}")}
  end

  @impl true
  def handle_event("toggle_favorite", %{"type" => type, "id" => id, "favorite" => favorite}, socket) do
    scope = socket.assigns.current_scope
    favorite? = favorite != "true"

    with {:ok, target_type} <- target_type(type),
         {:ok, _preference} <-
           Dashboards.set_dashboard_favorite(scope, target_type, id, favorite?) do
      {:noreply, reload(socket)}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Favorite update failed: #{format_error(reason)}")}
    end
  end

  def handle_event("set_default", %{"type" => type, "id" => id}, socket) do
    scope = socket.assigns.current_scope

    with {:ok, target_type} <- target_type(type),
         {:ok, _preference} <- Dashboards.set_default_dashboard(scope, target_type, id) do
      {:noreply, reload(socket)}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Default update failed: #{format_error(reason)}")}
    end
  end

  def handle_event("srql_change", %{"q" => query}, socket) do
    {:noreply, update_srql(socket, %{draft: query})}
  end

  def handle_event("srql_submit", params, socket) do
    query =
      params
      |> Map.get("q", socket.assigns.srql[:draft] || @default_query)
      |> normalize_dashboard_query()

    {:noreply, push_patch(socket, to: ~p"/dashboards?#{%{q: query}}")}
  end

  def handle_event("srql_reset", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/dashboards?#{%{q: @default_query}}")}
  end

  def handle_event("srql_builder_toggle", _params, socket) do
    srql = socket.assigns.srql
    {:noreply, assign(socket, :srql, Map.put(srql, :builder_open, !srql[:builder_open]))}
  end

  def handle_event("srql_builder_change", %{"builder" => params}, socket) do
    builder = SRQLBuilder.update(socket.assigns.srql[:builder], params)
    query = SRQLBuilder.build(builder)

    {:noreply,
     assign(
       socket,
       :srql,
       Map.merge(socket.assigns.srql, %{builder: builder, draft: query, query: query})
     )}
  end

  def handle_event("srql_builder_add_filter", _params, socket) do
    srql = socket.assigns.srql
    builder = srql[:builder] || SRQLBuilder.default_state("dashboards", 100)
    filters = Map.get(builder, "filters", []) || []
    next = %{"field" => "title", "op" => "contains", "value" => ""}
    builder = Map.put(builder, "filters", filters ++ [next])
    query = SRQLBuilder.build(builder)

    {:noreply, assign(socket, :srql, Map.merge(srql, %{builder: builder, draft: query, query: query}))}
  end

  def handle_event("srql_builder_remove_filter", %{"idx" => idx}, socket) do
    srql = socket.assigns.srql
    builder = srql[:builder] || SRQLBuilder.default_state("dashboards", 100)
    index = parse_int(idx, -1)

    filters =
      builder
      |> Map.get("filters", [])
      |> Enum.with_index()
      |> Enum.reject(fn {_filter, i} -> i == index end)
      |> Enum.map(fn {filter, _i} -> filter end)

    builder = Map.put(builder, "filters", filters)
    query = SRQLBuilder.build(builder)

    {:noreply, assign(socket, :srql, Map.merge(srql, %{builder: builder, draft: query, query: query}))}
  end

  def handle_event("srql_builder_apply", _params, socket) do
    query = SRQLBuilder.build(socket.assigns.srql[:builder] || %{})

    {:noreply, assign(socket, :srql, Map.merge(socket.assigns.srql, %{query: query, draft: query}))}
  end

  def handle_event("srql_builder_run", _params, socket) do
    query = SRQLBuilder.build(socket.assigns.srql[:builder] || %{})
    {:noreply, push_patch(socket, to: ~p"/dashboards?#{%{q: query}}")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    query = params |> Map.get("q", @default_query) |> normalize_dashboard_query()

    socket =
      socket
      |> assign(:current_path, @current_path)
      |> assign(:srql, dashboard_srql(query, @current_path))

    if connected?(socket) do
      scope = socket.assigns.current_scope

      {:noreply,
       socket
       |> assign(:loading?, true)
       |> start_async(:load_dashboards, fn ->
         load_dashboards(scope, query)
       end)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      page_title={@page_title}
      shell={:operations}
      srql={@srql}
    >
      <div class="mx-auto flex w-full max-w-7xl flex-col gap-6 px-4 py-6 sm:px-6 lg:px-8">
        <section class="flex flex-col gap-3 border-b border-sr-line pb-5 lg:flex-row lg:items-end lg:justify-between">
          <div>
            <p class="text-sm font-medium text-sr-brand">Dashboards</p>
            <h1 class="mt-1 text-2xl font-semibold tracking-tight text-sr-ink">
              Dashboard &amp; Report Library
            </h1>
            <p class="mt-2 max-w-3xl text-sm text-sr-muted">
              Find your dashboards, shared dashboards, dashboard packages, scheduled reports, and favorites in one place.
            </p>
          </div>
          <div class="flex flex-wrap gap-2">
            <.ui_button :if={@default_item} navigate={@default_item.href} size="sm" variant="primary">
              <.icon name="hero-play" class="size-4" /> Open default
            </.ui_button>
            <.ui_button navigate={~p"/analytics"} size="sm" variant="ghost">
              <.icon name="hero-plus" class="size-4" /> Create
            </.ui_button>
          </div>
        </section>

        <section
          :if={!@loading? and @default_item}
          class="rounded-sr-surface border border-sr-brand/25 bg-sr-subtle p-4"
        >
          <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <p class="text-xs font-semibold uppercase tracking-[0.14em] text-sr-brand">
                Default Dashboard
              </p>
              <h2 class="mt-1 text-lg font-semibold text-sr-ink">{@default_item.title}</h2>
              <p class="mt-1 text-sm text-sr-muted">{@default_item.description}</p>
            </div>
            <.ui_button navigate={@default_item.href} size="sm" variant="primary">
              <.icon name="hero-arrow-top-right-on-square" class="size-4" /> Open
            </.ui_button>
          </div>
        </section>

        <section
          :if={!@loading? and @system_default_missing?}
          class="rounded-sr-surface border border-amber-500/30 bg-amber-500/10 p-4 text-sm text-amber-900 dark:text-amber-200"
        >
          The bundled service availability dashboard package is not enabled at /dashboards/{@system_default_slug}.
        </section>

        <div
          :if={@loading?}
          class="rounded-sr-surface border border-sr-line bg-sr-surface p-6 text-sm text-sr-muted"
        >
          Loading dashboards...
        </div>

        <div
          :if={!@loading? and @items == []}
          class="rounded-sr-surface border border-sr-line bg-sr-surface p-6 text-sm text-sr-muted"
        >
          No dashboards are available yet.
        </div>

        <section :if={!@loading? and favorite_items(@items) != []} class="space-y-3">
          <h2 class="text-sm font-semibold uppercase tracking-normal text-sr-muted">
            Favorites
          </h2>
          <div class="grid grid-cols-1 gap-3 lg:grid-cols-2">
            <.dashboard_card :for={item <- favorite_items(@items)} item={item} />
          </div>
        </section>

        <section :if={!@loading? and report_items(@items) != []} class="space-y-3">
          <h2 class="text-sm font-semibold uppercase tracking-normal text-sr-muted">
            Reports
          </h2>
          <p class="text-sm text-sr-muted">
            System SRQL reports. Open one and use Email Reports to send it on a schedule.
          </p>
          <div class="grid grid-cols-1 gap-3 lg:grid-cols-2">
            <.dashboard_card :for={item <- report_items(@items)} item={item} />
          </div>
        </section>

        <section :if={!@loading? and @items != []} class="space-y-3">
          <h2 class="text-sm font-semibold uppercase tracking-normal text-sr-muted">
            All Dashboards
          </h2>
          <div class="grid grid-cols-1 gap-3 lg:grid-cols-2">
            <.dashboard_card :for={item <- @items} item={item} />
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr(:item, :map, required: true)

  defp dashboard_card(assigns) do
    ~H"""
    <article class="rounded-sr-surface border border-sr-line bg-sr-surface p-4 shadow-sr-surface">
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="flex flex-wrap items-center gap-2">
            <.link
              navigate={@item.href}
              class="truncate font-semibold text-sr-ink outline-none hover:text-sr-brand focus-visible:ring-2 focus-visible:ring-sr-focus"
            >
              {@item.title}
            </.link>
            <.ui_badge size="sm" variant="ghost">{@item.kind_label}</.ui_badge>
            <.ui_badge :if={@item.default?} size="sm" variant="info">Default</.ui_badge>
          </div>
          <p class="mt-2 line-clamp-2 text-sm text-sr-muted">{@item.description}</p>
          <p class="mt-2 font-mono text-xs text-sr-muted/80">{@item.href}</p>
        </div>
        <div class="flex shrink-0 gap-1">
          <.ui_icon_button
            type="button"
            size="sm"
            variant="ghost"
            title={if @item.favorite?, do: "Remove favorite", else: "Favorite"}
            aria-label={if @item.favorite?, do: "Remove favorite", else: "Favorite"}
            phx-click="toggle_favorite"
            phx-value-type={@item.type}
            phx-value-id={@item.id}
            phx-value-favorite={to_string(@item.favorite?)}
          >
            <.icon name={if @item.favorite?, do: "hero-star-solid", else: "hero-star"} class="size-4" />
          </.ui_icon_button>
          <.ui_icon_button
            type="button"
            size="sm"
            variant="ghost"
            title="Set as default"
            aria-label="Set as default"
            phx-click="set_default"
            phx-value-type={@item.type}
            phx-value-id={@item.id}
          >
            <.icon name="hero-bookmark" class="size-4" />
          </.ui_icon_button>
        </div>
      </div>
    </article>
    """
  end

  defp load_dashboards(scope, query) do
    preferences =
      scope
      |> Dashboards.list_dashboard_preferences()
      |> Map.new(fn preference ->
        {{preference.target_type, preference.target_id}, preference}
      end)

    authored =
      scope
      |> Dashboards.list_authored_dashboards(%{status: [:draft, :active], limit: 200})
      |> Enum.map(&authored_item(&1, preferences))

    packages =
      [scope: scope]
      |> Dashboards.enabled_package_instances()
      |> Enum.map(&package_item(&1, preferences))

    system_default_available? =
      Enum.any?(packages, &(&1.type == "package" and &1.id == @system_default_slug))

    items =
      (authored ++ packages)
      |> filter_items(query)
      |> Enum.sort_by(&sort_key/1)

    system_default = Enum.find(items, &(&1.type == "package" and &1.id == @system_default_slug))

    %{
      items: items,
      preferences: preferences,
      default_item: Enum.find(items, & &1.default?) || system_default,
      system_default_missing?: not system_default_available?
    }
  end

  defp authored_item(%AuthoredDashboard{} = dashboard, preferences) do
    preference = Map.get(preferences, {:authored, dashboard.id})

    %{
      type: "authored",
      id: dashboard.id,
      title: dashboard.title,
      description: dashboard.description || "SRQL dashboard",
      href: ~p"/dashboard/#{Dashboards.authored_dashboard_route_ref(dashboard)}",
      slug: dashboard.slug,
      status: to_string(dashboard.status),
      search_text:
        Enum.join(
          [dashboard.title, dashboard.description, dashboard.slug, dashboard.status, "authored"],
          " "
        ),
      kind_label: if(system_report?(dashboard), do: "Report", else: "Authored"),
      report?: system_report?(dashboard),
      favorite?: favorite?(preference),
      default?: default?(preference),
      updated_at: dashboard.updated_at
    }
  end

  defp package_item(%DashboardInstance{} = instance, preferences) do
    package = instance.dashboard_package
    preference = Map.get(preferences, {:package, instance.route_slug})

    %{
      type: "package",
      id: instance.route_slug,
      title: instance.name || package_name(package) || instance.route_slug,
      description: package_description(package),
      href: ~p"/dashboards/#{instance.route_slug}",
      slug: instance.route_slug,
      status: if(instance.enabled, do: "active", else: "disabled"),
      search_text:
        Enum.join(
          [
            instance.name,
            instance.route_slug,
            package_name(package),
            package_description(package),
            if(instance.enabled, do: "active", else: "disabled"),
            "package"
          ],
          " "
        ),
      kind_label: "Package",
      report?: false,
      favorite?: favorite?(preference),
      default?: default?(preference) or instance.is_default,
      updated_at: instance.updated_at
    }
  end

  defp package_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp package_name(_package), do: nil

  defp package_description(%{description: description}) when is_binary(description) and description != "" do
    description
  end

  defp package_description(_package), do: "Signed dashboard package"

  defp favorite_items(items), do: Enum.filter(items, & &1.favorite?)

  defp report_items(items), do: Enum.filter(items, & &1.report?)

  defp system_report?(%{metadata: %{"system_report" => true}}), do: true
  defp system_report?(%{metadata: %{system_report: true}}), do: true
  defp system_report?(_dashboard), do: false

  defp favorite?(%{favorite: true}), do: true
  defp favorite?(_preference), do: false

  defp default?(%{is_default: true}), do: true
  defp default?(_preference), do: false

  defp sort_key(item), do: {not item.default?, not item.favorite?, item.title}

  defp filter_items(items, query) do
    filters = dashboard_query_filters(query)
    Enum.filter(items, &dashboard_item_matches?(&1, filters))
  end

  defp dashboard_query_filters(query) when is_binary(query) do
    query
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&dashboard_control_token?/1)
    |> Enum.flat_map(&dashboard_query_filter/1)
  end

  defp dashboard_query_filters(_query), do: []

  defp dashboard_control_token?(token) do
    Enum.any?(
      ~w(in: limit: sort: time: stats: rollup_stats: group_by:),
      &String.starts_with?(token, &1)
    )
  end

  defp dashboard_query_filter("title:" <> value), do: clean_filter(:title, value)
  defp dashboard_query_filter("description:" <> value), do: clean_filter(:description, value)
  defp dashboard_query_filter("slug:" <> value), do: clean_filter(:slug, value)
  defp dashboard_query_filter("type:" <> value), do: clean_filter(:type, value)
  defp dashboard_query_filter("status:" <> value), do: clean_filter(:status, value)
  defp dashboard_query_filter(value), do: clean_filter(:text, value)

  defp clean_filter(field, value) do
    case clean_value(value) do
      "" -> []
      cleaned -> [{field, cleaned}]
    end
  end

  defp clean_value(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.trim("\"")
    |> String.trim("'")
    |> String.trim("%")
    |> String.downcase()
  end

  defp dashboard_item_matches?(_item, []), do: true

  defp dashboard_item_matches?(item, filters) do
    Enum.all?(filters, fn
      {:title, value} -> dashboard_filter_match?(item.title, value)
      {:description, value} -> dashboard_filter_match?(item.description, value)
      {:slug, value} -> dashboard_filter_match?(item.slug, value)
      {:type, value} -> dashboard_filter_match?(item.type, value)
      {:status, value} -> dashboard_filter_match?(Map.get(item, :status), value)
      {:text, value} -> dashboard_filter_match?(item.search_text, value)
    end)
  end

  defp dashboard_filter_match?(nil, _value), do: false

  defp dashboard_filter_match?(haystack, value) do
    haystack
    |> to_string()
    |> String.downcase()
    |> String.contains?(value)
  end

  defp target_type("authored"), do: {:ok, :authored}
  defp target_type("package"), do: {:ok, :package}
  defp target_type(_type), do: {:error, :invalid_dashboard_type}

  defp format_error(:invalid_dashboard_type), do: "Unknown dashboard type"
  defp format_error(%Ash.Error.Forbidden{}), do: "Not authorized"
  defp format_error(_reason), do: "Unable to update dashboard preference"

  defp reload(socket) do
    scope = socket.assigns.current_scope
    query = socket.assigns.srql[:query] || @default_query

    socket
    |> assign(:loading?, true)
    |> start_async(:load_dashboards, fn ->
      load_dashboards(scope, query)
    end)
  end

  defp dashboard_srql(query, path) do
    query = normalize_dashboard_query(query)
    {supported?, sync?, builder} = dashboard_builder(query)

    %{
      enabled: true,
      placement: :topbar,
      entity: "dashboards",
      page_path: path,
      query: query,
      draft: query,
      error: nil,
      loading: false,
      builder_available: true,
      builder_open: false,
      builder_supported: supported?,
      builder_sync: sync?,
      builder: builder
    }
  end

  defp dashboard_builder(query) do
    case SRQLBuilder.parse(query) do
      {:ok, builder} -> {true, true, builder}
      {:error, _reason} -> {false, false, SRQLBuilder.default_state("dashboards", 100)}
    end
  end

  defp normalize_dashboard_query(query) when is_binary(query) do
    query = String.trim(query)

    cond do
      query == "" -> @default_query
      String.contains?(query, "in:dashboards") -> query
      true -> "in:dashboards #{query} limit:100"
    end
  end

  defp normalize_dashboard_query(_query), do: @default_query

  defp update_srql(socket, attrs) do
    assign(socket, :srql, Map.merge(socket.assigns.srql, attrs))
  end

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp parse_int(value, _default) when is_integer(value), do: value
  defp parse_int(_value, default), do: default
end
