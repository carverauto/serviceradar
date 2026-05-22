defmodule ServiceRadarWebNGWeb.DashboardHubLive.Index do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Dashboards.AuthoredDashboard
  alias ServiceRadar.Dashboards.DashboardInstance
  alias ServiceRadarWebNG.Dashboards

  @current_path "/dashboards"
  @system_default_slug "service-availability-noc"

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    socket =
      socket
      |> assign(:page_title, "Dashboards")
      |> assign(:current_path, @current_path)
      |> assign(:loading?, connected?(socket))
      |> assign(:items, [])
      |> assign(:preferences, %{})
      |> assign(:default_item, nil)

    socket =
      if connected?(socket) do
        start_async(socket, :load_dashboards, fn -> load_dashboards(scope) end)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_async(:load_dashboards, {:ok, result}, socket) do
    {:noreply,
     socket
     |> assign(:items, result.items)
     |> assign(:preferences, result.preferences)
     |> assign(:default_item, result.default_item)
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
         {:ok, _preference} <- Dashboards.set_dashboard_favorite(scope, target_type, id, favorite?) do
      {:noreply, reload(socket)}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Favorite update failed: #{format_error(reason)}")}
    end
  end

  def handle_event("set_default", %{"type" => type, "id" => id}, socket) do
    scope = socket.assigns.current_scope

    with {:ok, target_type} <- target_type(type),
         {:ok, _preference} <- Dashboards.set_default_dashboard(scope, target_type, id) do
      {:noreply, reload(socket)}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Default update failed: #{format_error(reason)}")}
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
            <p class="text-sm font-medium text-primary">Dashboards</p>
            <h1 class="mt-1 text-2xl font-semibold tracking-normal">Dashboard Library</h1>
            <p class="mt-2 max-w-3xl text-sm text-base-content/65">
              Find your dashboards, shared dashboards, dashboard packages, and favorites in one place.
            </p>
          </div>
          <div class="flex flex-wrap gap-2">
            <.link :if={@default_item} navigate={@default_item.href} class="btn btn-sm btn-primary">
              <.icon name="hero-play" class="size-4" /> Open default
            </.link>
            <.link navigate={~p"/analytics"} class="btn btn-sm btn-ghost">
              <.icon name="hero-plus" class="size-4" /> Create
            </.link>
          </div>
        </section>

        <div
          :if={@loading?}
          class="rounded-lg border border-base-300 bg-base-100 p-6 text-sm text-base-content/60"
        >
          Loading dashboards...
        </div>

        <div
          :if={!@loading? and @items == []}
          class="rounded-lg border border-base-300 bg-base-100 p-6 text-sm text-base-content/60"
        >
          No dashboards are available yet.
        </div>

        <section :if={!@loading? and favorite_items(@items) != []} class="space-y-3">
          <h2 class="text-sm font-semibold uppercase tracking-normal text-base-content/60">
            Favorites
          </h2>
          <div class="grid grid-cols-1 gap-3 lg:grid-cols-2">
            <.dashboard_card :for={item <- favorite_items(@items)} item={item} />
          </div>
        </section>

        <section :if={!@loading? and @items != []} class="space-y-3">
          <h2 class="text-sm font-semibold uppercase tracking-normal text-base-content/60">
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

  attr :item, :map, required: true

  defp dashboard_card(assigns) do
    ~H"""
    <article class="rounded-lg border border-base-300 bg-base-100 p-4">
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="flex flex-wrap items-center gap-2">
            <.link navigate={@item.href} class="truncate font-semibold hover:text-primary">
              {@item.title}
            </.link>
            <span class="badge badge-sm badge-outline">{@item.kind_label}</span>
            <span :if={@item.default?} class="badge badge-sm badge-primary">Default</span>
          </div>
          <p class="mt-2 line-clamp-2 text-sm text-base-content/60">{@item.description}</p>
          <p class="mt-2 font-mono text-xs text-base-content/45">{@item.href}</p>
        </div>
        <div class="flex shrink-0 gap-1">
          <button
            type="button"
            class="btn btn-square btn-ghost btn-sm"
            title={if @item.favorite?, do: "Remove favorite", else: "Favorite"}
            aria-label={if @item.favorite?, do: "Remove favorite", else: "Favorite"}
            phx-click="toggle_favorite"
            phx-value-type={@item.type}
            phx-value-id={@item.id}
            phx-value-favorite={to_string(@item.favorite?)}
          >
            <.icon name={if @item.favorite?, do: "hero-star-solid", else: "hero-star"} class="size-4" />
          </button>
          <button
            type="button"
            class="btn btn-square btn-ghost btn-sm"
            title="Set as default"
            aria-label="Set as default"
            phx-click="set_default"
            phx-value-type={@item.type}
            phx-value-id={@item.id}
          >
            <.icon name="hero-bookmark" class="size-4" />
          </button>
        </div>
      </div>
    </article>
    """
  end

  defp load_dashboards(scope) do
    preferences =
      scope
      |> Dashboards.list_dashboard_preferences()
      |> Map.new(fn preference -> {{preference.target_type, preference.target_id}, preference} end)

    authored =
      scope
      |> Dashboards.list_authored_dashboards(%{status: [:draft, :active], limit: 200})
      |> Enum.map(&authored_item(&1, preferences))

    packages =
      [scope: scope]
      |> Dashboards.enabled_package_instances()
      |> Enum.map(&package_item(&1, preferences))

    items = Enum.sort_by(authored ++ packages, &sort_key/1)

    %{
      items: items,
      preferences: preferences,
      default_item:
        Enum.find(items, & &1.default?) || Enum.find(items, &(&1.type == "package" and &1.id == @system_default_slug))
    }
  end

  defp authored_item(%AuthoredDashboard{} = dashboard, preferences) do
    preference = Map.get(preferences, {:authored, dashboard.id})

    %{
      type: "authored",
      id: dashboard.id,
      title: dashboard.title,
      description: dashboard.description || "SRQL dashboard",
      href: ~p"/dashboard/#{dashboard.id}",
      kind_label: "Authored",
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
      kind_label: "Package",
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

  defp favorite?(%{favorite: true}), do: true
  defp favorite?(_preference), do: false

  defp default?(%{is_default: true}), do: true
  defp default?(_preference), do: false

  defp sort_key(item), do: {not item.default?, not item.favorite?, item.title}

  defp target_type("authored"), do: {:ok, :authored}
  defp target_type("package"), do: {:ok, :package}
  defp target_type(_type), do: {:error, :invalid_dashboard_type}

  defp format_error(:invalid_dashboard_type), do: "Unknown dashboard type"
  defp format_error(%Ash.Error.Forbidden{}), do: "Not authorized"
  defp format_error(_reason), do: "Unable to update dashboard preference"

  defp reload(socket) do
    scope = socket.assigns.current_scope

    socket
    |> assign(:loading?, true)
    |> start_async(:load_dashboards, fn ->
      load_dashboards(scope)
    end)
  end
end
