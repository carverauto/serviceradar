defmodule ServiceRadarWebNGWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use ServiceRadarWebNGWeb, :html

  alias ServiceRadarWebNGWeb.FeatureFlags

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates("layouts/*")

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr(:flash, :map, required: true, doc: "the map of flash messages")

  attr(:current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"
  )

  attr(:srql, :map, default: %{}, doc: "SRQL query bar state for SRQL-driven pages")

  attr(:hide_breadcrumb, :boolean,
    default: false,
    doc: "Hide auto breadcrumb when page has custom one"
  )

  attr(:current_path, :string, default: nil, doc: "Current route path for shell navigation state")
  attr(:shell, :atom, default: :auto, doc: "Application shell variant")
  attr(:page_title, :string, default: nil, doc: "Title shown in the operations shell topbar")

  slot(:inner_block, required: true)

  def app(assigns) do
    assigns = assign_new(assigns, :srql, fn -> %{} end)
    assigns = assign_new(assigns, :hide_breadcrumb, fn -> false end)
    current_scope = assigns[:current_scope]
    signed_in? = is_map(current_scope) and not is_nil(Map.get(current_scope, :user))
    current_path = assigns[:current_path] || Map.get(assigns.srql, :page_path)
    page_title = assigns[:page_title] || operations_page_title(current_path)
    assigns = assign(assigns, signed_in?: signed_in?, current_path: current_path, page_title: page_title)

    cond do
      assigns.shell == :operations -> operations_app(assigns)
      assigns.shell == :standard -> standard_app(assigns)
      signed_in? -> operations_app(assigns)
      true -> standard_app(assigns)
    end
  end

  defp standard_app(assigns) do
    ~H"""
    <div class="drawer lg:drawer-open">
      <input id="sr-sidebar" type="checkbox" class="drawer-toggle" />

      <div class="drawer-content flex min-h-screen flex-col">
        <header class="sticky top-0 z-20 border-b border-base-200 bg-base-100/90 backdrop-blur">
          <div class="px-4 sm:px-6 lg:px-8 py-3 flex flex-col gap-2">
            <%!-- Top row: hamburger, SRQL bar, and auth buttons --%>
            <div class="flex items-center gap-3">
              <label
                :if={@signed_in?}
                for="sr-sidebar"
                class="btn btn-ghost btn-sm lg:hidden shrink-0"
                aria-label="Open navigation"
                title="Open navigation"
              >
                <.icon name="hero-bars-3" class="size-5" />
              </label>

              <div :if={Map.get(@srql, :enabled, false)} class="flex-1 min-w-0">
                <.srql_query_bar
                  query={Map.get(@srql, :query)}
                  draft={Map.get(@srql, :draft)}
                  loading={Map.get(@srql, :loading, false)}
                  builder_available={Map.get(@srql, :builder_available, false)}
                  builder_open={Map.get(@srql, :builder_open, false)}
                  builder_supported={Map.get(@srql, :builder_supported, true)}
                  builder_sync={Map.get(@srql, :builder_sync, true)}
                  builder={Map.get(@srql, :builder, %{})}
                />
              </div>
              <div :if={not Map.get(@srql, :enabled, false)} class="flex-1"></div>

              <div class="flex items-center gap-2 shrink-0">
                <.theme_toggle :if={not @signed_in?} />

                <%= if not @signed_in? do %>
                  <.ui_button href={~p"/users/log-in"} variant="primary" size="sm">Log in</.ui_button>
                <% end %>
              </div>
            </div>

            <%!-- Second row: breadcrumb navigation (all on one line) --%>
            <.breadcrumb_nav :if={@current_path && !@hide_breadcrumb} current_path={@current_path} />
          </div>
        </header>

        <div
          :if={Map.get(@srql, :builder_open, false) or Map.get(@srql, :error)}
          class="border-b border-base-200 bg-base-100"
        >
          <div class="px-4 sm:px-6 lg:px-8 py-4">
            <div :if={Map.get(@srql, :error)} class="mb-3 text-xs text-error">
              {Map.get(@srql, :error)}
            </div>

            <.srql_query_builder
              :if={Map.get(@srql, :builder_open, false)}
              supported={Map.get(@srql, :builder_supported, true)}
              sync={Map.get(@srql, :builder_sync, true)}
              builder={Map.get(@srql, :builder, %{})}
            />
          </div>
        </div>

        <main class="px-4 py-6 sm:px-6 lg:px-8 flex-1">
          {render_slot(@inner_block)}
        </main>

        <.flash_group flash={@flash} />
      </div>

      <div :if={@signed_in?} class="drawer-side z-30 overflow-visible">
        <label for="sr-sidebar" class="drawer-overlay" aria-label="Close navigation"></label>
        <aside class="w-48 bg-base-100 border-r border-base-200 min-h-full flex flex-col overflow-visible">
          <div class="p-3">
            <.link href={~p"/"} class="flex items-center gap-2 mb-4">
              <img
                src={~p"/images/logo.svg"}
                alt="ServiceRadar"
                class="size-6 opacity-95"
                width="24"
                height="24"
              />
              <span class="font-semibold text-sm tracking-tight">ServiceRadar</span>
            </.link>

            <ul class="menu menu-sm">
              <li>
                <.sidebar_link
                  href={~p"/dashboard"}
                  label="Dashboard"
                  icon="hero-home"
                  active={@current_path == "/dashboard"}
                />
              </li>
              <li>
                <.sidebar_link
                  href={~p"/analytics"}
                  label="Analytics"
                  icon="hero-chart-bar"
                  active={@current_path == "/analytics"}
                />
              </li>
              <li>
                <.sidebar_link
                  href={~p"/devices"}
                  label="Devices"
                  icon="hero-server"
                  active={@current_path == "/devices"}
                />
              </li>
              <li>
                <.sidebar_link
                  href={~p"/services"}
                  label="Services"
                  icon="hero-cog-6-tooth"
                  active={@current_path in ["/services", "/gateways"]}
                />
              </li>
              <li :if={FeatureFlags.god_view_enabled?()}>
                <.sidebar_link
                  href={~p"/topology"}
                  label="Topology"
                  icon="hero-share"
                  active={@current_path && String.starts_with?(@current_path, "/topology")}
                />
              </li>
              <li>
                <.sidebar_link
                  href={~p"/diagnostics/mtr"}
                  label="Diagnostics"
                  icon="hero-signal"
                  active={
                    @current_path &&
                      String.starts_with?(@current_path, "/diagnostics")
                  }
                />
              </li>
              <li>
                <.sidebar_link
                  href={~p"/observability"}
                  label="Observability"
                  icon="hero-presentation-chart-line"
                  active={
                    @current_path &&
                      (String.starts_with?(@current_path, "/observability") ||
                         String.starts_with?(@current_path, "/logs") ||
                         String.starts_with?(@current_path, "/events") ||
                         String.starts_with?(@current_path, "/alerts") ||
                         String.starts_with?(@current_path, "/flows"))
                  }
                />
              </li>
              <li>
                <.sidebar_link
                  href={~p"/settings/cluster"}
                  label="Settings"
                  icon="hero-adjustments-horizontal"
                  active={
                    @current_path &&
                      (String.starts_with?(@current_path, "/settings") ||
                         String.starts_with?(@current_path, "/admin") ||
                         String.starts_with?(@current_path, "/users/settings"))
                  }
                />
              </li>
            </ul>
          </div>

          <div class="mt-auto p-3 border-t border-base-200">
            <div class="dropdown dropdown-top w-full">
              <div
                tabindex="0"
                role="button"
                class="flex items-center gap-2 p-2 rounded-lg hover:bg-base-200 cursor-pointer w-full"
              >
                <div class="avatar avatar-placeholder">
                  <div class="bg-neutral text-neutral-content w-8 rounded-full">
                    <span class="text-xs">{user_initials(@current_scope.user.email)}</span>
                  </div>
                </div>
                <.icon name="hero-chevron-up" class="size-3 text-base-content/50 ml-auto" />
              </div>
              <ul
                tabindex="0"
                class="dropdown-content menu bg-base-200 rounded-box z-10 w-56 p-2 shadow-lg mb-2"
              >
                <li :if={@current_scope && @current_scope.user}>
                  <div class="flex flex-col gap-1">
                    <span class="text-[10px] uppercase tracking-wider text-base-content/60">
                      Signed in as
                    </span>
                    <span class="text-sm font-medium truncate max-w-[180px]">
                      {@current_scope.user.email}
                    </span>
                    <span class="text-[10px] uppercase tracking-wider text-base-content/50 mt-1">
                      Role
                    </span>
                    <span class="text-xs font-medium">
                      {format_role(@current_scope.user.role)}
                    </span>
                  </div>
                </li>
                <li>
                  <div class="flex flex-col gap-2">
                    <span class="text-[10px] uppercase tracking-wider text-base-content/60">
                      Theme
                    </span>
                    <.theme_toggle />
                  </div>
                </li>
                <li>
                  <.link href={~p"/settings/profile"} class="text-sm">
                    <.icon name="hero-cog-6-tooth" class="size-4" /> Account
                  </.link>
                </li>
                <li>
                  <.link href={~p"/users/log-out"} method="delete" class="text-sm">
                    <.icon name="hero-arrow-right-on-rectangle" class="size-4" /> Log out
                  </.link>
                </li>
              </ul>
            </div>
          </div>
        </aside>
      </div>
    </div>
    """
  end

  defp operations_app(assigns) do
    nav_items = [
      %{href: "/dashboard", label: "Dashboard", icon: "hero-home"},
      %{href: "/devices", label: "Devices", icon: "hero-server-stack"},
      %{href: "/topology", label: "Topology", icon: "hero-share"},
      %{href: "/observability?tab=netflows", label: "Flows", icon: "hero-arrow-path"},
      %{href: "/events", label: "Events", icon: "hero-document-text"},
      %{href: "/cameras", label: "Cameras", icon: "hero-video-camera"},
      %{href: "/spatial", label: "FieldSurvey", icon: "hero-wifi"},
      %{href: "/observability", label: "Observability", icon: "hero-presentation-chart-line"},
      %{href: "/settings/cluster", label: "Settings", icon: "hero-cog-6-tooth"}
    ]

    assigns = assign(assigns, :nav_items, nav_items)

    ~H"""
    <div class="sr-ops-shell">
      <aside :if={@signed_in?} class="sr-ops-sidebar" aria-label="Primary navigation">
        <nav class="sr-ops-nav">
          <.link
            :for={item <- @nav_items}
            href={item.href}
            title={item.label}
            aria-label={item.label}
            aria-current={ops_nav_active?(@current_path, item.href) && "page"}
            class={[
              "sr-ops-nav-button",
              ops_nav_active?(@current_path, item.href) && "is-active"
            ]}
          >
            <.icon name={item.icon} class="size-5" />
          </.link>
        </nav>

        <div class="sr-ops-nav mt-auto">
          <.link
            href={~p"/users/log-out"}
            method="delete"
            class="sr-ops-nav-button"
            title="Log out"
            aria-label="Log out"
          >
            <.icon name="hero-arrow-right-on-rectangle" class="size-5" />
          </.link>
        </div>
      </aside>

      <div class="sr-ops-main">
        <header class="sr-ops-topbar">
          <div class="sr-ops-topbar-title">
            <div class="sr-ops-topbar-brand">
              <img src={~p"/images/logo.svg"} alt="" class="size-7" width="28" height="28" />
              <span class="text-lg font-semibold text-white">ServiceRadar</span>
              <span class="h-7 w-px bg-slate-700"></span>
            </div>
            <h1 class="sr-ops-page-title">
              {@page_title}
            </h1>
          </div>

          <div class="sr-ops-topbar-actions">
            <.theme_toggle />
            <.link
              href={~p"/events"}
              class="sr-ops-topbar-icon relative"
              aria-label="Events"
              title="Events"
            >
              <.icon name="hero-bell" class="size-5" />
              <span class="sr-ops-notification-dot">0</span>
            </.link>
            <.link
              href={~p"/settings/profile"}
              class="sr-ops-avatar"
              aria-label="Account"
              title={@current_scope && @current_scope.user && @current_scope.user.email}
            >
              <span>
                {user_initials(@current_scope && @current_scope.user && @current_scope.user.email)}
              </span>
            </.link>
          </div>
        </header>

        <div :if={Map.get(@srql, :enabled, false)} class="sr-ops-querybar">
          <.srql_query_bar
            query={Map.get(@srql, :query)}
            draft={Map.get(@srql, :draft)}
            loading={Map.get(@srql, :loading, false)}
            builder_available={Map.get(@srql, :builder_available, false)}
            builder_open={Map.get(@srql, :builder_open, false)}
            builder_supported={Map.get(@srql, :builder_supported, true)}
            builder_sync={Map.get(@srql, :builder_sync, true)}
            builder={Map.get(@srql, :builder, %{})}
          />
        </div>

        <div
          :if={Map.get(@srql, :builder_open, false) or Map.get(@srql, :error)}
          class="sr-ops-querybuilder"
        >
          <div :if={Map.get(@srql, :error)} class="sr-ops-query-error">
            {Map.get(@srql, :error)}
          </div>

          <.srql_query_builder
            :if={Map.get(@srql, :builder_open, false)}
            supported={Map.get(@srql, :builder_supported, true)}
            sync={Map.get(@srql, :builder_sync, true)}
            builder={Map.get(@srql, :builder, %{})}
          />
        </div>

        <main class="sr-ops-content">
          {render_slot(@inner_block)}
        </main>

        <.flash_group flash={@flash} />
      </div>
    </div>
    """
  end

  defp user_initials(email) when is_binary(email) do
    email
    |> String.split("@")
    |> List.first()
    |> String.slice(0, 2)
    |> String.upcase()
  end

  defp user_initials(_), do: "?"

  defp format_role(role) when is_atom(role) do
    role
    |> Atom.to_string()
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp format_role(role) when is_binary(role), do: role

  defp ops_nav_active?(current_path, href) when is_binary(current_path) and is_binary(href) do
    cond do
      current_path == href ->
        true

      href == "/dashboard" ->
        false

      href == "/observability" ->
        current_path in ["/observability", "/logs", "/alerts"] or
          String.starts_with?(current_path, "/observability/bmp") or
          String.starts_with?(current_path, "/observability/bgp") or
          String.starts_with?(current_path, "/logs/") or
          String.starts_with?(current_path, "/alerts/")

      true ->
        String.starts_with?(current_path, href)
    end
  end

  defp ops_nav_active?(_, _), do: false

  defp operations_page_title("/dashboard"), do: "Unified Operations Dashboard"
  defp operations_page_title("/cameras"), do: "Camera Multiview"
  defp operations_page_title("/topology"), do: "Topology"
  defp operations_page_title("/events"), do: "Events"
  defp operations_page_title("/alerts"), do: "Alerts"
  defp operations_page_title("/observability"), do: "Observability"
  defp operations_page_title("/observability/flows"), do: "Network Flows"
  defp operations_page_title("/spatial"), do: "FieldSurvey"

  defp operations_page_title(path) when is_binary(path) do
    cond do
      String.starts_with?(path, "/cameras/") -> "Camera Feed"
      String.starts_with?(path, "/devices") -> "Devices"
      String.starts_with?(path, "/services") -> "Services"
      String.starts_with?(path, "/diagnostics") -> "Diagnostics"
      String.starts_with?(path, "/settings") -> "Settings"
      String.starts_with?(path, "/observability") -> "Observability"
      true -> "ServiceRadar"
    end
  end

  defp operations_page_title(_), do: "ServiceRadar"

  attr(:href, :string, required: true)
  attr(:label, :string, required: true)
  attr(:icon, :string, default: nil)
  attr(:active, :boolean, default: false)

  def sidebar_link(assigns) do
    ~H"""
    <.link
      href={@href}
      aria-current={@active && "page"}
      class={[
        "flex items-center gap-2",
        @active && "active"
      ]}
    >
      <.icon :if={@icon} name={@icon} class="size-4 opacity-80" />
      <span class="truncate">{@label}</span>
    </.link>
    """
  end

  attr(:current_path, :string, required: true)

  defp breadcrumb_nav(assigns) do
    crumbs = build_breadcrumbs(assigns.current_path)
    assigns = assign(assigns, :crumbs, crumbs)

    ~H"""
    <nav class="text-xs sm:text-sm">
      <div class="breadcrumbs">
        <ul class="flex items-center flex-wrap min-w-0">
          <li>
            <.link
              href={~p"/analytics"}
              class="flex items-center gap-1.5 text-base-content/60 hover:text-base-content"
              title="Home"
            >
              <.icon name="hero-home-micro" class="size-3.5" />
            </.link>
          </li>
          <li :for={crumb <- @crumbs}>
            <.link
              :if={crumb.href != nil}
              href={crumb.href}
              class="flex items-center gap-1.5 text-base-content/60 hover:text-base-content"
              title={crumb.label}
            >
              <.icon :if={crumb.icon} name={crumb.icon} class="size-3.5 shrink-0" />
              <span>{crumb.label}</span>
            </.link>
            <span
              :if={crumb.href == nil}
              class="flex items-center gap-1.5 font-medium text-base-content truncate max-w-[20rem]"
              title={crumb.label}
            >
              {crumb.label}
            </span>
          </li>
        </ul>
      </div>
    </nav>
    """
  end

  defp build_breadcrumbs(path) when is_binary(path) do
    segments =
      path
      |> String.trim_leading("/")
      |> String.split("/")
      |> Enum.reject(&(&1 == ""))

    # Treat agents and gateways as children of infrastructure
    segments = normalize_infrastructure_path(segments)

    case segments do
      [] ->
        []

      [section] ->
        [%{label: section_label(section), icon: section_icon(section), href: nil}]

      [section, id] ->
        [
          %{
            label: section_label(section),
            icon: section_icon(section),
            href: section_href(section)
          },
          %{label: format_id(id), icon: nil, href: nil}
        ]

      [section, subsection, id] ->
        [
          %{
            label: section_label(section),
            icon: section_icon(section),
            href: section_href(section)
          },
          %{
            label: section_label(subsection),
            icon: section_icon(subsection),
            href: subsection_href(section, subsection)
          },
          %{label: format_id(id), icon: nil, href: nil}
        ]

      [section, id | _rest] ->
        [
          %{
            label: section_label(section),
            icon: section_icon(section),
            href: section_href(section)
          },
          %{label: format_id(id), icon: nil, href: nil}
        ]
    end
  end

  defp build_breadcrumbs(_), do: []

  defp section_href("diagnostics"), do: "/diagnostics/mtr"
  defp section_href(section), do: "/#{section}"

  defp subsection_href("diagnostics", subsection), do: "/diagnostics/#{subsection}"
  defp subsection_href(section, subsection), do: "/#{section}?tab=#{subsection}"

  # Normalize paths so agents and gateways appear under infrastructure
  defp normalize_infrastructure_path(["agents" | rest]) do
    ["infrastructure", "agents" | rest]
  end

  defp normalize_infrastructure_path(["gateways" | rest]) do
    ["infrastructure", "gateways" | rest]
  end

  defp normalize_infrastructure_path(segments), do: segments

  defp section_label("analytics"), do: "Analytics"
  defp section_label("devices"), do: "Devices"
  defp section_label("infrastructure"), do: "Infrastructure"
  defp section_label("gateways"), do: "Gateways"
  defp section_label("agents"), do: "Agents"
  defp section_label("nodes"), do: "Nodes"
  defp section_label("events"), do: "Events"
  defp section_label("alerts"), do: "Alerts"
  defp section_label("logs"), do: "Logs"
  defp section_label("observability"), do: "Observability"
  defp section_label("services"), do: "Services"
  defp section_label("netflows"), do: "Network Flows"
  defp section_label("admin"), do: "Settings"
  defp section_label("settings"), do: "Settings"
  defp section_label(other), do: String.capitalize(other)

  defp section_icon("analytics"), do: "hero-chart-bar-micro"
  defp section_icon("devices"), do: "hero-server-micro"
  defp section_icon("infrastructure"), do: "hero-cpu-chip-micro"
  defp section_icon("gateways"), do: "hero-cog-6-tooth-micro"
  defp section_icon("agents"), do: "hero-cube-micro"
  defp section_icon("nodes"), do: "hero-server-stack-micro"
  defp section_icon("events"), do: "hero-bell-alert-micro"
  defp section_icon("alerts"), do: "hero-exclamation-triangle-micro"
  defp section_icon("logs"), do: "hero-presentation-chart-line-micro"
  defp section_icon("admin"), do: "hero-adjustments-horizontal-micro"
  defp section_icon("settings"), do: "hero-adjustments-horizontal-micro"
  defp section_icon("observability"), do: "hero-presentation-chart-line-micro"
  defp section_icon("services"), do: "hero-cog-6-tooth-micro"
  defp section_icon("netflows"), do: "hero-arrow-path-micro"
  defp section_icon(_), do: nil

  defp format_id(id) when is_binary(id), do: URI.decode(id)
  defp format_id(id), do: to_string(id)

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr(:flash, :map, required: true, doc: "the map of flash messages")
  attr(:id, :string, default: "flash-group", doc: "the optional id of flash container")

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
